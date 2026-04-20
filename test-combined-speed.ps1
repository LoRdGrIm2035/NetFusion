# === NetFusion Throughput + Root-Cause Verifier ===
# Goal policy:
#   - Near-600 Mbps combined proxy throughput is the target.
#   - Any lower result is treated as a problem until proven otherwise.
#   - External bottleneck is accepted only after internal inefficiencies are eliminated.

[CmdletBinding()]
param(
    [int]$TargetCombinedMbps = 600,
    [int]$NearTargetMarginMbps = 40,
    [int[]]$ConcurrencySweep = @(16, 24, 32, 48, 64),
    [int]$DirectTestBytes = 20000000,
    [int]$ProxyTestBytesPerConnection = 12000000,
    [int]$ProxyRunTimeoutSec = 90,
    [int]$DirectAttempts = 2,
    [string]$TestHost = "speed.cloudflare.com",
    [string]$TestUrlTemplate = "http://{host}/__down?bytes={bytes}&nf={id}&c={index}",
    [string]$ProxyHost = "127.0.0.1",
    [int]$ProxyPort = 8080,
    [int]$DashboardPort = 9090,
    [string[]]$AdapterNames = @("Wi-Fi 3", "Wi-Fi 4")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Write-Section {
    param(
        [string]$Title,
        [string]$Color = 'Yellow'
    )
    Write-Host ""
    Write-Host ("--- {0} ---" -f $Title) -ForegroundColor $Color
}

function Get-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function Invoke-NativeCommandSafe {
    param([scriptblock]$ScriptBlock)

    $previousErrorAction = $global:ErrorActionPreference
    try {
        # Windows PowerShell can treat native stderr as ErrorRecord when ErrorAction=Stop.
        $global:ErrorActionPreference = 'Continue'
        $output = & $ScriptBlock 2>&1
        return @($output | ForEach-Object { $_.ToString() })
    } finally {
        $global:ErrorActionPreference = $previousErrorAction
    }
}

function New-TestUrl {
    param(
        [string]$Template,
        [string]$DownloadHost,
        [int]$Bytes,
        [string]$Id,
        [int]$Index = 0
    )

    $url = [string]$Template
    $url = $url.Replace('{host}', [string]$DownloadHost)
    $url = $url.Replace('{bytes}', [string]$Bytes)
    $url = $url.Replace('{id}', [string]$Id)
    $url = $url.Replace('{index}', [string]$Index)
    return $url
}

function Get-DashboardStats {
    param(
        [string]$RootPath,
        [int]$Port
    )
    try {
        $tokenFile = Join-Path $RootPath "config\dashboard-token.txt"
        if (-not (Test-Path $tokenFile)) { return $null }
        $token = (Get-Content $tokenFile -Raw -ErrorAction Stop).Trim()
        if (-not $token) { return $null }

        return Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/stats" -f $Port) -Headers @{ "X-NetFusion-Token" = $token } -Method Get -TimeoutSec 5
    } catch {
        return $null
    }
}

function Get-AdapterSnapshot {
    param([string[]]$Names)

    $snapshot = @{}
    foreach ($name in $Names) {
        $stats = Get-NetAdapterStatistics -Name $name -ErrorAction SilentlyContinue
        if ($stats) {
            $snapshot[$name] = @{
                ReceivedBytes = [int64]$stats.ReceivedBytes
                SentBytes = [int64]$stats.SentBytes
            }
        } else {
            $snapshot[$name] = @{
                ReceivedBytes = [int64]0
                SentBytes = [int64]0
            }
        }
    }
    return $snapshot
}

function Get-AdapterDiagnostics {
    param([string[]]$Names)

    $rows = @()
    foreach ($name in $Names) {
        $adapter = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
        if (-not $adapter) {
            $rows += [pscustomobject]@{
                Name = $name
                Exists = $false
                Status = 'Missing'
                InterfaceIndex = -1
                IPAddress = $null
                HasIPv4 = $false
                Gateway = $null
                HasDefaultRoute = $false
                RouteMetric = -1
                InterfaceMetric = -1
                AutomaticMetric = 'Unknown'
            }
            continue
        }

        $ip = (Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
            Select-Object -First 1).IPAddress
        $route = Get-NetRoute -InterfaceAlias $name -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric |
            Select-Object -First 1
        $ipInterface = Get-NetIPInterface -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue

        $rows += [pscustomobject]@{
            Name = $name
            Exists = $true
            Status = $adapter.Status
            InterfaceIndex = $adapter.ifIndex
            IPAddress = $ip
            HasIPv4 = [bool]$ip
            Gateway = if ($route) { $route.NextHop } else { $null }
            HasDefaultRoute = [bool]$route
            RouteMetric = if ($route) { [int]$route.RouteMetric } else { -1 }
            InterfaceMetric = if ($ipInterface -and $null -ne $ipInterface.InterfaceMetric) { [int]$ipInterface.InterfaceMetric } else { -1 }
            AutomaticMetric = if ($ipInterface) { [string]$ipInterface.AutomaticMetric } else { 'Unknown' }
        }
    }
    return $rows
}

function Invoke-BoundCurlDownload {
    param(
        [string]$LocalIP,
        [string]$DownloadHost,
        [string]$UrlTemplate,
        [int]$Bytes,
        [int]$MaxTimeSec = 90
    )

    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curlCmd) { throw "curl.exe is required but was not found." }

    $url = New-TestUrl -Template $UrlTemplate -DownloadHost $DownloadHost -Bytes $Bytes -Id ([guid]::NewGuid().ToString('N')) -Index 0
    $format = "SIZE=%{size_download};TIME=%{time_total};SPEED=%{speed_download};CODE=%{http_code};IP=%{local_ip}"
    $output = Invoke-NativeCommandSafe -ScriptBlock {
        & $curlCmd.Source --interface $LocalIP --noproxy "*" -L --http1.1 --connect-timeout 10 --max-time $MaxTimeSec -o NUL -sS -w $format $url
    }
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($text -notmatch 'SIZE=(\d+);TIME=([0-9.]+);SPEED=([0-9.]+);CODE=(\d+);IP=(.*)') {
        return [pscustomobject]@{
            Ok = $false
            Bytes = 0.0
            Seconds = 0.0
            SpeedBytesPerSec = 0.0
            HttpCode = 0
            LocalIP = $LocalIP
            ExitCode = $exitCode
            Raw = $text
        }
    }

    $bytes = [double]$Matches[1]
    $seconds = [double]$Matches[2]
    $speed = [double]$Matches[3]
    $code = [int]$Matches[4]
    # Treat timed partial transfers with valid HTTP status and non-zero bytes as usable samples.
    $ok = ($code -ge 200 -and $code -lt 400 -and $bytes -gt 0)
    return [pscustomobject]@{
        Ok = $ok
        Bytes = $bytes
        Seconds = $seconds
        SpeedBytesPerSec = $speed
        HttpCode = $code
        LocalIP = $Matches[5]
        ExitCode = $exitCode
        Raw = $text
    }
}

