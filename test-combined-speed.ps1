# === NetFusion v6.1 — Real Combined Speed Verification ===
# This test HONESTLY measures whether both adapters carry real traffic
# No fakes, no estimates — raw byte counters from the OS

<<<<<<< HEAD
=======
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

>>>>>>> origin/main
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  NetFusion Combined Speed Verifier v6.1     " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

<<<<<<< HEAD
# Step 1: Verify adapter status
Write-Host "`n--- STEP 1: Adapter Check ---" -ForegroundColor Yellow
$wifi3 = Get-NetAdapter -Name "Wi-Fi 3" -ErrorAction SilentlyContinue
$wifi4 = Get-NetAdapter -Name "Wi-Fi 4" -ErrorAction SilentlyContinue

$wifi3IP = (Get-NetIPAddress -InterfaceAlias "Wi-Fi 3" -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
$wifi4IP = (Get-NetIPAddress -InterfaceAlias "Wi-Fi 4" -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress

Write-Host "  Wi-Fi 3: $wifi3IP ($(if($wifi3.Status -eq 'Up'){'UP'}else{'DOWN'}))"
Write-Host "  Wi-Fi 4: $wifi4IP ($(if($wifi4.Status -eq 'Up'){'UP'}else{'DOWN'}))"

if ($wifi4IP -match '^169\.254\.' -or -not $wifi4IP) {
    Write-Host "  [FAIL] Wi-Fi 4 has no valid IP. Cannot test combined speed." -ForegroundColor Red
    exit 1
}

function Invoke-BoundCurlDownload {
    param(
        [string]$LocalIP,
        [string]$Url
    )

    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curlCmd) {
        throw "curl.exe is required for adapter-bound testing but was not found."
    }

    $format = "SIZE=%{size_download};TIME=%{time_total};SPEED=%{speed_download};IP=%{local_ip}"
    $output = & $curlCmd.Source --interface $LocalIP --noproxy "*" -L -o NUL -sS -w $format $Url 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }

    $text = ($output | Out-String).Trim()
    $result = @{}
    foreach ($part in ($text -split ';')) {
        if ($part -match '^(SIZE|TIME|SPEED|IP)=(.*)$') {
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
    }
=======
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
>>>>>>> origin/main
}

# Step 2: Check routes
Write-Host "`n--- STEP 2: Route Check ---" -ForegroundColor Yellow
<<<<<<< HEAD
$routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Where-Object { $_.InterfaceAlias -match 'Wi-Fi' }
=======
$routeNames = $adapterDetails.Name
$routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $routeNames -contains $_.InterfaceAlias }
>>>>>>> origin/main
foreach ($r in $routes) {
    Write-Host "  $($r.InterfaceAlias) -> $($r.NextHop) (metric: $($r.RouteMetric))"
}
if ($routes.Count -lt 2) {
    Write-Host "  [WARN] Only $($routes.Count) route(s). Both adapters need a default route for ECMP." -ForegroundColor Red
}

<<<<<<< HEAD
# Step 3: Real adapter-bound direct test.
Write-Host "`n--- STEP 3: Adapter-Bound Direct Download Test ---" -ForegroundColor Yellow
Write-Host "  Using curl.exe --interface <local-ip> so each request is pinned to the selected adapter." -ForegroundColor DarkYellow
$testURL = "http://speed.cloudflare.com/__down?bytes=10000000"  # 10MB

