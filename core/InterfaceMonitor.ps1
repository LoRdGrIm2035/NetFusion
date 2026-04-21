<#
.SYNOPSIS
    InterfaceMonitor v5.0 -- Adaptive per-adapter telemetry and health scoring.
.DESCRIPTION
    Provides continuous N-adapter health and throughput telemetry:
      - 1s performance-counter throughput sampling (Rx/Tx/Total)
      - Rolling 5s/30s/60s throughput windows
      - Weighted health score (0.0-1.0) with 0-100 mirror
      - Fast/medium/deep checks with independent cadences
      - Quarantine and instability isolation state machine
      - Rebalance and shared-upstream bottleneck hints
#>

[CmdletBinding()]
param(
    [int]$Interval = 1
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$InterfacesFile = Join-Path $projectDir "config\interfaces.json"
$HealthFile = Join-Path $projectDir "config\health.json"
$LogFile = Join-Path $projectDir "config\throughput.csv"
$EventsFile = Join-Path $projectDir "logs\events.json"

$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

$configPath = Join-Path $projectDir "config\config.json"
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
$pingTarget = if ($config -and $config.healthCheck -and $config.healthCheck.pingTarget) { [string]$config.healthCheck.pingTarget } else { '8.8.8.8' }
$pingTarget2 = if ($config -and $config.healthCheck -and $config.healthCheck.pingTarget2) { [string]$config.healthCheck.pingTarget2 } else { '1.1.1.1' }
$pingTimeout = if ($config -and $config.healthCheck -and $config.healthCheck.timeout) { [int]$config.healthCheck.timeout } else { 1500 }

# Fixed cadences per requirements
$script:fastCheckSec = 3
$script:mediumCheckSec = 10
$script:deepCheckSec = 30
$script:throughputSampleSec = 1

$script:adapterState = @{}
$script:startTime = Get-Date
$script:loopCount = 0
$script:maxCSVLines = if ($config -and $config.logging -and $config.logging.maxCSVLines) { [int]$config.logging.maxCSVLines } else { 2000 }
$script:csvBuffer = [System.Collections.Generic.List[string]]::new()
$script:lastCsvFlush = Get-Date
$script:lastCounterSample = [datetime]::MinValue
$script:lastPublicIpRefresh = [datetime]::MinValue
$script:perfCounterCache = @{}
$script:globalAnomalyCounter = @{}
$script:rebalanceHint = @{}
$script:InterfaceMonitorLogMutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")

function Write-AtomicJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 7
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tmp = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    try {
        $Data | ConvertTo-Json -Depth $Depth -Compress | Set-Content $tmp -Force -Encoding UTF8 -ErrorAction Stop
        Move-Item $tmp $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Repair-EventsFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-AtomicJson -Path $Path -Data @{ events = @() } -Depth 3
        return
    }

    try {
        $existing = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $existing -or -not $existing.events) {
            throw "Invalid event store"
        }
    } catch {
        Write-AtomicJson -Path $Path -Data @{ events = @() } -Depth 3
    }
}

function Write-Event {
    param(
        [string]$Type,
        [string]$Adapter,
        [string]$Message,
        [string]$Level = 'info'
    )

    $evt = @{
        timestamp = (Get-Date).ToString('o')
        type = $Type
        adapter = $Adapter
        message = $Message
        level = $Level
    }

    $mutexTaken = $false
    try {
        try {
            $mutexTaken = $script:InterfaceMonitorLogMutex.WaitOne(3000)
        } catch [System.Threading.AbandonedMutexException] {
            try { Repair-EventsFile -Path $EventsFile } catch {}
            $mutexTaken = $true
        }

        if (-not $mutexTaken) { return }

        try {
            $events = @()
            if (Test-Path $EventsFile) {
                $data = Get-Content $EventsFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($data -and $data.events) { $events = @($data.events) }
            }
            $events = @($evt) + $events
            if ($events.Count -gt 300) { $events = $events[0..299] }
            Write-AtomicJson -Path $EventsFile -Data @{ events = $events } -Depth 4
        } finally {
            if ($mutexTaken) {
                try { $script:InterfaceMonitorLogMutex.ReleaseMutex() } catch {}
            }
        }
    } catch {}
}

function Normalize-InstanceToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value -replace '[^a-zA-Z0-9]', '').ToLowerInvariant())
}

function Ensure-AdapterState {
    param([string]$Name)

    if (-not $script:adapterState.ContainsKey($Name)) {
        $script:adapterState[$Name] = @{
            lastFastCheck = [datetime]::MinValue
            lastMediumCheck = [datetime]::MinValue
            lastDeepCheck = [datetime]::MinValue
            lastGatewayLatency = 999.0
            lastInternetLatency = 999.0
            lastDnsLatency = 999.0
            lastPacketLoss = 100.0
            throughputHistory = [System.Collections.Generic.List[object]]::new()
            lastRxMbps = 0.0
            lastTxMbps = 0.0
            lastTotalMbps = 0.0
            avg5 = 0.0
            avg30 = 0.0
            avg60 = 0.0
            successCount = 0
            failCount = 0
            errorRate = 0.0
            healthySince = [datetime]::UtcNow
            failStreak = 0
            quarantineUntil = $null
            disabledUntil = $null
            failureTimes = [System.Collections.Generic.List[datetime]]::new()
            quarantineCount = 0
            reintroLimit = 0
            lastProbeMbps = 0.0
            lastAnomalyAt = [datetime]::MinValue
            highUtilCount = 0
            lowUtilCount = 0
            publicIp = ''
            publicIpCheckedAt = [datetime]::MinValue
        }
    }

    return $script:adapterState[$Name]
}

