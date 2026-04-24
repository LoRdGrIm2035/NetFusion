# === NetFusion Real Combined Speed Verification ===
# Measures direct per-adapter capacity and proxied aggregate throughput using
# source-bound curl plus OS byte counters. No adapter names are hardcoded.

[CmdletBinding()]
param(
    [string[]]$AdapterNames = @(),
    [int]$Connections = 0,
    [string]$TestUrl = "https://speed.cloudflare.com/__down?bytes=100000000",
    [string]$UploadUrl = "https://speed.cloudflare.com/__up",
    [int]$UploadMegabytes = 32,
    [int]$ProxyPort = 8080,
    [int]$DashboardPort = 9090
)

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  NetFusion Combined Speed Verifier          " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

function Get-DashboardStats {
    param([int]$Port)

    $tokenFile = Join-Path $PSScriptRoot "config\dashboard-token.txt"
    if (-not (Test-Path $tokenFile)) {
        throw "Dashboard token file not found: $tokenFile"
    }

    $token = (Get-Content $tokenFile -Raw -ErrorAction Stop).Trim()
    return Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/stats" -Headers @{ "X-NetFusion-Token" = $token } -Method Get
}

function Get-LinkSpeedMbps {
    param([AllowNull()][object]$LinkSpeed)
    $text = [string]$LinkSpeed
    if ($text -match '([\d.]+)\s*(Gbps|Mbps|Kbps)') {
        $value = [double]$Matches[1]
        switch ($Matches[2]) {
            'Gbps' { return ($value * 1000.0) }
            'Mbps' { return $value }
            'Kbps' { return ($value / 1000.0) }
        }
    }
    return 0.0
}

function Add-CacheBuster {
    param(
        [string]$Url,
        [string]$Name = 'r'
    )

    $separator = if ($Url -match '\?') { '&' } else { '?' }
    return ('{0}{1}{2}={3}' -f $Url, $separator, $Name, ([guid]::NewGuid().ToString('N')))
}

function Get-UsableAdapters {
    $interfacesPath = Join-Path $PSScriptRoot "config\interfaces.json"
    $fromState = @()
    if (Test-Path $interfacesPath) {
        try {
            $state = Get-Content $interfacesPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($iface in @($state.interfaces)) {
                $ip = if ($iface.IPAddress) { [string]$iface.IPAddress } else { [string]$iface.IpAddress }
                if ($iface.Status -eq 'Up' -and $ip -and $ip -notmatch '^169\.254\.' -and $iface.Gateway) {
                    $fromState += [pscustomobject]@{
                        Name = [string]$iface.Name
                        InterfaceIndex = [int]$iface.InterfaceIndex
                        IPAddress = $ip
                        Gateway = [string]$iface.Gateway
                        Type = [string]$iface.Type
                        LinkSpeedMbps = if ($null -ne $iface.LinkSpeedMbps) { [double]$iface.LinkSpeedMbps } else { 0.0 }
                    }
                }
            }
        } catch {}
    }

    if ($fromState.Count -ge 2) {
        return @($fromState)
    }

    $results = @()
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|OpenVPN|WireGuard|TAP-Windows|Cisco AnyConnect|Tailscale|ZeroTier'
    }

    foreach ($adapter in @($adapters)) {
        $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
            Select-Object -First 1
        if (-not $ip) { continue }

        $route = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric |
            Select-Object -First 1
        if (-not $route -or -not $route.NextHop) { continue }

        $type = if ($adapter.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11|WLAN' -or $adapter.Name -match 'Wi-Fi|Wireless') {
            if ($adapter.InterfaceDescription -match 'USB|TP-Link|Realtek.*USB|Ralink.*USB|MediaTek.*USB') { 'USB-WiFi' } else { 'WiFi' }
        } elseif ($adapter.InterfaceDescription -match 'Ethernet|GbE|2\.5G|5G|10G' -or $adapter.Name -match 'Ethernet') {
            'Ethernet'
        } else {
            'Unknown'
        }

        $results += [pscustomobject]@{
            Name = $adapter.Name
            InterfaceIndex = [int]$adapter.ifIndex
            IPAddress = $ip.IPAddress
            Gateway = [string]$route.NextHop
            Type = $type
            LinkSpeedMbps = Get-LinkSpeedMbps $adapter.LinkSpeed
        }
    }

    return @($results)
}

