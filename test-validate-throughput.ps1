[CmdletBinding()]
param(
    [string[]]$AdapterNames = @(),
    [int]$PerAdapterConnections = 4,
    [int]$CombinedConnectionsPerAdapter = 4,
    [int]$BytesPerConnection = 8000000,
    [string]$TestHost = 'speed.cloudflare.com',
    [int]$TestPort = 80,
    [int]$ConnectTimeoutMs = 8000,
    [int]$IoTimeoutMs = 45000,
    [string]$OutputPath = "logs\test-validate-throughput.json",
    [switch]$IncludeCombinedTest,
    [switch]$WriteMonitoringLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:ConfigDir = Join-Path $script:Root "config"
$script:HealthFile = Join-Path $script:ConfigDir "health.json"
$script:ProxyStatsFile = Join-Path $script:ConfigDir "proxy-stats.json"
$script:InterfacesFile = Join-Path $script:ConfigDir "interfaces.json"

function Write-AtomicJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 8
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $tmp = Join-Path $dir ([System.IO.Path]::GetRandomFileName())
    try {
        $Data | ConvertTo-Json -Depth $Depth -Compress | Set-Content -Path $tmp -Encoding UTF8 -Force -ErrorAction Stop
        Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-ActiveAdapters {
    param([string[]]$FilterNames = @())

    $FilterNames = @($FilterNames)

    $map = @{}
    $ifData = Read-JsonSafe -Path $script:InterfacesFile
    if ($ifData -and $ifData.interfaces) {
        foreach ($iface in @($ifData.interfaces)) {
            $name = [string]$iface.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($FilterNames.Count -gt 0 -and $name -notin $FilterNames) { continue }
            $primaryIPv4 = if ($iface.PSObject.Properties['PrimaryIPv4']) { [string]$iface.PrimaryIPv4 } else { '' }
            $ipAddress = if ($iface.PSObject.Properties['IPAddress']) { [string]$iface.IPAddress } else { '' }
            $ipList = if ($iface.PSObject.Properties['IPAddresses']) { @($iface.IPAddresses) } else { @() }
            $ip = ''
            if ($primaryIPv4) {
                $ip = $primaryIPv4
            } elseif ($ipAddress -and $ipAddress -notmatch ':') {
                $ip = $ipAddress
            } elseif ($ipList.Count -gt 0) {
                $ip = [string]($ipList | Where-Object { $_ -and [string]$_ -notmatch ':' } | Select-Object -First 1)
            }
            if ([string]::IsNullOrWhiteSpace($ip) -or $ip -match '^169\.254\.') { continue }
            $map[$name] = [pscustomobject]@{
                Name = $name
                IPAddress = $ip
                InterfaceIndex = if ($iface.PSObject.Properties['InterfaceIndex'] -and $iface.InterfaceIndex) { [int]$iface.InterfaceIndex } else { 0 }
                Type = if ($iface.PSObject.Properties['Type'] -and $iface.Type) { [string]$iface.Type } else { 'Unknown' }
                EstimatedCapacityMbps = if ($iface.PSObject.Properties['EstimatedCapacityMbps'] -and $iface.EstimatedCapacityMbps) { [double]$iface.EstimatedCapacityMbps } else { 0.0 }
            }
        }
    }

    if ($map.Count -eq 0) {
        $fallback = @(
            Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Status -eq 'Up' -and
                    $_.InterfaceDescription -notmatch '(?i)Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN|OpenVPN|WireGuard|Tailscale|ZeroTier|Npcap|vEthernet|VMware|VirtualBox'
                }
        )
        foreach ($adapter in $fallback) {
            $name = [string]$adapter.Name
            if ($FilterNames.Count -gt 0 -and $name -notin $FilterNames) { continue }
            $ip = @(
                Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
                    Select-Object -ExpandProperty IPAddress
            ) | Select-Object -First 1
            if (-not $ip) { continue }
            $map[$name] = [pscustomobject]@{
                Name = $name
                IPAddress = [string]$ip
                InterfaceIndex = [int]$adapter.ifIndex
                Type = 'Unknown'
                EstimatedCapacityMbps = 0.0
            }
        }
    }

    return @($map.Values | Sort-Object Name)
}

function Get-AdapterTrafficSnapshot {
    param([object[]]$Adapters)

    $snapshot = @{}
    foreach ($adapter in $Adapters) {
        $stats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
        $snapshot[$adapter.Name] = @{
            rx = if ($stats) { [int64]$stats.ReceivedBytes } else { [int64]0 }
            tx = if ($stats) { [int64]$stats.SentBytes } else { [int64]0 }
        }
    }
    return $snapshot
}

function Get-HealthScoreMap {
    $map = @{}
    $health = Read-JsonSafe -Path $script:HealthFile
    if (-not $health -or -not $health.adapters) { return $map }
    foreach ($a in @($health.adapters)) {
        if (-not $a.Name) { continue }
        $h01 = 0.0
        if ($a.PSObject.Properties['HealthScore01'] -and $null -ne $a.HealthScore01) {
            $h01 = [double]$a.HealthScore01
        } else {
            $hScore = if ($a.PSObject.Properties['HealthScore'] -and $null -ne $a.HealthScore) { [double]$a.HealthScore } else { 0.0 }
            $h01 = [double]($hScore / 100.0)
        }
        $map[[string]$a.Name] = @{
            health = $h01
            utilizationPct = if ($a.PSObject.Properties['UtilizationPct'] -and $null -ne $a.UtilizationPct) { [double]$a.UtilizationPct } else { 0.0 }
        }
    }
    return $map
}

function Get-FlowCountMap {
    $map = @{}
    $proxy = Read-JsonSafe -Path $script:ProxyStatsFile
    if (-not $proxy -or -not $proxy.PSObject.Properties['activePerAdapter']) { return $map }
    if (-not $proxy.activePerAdapter) { return $map }
    foreach ($prop in $proxy.activePerAdapter.PSObject.Properties) {
        $map[[string]$prop.Name] = [int]$prop.Value
    }
    return $map
}

function Invoke-BoundDownloadWorkers {
    param(
        [object[]]$Assignments,
        [string]$TargetHost,
        [int]$Port,
        [int]$Bytes,
        [int]$ConnectTimeout,
        [int]$IoTimeout
    )

    $jobScript = {
        param($AdapterName, $LocalIP, $TargetHost, $Port, $Bytes, $ConnectTimeout, $IoTimeout)
        $client = $null
        $stream = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Client.NoDelay = $true
            $client.SendTimeout = $IoTimeout
            $client.ReceiveTimeout = $IoTimeout
            $client.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($LocalIP), 0)))

            $connectAr = $client.BeginConnect($TargetHost, $Port, $null, $null)
            if (-not $connectAr.AsyncWaitHandle.WaitOne($ConnectTimeout, $false)) {
                throw "connect timeout"
            }
            try { $client.EndConnect($connectAr) } catch {}
            if (-not $client.Connected) { throw "connect failed" }

            $stream = $client.GetStream()
            $id = [guid]::NewGuid().ToString('N')
            $req = "GET /__down?bytes=$Bytes&nfvalidate=$id HTTP/1.1`r`nHost: $TargetHost`r`nConnection: close`r`nUser-Agent: NetFusion-Validate/1.0`r`n`r`n"
            $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $stream.Write($reqBytes, 0, $reqBytes.Length)
            $stream.Flush()

            $buf = New-Object byte[] 65536
            $total = 0L
            while ($true) {
                $read = $stream.Read($buf, 0, $buf.Length)
                if ($read -le 0) { break }
                $total += [int64]$read
            }
            $sw.Stop()

            $secs = [math]::Max(0.001, [double]$sw.Elapsed.TotalSeconds)
            $mbps = (($total * 8.0) / 1000000.0) / $secs
            return [pscustomobject]@{
                adapter = $AdapterName
                localIP = $LocalIP
                ok = $true
                bytes = [int64]$total
                seconds = [double]$secs
                throughputMbps = [double]$mbps
                error = ''
            }
        } catch {
            return [pscustomobject]@{
                adapter = $AdapterName
                localIP = $LocalIP
                ok = $false
                bytes = [int64]0
                seconds = 0.0
                throughputMbps = 0.0
                error = [string]$_.Exception.Message
            }
        } finally {
            try { if ($stream) { $stream.Dispose() } } catch {}
            try { if ($client) { $client.Dispose() } } catch {}
        }
    }

    $jobs = @()
    foreach ($assignment in $Assignments) {
        $jobs += Start-Job -ScriptBlock $jobScript -ArgumentList @(
            [string]$assignment.AdapterName,
            [string]$assignment.LocalIP,
            $TargetHost,
            $Port,
            $Bytes,
            $ConnectTimeout,
            $IoTimeout
        )
    }
    return $jobs
}

