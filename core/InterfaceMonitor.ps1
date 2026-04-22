<#
.SYNOPSIS
    InterfaceMonitor v4.0 -- Intelligent adaptive health monitoring with predictive analytics.
.DESCRIPTION
    Production-grade health monitoring with:
      - EWMA (Exponential Weighted Moving Average) smoothed latency
      - Jitter tracking via rolling window variance
      - Rolling statistics engine (min/max/avg/p95)
      - Connection success rate tracking
      - Predictive degradation detection with trend analysis
      - Preemptive rerouting signals
      - Enhanced multi-factor health scoring
    Multi-method health detection:
      1. Direct gateway ping (most reliable)
      2. Internet ping with source binding
      3. DNS resolution test
      4. Bandwidth-based health (if data flows, adapter is alive)
    Writes enriched health data to shared JSON for proxy/router consumption.
#>

[CmdletBinding()]
param(
    [int]$Interval = 15
)

# Resolve paths
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$InterfacesFile = Join-Path $projectDir "config\interfaces.json"
$HealthFile = Join-Path $projectDir "config\health.json"
$LogFile = Join-Path $projectDir "config\throughput.csv"
$EventsFile = Join-Path $projectDir "logs\events.json"

# Ensure logs dir exists
$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

# Load config
$configPath = Join-Path $projectDir "config\config.json"
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
$pingTarget = if ($config -and $config.healthCheck -and $config.healthCheck.pingTarget) { $config.healthCheck.pingTarget } else { '8.8.8.8' }
$pingTarget2 = '1.1.1.1'
$pingTimeout = if ($config -and $config.healthCheck -and $config.healthCheck.timeout) { $config.healthCheck.timeout } else { 1500 }
# NetFusion-FIX: 11 - Slow the primary health cadence down to a 10s TCP probe and reserve full latency/jitter sampling for 60s intervals.
$script:healthPrimaryIntervalSeconds = if ($config -and $config.healthCheck -and $config.healthCheck.primaryIntervalSeconds) { [Math]::Max(10, [int]$config.healthCheck.primaryIntervalSeconds) } else { 10 }
$script:healthFullMeasurementIntervalSeconds = if ($config -and $config.healthCheck -and $config.healthCheck.fullMeasurementIntervalSeconds) { [Math]::Max(30, [int]$config.healthCheck.fullMeasurementIntervalSeconds) } else { 60 }
$script:tcpProbeTarget = if ($config -and $config.healthCheck -and $config.healthCheck.tcpTarget) { [string]$config.healthCheck.tcpTarget } else { '1.1.1.1' }
$script:tcpProbeTarget2 = if ($config -and $config.healthCheck -and $config.healthCheck.tcpTarget2) { [string]$config.healthCheck.tcpTarget2 } else { '1.0.0.1' }
$script:tcpProbePort = if ($config -and $config.healthCheck -and $config.healthCheck.tcpPort) { [int]$config.healthCheck.tcpPort } else { 80 }

# Intelligence config
$script:defaultEwmaAlpha = 0.30
$script:ewmaAlphaMap = @{}
$jitterWindowSize = if ($config -and $config.intelligence -and $config.intelligence.jitterWindow) { $config.intelligence.jitterWindow } else { 30 }
$healthTrendWindow = if ($config -and $config.intelligence -and $config.intelligence.healthTrendWindow) { $config.intelligence.healthTrendWindow } else { 20 }
$degradationThreshold = if ($config -and $config.intelligence -and $config.intelligence.degradationThreshold) { $config.intelligence.degradationThreshold } else { -2.0 }

# ===== State Tracking =====
$script:prevBytes = @{}     # @{ name = @{ rx=N; tx=N; time=[DateTime] } }
$script:startTime = Get-Date
$script:events = @()
$script:prevStates = @{}
$script:maxCSVLines = 2000