function Invoke-BoundCurlDownload {
    param(
        [string]$LocalIP,
        [string]$Url,
        [string]$Proxy = ''
    )

    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curlCmd) {
        throw "curl.exe is required for adapter-bound testing but was not found."
    }

    $format = "SIZE=%{size_download};TIME=%{time_total};SPEED=%{speed_download};IP=%{local_ip};CODE=%{http_code}"
    $args = @('--interface', $LocalIP, '-L', '-o', 'NUL', '-sS', '-w', $format)
    if ($Proxy) {
        $args = @('-x', $Proxy) + $args
    } else {
        $args = @('--noproxy', '*') + $args
    }
    $args += $Url

    $output = & $curlCmd.Source @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }

    $text = ($output | Out-String).Trim()
    $result = @{}
    foreach ($part in ($text -split ';')) {
        if ($part -match '^(SIZE|TIME|SPEED|IP|CODE)=(.*)$') {
            $result[$Matches[1]] = $Matches[2]
        }
    }

    if (-not $result.ContainsKey('SIZE') -or -not $result.ContainsKey('TIME')) {
        throw "curl.exe returned unexpected output: $text"
    }

    return @{
        Bytes = [double]$result['SIZE']
        Seconds = [double]$result['TIME']
        SpeedBytesPerSec = if ($result.ContainsKey('SPEED')) { [double]$result['SPEED'] } else { 0.0 }
        LocalIP = if ($result.ContainsKey('IP')) { $result['IP'] } else { $LocalIP }
        StatusCode = if ($result.ContainsKey('CODE')) { [int]$result['CODE'] } else { 0 }
    }
}

function Invoke-BoundCurlUpload {
    param(
        [string]$LocalIP,
        [string]$Url,
        [string]$PayloadPath,
        [string]$Proxy = ''
    )

    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curlCmd) {
        throw "curl.exe is required for adapter-bound testing but was not found."
    }

    $format = "SIZE=%{size_upload};TIME=%{time_total};SPEED=%{speed_upload};IP=%{local_ip};CODE=%{http_code}"
    $args = @('--interface', $LocalIP, '-L', '-o', 'NUL', '-sS', '-w', $format, '-X', 'POST', '--data-binary', "@$PayloadPath")
    if ($Proxy) {
        $args = @('-x', $Proxy) + $args
    } else {
        $args = @('--noproxy', '*') + $args
    }
    $args += $Url

    $output = & $curlCmd.Source @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }

    $text = ($output | Out-String).Trim()
    $result = @{}
    foreach ($part in ($text -split ';')) {
        if ($part -match '^(SIZE|TIME|SPEED|IP|CODE)=(.*)$') {
            $result[$Matches[1]] = $Matches[2]
        }
    }

    if (-not $result.ContainsKey('SIZE') -or -not $result.ContainsKey('TIME')) {
        throw "curl.exe returned unexpected upload output: $text"
    }

    return @{
        Bytes = [double]$result['SIZE']
        Seconds = [double]$result['TIME']
        SpeedBytesPerSec = if ($result.ContainsKey('SPEED')) { [double]$result['SPEED'] } else { 0.0 }
        LocalIP = if ($result.ContainsKey('IP')) { $result['IP'] } else { $LocalIP }
        StatusCode = if ($result.ContainsKey('CODE')) { [int]$result['CODE'] } else { 0 }
    }
}

function Get-RxBytes {
    param([string]$Name)
    $stats = Get-NetAdapterStatistics -Name $Name -ErrorAction SilentlyContinue
    if ($stats) { return [int64]$stats.ReceivedBytes }
    return 0L
}

function Get-TxBytes {
    param([string]$Name)
    $stats = Get-NetAdapterStatistics -Name $Name -ErrorAction SilentlyContinue
    if ($stats) { return [int64]$stats.SentBytes }
    return 0L
}

