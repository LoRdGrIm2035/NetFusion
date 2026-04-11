# === NetFusion v6.1 — Real Combined Speed Verification ===
# This test HONESTLY measures whether both adapters carry real traffic
# No fakes, no estimates — raw byte counters from the OS

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ifFile = Join-Path $scriptDir "config\interfaces.json"
$tokenFile = Join-Path $scriptDir "config\dashboard-token.txt"

function Get-TestAdapters {
    param(
        [string]$InterfacesPath
    )

    $adapters = @()
    if (Test-Path $InterfacesPath) {
        try {
            $ifData = Get-Content $InterfacesPath -Raw | ConvertFrom-Json
            $rawInterfaces = @()
            if ($ifData.interfaces -is [System.Array]) {
                $rawInterfaces = @($ifData.interfaces)
            } elseif ($ifData.interfaces) {
                $rawInterfaces = @($ifData.interfaces)
            }

            $adapters = @(
                $rawInterfaces | Where-Object {
                    $_.Status -eq 'Up' -and $_.Type -match 'WiFi|USB-WiFi|Ethernet'
                }
            )
        } catch {
            Write-Host "[!] Failed to parse interfaces.json: $_" -ForegroundColor Red
        }
    }

    if ($adapters.Count -lt 2) {
        Write-Host "[!] interfaces.json missing or has <2 adapters -- falling back to OS detection" -ForegroundColor Yellow
        $adapters = @(
            Get-NetAdapter | Where-Object {
                $_.Status -eq 'Up' -and
                $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel'
            } | Select-Object -First 2
        )
    }

    return @($adapters)
}

function Resolve-AdapterDetails {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter
    )

    $name = $Adapter.Name
    $index = if ($Adapter.ifIndex) {
        [int]$Adapter.ifIndex
    } elseif ($Adapter.InterfaceIndex) {
        [int]$Adapter.InterfaceIndex
    } else {
        (Get-NetAdapter -Name $name -ErrorAction Stop).InterfaceIndex
    }

    $ipConfig = Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
        Select-Object -First 1

    $status = if ($Adapter.Status) {
        $Adapter.Status
    } else {
        (Get-NetAdapter -InterfaceIndex $index -ErrorAction SilentlyContinue).Status
    }

    [pscustomobject]@{
        Name           = $name
        InterfaceIndex = $index
        IPAddress      = if ($ipConfig) { $ipConfig.IPAddress } else { $null }
        Status         = $status
    }
}

function Invoke-BoundDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$LocalIPAddress
    )

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000

    $bindIP = [System.Net.IPAddress]::Parse($LocalIPAddress)
    $request.ServicePoint.BindIPEndPointDelegate = {
        param($servicePoint, $remoteEndPoint, $retryCount)
        return New-Object System.Net.IPEndPoint($bindIP, 0)
    }.GetNewClosure()

    $response = $null
    $responseStream = $null
    $memoryStream = $null
    try {
        $response = $request.GetResponse()
        $responseStream = $response.GetResponseStream()
        $memoryStream = New-Object System.IO.MemoryStream
        $responseStream.CopyTo($memoryStream)
        return $memoryStream.ToArray()
    } finally {
        if ($memoryStream) { $memoryStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Dispose() }
        $request.ServicePoint.BindIPEndPointDelegate = $null
    }
}

function Get-DashboardStats {
    param(
        [string]$TokenPath
    )

    $token = if (Test-Path $TokenPath) { (Get-Content $TokenPath -Raw).Trim() } else { "" }
    $headers = @()
    if ($token) {
        $headers = @('-H', "X-NetFusion-Token: $token")
    }

    $args = @('-s', 'http://127.0.0.1:9090/api/stats') + $headers
    $response = & curl.exe @args
    if ($LASTEXITCODE -ne 0 -or -not $response) {
        return $null
    }

    return $response | ConvertFrom-Json
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  NetFusion Combined Speed Verifier v6.1     " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$adapters = Get-TestAdapters -InterfacesPath $ifFile
if ($adapters.Count -lt 2) {
    Write-Host "[FAIL] Need 2+ network adapters for combined speed test. Found: $($adapters.Count)" -ForegroundColor Red
    exit 1
}

$adapterDetails = @(
    Resolve-AdapterDetails -Adapter $adapters[0]
    Resolve-AdapterDetails -Adapter $adapters[1]
)

# Step 1: Verify adapter status
Write-Host "`n--- STEP 1: Adapter Check ---" -ForegroundColor Yellow
foreach ($adapter in $adapterDetails) {
    $state = if ($adapter.Status -eq 'Up') { 'UP' } else { 'DOWN' }
    Write-Host "  $($adapter.Name): $($adapter.IPAddress) ($state)"
}

$invalidAdapters = @($adapterDetails | Where-Object { -not $_.IPAddress })
if ($invalidAdapters.Count -gt 0) {
    Write-Host "  [FAIL] One or more adapters have no valid IPv4 address. Cannot test combined speed." -ForegroundColor Red
    foreach ($adapter in $invalidAdapters) {
        Write-Host "         - $($adapter.Name)" -ForegroundColor DarkGray
    }
    exit 1
}

# Step 2: Check routes
Write-Host "`n--- STEP 2: Route Check ---" -ForegroundColor Yellow
$routeNames = $adapterDetails.Name
$routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $routeNames -contains $_.InterfaceAlias }
foreach ($r in $routes) {
    Write-Host "  $($r.InterfaceAlias) -> $($r.NextHop) (metric: $($r.RouteMetric))"
}
if ($routes.Count -lt 2) {
    Write-Host "  [WARN] Only $($routes.Count) route(s). Both adapters need a default route for ECMP." -ForegroundColor Red
}