# v4.0 Intelligence State
$script:latencyHistory = @{}        # Rolling latency samples per adapter: @{ name = @(samples) }
$script:ewmaLatency = @{}           # EWMA-smoothed latency per adapter: @{ name = [double] }
$script:ewmaGwLatency = @{}         # EWMA-smoothed gateway latency per adapter
$script:jitterValues = @{}          # Computed jitter per adapter
$script:healthTrend = @{}           # Rolling health scores for trend: @{ name = @(scores) }
$script:successRates = @{}          # Success/fail tracking: @{ name = @{ success=N; fail=N; rate=0.0 } }
$script:degradationWarnings = @{}   # Predictive warnings: @{ name = @{ warned=$bool; trend=$val; since=$time } }
$script:stabilityScores = @{}       # Health variance tracking for stability: @{ name = [double] }
$script:lastHealthOutput = $null
$script:lastHealthRun = $null
$script:lastFullHealthRun = $null
$script:lastHealthByAdapter = @{}
$script:InterfaceMonitorLogMutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")

function Write-AtomicJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 4
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

function Get-ConfiguredEwmaAlphaMap {
    param($LiveConfig)

    $map = @{
        gaming     = 0.65
        streaming  = 0.25
        bulk       = 0.15
        interactive = 0.45
        default    = $script:defaultEwmaAlpha
    }

    if ($LiveConfig -and $LiveConfig.intelligence -and $LiveConfig.intelligence.ewmaAlphas) {
        $LiveConfig.intelligence.ewmaAlphas.PSObject.Properties | ForEach-Object {
            $value = 0.0
            if ([double]::TryParse([string]$_.Value, [ref]$value) -and $value -gt 0 -and $value -lt 1) {
                $map[$_.Name] = $value
            }
        }
    }

    return $map
}

function Get-EwmaAlphaForMode {
    param([string]$Mode = 'default')

    $normalizedMode = if ([string]::IsNullOrWhiteSpace($Mode)) { 'default' } else { $Mode.ToLowerInvariant() }
    $modeKey = switch ($normalizedMode) {
        'balanced' { 'interactive'; break }
        'download' { 'bulk'; break }
        'maxspeed' { 'bulk'; break }
        default { $normalizedMode }
    }

    if ($script:ewmaAlphaMap.ContainsKey($modeKey)) {
        return [double]$script:ewmaAlphaMap[$modeKey]
    }
    if ($script:ewmaAlphaMap.ContainsKey('default')) {
        return [double]$script:ewmaAlphaMap['default']
    }
    return $script:defaultEwmaAlpha
}

$script:ewmaAlphaMap = Get-ConfiguredEwmaAlphaMap -LiveConfig $config

function Write-Event {
    param([string]$Type, [string]$Adapter, [string]$Message)
    $evt = @{
        timestamp = (Get-Date).ToString('o')
        type      = $Type
        adapter   = $Adapter
        message   = $Message
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
            $fileEvents = @()
            if (Test-Path $EventsFile) {
                $data = Get-Content $EventsFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($data -and $data.events) { $fileEvents = @($data.events) }
            }
            $fileEvents = @($evt) + $fileEvents
            if ($fileEvents.Count -gt 200) { $fileEvents = $fileEvents[0..199] }

            Write-AtomicJson -Path $EventsFile -Data @{ events = $fileEvents } -Depth 3
        } finally {
            if ($mutexTaken) {
                try { $script:InterfaceMonitorLogMutex.ReleaseMutex() } catch {}
            }
        }
    } catch {}
}

# ===== Latency Testing =====

function Test-GatewayLatency {
    param([string]$Gateway)
    if (-not $Gateway) { return 999 }
    try {
        $result = ping.exe -n 1 -w 1000 $Gateway 2>$null
        $joined = $result -join "`n"
        if ($joined -match 'time[=<](\d+)\s*ms') { return [int]$Matches[1] }
        if ($joined -match 'time[=<](\d+)') { return [int]$Matches[1] }
        if ($joined -match 'Reply from') { return 1 }
    } catch {}
    return 999
}