function Get-RollingAverage {
    param(
        [System.Collections.Generic.List[object]]$History,
        [int]$WindowSec,
        [string]$Key = 'total'
    )

    if (-not $History -or $History.Count -eq 0) { return 0.0 }
    $cutoff = (Get-Date).AddSeconds(-1 * [math]::Max(1, $WindowSec))
    $vals = @()
    foreach ($row in $History) {
        if ($row.t -ge $cutoff) {
            $vals += [double]$row[$Key]
        }
    }
    if ($vals.Count -eq 0) { return 0.0 }
    return [math]::Round((($vals | Measure-Object -Average).Average), 3)
}

function Test-GatewayLatency {
    param([string]$Gateway)
    if ([string]::IsNullOrWhiteSpace($Gateway)) { return 999.0 }
    try {
        $pinger = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $pinger.Send($Gateway, 1000)
            if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                return [math]::Max(1.0, [double]$reply.RoundtripTime)
            }
        } finally {
            $pinger.Dispose()
        }
    } catch {}
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ar = $tcp.BeginConnect($Gateway, 443, $null, $null)
        $connected = $ar.AsyncWaitHandle.WaitOne(1000, $false)
        if ($connected -and $tcp.Connected) {
            try { $tcp.EndConnect($ar) } catch {}
        }
        $sw.Stop()
        $tcp.Dispose()
        if ($connected) { return [math]::Max(1.0, [double]$sw.ElapsedMilliseconds) }
    } catch {}
    return 999.0
}

function Test-InternetLatency {
    param(
        [string]$SourceIP,
        [string]$Target,
        [int]$Timeout = 1500
    )

    if ([string]::IsNullOrWhiteSpace($SourceIP)) { return 999.0 }

    try {
        $localEndpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($SourceIP), 0)
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Client.Bind($localEndpoint)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ar = $tcp.BeginConnect($Target, 443, $null, $null)
        $connected = $ar.AsyncWaitHandle.WaitOne($Timeout, $false)
        if ($connected -and $tcp.Connected) {
            try { $tcp.EndConnect($ar) } catch {}
        }
        $sw.Stop()
        $tcp.Dispose()
        if ($connected) { return [math]::Max(1.0, [double]$sw.ElapsedMilliseconds) }
    } catch {}

    return 999.0
}

function Test-DnsLatency {
    param(
        [string]$TargetName = 'one.one.one.one'
    )

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Resolve-DnsName -Name $TargetName -Type A -QuickTimeout -ErrorAction Stop | Out-Null
        $sw.Stop()
        $elapsed = [double]$sw.ElapsedMilliseconds
        if ($elapsed -le 0) { $elapsed = 1.0 }
        return $elapsed
    } catch {
        return 999.0
    }
}

function Invoke-ThroughputProbe {
    param(
        [string]$SourceIP,
        [string]$TargetHost = 'speed.cloudflare.com',
        [int]$Bytes = 262144,
        [int]$TimeoutMs = 5000
    )

    if ([string]::IsNullOrWhiteSpace($SourceIP)) { return 0.0 }

    $client = $null
    $stream = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Client.NoDelay = $true
        $client.SendTimeout = $TimeoutMs
        $client.ReceiveTimeout = $TimeoutMs
        $client.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($SourceIP), 0)))
        $ar = $client.BeginConnect($TargetHost, 80, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return 0.0
        }
        try { $client.EndConnect($ar) } catch {}
        if (-not $client.Connected) { return 0.0 }

        $stream = $client.GetStream()
        $request = "GET /__down?bytes=$Bytes&nfprobe=1 HTTP/1.1`r`nHost: $TargetHost`r`nConnection: close`r`n`r`n"
        $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($request)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $stream.Write($reqBytes, 0, $reqBytes.Length)
        $stream.Flush()

        $buffer = New-Object byte[] 32768
        $total = 0
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $total += $read
            if ($total -ge ($Bytes + 2048)) { break }
        }
        $sw.Stop()

        if ($sw.Elapsed.TotalSeconds -le 0 -or $total -le 0) { return 0.0 }
        return [math]::Round((($total * 8.0) / 1000000.0) / $sw.Elapsed.TotalSeconds, 3)
    } catch {
        return 0.0
    } finally {
        try { if ($stream) { $stream.Dispose() } } catch {}
        try { if ($client) { $client.Dispose() } } catch {}
    }
}