function Invoke-ParallelBoundTest {
    param(
        [string]$Phase,
        [object[]]$Adapters,
        [object[]]$Assignments,
        [string]$TargetHost,
        [int]$Port,
        [int]$Bytes,
        [int]$ConnectTimeout,
        [int]$IoTimeout,
        [int]$MaxPhaseSeconds = 60,
        [switch]$WriteMonitoringLog
    )

    if (-not $Assignments -or $Assignments.Count -eq 0) {
        throw "No assignments for phase '$Phase'."
    }

    $jobs = Invoke-BoundDownloadWorkers -Assignments $Assignments -TargetHost $TargetHost -Port $Port -Bytes $Bytes -ConnectTimeout $ConnectTimeout -IoTimeout $IoTimeout
    $started = Get-Date
    $samples = @()
    $prevTraffic = Get-AdapterTrafficSnapshot -Adapters $Adapters
    $lastHealthRefresh = [datetime]::MinValue
    $healthMap = @{}

    while (@($jobs | Where-Object State -notin @('Completed', 'Failed', 'Stopped')).Count -gt 0) {
        if (((Get-Date) - $started).TotalSeconds -ge $MaxPhaseSeconds) {
            foreach ($job in @($jobs | Where-Object State -notin @('Completed', 'Failed', 'Stopped'))) {
                try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
            }
            break
        }
        Start-Sleep -Seconds 1
        $now = Get-Date
        $currentTraffic = Get-AdapterTrafficSnapshot -Adapters $Adapters
        $flowMap = Get-FlowCountMap
        if (($now - $lastHealthRefresh).TotalSeconds -ge 5) {
            $healthMap = Get-HealthScoreMap
            $lastHealthRefresh = $now
        }

        $throughputMap = @{}
        $combinedMbps = 0.0
        foreach ($adapter in $Adapters) {
            $name = [string]$adapter.Name
            $prev = $prevTraffic[$name]
            $curr = $currentTraffic[$name]
            $deltaBytes = [double](([int64]$curr.rx + [int64]$curr.tx) - ([int64]$prev.rx + [int64]$prev.tx))
            if ($deltaBytes -lt 0) { $deltaBytes = 0 }
            $mbps = [math]::Round(($deltaBytes * 8.0) / 1000000.0, 3)
            $throughputMap[$name] = $mbps
            $combinedMbps += $mbps
        }

        $samples += [pscustomobject]@{
            phase = $Phase
            timestamp = $now.ToString('o')
            throughputMbps = $throughputMap
            combinedMbps = [math]::Round($combinedMbps, 3)
            flowCounts = $flowMap
            health = $healthMap
        }
        $prevTraffic = $currentTraffic
    }

    foreach ($job in @($jobs | Where-Object State -notin @('Completed', 'Failed', 'Stopped'))) {
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
    }
    Wait-Job -Job $jobs -Timeout 5 | Out-Null
    $results = @()
    foreach ($job in @($jobs | Where-Object State -in @('Completed', 'Failed', 'Stopped'))) {
        try {
            $results += @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        } catch {}
    }
    Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
    $ended = Get-Date

    $elapsedSec = [math]::Max(0.001, ($ended - $started).TotalSeconds)
    $totalBytes = [double](($results | Measure-Object -Property bytes -Sum).Sum)
    $combinedMbps = (($totalBytes * 8.0) / 1000000.0) / $elapsedSec
    $successes = @($results | Where-Object { $_.ok }).Count
    $failures = @($results | Where-Object { -not $_.ok }).Count

    $perAdapter = @{}
    foreach ($adapter in $Adapters) {
        $name = [string]$adapter.Name
        $rows = @($results | Where-Object { $_.adapter -eq $name })
        if ($rows.Count -eq 0) { continue }
        $adapterBytes = [double](($rows | Measure-Object -Property bytes -Sum).Sum)
        $adapterMbps = (($adapterBytes * 8.0) / 1000000.0) / $elapsedSec
        $perAdapter[$name] = [math]::Round($adapterMbps, 3)
    }

    $combinedSeries = @($samples | ForEach-Object { [double]$_.combinedMbps })
    $peakCombined = if ($combinedSeries.Count -gt 0) { [double]($combinedSeries | Measure-Object -Maximum).Maximum } else { 0.0 }
    $sustained30 = if ($combinedSeries.Count -gt 0) {
        $window = @($combinedSeries | Select-Object -Last ([math]::Min(30, $combinedSeries.Count)))
        [double](($window | Measure-Object -Average).Average)
    } else { 0.0 }

    if ($WriteMonitoringLog) {
        $monPath = Join-Path $script:Root "logs\test-validate-throughput-monitor-$($Phase).json"
        Write-AtomicJson -Path $monPath -Data @{
            timestamp = (Get-Date).ToString('o')
            phase = $Phase
            samples = $samples
        } -Depth 9
    }

    return [pscustomobject]@{
        Phase = $Phase
        StartedAt = $started.ToString('o')
        EndedAt = $ended.ToString('o')
        ElapsedSec = [math]::Round($elapsedSec, 3)
        TotalBytes = [int64]$totalBytes
        CombinedMbps = [math]::Round($combinedMbps, 3)
        PerAdapterMbps = $perAdapter
        Successes = $successes
        Failures = $failures
        Results = $results
        Monitoring = @{
            SampleCount = $samples.Count
            Samples = $samples
            PeakCombinedMbps = [math]::Round($peakCombined, 3)
            Sustained30SecMbps = [math]::Round($sustained30, 3)
        }
    }
}