function Test-InternetLatency {
    param([string]$SourceIP, [string]$Target, [int]$Timeout)
    # Method 1: ping with source binding
    try {
        $result = ping.exe -S $SourceIP -n 1 -w $Timeout $Target 2>$null
        $joined = $result -join "`n"
        if ($joined -match 'time[=<](\d+)\s*ms') { return [int]$Matches[1] }
        if ($joined -match 'time[=<](\d+)') { return [int]$Matches[1] }
        if ($joined -match 'Reply from') { return 1 }
    } catch {}

    # Method 2: plain ping (no source binding)
    try {
        $result = ping.exe -n 1 -w $Timeout $Target 2>$null
        $joined = $result -join "`n"
        if ($joined -match 'time[=<](\d+)\s*ms') { return [int]$Matches[1] }
        if ($joined -match 'time[=<](\d+)') { return [int]$Matches[1] }
        if ($joined -match 'Reply from') { return 1 }
    } catch {}

    # Method 3: TCP connect test to DNS port
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.ReceiveBufferSize = 524288
        $tcp.SendBufferSize = 524288
        $asyncResult = $tcp.BeginConnect($Target, 53, $null, $null)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $connected = $asyncResult.AsyncWaitHandle.WaitOne($Timeout, $false)
        $sw.Stop()
        $tcp.Close()
        if ($connected) { return [math]::Max(1, [int]$sw.ElapsedMilliseconds) }
    } catch {}

    return 999
}

function Test-BoundTcpLatency {
    param(
        [string]$SourceIP,
        [string]$Target,
        [int]$Port,
        [int]$Timeout
    )

    if ([string]::IsNullOrWhiteSpace($SourceIP) -or [string]::IsNullOrWhiteSpace($Target)) {
        return 999
    }

    try {
        $tcp = [System.Net.Sockets.TcpClient]::new([System.Net.Sockets.AddressFamily]::InterNetwork)
        $tcp.NoDelay = $true
        $tcp.ReceiveBufferSize = 1048576
        $tcp.SendBufferSize = 1048576
        $tcp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($SourceIP), 0))

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $asyncResult = $tcp.BeginConnect($Target, $Port, $null, $null)
        $connected = $asyncResult.AsyncWaitHandle.WaitOne($Timeout, $false)
        $sw.Stop()

        if ($connected -and $tcp.Connected) {
            try { $tcp.EndConnect($asyncResult) } catch {}
            $tcp.Close()
            return [math]::Max(1, [int]$sw.ElapsedMilliseconds)
        }

        $tcp.Close()
    } catch {}

    return 999
}

# ===== v4.0 Intelligence Functions =====

function Update-EWMALatency {
    <# Smooth latency using Exponential Weighted Moving Average to prevent single spikes from causing routing changes. #>
    param([string]$Name, [double]$RawLatency, [string]$Type, [string]$Mode = 'default')

    $store = if ($Type -eq 'gateway') { $script:ewmaGwLatency } else { $script:ewmaLatency }
    $alpha = Get-EwmaAlphaForMode -Mode $Mode

    if ($store.ContainsKey($Name) -and $store[$Name] -lt 998) {
        $prev = $store[$Name]
        if ($RawLatency -ge 999) {
            # Timeout: don't fully switch, increase gradually
            $store[$Name] = [math]::Min(999, $prev + ($alpha * (999 - $prev)))
        } else {
            $store[$Name] = ($alpha * $RawLatency) + ((1 - $alpha) * $prev)
        }
    } else {
        $store[$Name] = $RawLatency
    }

    if ($Type -eq 'gateway') { $script:ewmaGwLatency = $store } else { $script:ewmaLatency = $store }
    return [math]::Round($store[$Name], 1)
}