function Get-AdapterBoundPublicIP {
    param(
        [string]$SourceIP,
        [int]$TimeoutMs = 3500
    )

    if ([string]::IsNullOrWhiteSpace($SourceIP)) { return '' }

    $client = $null
    $stream = $null
    $reader = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($SourceIP), 0)))
        $client.SendTimeout = $TimeoutMs
        $client.ReceiveTimeout = $TimeoutMs
        $ar = $client.BeginConnect('api.ipify.org', 80, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return '' }
        try { $client.EndConnect($ar) } catch {}
        if (-not $client.Connected) { return '' }

        $stream = $client.GetStream()
        $request = "GET / HTTP/1.1`r`nHost: api.ipify.org`r`nConnection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
        $text = $reader.ReadToEnd()
        if ($text -match "`r`n`r`n(?<ip>\d+\.\d+\.\d+\.\d+)") {
            return [string]$Matches['ip']
        }
        if ($text -match "(?<ip>\d+\.\d+\.\d+\.\d+)") {
            return [string]$Matches['ip']
        }
        return ''
    } catch {
        return ''
    } finally {
        try { if ($reader) { $reader.Dispose() } } catch {}
        try { if ($stream) { $stream.Dispose() } } catch {}
        try { if ($client) { $client.Dispose() } } catch {}
    }
}

function Get-PerformanceCounterSamples {
    param([array]$Interfaces)

    $now = Get-Date
    if (($now - $script:lastCounterSample).TotalSeconds -lt $script:throughputSampleSec -and $script:perfCounterCache.Count -gt 0) {
        return $script:perfCounterCache
    }

    $script:lastCounterSample = $now
    $snapshot = @{}

    try {
        $counterPaths = @(
            '\Network Interface(*)\Bytes Received/sec',
            '\Network Interface(*)\Bytes Sent/sec',
            '\Network Interface(*)\Bytes Total/sec'
        )
        $counter = Get-Counter -Counter $counterPaths -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop

        $instanceMap = @{}
        foreach ($sample in @($counter.CounterSamples)) {
            $inst = [string]$sample.InstanceName
            if (-not $instanceMap.ContainsKey($inst)) {
                $instanceMap[$inst] = @{ rx = 0.0; tx = 0.0; total = 0.0 }
            }
            if ($sample.Path -match 'Bytes Received/sec') {
                $instanceMap[$inst].rx = [double]$sample.CookedValue
            } elseif ($sample.Path -match 'Bytes Sent/sec') {
                $instanceMap[$inst].tx = [double]$sample.CookedValue
            } elseif ($sample.Path -match 'Bytes Total/sec') {
                $instanceMap[$inst].total = [double]$sample.CookedValue
            }
        }

        foreach ($iface in @($Interfaces)) {
            $name = [string]$iface.Name
            $desc = [string]$iface.Description
            $nameTok = Normalize-InstanceToken -Value $name
            $descTok = Normalize-InstanceToken -Value $desc

            $best = $null
            foreach ($entry in $instanceMap.GetEnumerator()) {
                $instTok = Normalize-InstanceToken -Value ([string]$entry.Key)
                if ([string]::IsNullOrWhiteSpace($instTok)) { continue }
                if (
                    ($nameTok -and ($instTok.Contains($nameTok) -or $nameTok.Contains($instTok))) -or
                    ($descTok -and ($instTok.Contains($descTok) -or $descTok.Contains($instTok)))
                ) {
                    $best = $entry.Value
                    break
                }
            }

            if (-not $best) {
                $best = @{ rx = 0.0; tx = 0.0; total = 0.0 }
            }

            $snapshot[$name] = @{
                rxMbps = [math]::Round(([double]$best.rx * 8.0) / 1000000.0, 3)
                txMbps = [math]::Round(([double]$best.tx * 8.0) / 1000000.0, 3)
                totalMbps = [math]::Round(([double]$best.total * 8.0) / 1000000.0, 3)
            }
        }
    } catch {
        foreach ($iface in @($Interfaces)) {
            $snapshot[[string]$iface.Name] = @{ rxMbps = 0.0; txMbps = 0.0; totalMbps = 0.0 }
        }
    }

    $script:perfCounterCache = $snapshot
    return $snapshot
}

function Update-ThroughputState {
    param(
        [hashtable]$Iface,
        [hashtable]$CounterSnapshot
    )

    $name = [string]$Iface.Name
    $state = Ensure-AdapterState -Name $name
    $row = if ($CounterSnapshot.ContainsKey($name)) { $CounterSnapshot[$name] } else { @{ rxMbps = 0.0; txMbps = 0.0; totalMbps = 0.0 } }

    $rx = [double]$row.rxMbps
    $tx = [double]$row.txMbps
    $total = [double]$row.totalMbps

    $state.lastRxMbps = $rx
    $state.lastTxMbps = $tx
    $state.lastTotalMbps = $total

    $entry = [pscustomobject]@{ t = Get-Date; rx = $rx; tx = $tx; total = $total }
    $state.throughputHistory.Add($entry)

    $cutoff = (Get-Date).AddSeconds(-65)
    while ($state.throughputHistory.Count -gt 0 -and $state.throughputHistory[0].t -lt $cutoff) {
        $state.throughputHistory.RemoveAt(0)
    }

    $state.avg5 = Get-RollingAverage -History $state.throughputHistory -WindowSec 5 -Key 'total'
    $state.avg30 = Get-RollingAverage -History $state.throughputHistory -WindowSec 30 -Key 'total'
    $state.avg60 = Get-RollingAverage -History $state.throughputHistory -WindowSec 60 -Key 'total'

    return $state
}