$adapters = @(Get-UsableAdapters)
if ($AdapterNames.Count -gt 0) {
    $nameSet = @($AdapterNames | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $adapters = @($adapters | Where-Object { $_.Name -in $nameSet })
}

$adapters = @($adapters | Sort-Object @{ Expression = { -1 * [double]$_.LinkSpeedMbps } }, Name)

Write-Host "`n--- STEP 1: Adapter Check ---" -ForegroundColor Yellow
if ($adapters.Count -lt 2) {
    Write-Host "  [FAIL] Need at least 2 usable adapters with IPv4 and default gateways. Found: $($adapters.Count)" -ForegroundColor Red
    if ($adapters.Count -eq 1) {
        Write-Host "  Found: $($adapters[0].Name) $($adapters[0].IPAddress) via $($adapters[0].Gateway)"
    }
    exit 1
}

foreach ($adapter in $adapters) {
    Write-Host ("  {0}: {1} [{2}] gateway={3} link={4} Mbps" -f $adapter.Name, $adapter.IPAddress, $adapter.Type, $adapter.Gateway, [math]::Round($adapter.LinkSpeedMbps, 0))
}

Write-Host "`n--- STEP 2: Route Check ---" -ForegroundColor Yellow
foreach ($adapter in $adapters) {
    $routes = @(Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric)
    if ($routes.Count -eq 0) {
        Write-Host "  [FAIL] $($adapter.Name) has no default route." -ForegroundColor Red
    } else {
        foreach ($route in $routes) {
            Write-Host "  $($adapter.Name) -> $($route.NextHop) (route metric: $($route.RouteMetric))"
        }
    }
}

Write-Host "`n--- STEP 3: Adapter-Bound Direct Download Test ---" -ForegroundColor Yellow
$directResults = @{}
foreach ($adapter in $adapters) {
    Write-Host "  Testing $($adapter.Name) ($($adapter.IPAddress))..." -NoNewline
    try {
        $result = Invoke-BoundCurlDownload -LocalIP $adapter.IPAddress -Url $TestUrl
        $mbps = if ($result.Seconds -gt 0) { [math]::Round(($result.Bytes * 8 / 1MB) / $result.Seconds, 2) } else { 0 }
        $directResults[$adapter.Name] = $mbps
        Write-Host " $mbps Mbps ($([math]::Round($result.Bytes/1MB, 1)) MB in $([math]::Round($result.Seconds, 2))s, source $($result.LocalIP))" -ForegroundColor Green
    } catch {
        $directResults[$adapter.Name] = 0.0
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n--- STEP 4: Adapter-Bound Direct Upload Test ---" -ForegroundColor Yellow
$uploadPayloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("netfusion-upload-{0}.bin" -f $PID)
$payloadStream = [System.IO.File]::Open($uploadPayloadPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
try {
    $payloadStream.SetLength([int64]$UploadMegabytes * 1MB)
} finally {
    $payloadStream.Close()
}

$directUploadResults = @{}
foreach ($adapter in $adapters) {
    Write-Host "  Testing $($adapter.Name) ($($adapter.IPAddress)) upload..." -NoNewline
    try {
        $uploadResult = Invoke-BoundCurlUpload -LocalIP $adapter.IPAddress -Url (Add-CacheBuster -Url $UploadUrl) -PayloadPath $uploadPayloadPath
        $uploadMbps = if ($uploadResult.Seconds -gt 0) { [math]::Round(($uploadResult.Bytes * 8 / 1MB) / $uploadResult.Seconds, 2) } else { 0 }
        $directUploadResults[$adapter.Name] = $uploadMbps
        Write-Host " $uploadMbps Mbps ($([math]::Round($uploadResult.Bytes/1MB, 1)) MB in $([math]::Round($uploadResult.Seconds, 2))s, source $($uploadResult.LocalIP))" -ForegroundColor Green
    } catch {
        $directUploadResults[$adapter.Name] = 0.0
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n--- STEP 5: Combined Proxy Download Throughput Test ---" -ForegroundColor Yellow
if ($Connections -le 0) {
    $Connections = [math]::Max(32, $adapters.Count * 16)
}
Write-Host "  Using $Connections parallel connections through proxy 127.0.0.1:$ProxyPort"

$before = @{}
foreach ($adapter in $adapters) {
    $before[$adapter.Name] = Get-RxBytes -Name $adapter.Name
}

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
$proxyAddr = "http://127.0.0.1:$ProxyPort"
$jobs = 1..$Connections | ForEach-Object {
    $jobUrl = Add-CacheBuster -Url $TestUrl
    Start-Job -ScriptBlock {
        param($url, $proxy)
        try {
            $curlCmd = Get-Command curl.exe -ErrorAction Stop
            $format = "SIZE=%{size_download};TIME=%{time_total};CODE=%{http_code}"
            $output = & $curlCmd.Source -x $proxy -L -o NUL -sS -w $format $url 2>&1
            $text = ($output | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { return 0L }
            if ($text -notmatch 'SIZE=(\d+);TIME=([0-9.]+);CODE=(\d+)') { return 0L }
            $code = [int]$Matches[3]
            if ($code -lt 200 -or $code -ge 400) { return 0L }
            return [int64]$Matches[1]
        } catch {
            return 0L
        }
    } -ArgumentList $jobUrl, $proxyAddr
}

Write-Host "  Downloading..." -NoNewline
$null = Wait-Job -Job $jobs -Timeout 90
$swTotal.Stop()

$totalBytes = 0L
foreach ($job in $jobs) {
    $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
    if ($result) { $totalBytes += [int64]$result }
}
Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
Write-Host " Done!" -ForegroundColor Green

$after = @{}
$deltas = @{}
$totalDelta = 0L
foreach ($adapter in $adapters) {
    $after[$adapter.Name] = Get-RxBytes -Name $adapter.Name
    $delta = [math]::Max(0L, ([int64]$after[$adapter.Name] - [int64]$before[$adapter.Name]))
    $deltas[$adapter.Name] = $delta
    $totalDelta += $delta
}

$combinedMbps = if ($swTotal.Elapsed.TotalSeconds -gt 0) { [math]::Round(($totalBytes * 8 / 1MB) / $swTotal.Elapsed.TotalSeconds, 2) } else { 0 }
$bestDirectMbps = if ($directResults.Count -gt 0) { [double](($directResults.Values | Measure-Object -Maximum).Maximum) } else { 0 }
$sumDirectMbps = if ($directResults.Count -gt 0) { [double](($directResults.Values | Measure-Object -Sum).Sum) } else { 0 }
$gainVsBest = [math]::Round(($combinedMbps - $bestDirectMbps), 2)
$efficiencyVsDirectSum = if ($sumDirectMbps -gt 0) { [math]::Round(($combinedMbps / $sumDirectMbps) * 100, 1) } else { 0 }

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  REAL COMBINED SPEED TEST RESULTS           " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Duration:             $([math]::Round($swTotal.Elapsed.TotalSeconds, 2)) seconds"
Write-Host "  Connections:          $Connections parallel"
Write-Host "  Total Downloaded:     $([math]::Round($totalBytes / 1MB, 2)) MB"
Write-Host "  Best Single-Link:     $bestDirectMbps Mbps" -ForegroundColor DarkCyan
Write-Host "  Sum Direct Links:     $([math]::Round($sumDirectMbps, 2)) Mbps" -ForegroundColor DarkCyan
Write-Host "  Combined Proxy Speed: $combinedMbps Mbps" -ForegroundColor Cyan
Write-Host "  Gain vs Best Link:    $gainVsBest Mbps" -ForegroundColor Cyan
Write-Host "  Efficiency vs Sum:    $efficiencyVsDirectSum%" -ForegroundColor Cyan

Write-Host "`n  --- Per-Adapter Traffic (OS Byte Counters) ---" -ForegroundColor Yellow
$minPct = 100
foreach ($adapter in $adapters) {
    $delta = [int64]$deltas[$adapter.Name]
    $pct = if ($totalDelta -gt 0) { [math]::Round(($delta / $totalDelta) * 100, 1) } else { 0 }
    $minPct = [math]::Min($minPct, $pct)
    $bar = '#' * [math]::Max(1, [int]($pct / 2))
    $color = if ($pct -ge 10) { 'Green' } else { 'Red' }
    Write-Host ("  {0}: {1} MB ({2}%) [{3}]" -f $adapter.Name, [math]::Round($delta / 1MB, 2), $pct, $bar) -ForegroundColor $color
}

Write-Host ""
if ($minPct -lt 5) {
    Write-Host "  [PROBLEM] At least one adapter carried less than 5% of proxy traffic." -ForegroundColor Red
} elseif ($minPct -lt 15) {
    Write-Host "  [WARN] All adapters carried traffic, but distribution is heavily skewed." -ForegroundColor Yellow
} else {
    Write-Host "  [OK] All selected adapters actively carried proxy traffic." -ForegroundColor Green
}

if ($bestDirectMbps -gt 0) {
    if ($combinedMbps -le ($bestDirectMbps * 0.90)) {
        Write-Host "  [FAIL] Proxy path is slower than the best direct adapter by more than 10%." -ForegroundColor Red
    } elseif ($combinedMbps -le ($bestDirectMbps * 1.05)) {
        Write-Host "  [WARN] Combined proxy speed is not materially above the best single adapter." -ForegroundColor Yellow
    } else {
        Write-Host "  [GOOD] Combined proxy speed is above the best single adapter." -ForegroundColor Green
    }
}

Write-Host "`n--- STEP 6: Combined Proxy Upload Throughput Test ---" -ForegroundColor Yellow
$beforeTx = @{}
foreach ($adapter in $adapters) {
    $beforeTx[$adapter.Name] = Get-TxBytes -Name $adapter.Name
}

$swUploadTotal = [System.Diagnostics.Stopwatch]::StartNew()
$uploadJobs = 1..$Connections | ForEach-Object {
    $jobUrl = Add-CacheBuster -Url $UploadUrl
    Start-Job -ScriptBlock {
        param($url, $proxy, $payload)
        try {
            $curlCmd = Get-Command curl.exe -ErrorAction Stop
            $format = "SIZE=%{size_upload};TIME=%{time_total};CODE=%{http_code}"
            $output = & $curlCmd.Source -x $proxy -L -o NUL -sS -w $format -X POST --data-binary "@$payload" $url 2>&1
            $text = ($output | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { return 0L }
            if ($text -notmatch 'SIZE=(\d+);TIME=([0-9.]+);CODE=(\d+)') { return 0L }
            $code = [int]$Matches[3]
            if ($code -lt 200 -or $code -ge 400) { return 0L }
            return [int64]$Matches[1]
        } catch {
            return 0L
        }
    } -ArgumentList $jobUrl, $proxyAddr, $uploadPayloadPath
}

Write-Host "  Uploading..." -NoNewline
$null = Wait-Job -Job $uploadJobs -Timeout 120
$swUploadTotal.Stop()

$totalUploadBytes = 0L
foreach ($job in $uploadJobs) {
    $uploadJobResult = Receive-Job -Job $job -ErrorAction SilentlyContinue
    if ($uploadJobResult) { $totalUploadBytes += [int64]$uploadJobResult }
}
Remove-Job -Job $uploadJobs -Force -ErrorAction SilentlyContinue
Write-Host " Done!" -ForegroundColor Green

$afterTx = @{}
$txDeltas = @{}
$totalTxDelta = 0L
foreach ($adapter in $adapters) {
    $afterTx[$adapter.Name] = Get-TxBytes -Name $adapter.Name
    $txDelta = [math]::Max(0L, ([int64]$afterTx[$adapter.Name] - [int64]$beforeTx[$adapter.Name]))
    $txDeltas[$adapter.Name] = $txDelta
    $totalTxDelta += $txDelta
}

$combinedUploadMbps = if ($swUploadTotal.Elapsed.TotalSeconds -gt 0) { [math]::Round(($totalUploadBytes * 8 / 1MB) / $swUploadTotal.Elapsed.TotalSeconds, 2) } else { 0 }
$bestDirectUploadMbps = if ($directUploadResults.Count -gt 0) { [double](($directUploadResults.Values | Measure-Object -Maximum).Maximum) } else { 0 }
$sumDirectUploadMbps = if ($directUploadResults.Count -gt 0) { [double](($directUploadResults.Values | Measure-Object -Sum).Sum) } else { 0 }
$uploadEfficiencyVsDirectSum = if ($sumDirectUploadMbps -gt 0) { [math]::Round(($combinedUploadMbps / $sumDirectUploadMbps) * 100, 1) } else { 0 }

Write-Host "`n  --- Upload Results ---" -ForegroundColor Yellow
Write-Host "  Total Uploaded:       $([math]::Round($totalUploadBytes / 1MB, 2)) MB"
Write-Host "  Best Upload Link:     $bestDirectUploadMbps Mbps" -ForegroundColor DarkCyan
Write-Host "  Sum Upload Links:     $([math]::Round($sumDirectUploadMbps, 2)) Mbps" -ForegroundColor DarkCyan
Write-Host "  Combined Upload:      $combinedUploadMbps Mbps" -ForegroundColor Cyan
Write-Host "  Upload Efficiency:    $uploadEfficiencyVsDirectSum%" -ForegroundColor Cyan

Write-Host "`n  --- Per-Adapter Upload Traffic (OS Byte Counters) ---" -ForegroundColor Yellow
foreach ($adapter in $adapters) {
    $txDelta = [int64]$txDeltas[$adapter.Name]
    $pct = if ($totalTxDelta -gt 0) { [math]::Round(($txDelta / $totalTxDelta) * 100, 1) } else { 0 }
    $bar = '#' * [math]::Max(1, [int]($pct / 2))
    $color = if ($pct -ge 10) { 'Green' } else { 'Red' }
    Write-Host ("  {0}: {1} MB ({2}%) [{3}]" -f $adapter.Name, [math]::Round($txDelta / 1MB, 2), $pct, $bar) -ForegroundColor $color
}

try { Remove-Item $uploadPayloadPath -Force -ErrorAction SilentlyContinue } catch {}

Write-Host "`n--- Proxy Internal Stats ---" -ForegroundColor Yellow
try {
    $stats = Get-DashboardStats -Port $DashboardPort
    if ($stats -and $stats.proxy) {
        foreach ($adapter in @($stats.proxy.adapters)) {
            Write-Host "  $($adapter.name): $($adapter.connections) connections, $($adapter.successes) successes, $($adapter.failures) failures"
        }
    }
} catch {
    Write-Host "  Could not reach dashboard API: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host "=============================================" -ForegroundColor Cyan