function Update-LatencyHistory {
    <# Maintain rolling window of raw latency samples for jitter calculation. #>
    param([string]$Name, [double]$RawLatency)

    if (-not $script:latencyHistory.ContainsKey($Name)) {
        $script:latencyHistory[$Name] = [System.Collections.Generic.List[double]]::new()
    }
    $history = $script:latencyHistory[$Name]
    if ($RawLatency -lt 999) {
        $history.Add($RawLatency)
    }
    while ($history.Count -gt $jitterWindowSize) {
        $history.RemoveAt(0)
    }
}

function Measure-Jitter {
    <# Compute jitter as standard deviation of latency samples in rolling window. Low jitter = stable connection. #>
    param([string]$Name)

    if (-not $script:latencyHistory.ContainsKey($Name)) { return 0.0 }
    $samples = $script:latencyHistory[$Name]
    if ($samples.Count -lt 3) { return 0.0 }

    $avg = ($samples | Measure-Object -Average).Average
    $variance = 0.0
    foreach ($s in $samples) {
        $variance += ($s - $avg) * ($s - $avg)
    }
    $variance /= $samples.Count
    $jitter = [math]::Round([math]::Sqrt($variance), 2)
    $script:jitterValues[$Name] = $jitter
    return $jitter
}

function Update-HealthTrend {
    <# Track health score history for trend analysis. Returns slope of recent health scores. #>
    param([string]$Name, [double]$HealthScore)

    if (-not $script:healthTrend.ContainsKey($Name)) {
        $script:healthTrend[$Name] = [System.Collections.Generic.List[double]]::new()
    }
    $trend = $script:healthTrend[$Name]
    $trend.Add($HealthScore)
    while ($trend.Count -gt $healthTrendWindow) {
        $trend.RemoveAt(0)
    }

    # Calculate linear regression slope
    if ($trend.Count -lt 5) { return 0.0 }
    $n = $trend.Count
    $sumX = 0.0; $sumY = 0.0; $sumXY = 0.0; $sumX2 = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $sumX += $i
        $sumY += $trend[$i]
        $sumXY += $i * $trend[$i]
        $sumX2 += $i * $i
    }
    $denom = ($n * $sumX2) - ($sumX * $sumX)
    if ([math]::Abs($denom) -lt 0.001) { return 0.0 }
    $slope = [math]::Round((($n * $sumXY) - ($sumX * $sumY)) / $denom, 3)
    return $slope
}

function Test-PredictiveDegradation {
    <# Detect declining health trend and flag adapter for preemptive rerouting. #>
    param([string]$Name, [double]$Slope, [double]$CurrentHealth)

    $wasWarned = $script:degradationWarnings.ContainsKey($Name) -and $script:degradationWarnings[$Name].warned

    if ($Slope -lt $degradationThreshold -and $CurrentHealth -lt 80) {
        # Health is declining -- warn
        if (-not $wasWarned) {
            $script:degradationWarnings[$Name] = @{
                warned = $true
                trend  = $Slope
                since  = (Get-Date).ToString('o')
                health = $CurrentHealth
            }
            Write-Event -Type 'prediction' -Adapter $Name -Message "Degradation predicted (trend: $Slope/cycle, health: $CurrentHealth%) -- reducing traffic"
            Write-Host "  [!] PREDICTION: $Name degrading (trend=$Slope) -- preemptive rerouting" -ForegroundColor Magenta
        } else {
            $script:degradationWarnings[$Name].trend = $Slope
            $script:degradationWarnings[$Name].health = $CurrentHealth
        }
        return $true
    } elseif ($wasWarned -and $Slope -ge ($degradationThreshold / 2)) {
        # Health recovering -- clear warning
        $script:degradationWarnings[$Name] = @{ warned = $false; trend = $Slope; since = $null; health = $CurrentHealth }
        Write-Event -Type 'prediction' -Adapter $Name -Message "Degradation resolved (trend: $Slope/cycle, health: $CurrentHealth%) -- restoring traffic"
        Write-Host "  [OK] RECOVERY: $Name stabilized (trend=$Slope)" -ForegroundColor Green
        return $false
    }
    return $wasWarned
}