function Invoke-DirectBaseline {
    param(
        [string]$AdapterName,
        [string]$LocalIP,
        [string]$DownloadHost,
        [string]$UrlTemplate,
        [int]$Bytes,
        [int]$Attempts
    )

    $attemptResults = @()
    for ($i = 1; $i -le $Attempts; $i++) {
        $r = Invoke-BoundCurlDownload -LocalIP $LocalIP -DownloadHost $DownloadHost -UrlTemplate $UrlTemplate -Bytes $Bytes
        $mbps = if ($r.Ok -and $r.Seconds -gt 0) { [math]::Round(($r.Bytes * 8 / 1MB) / $r.Seconds, 2) } else { 0.0 }
        $attemptResults += [pscustomobject]@{
            Attempt = $i
            Ok = $r.Ok
            Mbps = $mbps
            Seconds = [math]::Round($r.Seconds, 3)
            Bytes = [int64]$r.Bytes
            HttpCode = $r.HttpCode
            Detail = $r.Raw
        }
    }

    $best = ($attemptResults | Sort-Object Mbps -Descending | Select-Object -First 1)
    return [pscustomobject]@{
        Adapter = $AdapterName
        LocalIP = $LocalIP
        Attempts = $attemptResults
        BestMbps = if ($best) { [double]$best.Mbps } else { 0.0 }
        BestAttempt = $best
    }
}