function Compute-LatencyComponent {
    param(
        [double]$GatewayLatency,
        [double]$InternetLatency,
        [double]$DnsLatency
    )

    $gwScore = if ($GatewayLatency -ge 999) { 0.0 } elseif ($GatewayLatency -le 5) { 1.0 } else { [math]::Max(0.0, 1.0 - (($GatewayLatency - 5.0) / 195.0)) }
    $inetScore = if ($InternetLatency -ge 999) { 0.0 } elseif ($InternetLatency -le 20) { 1.0 } else { [math]::Max(0.0, 1.0 - (($InternetLatency - 20.0) / 380.0)) }
    $dnsScore = if ($DnsLatency -ge 999) { 0.0 } elseif ($DnsLatency -le 30) { 1.0 } else { [math]::Max(0.0, 1.0 - (($DnsLatency - 30.0) / 470.0)) }

    return [math]::Round((($gwScore * 0.4) + ($inetScore * 0.45) + ($dnsScore * 0.15)), 4)
}

function Compute-ThroughputComponent {
    param(
        [double]$CurrentMbps,
        [double]$Avg30Mbps,
        [double]$EstimatedCapacityMbps,
        [double]$ProbeMbps
    )

    $capacity = [math]::Max(1.0, $EstimatedCapacityMbps)
    $observed = [math]::Max([math]::Max($CurrentMbps, $Avg30Mbps), $ProbeMbps)

    if ($observed -lt 0.5) {
        # idle adapters should not be considered unhealthy solely due to low traffic
        return 0.75
    }

    $ratio = [math]::Min(1.0, $observed / $capacity)
    return [math]::Round([math]::Max(0.05, $ratio), 4)
}

function Compute-ErrorComponent {
    param(
        [int]$SuccessCount,
        [int]$FailCount
    )

    $total = [math]::Max(1, $SuccessCount + $FailCount)
    $failRate = [double]$FailCount / [double]$total
    return [math]::Round([math]::Max(0.0, 1.0 - $failRate), 4)
}

function Compute-StabilityComponent {
    param(
        [double]$Avg5,
        [double]$Avg30,
        [int]$FailStreak,
        [datetime]$HealthySince
    )

    $variancePenalty = 0.0
    if ($Avg30 -gt 0) {
        $delta = [math]::Abs($Avg5 - $Avg30)
        $variancePenalty = [math]::Min(0.5, $delta / [math]::Max(1.0, $Avg30))
    }

    $uptimeStableBonus = 0.0
    try {
        $stableMinutes = ((Get-Date).ToUniversalTime() - $HealthySince).TotalMinutes
        $uptimeStableBonus = [math]::Min(0.35, [math]::Max(0.0, $stableMinutes / 180.0))
    } catch {}

    $base = 0.65 + $uptimeStableBonus - ([math]::Min(0.5, $FailStreak * 0.12)) - $variancePenalty
    return [math]::Round([math]::Max(0.0, [math]::Min(1.0, $base)), 4)
}

function Compute-SignalComponent {
    param(
        [string]$Type,
        [double]$SignalQuality
    )

    if ($Type -notmatch 'WiFi') { return 1.0 }
    if ($SignalQuality -le 0) { return 0.4 }
    return [math]::Round([math]::Max(0.0, [math]::Min(1.0, $SignalQuality / 100.0)), 4)
}

function Update-QuarantineState {
    param(
        [string]$Name,
        [hashtable]$State,
        [double]$Health01,
        [bool]$GatewayOk,
        [bool]$InternetOk
    )

    $now = Get-Date
    $isFailure = ($Health01 -lt 0.3) -or (-not $GatewayOk -and -not $InternetOk)

    if ($State.disabledUntil -and $State.disabledUntil -gt $now) {
        return
    }

    if ($isFailure) {
        $State.failStreak = [int]$State.failStreak + 1
        $State.failCount = [int]$State.failCount + 1
        $State.failureTimes.Add($now)

        $cutoff30 = $now.AddMinutes(-30)
        while ($State.failureTimes.Count -gt 0 -and $State.failureTimes[0] -lt $cutoff30) {
            $State.failureTimes.RemoveAt(0)
        }

        if ($State.failStreak -ge 3 -and (-not $State.quarantineUntil -or $State.quarantineUntil -le $now)) {
            $recentFailure = $false
            $cutoff5 = $now.AddMinutes(-5)
            foreach ($t in @($State.failureTimes)) {
                if ($t -gt $cutoff5 -and $t -lt $now) {
                    $recentFailure = $true
                    break
                }
            }

            $qSec = if ($recentFailure) { 300 } else { 60 }
            $State.quarantineUntil = $now.AddSeconds($qSec)
            $State.quarantineCount = [int]$State.quarantineCount + 1
            $State.reintroLimit = 0
            Write-Event -Type 'quarantine' -Adapter $Name -Message "$Name quarantined for $qSec seconds after consecutive failures." -Level 'warn'
        }

        if ($State.failureTimes.Count -ge 5) {
            # RC-7: Check if disabling this adapter would leave zero active adapters
            $otherActive = $false
            foreach ($otherName in $script:adapterState.Keys) {
                if ($otherName -eq $Name) { continue }
                $otherState = $script:adapterState[$otherName]
                $otherDisabled = ($otherState.disabledUntil -and $otherState.disabledUntil -gt $now)
                $otherQuarantined = ($otherState.quarantineUntil -and $otherState.quarantineUntil -gt $now)
                if (-not $otherDisabled -and -not $otherQuarantined) {
                    $otherActive = $true
                    break
                }
            }

            if (-not $otherActive) {
                # RC-7: NEVER disable the last remaining adapter -- keep internet alive
                $State.failStreak = 0
                $State.quarantineUntil = $now.AddSeconds(60)
                $State.reintroLimit = 0
                Write-Event -Type 'quarantine' -Adapter $Name -Message "$Name has 5 failures but is the LAST active adapter. Short quarantine only (60s) to keep internet alive." -Level 'warn'
            } else {
                # RC-7: Use 30-minute disable instead of permanent -- auto-recovers
                $State.disabledUntil = $now.AddMinutes(30)
                $State.quarantineUntil = $null
                $State.reintroLimit = 0
                Write-Event -Type 'quarantine' -Adapter $Name -Message "$Name disabled for 30 minutes after 5 failures. Will auto-recover." -Level 'error'
            }
        }
    } else {
        $State.successCount = [int]$State.successCount + 1
        $State.failStreak = 0

        if ($State.quarantineUntil -and $State.quarantineUntil -le $now) {
            # gradual re-introduction: 1 flow then 2 then normal
            if ($State.reintroLimit -lt 1) {
                $State.reintroLimit = 1
            } elseif ($State.reintroLimit -lt 2) {
                $State.reintroLimit = 2
            } else {
                $State.reintroLimit = 0
                $State.quarantineUntil = $null
            }
        }

        if (-not $State.healthySince) {
            $State.healthySince = [datetime]::UtcNow
        }
    }

    $totalChecks = [math]::Max(1, $State.successCount + $State.failCount)
    $State.errorRate = [math]::Round(([double]$State.failCount / [double]$totalChecks), 4)
}