function Get-StabilityScore {
    <# Score based on health variance over time. Low variance = high stability. Returns 0-100. #>
    param([string]$Name)

    if (-not $script:healthTrend.ContainsKey($Name)) { return 80 }
    $trend = $script:healthTrend[$Name]
    if ($trend.Count -lt 5) { return 80 }

    $avg = ($trend | Measure-Object -Average).Average
    $variance = 0.0
    foreach ($s in $trend) {
        $variance += ($s - $avg) * ($s - $avg)
    }
    $variance /= $trend.Count
    $stddev = [math]::Sqrt($variance)

    # Low stddev = stable = high score. StdDev of 0 â†’ 100, StdDev of 30+ â†’ 0
    $stability = [math]::Max(0, [math]::Min(100, [math]::Round(100 - ($stddev * 3.3))))
    $script:stabilityScores[$Name] = $stability
    return $stability
}

function Update-SuccessRate {
    <# Track connection success/failure rate per adapter. #>
    param([string]$Name, [bool]$GatewayOk, [bool]$InternetOk)

    if (-not $script:successRates.ContainsKey($Name)) {
        $script:successRates[$Name] = @{ success = 0; fail = 0; rate = 100.0 }
    }
    $sr = $script:successRates[$Name]

    if ($InternetOk) {
        $sr.success++
    } elseif ($GatewayOk) {
        $sr.success++  # Gateway OK still counts as partial success
    } else {
        $sr.fail++
    }

    $total = $sr.success + $sr.fail
    if ($total -gt 0) {
        $sr.rate = [math]::Round(($sr.success / $total) * 100, 1)
    }

    # Decay old counters every 100 samples to stay responsive
    if ($total -gt 200) {
        $sr.success = [math]::Floor($sr.success * 0.5)
        $sr.fail = [math]::Floor($sr.fail * 0.5)
    }
}

# ===== Enhanced Health Measurement =====