function Invoke-ParallelProxyCurl {
    param(
        [string]$ProxyUri,
        [string]$DownloadHost,
        [string]$UrlTemplate,
        [int]$Concurrency,
        [int]$BytesPerConnection,
        [int]$MaxTimeSec
    )

    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curlCmd) { throw "curl.exe is required but was not found." }

    $writeFormat = "SIZE=%{size_download};TIME=%{time_total};CODE=%{http_code};ERR=%{errormsg}`n"
    $args = @(
        "--http1.1",
        "-x", $ProxyUri,
        "-L",
        "--parallel",
        "--parallel-immediate",
        "--parallel-max", $Concurrency.ToString(),
        "--connect-timeout", "10",
        "--max-time", $MaxTimeSec.ToString(),
        "-sS",
        "-w", $writeFormat
    )

    for ($i = 1; $i -le $Concurrency; $i++) {
        $url = New-TestUrl -Template $UrlTemplate -DownloadHost $DownloadHost -Bytes $BytesPerConnection -Id ([guid]::NewGuid().ToString('N')) -Index $i
        $args += @("-o", "NUL", $url)
    }

    $output = Invoke-NativeCommandSafe -ScriptBlock {
        & $curlCmd.Source @args
    }
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String)
    $lines = @($text -split "(`r`n|`n|`r)" | Where-Object { $_ -and $_.Trim().Length -gt 0 })

    $transfers = @()
    foreach ($line in $lines) {
        if ($line -match '^SIZE=(\d+);TIME=([0-9.]+);CODE=(\d+);ERR=(.*)$') {
            $code = [int]$Matches[3]
            $ok = $code -ge 200 -and $code -lt 400
            $transfers += [pscustomobject]@{
                Ok = $ok
                Bytes = [int64]$Matches[1]
                Seconds = [double]$Matches[2]
                HttpCode = $code
                Error = $Matches[4]
            }
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Transfers = $transfers
        RawOutput = $text
    }
}

function Invoke-ProxySweepRun {
    param(
        [string[]]$Adapters,
        [string]$ProxyUri,
        [string]$DownloadHost,
        [string]$UrlTemplate,
        [int]$Concurrency,
        [int]$BytesPerConnection,
        [int]$MaxTimeSec
    )

    $before = Get-AdapterSnapshot -Names $Adapters
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $transferResult = Invoke-ParallelProxyCurl -ProxyUri $ProxyUri -DownloadHost $DownloadHost -UrlTemplate $UrlTemplate -Concurrency $Concurrency -BytesPerConnection $BytesPerConnection -MaxTimeSec $MaxTimeSec
    $sw.Stop()
    $after = Get-AdapterSnapshot -Names $Adapters

    $elapsedSec = [math]::Max(0.001, $sw.Elapsed.TotalSeconds)
    $adapterBytes = @{}
    $adapterMbps = @{}
    $adapterSharePct = @{}
    $totalCounterBytes = [int64]0

    foreach ($name in $Adapters) {
        $delta = [int64]$after[$name].ReceivedBytes - [int64]$before[$name].ReceivedBytes
        if ($delta -lt 0) { $delta = 0 }
        $adapterBytes[$name] = $delta
        $totalCounterBytes += $delta
    }

    foreach ($name in $Adapters) {
        $mbps = [math]::Round(($adapterBytes[$name] * 8 / 1MB) / $elapsedSec, 2)
        $adapterMbps[$name] = $mbps
        $share = if ($totalCounterBytes -gt 0) { [math]::Round(($adapterBytes[$name] * 100.0) / $totalCounterBytes, 1) } else { 0.0 }
        $adapterSharePct[$name] = $share
    }

    $successfulTransfers = @($transferResult.Transfers | Where-Object { $_.Ok -and $_.Bytes -gt 0 })
    $totalTransferBytes = [int64]0
    foreach ($t in $successfulTransfers) { $totalTransferBytes += [int64]$t.Bytes }

    $counterMbps = [math]::Round(($totalCounterBytes * 8 / 1MB) / $elapsedSec, 2)
    $transferMbps = [math]::Round(($totalTransferBytes * 8 / 1MB) / $elapsedSec, 2)
    $measurementGapPct = 0.0
    if ($counterMbps -gt 0 -or $transferMbps -gt 0) {
        $baseline = [math]::Max($counterMbps, $transferMbps)
        if ($baseline -gt 0) {
            $measurementGapPct = [math]::Round(([math]::Abs($counterMbps - $transferMbps) * 100.0) / $baseline, 1)
        }
    }

    $minShare = if ($Adapters.Count -gt 0) {
        ($Adapters | ForEach-Object { [double]$adapterSharePct[$_] } | Measure-Object -Minimum).Minimum
    } else {
        0.0
    }

    return [pscustomobject]@{
        Concurrency = $Concurrency
        ElapsedSec = [math]::Round($elapsedSec, 3)
        CounterBytes = $totalCounterBytes
        TransferBytes = $totalTransferBytes
        CounterMbps = $counterMbps
        TransferMbps = $transferMbps
        MeasurementGapPct = $measurementGapPct
        AdapterBytes = $adapterBytes
        AdapterMbps = $adapterMbps
        AdapterSharePct = $adapterSharePct
        MinSharePct = [math]::Round([double]$minShare, 1)
        SuccessCount = $successfulTransfers.Count
        TransferCount = $transferResult.Transfers.Count
        ExitCode = $transferResult.ExitCode
        RawOutput = $transferResult.RawOutput
    }
}