foreach ($adapterInfo in @(@{Name="Wi-Fi 3";IP=$wifi3IP}, @{Name="Wi-Fi 4";IP=$wifi4IP})) {
    $name = $adapterInfo.Name
    $ip = $adapterInfo.IP
    Write-Host "  Testing $name ($ip)..." -NoNewline
    
    try {
        $result = Invoke-BoundCurlDownload -LocalIP $ip -Url $testURL
        $mbps = if ($result.Seconds -gt 0) { [math]::Round(($result.Bytes * 8 / 1MB) / $result.Seconds, 2) } else { 0 }
        Write-Host " $mbps Mbps ($([math]::Round($result.Bytes/1MB, 1)) MB in $([math]::Round($result.Seconds, 2))s, source $($result.LocalIP))" -ForegroundColor Green
    } catch {
=======
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
>>>>>>> origin/main
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Step 4: Combined proxy test with live byte counting
Write-Host "`n--- STEP 4: Combined Proxy Throughput Test ---" -ForegroundColor Yellow
Write-Host "  Using $testURL through proxy 127.0.0.1:8080 with 16 parallel connections"

<<<<<<< HEAD
# Capture byte counters BEFORE
$before3 = (Get-NetAdapterStatistics -Name "Wi-Fi 3" -ErrorAction SilentlyContinue).ReceivedBytes
$before4 = (Get-NetAdapterStatistics -Name "Wi-Fi 4" -ErrorAction SilentlyContinue).ReceivedBytes
=======
$beforeStats = @{}
foreach ($adapter in $adapterDetails) {
    $beforeStats[$adapter.Name] = (Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue).ReceivedBytes
}
>>>>>>> origin/main
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

<<<<<<< HEAD
# Capture byte counters AFTER
$after3 = (Get-NetAdapterStatistics -Name "Wi-Fi 3" -ErrorAction SilentlyContinue).ReceivedBytes
$after4 = (Get-NetAdapterStatistics -Name "Wi-Fi 4" -ErrorAction SilentlyContinue).ReceivedBytes

$delta3 = $after3 - $before3
$delta4 = $after4 - $before4
$totalDelta = $delta3 + $delta4
=======
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
>>>>>>> origin/main
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
<<<<<<< HEAD
$pct3 = if ($totalDelta -gt 0) { [math]::Round(($delta3 / $totalDelta) * 100) } else { 0 }
$pct4 = if ($totalDelta -gt 0) { [math]::Round(($delta4 / $totalDelta) * 100) } else { 0 }

$bar3 = '#' * [math]::Max(1, [int]($pct3 / 2))
$bar4 = '#' * [math]::Max(1, [int]($pct4 / 2))

Write-Host "  Wi-Fi 3:  $([math]::Round($delta3 / 1MB, 2)) MB  ($pct3%)  [$bar3]" -ForegroundColor $(if($pct3 -gt 10){'Green'}else{'Red'})
Write-Host "  Wi-Fi 4:  $([math]::Round($delta4 / 1MB, 2)) MB  ($pct4%)  [$bar4]" -ForegroundColor $(if($pct4 -gt 10){'Green'}else{'Red'})

Write-Host ""
if ($pct4 -lt 5) {
    Write-Host "  [PROBLEM] Wi-Fi 4 carried less than 5% of traffic!" -ForegroundColor Red
    Write-Host "  Possible causes: proxy not binding to Wi-Fi 4, or no default route" -ForegroundColor Red
} elseif ($pct4 -lt 25) {
    Write-Host "  [OK] Wi-Fi 4 is carrying traffic, but less than Wi-Fi 3 (expected with different link speeds)" -ForegroundColor Yellow
=======

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
>>>>>>> origin/main
} else {
    Write-Host "  [EXCELLENT] Both adapters are actively carrying traffic!" -ForegroundColor Green
}

# Step 6: Proxy stats
Write-Host "`n--- Proxy Internal Stats ---" -ForegroundColor Yellow
try {
<<<<<<< HEAD
    $stats = curl.exe -s "http://127.0.0.1:9090/api/stats?token=AIqSCTmEekH5Dv" | ConvertFrom-Json
=======
    $stats = Get-DashboardStats -TokenPath $tokenFile
>>>>>>> origin/main
    if ($stats -and $stats.proxy) {
        foreach ($a in $stats.proxy.adapters) {
            Write-Host "  $($a.name): $($a.connections) connections, $($a.successes) successes, $($a.failures) failures"
        }
<<<<<<< HEAD
    }
} catch { Write-Host "  Could not reach dashboard API" }
=======
    } else {
        Write-Host "  Could not read proxy stats from dashboard API" -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "  Could not reach dashboard API" -ForegroundColor DarkYellow
}
>>>>>>> origin/main
Write-Host "=============================================" -ForegroundColor Cyan