function Measure-InterfaceHealth {
    param(
        [hashtable]$Interface,
        [string]$Mode = 'default',
        [switch]$PrimaryOnly
    )

    $ip = $Interface.IPAddress
    $gateway = $Interface.Gateway
    $name = $Interface.Name
    $previousHealth = if ($script:lastHealthByAdapter.ContainsKey($name)) { $script:lastHealthByAdapter[$name] } else { $null }

    # --- Gateway latency ---
    $gwLatencyMeasured = Test-GatewayLatency -Gateway $gateway
    $gwLatencyRaw = $gwLatencyMeasured
    if ($gwLatencyRaw -ge 999 -and $previousHealth -and $previousHealth.GatewayLatency) {
        $gwLatencyRaw = [double]$previousHealth.GatewayLatency
    }
    $gwLatencySmoothed = Update-EWMALatency -Name $name -RawLatency $gwLatencyRaw -Type 'gateway' -Mode $Mode

    # --- Internet latency ---
    $inetLatencyMeasured = 999
    if ($ip) {
        if ($PrimaryOnly) {
            $inetLatencyMeasured = Test-BoundTcpLatency -SourceIP $ip -Target $script:tcpProbeTarget -Port $script:tcpProbePort -Timeout $pingTimeout
            if ($inetLatencyMeasured -ge 999) {
                $inetLatencyMeasured = Test-BoundTcpLatency -SourceIP $ip -Target $script:tcpProbeTarget2 -Port $script:tcpProbePort -Timeout $pingTimeout
            }
        } else {
            $inetLatencyMeasured = Test-InternetLatency -SourceIP $ip -Target $pingTarget -Timeout $pingTimeout
            if ($inetLatencyMeasured -ge 999) {
                $inetLatencyMeasured = Test-InternetLatency -SourceIP $ip -Target $pingTarget2 -Timeout $pingTimeout
            }
        }
    }
    $inetLatencyRaw = $inetLatencyMeasured
    if ($inetLatencyRaw -ge 999 -and $previousHealth -and $previousHealth.InternetLatency) {
        $inetLatencyRaw = [double]$previousHealth.InternetLatency
    }
    $inetLatencySmoothed = Update-EWMALatency -Name $name -RawLatency $inetLatencyRaw -Type 'internet' -Mode $Mode

    # --- Update latency history and measure jitter ---
    if (-not $PrimaryOnly) {
        Update-LatencyHistory -Name $name -RawLatency $inetLatencyRaw
        $jitter = Measure-Jitter -Name $name
    } elseif ($script:jitterValues.ContainsKey($name)) {
        $jitter = [double]$script:jitterValues[$name]
    } elseif ($previousHealth -and $previousHealth.Jitter) {
        $jitter = [double]$previousHealth.Jitter
    } else {
        $jitter = 0.0
    }

    # --- Update success rate ---
    $gwOk = $gwLatencyMeasured -lt 999
    $inetOk = $inetLatencyMeasured -lt 999
    Update-SuccessRate -Name $name -GatewayOk $gwOk -InternetOk $inetOk

    # --- Bandwidth calculation (with counter wraparound protection) ---
    $stats = Get-NetAdapterStatistics -Name $name -ErrorAction SilentlyContinue
    $rxBytes = if ($stats) { [long]$stats.ReceivedBytes } else { 0 }
    $txBytes = if ($stats) { [long]$stats.SentBytes } else { 0 }

    $rxSpeed = 0.0
    $txSpeed = 0.0

    if ($script:prevBytes.ContainsKey($name)) {
        $prev = $script:prevBytes[$name]
        $timeDelta = ((Get-Date) - $prev.time).TotalSeconds
        if ($timeDelta -gt 0.5) {
            $rxDelta = $rxBytes - $prev.rx
            $txDelta = $txBytes - $prev.tx
            if ($rxDelta -lt 0) { $rxDelta = $rxBytes }
            if ($txDelta -lt 0) { $txDelta = $txBytes }
            $rxSpeed = [math]::Round($rxDelta * 8 / $timeDelta / 1000000, 2)
            $txSpeed = [math]::Round($txDelta * 8 / $timeDelta / 1000000, 2)
        }
    }
    $script:prevBytes[$name] = @{ rx = $rxBytes; tx = $txBytes; time = (Get-Date) }

    # --- Packet loss estimation (0-10% scale for weighting) ---
    $packetLoss = 0.0
    if (-not $inetOk -and -not $gwOk) {
        $packetLoss = 10.0
    } elseif (-not $inetOk) {
        $packetLoss = 5.0
    }

    # NetFusion-FIX: 6 - Score adapters with bandwidth as the primary factor, then latency, jitter, and loss.
    $hasIP = [bool]$ip
    $linkSpeedMbps = if ($null -ne $Interface.LinkSpeedMbps) { [double]$Interface.LinkSpeedMbps } else { 0.0 }
    if ($linkSpeedMbps -le 0.0 -and $previousHealth -and $previousHealth.LinkSpeedMbps) {
        $linkSpeedMbps = [double]$previousHealth.LinkSpeedMbps
    }
    if ($linkSpeedMbps -le 0.0) {
        $linkSpeedMbps = 100.0
    }

    if ($hasIP) {
        $bwFactor = [math]::Min($linkSpeedMbps / 500.0, 1.0)
        $latencyFactor = [math]::Max(0.0, 1.0 - ($inetLatencySmoothed / 200.0))
        $jitterFactor = [math]::Max(0.0, 1.0 - ($jitter / 100.0))
        $lossFactor = [math]::Max(0.0, 1.0 - ($packetLoss / 10.0))
        $rawScore = ($bwFactor * 50.0) + ($latencyFactor * 20.0) + ($jitterFactor * 10.0) + ($lossFactor * 20.0)

        $previousScore = if ($previousHealth -and $null -ne $previousHealth.HealthScore) { [double]$previousHealth.HealthScore } else { $rawScore }
        $score = [math]::Round([math]::Max(0.0, [math]::Min(100.0, (($previousScore * 0.7) + ($rawScore * 0.3)))), 1)

        $trendSlope = Update-HealthTrend -Name $name -HealthScore $score
        $stability = Get-StabilityScore -Name $name
        $isDegrading = Test-PredictiveDegradation -Name $name -Slope $trendSlope -CurrentHealth $score
    } else {
        $rawScore = 0.0
        $score = 0.0
        $trendSlope = 0.0
        $stability = 0.0
        $isDegrading = $false
    }

    # --- Status ---
    $status = 'offline'
    if ($score -ge 70) { $status = 'healthy' }
    elseif ($score -ge 40) { $status = 'degraded' }
    elseif ($score -gt 0) { $status = 'critical' }

    # --- State change events ---
    $prevState = $script:prevStates[$name]
    if ($prevState -and $prevState -ne $status) {
        Write-Event -Type 'state_change' -Adapter $name -Message "Status: $prevState -> $status (HP: $score)"
    }
    $script:prevStates[$name] = $status

    $result = @{
        Name               = $name
        Type               = $Interface.Type
        InterfaceIndex     = $Interface.InterfaceIndex
        GatewayLatency     = $gwLatencyRaw
        GatewayLatencyEWMA = [math]::Round($gwLatencySmoothed, 1)
        InternetLatency    = $inetLatencyRaw
        InternetLatencyEWMA = [math]::Round($inetLatencySmoothed, 1)
        Jitter             = $jitter
        DownloadMbps       = $rxSpeed
        UploadMbps         = $txSpeed
        PacketLoss         = $packetLoss
        RawHealthScore     = [math]::Round($rawScore, 1)
        HealthScore        = $score
        Status             = $status
        SuccessRate        = if ($script:successRates.ContainsKey($name)) { $script:successRates[$name].rate } else { 100.0 }
        StabilityScore     = if ($script:stabilityScores.ContainsKey($name)) { $script:stabilityScores[$name] } else { 80 }
        HealthTrend        = $trendSlope
        IsDegrading        = $isDegrading
        LinkSpeedMbps      = $linkSpeedMbps
        IPAddress          = $ip
        Gateway            = $gateway
        SSID               = $Interface.SSID
        MeasurementMode    = if ($PrimaryOnly) { 'primary' } else { 'full' }
    }

    $script:lastHealthByAdapter[$name] = $result
    return $result
}