$issues = New-Object System.Collections.Generic.List[object]
function Add-InvestigationIssue {
    param(
        [string]$Domain,
        [string]$Issue,
        [string]$Evidence,
        [string]$Action
    )
    $issues.Add([pscustomobject]@{
        Domain = $Domain
        Issue = $Issue
        Evidence = $Evidence
        Action = $Action
    }) | Out-Null
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  NetFusion Target-600 Throughput Verifier   " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$targetFloor = [math]::Max(1, $TargetCombinedMbps - $NearTargetMarginMbps)
$proxyUri = "http://{0}:{1}" -f $ProxyHost, $ProxyPort
Write-Host ("Target: near {0} Mbps (pass floor: {1} Mbps)" -f $TargetCombinedMbps, $targetFloor) -ForegroundColor White
Write-Host ("Proxy endpoint: {0}" -f $proxyUri) -ForegroundColor White
Write-Host ("Adapters under test: {0}" -f ($AdapterNames -join ", ")) -ForegroundColor White

$configPath = Join-Path $PSScriptRoot "config\config.json"
$decisionsPath = Join-Path $PSScriptRoot "config\decisions.json"
$config = Get-JsonFile -Path $configPath

Write-Section -Title "STEP 1: Adapter And Route Baseline"
$adapterDiag = Get-AdapterDiagnostics -Names $AdapterNames
foreach ($d in $adapterDiag) {
    if (-not $d.Exists) {
        Write-Host ("  {0}: MISSING" -f $d.Name) -ForegroundColor Red
        Add-InvestigationIssue -Domain "routing" -Issue "Adapter missing" -Evidence $d.Name -Action "Use valid adapter names and ensure both adapters are enabled."
        continue
    }

    Write-Host ("  {0}: Status={1}, IP={2}, GW={3}, RouteMetric={4}, IfMetric={5}, AutoMetric={6}" -f $d.Name, $d.Status, $d.IPAddress, $d.Gateway, $d.RouteMetric, $d.InterfaceMetric, $d.AutomaticMetric)

    if ($d.Status -ne 'Up') {
        Add-InvestigationIssue -Domain "routing" -Issue "Adapter is not Up" -Evidence ("{0} status={1}" -f $d.Name, $d.Status) -Action "Bring adapter up before throughput testing."
    }
    if (-not $d.HasIPv4) {
        Add-InvestigationIssue -Domain "routing" -Issue "Missing usable IPv4" -Evidence ("{0} has no non-APIPA IPv4" -f $d.Name) -Action "Repair DHCP/static IP before proceeding."
    }
    if (-not $d.HasDefaultRoute) {
        Add-InvestigationIssue -Domain "routing" -Issue "Missing default route" -Evidence ("{0} has no 0.0.0.0/0 route" -f $d.Name) -Action "Ensure each adapter has a valid gateway/default route."
    }
    if ($d.AutomaticMetric -notmatch 'Disabled|False|0') {
        Add-InvestigationIssue -Domain "routing" -Issue "Automatic metric still enabled" -Evidence ("{0} AutomaticMetric={1}" -f $d.Name, $d.AutomaticMetric) -Action "Disable AutomaticMetric and set deterministic interface metrics."
    }
}

$validMetrics = @($adapterDiag | Where-Object { $_.Exists -and $_.InterfaceMetric -ge 0 } | Select-Object -ExpandProperty InterfaceMetric)
if ($validMetrics.Count -ge 2) {
    $spread = ([double]($validMetrics | Measure-Object -Maximum).Maximum) - ([double]($validMetrics | Measure-Object -Minimum).Minimum)
    if ($spread -gt 10) {
        Add-InvestigationIssue -Domain "routing" -Issue "Interface metrics are heavily skewed" -Evidence ("Metric spread={0}" -f $spread) -Action "Align metrics (or enforce ECMP) to avoid one-link domination."
    }
}

Write-Section -Title "STEP 2: Direct Adapter Baselines"
$directResults = @()
foreach ($d in $adapterDiag | Where-Object { $_.Exists -and $_.HasIPv4 }) {
    Write-Host ("  Testing direct bound throughput on {0} ({1})..." -f $d.Name, $d.IPAddress) -ForegroundColor DarkYellow
    $direct = Invoke-DirectBaseline -AdapterName $d.Name -LocalIP $d.IPAddress -DownloadHost $TestHost -UrlTemplate $TestUrlTemplate -Bytes $DirectTestBytes -Attempts $DirectAttempts
    $directResults += $direct

    foreach ($attempt in $direct.Attempts) {
        $color = if ($attempt.Ok) { 'Green' } else { 'Red' }
        Write-Host ("    Attempt {0}: {1} Mbps (HTTP {2})" -f $attempt.Attempt, $attempt.Mbps, $attempt.HttpCode) -ForegroundColor $color
    }

    if ($direct.BestMbps -le 0) {
        Add-InvestigationIssue -Domain "adapter-utilization" -Issue "Direct adapter test failed" -Evidence ("{0} direct baseline is 0 Mbps" -f $d.Name) -Action "Fix adapter-specific connectivity/quality before proxy-level conclusions."
    }
}

$directSum = 0.0
foreach ($dr in $directResults) { $directSum += [double]$dr.BestMbps }
$directSum = [math]::Round($directSum, 2)
Write-Host ("  Direct baseline sum: {0} Mbps" -f $directSum) -ForegroundColor Cyan

Write-Section -Title "STEP 3: Proxy Combined Throughput Sweep"
$runs = @()
$sweep = @($ConcurrencySweep | Where-Object { $_ -ge 1 } | Sort-Object -Unique)
if ($sweep.Count -eq 0) { $sweep = @(16, 24, 32, 48, 64) }

foreach ($concurrency in $sweep) {
    Write-Host ("  Running proxy sweep at concurrency={0} ..." -f $concurrency) -ForegroundColor DarkYellow
    $run = Invoke-ProxySweepRun -Adapters $AdapterNames -ProxyUri $proxyUri -DownloadHost $TestHost -UrlTemplate $TestUrlTemplate -Concurrency $concurrency -BytesPerConnection $ProxyTestBytesPerConnection -MaxTimeSec $ProxyRunTimeoutSec
    $runs += $run

    $shareParts = @()
    foreach ($name in $AdapterNames) {
        $shareParts += ("{0}:{1}% ({2} Mbps)" -f $name, $run.AdapterSharePct[$name], $run.AdapterMbps[$name])
    }
    Write-Host ("    counter={0} Mbps | transfer={1} Mbps | ok={2}/{3} | gap={4}% | {5}" -f $run.CounterMbps, $run.TransferMbps, $run.SuccessCount, $run.Concurrency, $run.MeasurementGapPct, ($shareParts -join " | "))

    if ($run.CounterMbps -ge $targetFloor -and $run.MinSharePct -ge 20 -and $run.SuccessCount -ge [math]::Floor($run.Concurrency * 0.9)) {
        Write-Host "    Pass floor reached with healthy distribution. Stopping sweep early." -ForegroundColor Green
        break
    }
}

if ($runs.Count -eq 0) {
    Write-Host "No sweep results were produced." -ForegroundColor Red
    exit 1
}

$bestRun = $runs | Sort-Object CounterMbps -Descending | Select-Object -First 1
Write-Host ("  Best combined run: {0} Mbps at concurrency {1}" -f $bestRun.CounterMbps, $bestRun.Concurrency) -ForegroundColor Cyan

Write-Section -Title "STEP 4: Telemetry Cross-Checks"
$dashboard = Get-DashboardStats -RootPath $PSScriptRoot -Port $DashboardPort
$proxyStats = if ($dashboard -and $dashboard.proxy) { $dashboard.proxy } else { $null }
$decisionsData = Get-JsonFile -Path $decisionsPath
$decisions = if ($decisionsData -and $decisionsData.decisions) { @($decisionsData.decisions) } else { @() }
$proxyTotalConnections = 0
$proxyTotalFailures = 0
$proxyActiveConnections = 0
$proxyCurrentMaxThreads = 0
$proxySessionMapSize = 0
$proxyAdapterStats = @()

if ($proxyStats) {
    $proxyTotalConnections = [int](Get-ObjectPropertyValue -Object $proxyStats -Name "totalConnections" -Default 0)
    $proxyTotalFailures = [int](Get-ObjectPropertyValue -Object $proxyStats -Name "totalFailures" -Default 0)
    $proxyActiveConnections = [int](Get-ObjectPropertyValue -Object $proxyStats -Name "activeConnections" -Default 0)
    $proxyCurrentMaxThreads = [int](Get-ObjectPropertyValue -Object $proxyStats -Name "currentMaxThreads" -Default 0)
    $sessionMapRaw = Get-ObjectPropertyValue -Object $proxyStats -Name "sessionMapSize" -Default $null
    if ($null -eq $sessionMapRaw) {
        $sessionStats = Get-ObjectPropertyValue -Object $proxyStats -Name "sessionStats" -Default $null
        if ($sessionStats) {
            $sessionMapRaw = Get-ObjectPropertyValue -Object $sessionStats -Name "activeSessionCount" -Default 0
        }
    }
    if ($null -ne $sessionMapRaw) {
        $proxySessionMapSize = [int]$sessionMapRaw
    } else {
        $proxySessionMapSize = 0
    }
    $proxyAdapterStats = @(
        Get-ObjectPropertyValue -Object $proxyStats -Name "adapters" -Default @()
    )
    Write-Host ("  Proxy totalConnections={0}, totalFailures={1}, activeConnections={2}, currentMaxThreads={3}" -f $proxyTotalConnections, $proxyTotalFailures, $proxyActiveConnections, $proxyCurrentMaxThreads)
} else {
    Write-Host "  Dashboard proxy stats unavailable." -ForegroundColor Yellow
    Add-InvestigationIssue -Domain "measurement" -Issue "Dashboard stats unavailable" -Evidence "Cannot read /api/stats" -Action "Ensure dashboard is running so proxy internals can be verified."
}

Write-Host ("  Decisions sampled: {0}" -f $decisions.Count)

$stickyCount = 0
$decisionCounts = @{}
foreach ($name in $AdapterNames) { $decisionCounts[$name] = 0 }
foreach ($d in $decisions) {
    $decAdapter = [string](Get-ObjectPropertyValue -Object $d -Name "adapter" -Default "")
    if ($decAdapter -and $decisionCounts.ContainsKey($decAdapter)) {
        $decisionCounts[$decAdapter] = [int]$decisionCounts[$decAdapter] + 1
    }
    $affinityMode = [string](Get-ObjectPropertyValue -Object $d -Name "affinity_mode" -Default "")
    if ($affinityMode -match 'sticky') {
        $stickyCount++
    }
}

if ($decisions.Count -gt 0) {
    $parts = @()
    foreach ($name in $AdapterNames) {
        $parts += ("{0}:{1}" -f $name, $decisionCounts[$name])
    }
    Write-Host ("  Decision distribution: {0}" -f ($parts -join " | "))
    Write-Host ("  Sticky decisions: {0}/{1}" -f $stickyCount, $decisions.Count)
}

Write-Section -Title "STEP 5: Inefficiency Elimination Matrix"

# Software inefficiencies
if ($config) {
    $cfgProxy = Get-ObjectPropertyValue -Object $config -Name "proxy" -Default $null
} else {
    $cfgProxy = $null
}
if ($cfgProxy) {
    $cfgMaxThreads = [int](Get-ObjectPropertyValue -Object $cfgProxy -Name "maxThreads" -Default 0)
    $cfgMinThreads = [int](Get-ObjectPropertyValue -Object $cfgProxy -Name "minThreads" -Default 0)
    if ($cfgMaxThreads -lt 512) {
        Add-InvestigationIssue -Domain "software" -Issue "Proxy maxThreads is conservative" -Evidence ("proxy.maxThreads={0}" -f $cfgMaxThreads) -Action "Increase proxy.maxThreads to at least 512 for high-throughput validation."
    }
    if ($cfgMinThreads -lt 64) {
        Add-InvestigationIssue -Domain "software" -Issue "Proxy minThreads is low" -Evidence ("proxy.minThreads={0}" -f $cfgMinThreads) -Action "Use minThreads >= 64 to reduce burst cold-start latency."
    }
}
if ($bestRun.SuccessCount -lt [math]::Floor($bestRun.Concurrency * 0.9)) {
    Add-InvestigationIssue -Domain "software" -Issue "Too many transfer failures at best run" -Evidence ("success={0}/{1}" -f $bestRun.SuccessCount, $bestRun.Concurrency) -Action "Raise thread headroom and inspect proxy overload/retries."
}
if ($proxyStats -and $bestRun.Concurrency -gt 0 -and $proxyCurrentMaxThreads -gt 0 -and $proxyCurrentMaxThreads -lt $bestRun.Concurrency) {
    Add-InvestigationIssue -Domain "software" -Issue "Runtime thread cap below test concurrency" -Evidence ("currentMaxThreads={0}, testConcurrency={1}" -f $proxyCurrentMaxThreads, $bestRun.Concurrency) -Action "Increase maxThreads or rerun with higher stabilized pool size."
}

# Routing inefficiencies
$cfgRouting = if ($config) { Get-ObjectPropertyValue -Object $config -Name "routing" -Default $null } else { $null }
$enforceEcmp = if ($cfgRouting) { Get-ObjectPropertyValue -Object $cfgRouting -Name "enforceECMP" -Default $null } else { $null }
if ($null -ne $enforceEcmp -and -not [bool]$enforceEcmp) {
    Add-InvestigationIssue -Domain "routing" -Issue "ECMP enforcement is disabled" -Evidence "routing.enforceECMP=false" -Action "Enable ECMP enforcement when validating equal-path throughput."
}

# Proxy inefficiencies
if ($proxyStats -and $proxyTotalFailures -gt 0) {
    Add-InvestigationIssue -Domain "proxy" -Issue "Proxy reported connection failures" -Evidence ("totalFailures={0}" -f $proxyTotalFailures) -Action "Inspect retry path and adapter binding failures before blaming WAN."
}
if ($proxyAdapterStats -and $proxyAdapterStats.Count -gt 0) {
    foreach ($a in $proxyAdapterStats) {
        $adapterName = [string](Get-ObjectPropertyValue -Object $a -Name "name" -Default "unknown")
        $adapterFailures = [int](Get-ObjectPropertyValue -Object $a -Name "failures" -Default 0)
        if ($adapterFailures -gt 0) {
            Add-InvestigationIssue -Domain "proxy" -Issue "Per-adapter proxy failures observed" -Evidence ("{0}: failures={1}" -f $adapterName, $adapterFailures) -Action "Review binding/connect errors for this adapter."
        }
    }
}

# Balancing inefficiencies
if ($bestRun.MinSharePct -lt 20) {
    Add-InvestigationIssue -Domain "balancing" -Issue "Best run still has one adapter under 20% share" -Evidence ("minShare={0}%" -f $bestRun.MinSharePct) -Action "Increase bulk distribution pressure and recheck scheduler fairness."
}
if ($decisions.Count -ge 20) {
    $minDecisionShare = 100.0
    foreach ($name in $AdapterNames) {
        $pct = ([double]$decisionCounts[$name] * 100.0) / [double]$decisions.Count
        if ($pct -lt $minDecisionShare) { $minDecisionShare = $pct }
    }
    if ($minDecisionShare -lt 20.0) {
        Add-InvestigationIssue -Domain "balancing" -Issue "Decision log is heavily skewed toward one adapter" -Evidence ("minDecisionShare={0}%" -f [math]::Round($minDecisionShare, 1)) -Action "Inspect bulk selection thresholds and adapter weight skew."
    }
}

# Session inefficiencies
if ($cfgProxy) {
    $sessionTtl = [int](Get-ObjectPropertyValue -Object $cfgProxy -Name "sessionAffinityTTL" -Default 0)
    if ($sessionTtl -gt 120) {
        Add-InvestigationIssue -Domain "session" -Issue "Session affinity TTL is long for throughput mode" -Evidence ("sessionAffinityTTL={0}s" -f $sessionTtl) -Action "Reduce sessionAffinityTTL to 60-120s during max-throughput validation."
    }
}
if ($proxyStats -and $proxySessionMapSize -gt 200) {
    Add-InvestigationIssue -Domain "session" -Issue "Large active session map may over-stabilize routing" -Evidence ("sessionMapSize={0}" -f $proxySessionMapSize) -Action "Shorten TTL and verify bulk traffic skips sticky mapping."
}
if ($decisions.Count -ge 20) {
    $stickyPct = [math]::Round(($stickyCount * 100.0) / [double]$decisions.Count, 1)
    if ($stickyPct -gt 35) {
        Add-InvestigationIssue -Domain "session" -Issue "Sticky affinity dominates decision stream" -Evidence ("stickyPct={0}%" -f $stickyPct) -Action "Lower stickiness for throughput-centric traffic classes."
    }
}

# Adapter utilization inefficiencies
$directByAdapter = @{}
foreach ($dr in $directResults) { $directByAdapter[$dr.Adapter] = [double]$dr.BestMbps }
foreach ($name in $AdapterNames) {
    $directMbps = if ($directByAdapter.ContainsKey($name)) { [double]$directByAdapter[$name] } else { 0.0 }
    $runMbps = if ($bestRun.AdapterMbps.ContainsKey($name)) { [double]$bestRun.AdapterMbps[$name] } else { 0.0 }
    if ($directMbps -ge 20) {
        $ratio = if ($directMbps -gt 0) { $runMbps / $directMbps } else { 0.0 }
        if ($ratio -lt 0.5) {
            Add-InvestigationIssue -Domain "adapter-utilization" -Issue "Adapter under-utilized vs direct baseline" -Evidence ("{0}: run/direct ratio={1}" -f $name, [math]::Round($ratio, 2)) -Action "Tune scheduler pressure and verify this adapter receives enough bulk sessions."
        }
    }
}

# Measurement inefficiencies
if ($bestRun.TransferBytes -le 0) {
    Add-InvestigationIssue -Domain "measurement" -Issue "No successful transfer bytes reported" -Evidence "curl transfer bytes=0" -Action "Fix test endpoint/proxy connectivity before interpreting throughput."
}
if ($bestRun.CounterBytes -le 0) {
    Add-InvestigationIssue -Domain "measurement" -Issue "Adapter counters did not move" -Evidence "counter bytes=0" -Action "Verify adapter names and ensure traffic actually traverses tested adapters."
}
if ($bestRun.MeasurementGapPct -gt 20) {
    Add-InvestigationIssue -Domain "measurement" -Issue "Counter vs transfer mismatch is high" -Evidence ("measurement gap={0}%" -f $bestRun.MeasurementGapPct) -Action "Repeat test with larger payloads and stable run duration."
}
if ($bestRun.ElapsedSec -lt 5) {
    Add-InvestigationIssue -Domain "measurement" -Issue "Best run too short for stable throughput estimate" -Evidence ("elapsed={0}s" -f $bestRun.ElapsedSec) -Action "Increase bytes per connection for longer measurement windows."
}

$domains = @("software", "routing", "proxy", "balancing", "session", "adapter-utilization", "measurement")
foreach ($domain in $domains) {
    $count = @($issues | Where-Object { $_.Domain -eq $domain }).Count
    $status = if ($count -eq 0) { "CLEARED" } else { "OPEN($count)" }
    $color = if ($count -eq 0) { "Green" } else { "Yellow" }
    Write-Host ("  {0}: {1}" -f $domain, $status) -ForegroundColor $color
}

Write-Section -Title "FINAL VERDICT" -Color "Cyan"
$belowTarget = $bestRun.CounterMbps -lt $targetFloor
$nearTargetReached = -not $belowTarget
$externalBottleneckAccepted = $false

if ($nearTargetReached) {
    Write-Host ("PASS: Combined throughput {0} Mbps meets near-target floor ({1} Mbps)." -f $bestRun.CounterMbps, $targetFloor) -ForegroundColor Green
    exit 0
}

if ($issues.Count -gt 0) {
    Write-Host ("PROBLEM: Combined throughput {0} Mbps is below floor ({1} Mbps), and internal inefficiencies remain." -f $bestRun.CounterMbps, $targetFloor) -ForegroundColor Red
    foreach ($i in $issues) {
        Write-Host ("  [{0}] {1}" -f $i.Domain, $i.Issue) -ForegroundColor Yellow
        Write-Host ("      Evidence: {0}" -f $i.Evidence) -ForegroundColor DarkGray
        Write-Host ("      Action:   {0}" -f $i.Action) -ForegroundColor DarkGray
    }
    exit 2
}

# No internal inefficiency flags remain. Evaluate external bottleneck proof.
if ($directSum -lt $targetFloor) {
    $externalBottleneckAccepted = $true
    Write-Host ("EXTERNAL BOTTLENECK ACCEPTED: Direct adapter sum ({0} Mbps) is below the near-target floor ({1} Mbps) after internal checks cleared." -f $directSum, $targetFloor) -ForegroundColor Cyan
}

if (-not $externalBottleneckAccepted) {
    $utilizationRatios = @()
    foreach ($name in $AdapterNames) {
        $directMbps = if ($directByAdapter.ContainsKey($name)) { [double]$directByAdapter[$name] } else { 0.0 }
        $runMbps = if ($bestRun.AdapterMbps.ContainsKey($name)) { [double]$bestRun.AdapterMbps[$name] } else { 0.0 }
        if ($directMbps -gt 0) {
            $utilizationRatios += ($runMbps / $directMbps)
        }
    }
    $minUtilization = if ($utilizationRatios.Count -gt 0) { ($utilizationRatios | Measure-Object -Minimum).Minimum } else { 0.0 }
    if ($directSum -gt 0 -and $bestRun.CounterMbps -ge ($directSum * 0.85) -and $minUtilization -ge 0.75) {
        $externalBottleneckAccepted = $true
        Write-Host ("EXTERNAL BOTTLENECK ACCEPTED: Combined throughput is near measured direct-capacity ceiling ({0}/{1} Mbps) with healthy adapter utilization." -f $bestRun.CounterMbps, $directSum) -ForegroundColor Cyan
    }
}

if ($externalBottleneckAccepted) {
    exit 3
}

Write-Host ("PROBLEM: Combined throughput ({0} Mbps) is still below floor ({1} Mbps). Cause remains unproven, continue investigation." -f $bestRun.CounterMbps, $targetFloor) -ForegroundColor Red
exit 2