function Measure-InterfaceHealth {
    param(
        [hashtable]$Iface,
        [hashtable]$CounterSnapshot
    )

    $name = [string]$Iface.Name
    $state = Update-ThroughputState -Iface $Iface -CounterSnapshot $CounterSnapshot
    $now = Get-Date

    $ip = if ($Iface.PrimaryIPv4) { [string]$Iface.PrimaryIPv4 } elseif ($Iface.IPAddress) { [string]$Iface.IPAddress } else { '' }
    $gateway = if ($Iface.Gateway) { [string]$Iface.Gateway } else { '' }
    $dnsServers = @()
    if ($Iface.DNSServers) { $dnsServers = @($Iface.DNSServers) }
    $estimatedCapacity = if ($Iface.EstimatedCapacityMbps) { [double]$Iface.EstimatedCapacityMbps } else { [math]::Max(30.0, [double]$Iface.LinkSpeedMbps * 0.6) }

    # Fast check every 3s (gateway)
    if (($now - $state.lastFastCheck).TotalSeconds -ge $script:fastCheckSec) {
        $state.lastGatewayLatency = Test-GatewayLatency -Gateway $gateway
        $state.lastFastCheck = $now
    }

    # Medium check every 10s (internet + DNS)
    if (($now - $state.lastMediumCheck).TotalSeconds -ge $script:mediumCheckSec) {
        $lat = Test-InternetLatency -SourceIP $ip -Target $pingTarget -Timeout $pingTimeout
        if ($lat -ge 999) {
            $lat = Test-InternetLatency -SourceIP $ip -Target $pingTarget2 -Timeout $pingTimeout
        }
        $state.lastInternetLatency = $lat

        $state.lastDnsLatency = Test-DnsLatency
        $state.lastMediumCheck = $now
    }

    # Deep check every 30s only if adapter is idle
    if (($now - $state.lastDeepCheck).TotalSeconds -ge $script:deepCheckSec) {
        if ($state.lastTotalMbps -lt 1.0) {
            $state.lastProbeMbps = Invoke-ThroughputProbe -SourceIP $ip
        }
        $state.lastDeepCheck = $now
    }

    $gatewayOk = $state.lastGatewayLatency -lt 999
    $internetOk = $state.lastInternetLatency -lt 999

    if (-not $gatewayOk -and -not $internetOk) {
        $state.lastPacketLoss = 100.0
    } elseif (-not $internetOk) {
        $state.lastPacketLoss = 50.0
    } else {
        $state.lastPacketLoss = 0.0
    }

    $latencyComp = Compute-LatencyComponent -GatewayLatency $state.lastGatewayLatency -InternetLatency $state.lastInternetLatency -DnsLatency $state.lastDnsLatency
    $throughputComp = Compute-ThroughputComponent -CurrentMbps $state.lastTotalMbps -Avg30Mbps $state.avg30 -EstimatedCapacityMbps $estimatedCapacity -ProbeMbps $state.lastProbeMbps
    $errorComp = Compute-ErrorComponent -SuccessCount $state.successCount -FailCount $state.failCount
    $stabilityComp = Compute-StabilityComponent -Avg5 $state.avg5 -Avg30 $state.avg30 -FailStreak $state.failStreak -HealthySince $state.healthySince
    $signalComp = Compute-SignalComponent -Type ([string]$Iface.Type) -SignalQuality ([double]$Iface.SignalQuality)

    $health01 =
        ($latencyComp * 0.30) +
        ($throughputComp * 0.30) +
        ($errorComp * 0.20) +
        ($stabilityComp * 0.10) +
        ($signalComp * 0.10)
    $health01 = [math]::Max(0.0, [math]::Min(1.0, [math]::Round($health01, 4)))

    Update-QuarantineState -Name $name -State $state -Health01 $health01 -GatewayOk $gatewayOk -InternetOk $internetOk

    $isDisabled = $false
    if ($state.disabledUntil -and $state.disabledUntil -gt $now) {
        $isDisabled = $true
        $health01 = 0.0
    }

    $isQuarantined = $false
    if ($state.quarantineUntil -and $state.quarantineUntil -gt $now) {
        $isQuarantined = $true
        $health01 = [math]::Min($health01, 0.2)
    }

    $healthScore = [int][math]::Round($health01 * 100.0)

    $utilizationPct = 0.0
    if ($estimatedCapacity -gt 0) {
        $utilizationPct = [math]::Round(([math]::Min(1.0, [math]::Max(0.0, $state.lastTotalMbps / $estimatedCapacity)) * 100.0), 2)
    }

    # congestion hint counters
    if ($utilizationPct -ge 90) {
        $state.highUtilCount = [int]$state.highUtilCount + 1
    } else {
        $state.highUtilCount = 0
    }
    if ($utilizationPct -le 50) {
        $state.lowUtilCount = [int]$state.lowUtilCount + 1
    } else {
        $state.lowUtilCount = 0
    }

    # anomaly detection
    if ($state.avg30 -ge 20 -and $state.lastTotalMbps -lt ($state.avg30 * 0.4)) {
        if (($now - $state.lastAnomalyAt).TotalSeconds -gt 30) {
            $state.lastAnomalyAt = $now
            Write-Event -Type 'anomaly' -Adapter $name -Message "$name throughput dropped sharply ($($state.lastTotalMbps) Mbps vs avg30=$($state.avg30) Mbps)." -Level 'warn'
        }
    }

    $status = 'offline'
    if ($isDisabled) {
        $status = 'disabled'
    } elseif ($isQuarantined) {
        $status = 'quarantined'
    } elseif ($health01 -gt 0.8) {
        $status = 'healthy'
    } elseif ($health01 -ge 0.5) {
        $status = 'degraded'
    } elseif ($health01 -ge 0.3) {
        $status = 'poor'
    } elseif ($health01 -gt 0.0) {
        $status = 'failing'
    }

    $shouldAvoidNew = $isDisabled -or $isQuarantined -or ($health01 -lt 0.5)
    $forceDrain = $health01 -lt 0.3

    $throughputHistory = @($state.throughputHistory | Select-Object -Last 60 | ForEach-Object {
        @{ t = $_.t.ToString('HH:mm:ss'); rx = [double]$_.rx; tx = [double]$_.tx; total = [double]$_.total }
    })

    return @{
        Name = $name
        Type = $Iface.Type
        InterfaceIndex = $Iface.InterfaceIndex
        IPAddress = $ip
        Gateway = $gateway
        GatewayLatency = [math]::Round([double]$state.lastGatewayLatency, 2)
        InternetLatency = [math]::Round([double]$state.lastInternetLatency, 2)
        DNSLatency = [math]::Round([double]$state.lastDnsLatency, 2)
        PacketLoss = [math]::Round([double]$state.lastPacketLoss, 2)
        DownloadMbps = [math]::Round([double]$state.lastRxMbps, 3)
        UploadMbps = [math]::Round([double]$state.lastTxMbps, 3)
        ThroughputMbps = [math]::Round([double]$state.lastTotalMbps, 3)
        ThroughputAvg5 = [math]::Round([double]$state.avg5, 3)
        ThroughputAvg30 = [math]::Round([double]$state.avg30, 3)
        ThroughputAvg60 = [math]::Round([double]$state.avg60, 3)
        ThroughputHistory = $throughputHistory
        EstimatedCapacityMbps = [math]::Round([double]$estimatedCapacity, 3)
        UtilizationPct = [double]$utilizationPct
        ProbeThroughputMbps = [math]::Round([double]$state.lastProbeMbps, 3)
        HealthLatencyComponent = [double]$latencyComp
        HealthThroughputComponent = [double]$throughputComp
        HealthErrorComponent = [double]$errorComp
        HealthStabilityComponent = [double]$stabilityComp
        HealthSignalComponent = [double]$signalComp
        HealthScore01 = [double]$health01
        HealthScore = $healthScore
        Status = $status
        ErrorRate = [double]$state.errorRate
        SuccessRate = [math]::Round((1.0 - [double]$state.errorRate) * 100.0, 2)
        StabilityScore = [math]::Round([double]$stabilityComp * 100.0, 2)
        HealthTrend = [math]::Round(([double]$state.avg5 - [double]$state.avg30), 3)
        IsDegrading = [bool]($state.avg30 -gt 0 -and $state.avg5 -lt ($state.avg30 * 0.65))
        IsQuarantined = [bool]$isQuarantined
        QuarantineUntil = if ($state.quarantineUntil) { ([datetime]$state.quarantineUntil).ToString('o') } else { $null }
        IsDisabled = [bool]$isDisabled
        DisabledUntil = if ($state.disabledUntil) { ([datetime]$state.disabledUntil).ToString('o') } else { $null }
        ReintroLimitFlows = [int]$state.reintroLimit
        ShouldAvoidNewFlows = [bool]$shouldAvoidNew
        ForceDrain = [bool]$forceDrain
        ConsecutiveFailures = [int]$state.failStreak
        QuarantineCount = [int]$state.quarantineCount
        PublicIP = [string]$state.publicIp
        SignalQuality = if ($Iface.SignalQuality) { [double]$Iface.SignalQuality } else { 0.0 }
        LinkSpeedMbps = if ($Iface.LinkSpeedMbps) { [double]$Iface.LinkSpeedMbps } else { 0.0 }
        SSID = if ($Iface.SSID) { [string]$Iface.SSID } else { '' }
        DNSServers = $dnsServers
    }
}