function Rotate-CSVLog {
    if (Test-Path $LogFile) {
        $lines = Get-Content $LogFile -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt $script:maxCSVLines) {
            $header = $lines[0]
            $kept = $lines[($lines.Count - 1000)..($lines.Count - 1)]
            @($header) + $kept | Set-Content $LogFile -Encoding UTF8 -Force
        }
    }
}

# --- Main Loop ---
Write-Host ""
Write-Host "  [InterfaceMonitor v4.0] Intelligent health monitoring every ${Interval}s" -ForegroundColor Yellow
Write-Host "  Ping targets: $pingTarget, $pingTarget2" -ForegroundColor DarkGray
Write-Host "  Primary checks: every $($script:healthPrimaryIntervalSeconds)s via bound TCP $($script:tcpProbeTarget):$($script:tcpProbePort)" -ForegroundColor DarkGray
Write-Host "  Full checks: every $($script:healthFullMeasurementIntervalSeconds)s via ping + jitter refresh" -ForegroundColor DarkGray
Write-Host "  Multi-method: Gateway + Internet + DNS + Bandwidth" -ForegroundColor DarkGray
Write-Host "  Intelligence: Dynamic EWMA + Jitter(w=$jitterWindowSize) + Trend(w=$healthTrendWindow) + Prediction(t=$degradationThreshold)" -ForegroundColor DarkGray
Write-Host ""

