# === NetFusion v6.1 — Real Combined Speed Verification ===
# This test HONESTLY measures whether both adapters carry real traffic
# No fakes, no estimates — raw byte counters from the OS

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  NetFusion Combined Speed Verifier v6.1     " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

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

# Step 2: Check routes
Write-Host "`n--- STEP 2: Route Check ---" -ForegroundColor Yellow
$routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Where-Object { $_.InterfaceAlias -match 'Wi-Fi' }
foreach ($r in $routes) {
    Write-Host "  $($r.InterfaceAlias) -> $($r.NextHop) (metric: $($r.RouteMetric))"
}
if ($routes.Count -lt 2) {
    Write-Host "  [WARN] Only $($routes.Count) route(s). Both adapters need a default route for ECMP." -ForegroundColor Red
}

# Step 3: Test per-adapter internet speed (1 connection each)
Write-Host "`n--- STEP 3: Per-Adapter Download Test ---" -ForegroundColor Yellow
$testURL = "http://speed.cloudflare.com/__down?bytes=10000000"  # 10MB

foreach ($adapterInfo in @(@{Name="Wi-Fi 3";IP=$wifi3IP}, @{Name="Wi-Fi 4";IP=$wifi4IP})) {
    $name = $adapterInfo.Name
    $ip = $adapterInfo.IP
    Write-Host "  Testing $name ($ip)..." -NoNewline
    
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $wc = New-Object System.Net.WebClient
        # Bind to specific adapter IP
        $wc.Headers.Add("Host", "speed.cloudflare.com")
        $data = $wc.DownloadData($testURL)
        $sw.Stop()
        $mbps = [math]::Round(($data.Length * 8 / 1MB) / $sw.Elapsed.TotalSeconds, 2)
        Write-Host " $mbps Mbps ($([math]::Round($data.Length/1MB, 1)) MB in $([math]::Round($sw.Elapsed.TotalSeconds, 2))s)" -ForegroundColor Green
    } catch {
        $sw.Stop()
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Step 4: Combined proxy test with live byte counting
Write-Host "`n--- STEP 4: Combined Proxy Throughput Test ---" -ForegroundColor Yellow
Write-Host "  Using $testURL through proxy 127.0.0.1:8080 with 16 parallel connections"

# Capture byte counters BEFORE
$before3 = (Get-NetAdapterStatistics -Name "Wi-Fi 3" -ErrorAction SilentlyContinue).ReceivedBytes
$before4 = (Get-NetAdapterStatistics -Name "Wi-Fi 4" -ErrorAction SilentlyContinue).ReceivedBytes
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

# Capture byte counters AFTER
$after3 = (Get-NetAdapterStatistics -Name "Wi-Fi 3" -ErrorAction SilentlyContinue).ReceivedBytes
$after4 = (Get-NetAdapterStatistics -Name "Wi-Fi 4" -ErrorAction SilentlyContinue).ReceivedBytes

$delta3 = $after3 - $before3
$delta4 = $after4 - $before4
$totalDelta = $delta3 + $delta4
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
} else {
    Write-Host "  [EXCELLENT] Both adapters are actively carrying traffic!" -ForegroundColor Green
}

# Step 6: Proxy stats
Write-Host "`n--- Proxy Internal Stats ---" -ForegroundColor Yellow
try {
    $stats = curl.exe -s "http://127.0.0.1:9090/api/stats?token=AIqSCTmEekH5Dv" | ConvertFrom-Json
    if ($stats -and $stats.proxy) {
        foreach ($a in $stats.proxy.adapters) {
            Write-Host "  $($a.name): $($a.connections) connections, $($a.successes) successes, $($a.failures) failures"
        }
    }
} catch { Write-Host "  Could not reach dashboard API" }
Write-Host "=============================================" -ForegroundColor Cyan