function Invoke-NetFusionThroughputValidation {
    [CmdletBinding()]
    param(
        [string[]]$AdapterNames = @(),
        [int]$PerAdapterConnections = 4,
        [int]$CombinedConnectionsPerAdapter = 4,
        [int]$BytesPerConnection = 8000000,
        [string]$TestHost = 'speed.cloudflare.com',
        [int]$TestPort = 80,
        [int]$ConnectTimeoutMs = 8000,
        [int]$IoTimeoutMs = 45000,
        [string]$OutputPath = "logs\test-validate-throughput.json",
        [switch]$IncludeCombinedTest,
        [switch]$WriteMonitoringLog
    )

    $AdapterNames = @($AdapterNames)
    $adapters = @(Get-ActiveAdapters -FilterNames $AdapterNames)
    if ($adapters.Count -eq 0) { throw "No active routable adapters found." }

    $individual = @()
    foreach ($adapter in $adapters) {
        $assignments = @()
        for ($i = 0; $i -lt $PerAdapterConnections; $i++) {
            $assignments += [pscustomobject]@{ AdapterName = $adapter.Name; LocalIP = $adapter.IPAddress }
        }
        $phaseTimeout = [math]::Max(10, [int](($ConnectTimeoutMs + $IoTimeoutMs) / 1000) + 5)
        $run = Invoke-ParallelBoundTest -Phase ("individual-" + $adapter.Name.Replace(' ', '_')) -Adapters @($adapter) -Assignments $assignments -TargetHost $TestHost -Port $TestPort -Bytes $BytesPerConnection -ConnectTimeout $ConnectTimeoutMs -IoTimeout $IoTimeoutMs -MaxPhaseSeconds $phaseTimeout -WriteMonitoringLog:$WriteMonitoringLog
        $run | Add-Member -NotePropertyName AdapterName -NotePropertyValue $adapter.Name -Force
        $individual += $run
    }

    $combined = $null
    $assignments = @()
    foreach ($adapter in $adapters) {
        for ($i = 0; $i -lt $CombinedConnectionsPerAdapter; $i++) {
            $assignments += [pscustomobject]@{ AdapterName = $adapter.Name; LocalIP = $adapter.IPAddress }
        }
    }
    $phaseTimeout = [math]::Max(10, [int](($ConnectTimeoutMs + $IoTimeoutMs) / 1000) + 5)
    $combined = Invoke-ParallelBoundTest -Phase "combined" -Adapters $adapters -Assignments $assignments -TargetHost $TestHost -Port $TestPort -Bytes $BytesPerConnection -ConnectTimeout $ConnectTimeoutMs -IoTimeout $IoTimeoutMs -MaxPhaseSeconds $phaseTimeout -WriteMonitoringLog:$WriteMonitoringLog

    $individualMap = @{}
    foreach ($row in $individual) {
        $name = if ($row.AdapterName) { [string]$row.AdapterName } else { ([string]$row.Phase).Replace('individual-', '').Replace('_', ' ') }
        $individualMap[$name] = [double]$row.CombinedMbps
    }
    $sumIndividual = [double](($individual | Measure-Object -Property CombinedMbps -Sum).Sum)
    $efficiency = if ($sumIndividual -gt 0) { ([double]$combined.CombinedMbps / $sumIndividual) } else { 0.0 }

    $contribution = @()
    $underContributing = @()
    $utilizationMap = @{}
    foreach ($adapter in $adapters) {
        $name = [string]$adapter.Name
        $singleMbps = if ($individualMap.ContainsKey($name)) { [double]$individualMap[$name] } else { 0.0 }
        $combinedMbps = if ($combined.PerAdapterMbps.ContainsKey($name)) { [double]$combined.PerAdapterMbps[$name] } else { 0.0 }
        $ratio = if ($singleMbps -gt 0) { $combinedMbps / $singleMbps } else { 0.0 }
        $isContributing = ($singleMbps -le 0.001) -or ($ratio -ge 0.5)
        $row = [pscustomobject]@{
            Adapter = $name
            IndividualMbps = [math]::Round($singleMbps, 3)
            CombinedContributionMbps = [math]::Round($combinedMbps, 3)
            ContributionRatio = [math]::Round($ratio, 3)
            ContributionPct = [math]::Round($ratio * 100.0, 1)
            IsContributing = $isContributing
        }
        $contribution += $row
        if (-not $isContributing) { $underContributing += $row }

        $capacity = if ($adapter.EstimatedCapacityMbps -gt 0) { [double]$adapter.EstimatedCapacityMbps } else { 0.0 }
        $utilizationMap[$name] = if ($capacity -gt 0.001) { [math]::Round(([double]$combinedMbps / $capacity) * 100.0, 2) } else { 0.0 }
    }

    $result = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        TestHost = $TestHost
        AdapterCount = $adapters.Count
        Adapters = $adapters
        Settings = @{
            PerAdapterConnections = $PerAdapterConnections
            CombinedConnectionsPerAdapter = $CombinedConnectionsPerAdapter
            BytesPerConnection = $BytesPerConnection
            TestPort = $TestPort
            ConnectTimeoutMs = $ConnectTimeoutMs
            IoTimeoutMs = $IoTimeoutMs
        }
        Individual = $individual
        Combined = $combined
        Aggregates = @{
            SumIndividualMbps = [math]::Round($sumIndividual, 3)
            CombinedMbps = [math]::Round([double]$combined.CombinedMbps, 3)
            Efficiency = [math]::Round($efficiency, 4)
            EfficiencyPct = [math]::Round($efficiency * 100.0, 2)
            PeakCombinedMbps = [double]$combined.Monitoring.PeakCombinedMbps
            Sustained30SecMbps = [double]$combined.Monitoring.Sustained30SecMbps
            CombinedUtilizationPctByAdapter = $utilizationMap
        }
        Contribution = $contribution
        UnderContributing = $underContributing
    }

    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path $script:Root $OutputPath
    }
    Write-AtomicJson -Path $OutputPath -Data $result -Depth 9
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-NetFusionThroughputValidation `
        -AdapterNames $AdapterNames `
        -PerAdapterConnections $PerAdapterConnections `
        -CombinedConnectionsPerAdapter $CombinedConnectionsPerAdapter `
        -BytesPerConnection $BytesPerConnection `
        -TestHost $TestHost `
        -TestPort $TestPort `
        -ConnectTimeoutMs $ConnectTimeoutMs `
        -IoTimeoutMs $IoTimeoutMs `
        -OutputPath $OutputPath `
        -IncludeCombinedTest:$IncludeCombinedTest `
        -WriteMonitoringLog:$WriteMonitoringLog

    Write-Host ""
    Write-Host ("Validation completed for {0} adapter(s)." -f $result.AdapterCount) -ForegroundColor Green
    Write-Host ("Combined throughput: {0} Mbps" -f ([math]::Round([double]$result.Combined.CombinedMbps, 2))) -ForegroundColor Cyan
    Write-Host ("Efficiency: {0}%" -f ([math]::Round([double]$result.Aggregates.EfficiencyPct, 2))) -ForegroundColor Yellow
    if ($result.UnderContributing.Count -gt 0) {
        Write-Host "Under-contributing adapters (<50% of individual baseline):" -ForegroundColor Yellow
        foreach ($row in $result.UnderContributing) {
            Write-Host ("  - {0}: {1}% ({2} Mbps combined vs {3} Mbps baseline)" -f $row.Adapter, $row.ContributionPct, $row.CombinedContributionMbps, $row.IndividualMbps) -ForegroundColor Yellow
        }
    } else {
        Write-Host "All adapters contributed at or above 50% of their individual baseline." -ForegroundColor Green
    }

    $result | ConvertTo-Json -Depth 9
}