# Init CSV log (extended columns)
if (-not (Test-Path $LogFile)) {
    "Timestamp,Adapter,DownloadMbps,UploadMbps,GwLatency,GwLatencyEWMA,InetLatency,InetLatencyEWMA,Jitter,PacketLoss,HealthScore,SuccessRate,Stability,Trend" | Set-Content $LogFile -Encoding UTF8
}

function Update-HealthState {
    try {
        $now = Get-Date
        if ($script:lastHealthOutput -and $script:lastHealthRun -and (($now - $script:lastHealthRun).TotalSeconds -lt $script:healthPrimaryIntervalSeconds)) {
            return $script:lastHealthOutput
        }

        try {
            $liveCfg = Get-Content $configPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            $activeMode = if ($liveCfg -and $liveCfg.mode) { $liveCfg.mode } else { 'maxspeed' }
            $script:ewmaAlphaMap = Get-ConfiguredEwmaAlphaMap -LiveConfig $liveCfg
        } catch {}

        if (-not (Test-Path $InterfacesFile)) {
            return $null
        }

        $ifaceData = Get-Content $InterfacesFile -Raw | ConvertFrom-Json
        $healthResults = @()
        $fullMeasurementDue = (-not $script:lastFullHealthRun) -or (($now - $script:lastFullHealthRun).TotalSeconds -ge $script:healthFullMeasurementIntervalSeconds)

        foreach ($iface in $ifaceData.interfaces) {
            $ifHash = @{}
            $iface.PSObject.Properties | ForEach-Object { $ifHash[$_.Name] = $_.Value }

            $health = Measure-InterfaceHealth -Interface $ifHash -Mode $activeMode -PrimaryOnly:(-not $fullMeasurementDue)
            $healthResults += $health

            # Optional UI Console Output
            # Write-Host "$($health.Name) health: $($health.HealthScore)"
            
            # CSV log (extended)
            $logLine = "$(Get-Date -Format 'o'),$($health.Name),$($health.DownloadMbps),$($health.UploadMbps),$($health.GatewayLatency),$($health.GatewayLatencyEWMA),$($health.InternetLatency),$($health.InternetLatencyEWMA),$($health.Jitter),$($health.PacketLoss),$($health.HealthScore),$($health.SuccessRate),$($health.StabilityScore),$($health.HealthTrend)"
            Add-Content $LogFile $logLine -ErrorAction SilentlyContinue
        }

        # Write enriched health data
        $healthOutput = @{
            timestamp   = (Get-Date).ToString('o')
            version     = '4.0'
            uptime      = [math]::Round(((Get-Date) - $script:startTime).TotalMinutes, 1)
            measurementMode = if ($fullMeasurementDue) { 'full' } else { 'primary' }
            intervals   = @{
                primarySeconds = $script:healthPrimaryIntervalSeconds
                fullSeconds = $script:healthFullMeasurementIntervalSeconds
            }
            adapters    = $healthResults
            degradation = $script:degradationWarnings
        }
        Write-AtomicJson -Path $HealthFile -Data $healthOutput -Depth 4
        $script:lastHealthOutput = $healthOutput
        $script:lastHealthRun = $now
        if ($fullMeasurementDue) {
            $script:lastFullHealthRun = $now
        }

        # Rotate CSV and Events log every 50 loops
        $script:loopCount++
        if ($script:loopCount % 50 -eq 0) {
            Rotate-CSVLog
            try { & (Join-Path $projectDir "core\LogRotation.ps1") } catch {}
        }
        
        return $healthOutput

    } catch {
        Write-Host "  [InterfaceMonitor] Error: $_" -ForegroundColor Red
        return $null
    }
}