# Step 3: Test per-adapter internet speed (1 connection each)
Write-Host "`n--- STEP 3: Per-Adapter Download Test ---" -ForegroundColor Yellow
$testURL = "http://speed.cloudflare.com/__down?bytes=10000000"  # 10MB

foreach ($adapter in $adapterDetails) {
    Write-Host "  Testing $($adapter.Name) ($($adapter.IPAddress))..." -NoNewline

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $data = Invoke-BoundDownload -Url $testURL -LocalIPAddress $adapter.IPAddress
        $sw.Stop()
        $mbps = [math]::Round(($data.Length * 8 / 1MB) / $sw.Elapsed.TotalSeconds, 2)
        Write-Host " $mbps Mbps ($([math]::Round($data.Length / 1MB, 1)) MB in $([math]::Round($sw.Elapsed.TotalSeconds, 2))s)" -ForegroundColor Green
    } catch {
        $sw.Stop()
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Step 4: Combined proxy test with live byte counting
Write-Host "`n--- STEP 4: Combined Proxy Throughput Test ---" -ForegroundColor Yellow
Write-Host "  Using $testURL through proxy 127.0.0.1:8080 with 16 parallel connections"

$beforeStats = @{}
foreach ($adapter in $adapterDetails) {
    $beforeStats[$adapter.Name] = (Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue).ReceivedBytes
}
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

$proxyAddr = "http://127.0.0.1:8080"
$connCount = 16

$jobs = 1..$connCount | ForEach-Object {
    Start-Job -ScriptBlock {
        param($url, $proxy)
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Proxy = New-Object System.Net.WebProxy($proxy)
            $data = $wc.DownloadData($url)
            return $data.Length
        } catch {
            return 0
        }
    } -ArgumentList $testURL, $proxyAddr
}

Write-Host "  Downloading..." -NoNewline
$null = Wait-Job -Job $jobs -Timeout 60
$swTotal.Stop()

$totalBytes = 0
foreach ($j in $jobs) {
    $result = Receive-Job -Job $j -ErrorAction SilentlyContinue
    if ($result) { $totalBytes += $result }
}
Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue

$afterStats = @{}
foreach ($adapter in $adapterDetails) {
    $afterStats[$adapter.Name] = (Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue).ReceivedBytes
}

$deltas = @{}
$totalDelta = 0
foreach ($adapter in $adapterDetails) {
    $delta = ($afterStats[$adapter.Name] - $beforeStats[$adapter.Name])
    $deltas[$adapter.Name] = $delta
    $totalDelta += $delta
}
$combinedMbps = [math]::Round(($totalBytes * 8 / 1MB) / $swTotal.Elapsed.TotalSeconds, 2)

Write-Host " Done!" -ForegroundColor Green

# Step 5: Results
Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  REAL COMBINED SPEED TEST RESULTS           " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Duration:          $([math]::Round($swTotal.Elapsed.TotalSeconds, 2)) seconds"
Write-Host "  Connections:       $connCount parallel"
Write-Host "  Total Downloaded:  $([math]::Round($totalBytes / 1MB, 2)) MB"
Write-Host "  Combined Speed:    $combinedMbps Mbps" -ForegroundColor Cyan
Write-Host ""
Write-Host "  --- Per-Adapter Traffic (OS Byte Counters) ---" -ForegroundColor Yellow

$trafficShares = @()
foreach ($adapter in $adapterDetails) {
    $pct = if ($totalDelta -gt 0) { [math]::Round(($deltas[$adapter.Name] / $totalDelta) * 100) } else { 0 }
    $bar = '#' * [math]::Max(1, [int]($pct / 2))
    $trafficShares += [pscustomobject]@{
        Name    = $adapter.Name
        DeltaMB = [math]::Round($deltas[$adapter.Name] / 1MB, 2)
        Percent = $pct
        Bar     = $bar
    }
}

foreach ($share in $trafficShares) {
    $color = if ($share.Percent -gt 10) { 'Green' } else { 'Red' }
    Write-Host "  $($share.Name):  $($share.DeltaMB) MB  ($($share.Percent)%)  [$($share.Bar)]" -ForegroundColor $color
}

Write-Host ""
$secondaryShare = $trafficShares |
    Sort-Object Percent |
    Select-Object -First 1
if ($secondaryShare.Percent -lt 5) {
    Write-Host "  [PROBLEM] $($secondaryShare.Name) carried less than 5% of traffic!" -ForegroundColor Red
    Write-Host "  Possible causes: proxy not binding to that adapter, or no default route" -ForegroundColor Red
} elseif ($secondaryShare.Percent -lt 25) {
    Write-Host "  [OK] $($secondaryShare.Name) is carrying traffic, but less than the primary adapter (expected with different link speeds)" -ForegroundColor Yellow
} else {
    Write-Host "  [EXCELLENT] Both adapters are actively carrying traffic!" -ForegroundColor Green
}

# Step 6: Proxy stats
Write-Host "`n--- Proxy Internal Stats ---" -ForegroundColor Yellow
try {
    $stats = Get-DashboardStats -TokenPath $tokenFile
    if ($stats -and $stats.proxy) {
        foreach ($a in $stats.proxy.adapters) {
            Write-Host "  $($a.name): $($a.connections) connections, $($a.successes) successes, $($a.failures) failures"
        }
    } else {
        Write-Host "  Could not read proxy stats from dashboard API" -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "  Could not reach dashboard API" -ForegroundColor DarkYellow
}
Write-Host "=============================================" -ForegroundColor Cyan