function Get-SharedBottleneckState {
    param([array]$Adapters)

    $active = @($Adapters | Where-Object { $_.Status -notin @('offline', 'disabled') })
    if ($active.Count -le 1) {
        return @{ detected = $false; reason = 'insufficient_active_adapters'; sameGateway = $false; samePublicIp = $false }
    }

    $combined = [double](($active | Measure-Object -Property ThroughputMbps -Sum).Sum)
    $maxSingle = [double](($active | Measure-Object -Property ThroughputMbps -Maximum).Maximum)

    $gateways = @($active | ForEach-Object { [string]$_.Gateway } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $sameGateway = $gateways.Count -eq 1

    $ips = @($active | ForEach-Object { [string]$_.PublicIP } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $samePublicIp = $ips.Count -eq 1 -and $ips.Count -gt 0

    $throughputPlateau = $false
    if ($maxSingle -gt 5) {
        $throughputPlateau = $combined -le ($maxSingle * 1.2)
    }

    $detected = ($throughputPlateau -and ($sameGateway -or $samePublicIp))
    $reason = if ($detected) {
        "combined_throughput_close_to_single_adapter"
    } elseif ($throughputPlateau) {
        "throughput_plateau_without_gateway_or_publicip_match"
    } else {
        "no_shared_bottleneck_signature"
    }

    return @{
        detected = [bool]$detected
        reason = $reason
        sameGateway = [bool]$sameGateway
        samePublicIp = [bool]$samePublicIp
        combinedMbps = [math]::Round($combined, 3)
        maxSingleMbps = [math]::Round($maxSingle, 3)
        combinedThroughputMbps = [math]::Round($combined, 3)
        maxSingleThroughputMbps = [math]::Round($maxSingle, 3)
        ratioCombinedToSingle = if ($maxSingle -gt 0) { [math]::Round($combined / $maxSingle, 4) } else { 0.0 }
    }
}

function Update-RebalanceHint {
    param([array]$Adapters)

    $hint = @{ trigger = $false; overUtilized = @(); underUtilized = @(); reason = '' }
    if (-not $Adapters -or $Adapters.Count -le 1) { return $hint }

    $healthy = @($Adapters | Where-Object { $_.Status -in @('healthy', 'degraded', 'poor') -and -not $_.IsQuarantined -and -not $_.IsDisabled })
    if ($healthy.Count -le 1) { return $hint }

    $over = @($healthy | Where-Object { $_.UtilizationPct -ge 80 })
    $under = @($healthy | Where-Object { $_.UtilizationPct -le 20 })

    if ($over.Count -gt 0 -and $under.Count -gt 0) {
        $hint.trigger = $true
        $hint.overUtilized = @($over | ForEach-Object { $_.Name })
        $hint.underUtilized = @($under | ForEach-Object { $_.Name })
        $hint.reason = 'utilization_imbalance_over80_under20'
    }

    return $hint
}

function Rotate-CSVLog {
    if (-not (Test-Path $LogFile)) { return }
    try {
        $lines = Get-Content $LogFile -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt $script:maxCSVLines) {
            $header = $lines[0]
            $kept = $lines[([math]::Max(1, $lines.Count - 1000))..($lines.Count - 1)]
            @($header) + $kept | Set-Content $LogFile -Encoding UTF8 -Force
        }
    } catch {}
}

function Flush-CsvBuffer {
    if ($script:csvBuffer.Count -eq 0) { return }
    try {
        Add-Content -Path $LogFile -Value @($script:csvBuffer) -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
    $script:csvBuffer.Clear()
}

if (-not (Test-Path $LogFile)) {
    "Timestamp,Adapter,DownloadMbps,UploadMbps,ThroughputMbps,Avg5,Avg30,Avg60,GatewayLatency,InternetLatency,DNSLatency,PacketLoss,Health01,HealthScore,UtilizationPct,Status,ErrorRate,Quarantined,Disabled" | Set-Content $LogFile -Encoding UTF8
}

Write-Host ""
Write-Host "  [InterfaceMonitor v5.0] Adaptive health monitoring every ${Interval}s" -ForegroundColor Yellow
Write-Host "  Throughput counters: 1s | Fast/Medium/Deep checks: 3s/10s/30s" -ForegroundColor DarkGray
Write-Host "  Health model: latency(30) + throughput(30) + errors(20) + stability(10) + signal(10)" -ForegroundColor DarkGray
Write-Host ""

function Update-HealthState {
    try {
        if (-not (Test-Path $InterfacesFile)) {
            return $null
        }

        $ifaceData = Get-Content $InterfacesFile -Raw | ConvertFrom-Json
        $ifaces = @($ifaceData.interfaces)
        if ($ifaces.Count -eq 0) {
            return @{
                timestamp = (Get-Date).ToString('o')
                version = '5.0'
                uptime = [math]::Round(((Get-Date) - $script:startTime).TotalMinutes, 2)
                adapters = @()
                rebalance = @{ trigger = $false }
                upstreamBottleneck = @{ detected = $false; reason = 'no_adapters' }
            }
        }

        $counterSnapshot = Get-PerformanceCounterSamples -Interfaces $ifaces
        $healthResults = @()

        foreach ($iface in $ifaces) {
            $ifHash = @{}
            $iface.PSObject.Properties | ForEach-Object { $ifHash[$_.Name] = $_.Value }
            $health = Measure-InterfaceHealth -Iface $ifHash -CounterSnapshot $counterSnapshot
            $healthResults += $health

            $script:csvBuffer.Add("$(Get-Date -Format 'o'),$($health.Name),$($health.DownloadMbps),$($health.UploadMbps),$($health.ThroughputMbps),$($health.ThroughputAvg5),$($health.ThroughputAvg30),$($health.ThroughputAvg60),$($health.GatewayLatency),$($health.InternetLatency),$($health.DNSLatency),$($health.PacketLoss),$($health.HealthScore01),$($health.HealthScore),$($health.UtilizationPct),$($health.Status),$($health.ErrorRate),$($health.IsQuarantined),$($health.IsDisabled)") | Out-Null
        }

        # Refresh adapter-bound public IPs every 2 minutes for bottleneck diagnostics
        if (((Get-Date) - $script:lastPublicIpRefresh).TotalSeconds -ge 120) {
            foreach ($item in $healthResults) {
                $state = Ensure-AdapterState -Name ([string]$item.Name)
                $sourceIp = [string]$item.IPAddress
                if (-not [string]::IsNullOrWhiteSpace($sourceIp) -and -not $item.IsDisabled) {
                    $ip = Get-AdapterBoundPublicIP -SourceIP $sourceIp
                    if ($ip) {
                        $state.publicIp = $ip
                        $state.publicIpCheckedAt = Get-Date
                    }
                }
            }
            $script:lastPublicIpRefresh = Get-Date
        }

        foreach ($item in $healthResults) {
            $state = Ensure-AdapterState -Name ([string]$item.Name)
            if ($state.publicIp) {
                $item.PublicIP = [string]$state.publicIp
            }
        }

        $rebalance = Update-RebalanceHint -Adapters $healthResults
        if ($rebalance.trigger) {
            $newSig = (($rebalance.overUtilized -join ',') + '|' + ($rebalance.underUtilized -join ','))
            if (-not $script:rebalanceHint.signature -or $script:rebalanceHint.signature -ne $newSig) {
                Write-Event -Type 'rebalance' -Adapter '' -Message "Rebalance hint: over-utilized [$($rebalance.overUtilized -join ', ')] under-utilized [$($rebalance.underUtilized -join ', ')]" -Level 'info'
            }
            $script:rebalanceHint = @{ signature = $newSig; at = (Get-Date).ToString('o') }
        }

        $upstreamBottleneck = Get-SharedBottleneckState -Adapters $healthResults
        if ($upstreamBottleneck.detected) {
            $sig = "bottleneck:$($upstreamBottleneck.reason):$($upstreamBottleneck.sameGateway):$($upstreamBottleneck.samePublicIp)"
            if (-not $script:globalAnomalyCounter.ContainsKey($sig)) {
                Write-Event -Type 'bottleneck' -Adapter '' -Message "Potential shared upstream bottleneck detected (reason=$($upstreamBottleneck.reason), sameGateway=$($upstreamBottleneck.sameGateway), samePublicIp=$($upstreamBottleneck.samePublicIp))." -Level 'warn'
            }
            $script:globalAnomalyCounter[$sig] = (Get-Date).ToString('o')
        }

        $healthOutput = @{
            timestamp = (Get-Date).ToString('o')
            version = '5.0'
            uptime = [math]::Round(((Get-Date) - $script:startTime).TotalMinutes, 2)
            adapters = $healthResults
            rebalance = $rebalance
            upstreamBottleneck = $upstreamBottleneck
            checkCadenceSec = @{
                throughputSample = $script:throughputSampleSec
                fast = $script:fastCheckSec
                medium = $script:mediumCheckSec
                deep = $script:deepCheckSec
            }
        }

        Write-AtomicJson -Path $HealthFile -Data $healthOutput -Depth 8

        $script:loopCount++
        if (($script:loopCount % 5) -eq 0 -or ((Get-Date) - $script:lastCsvFlush).TotalSeconds -ge 5) {
            Flush-CsvBuffer
            $script:lastCsvFlush = Get-Date
        }

        if (($script:loopCount % 50) -eq 0) {
            Rotate-CSVLog
            try { & (Join-Path $projectDir "core\LogRotation.ps1") } catch {}
        }

        return $healthOutput
    } catch {
        Write-Host "  [InterfaceMonitor] Error: $_" -ForegroundColor Red
        return $null
    }
}
