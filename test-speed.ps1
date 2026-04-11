# Per-adapter speed test using WebClient bound per adapter via route metrics
$wifi3Idx = (Get-NetAdapter -Name "Wi-Fi 3").InterfaceIndex
$wifi4Idx = (Get-NetAdapter -Name "Wi-Fi 4").InterfaceIndex
$wifi3IP = (Get-NetIPAddress -InterfaceIndex $wifi3Idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
$wifi4IP = (Get-NetIPAddress -InterfaceIndex $wifi4Idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress

Write-Host "=== FULL SPEED TEST ===" -ForegroundColor Cyan
Write-Host "Wi-Fi 3: $wifi3IP (idx $wifi3Idx)" -ForegroundColor Green
Write-Host "Wi-Fi 4: $wifi4IP (idx $wifi4Idx)" -ForegroundColor Magenta
Write-Host ""

# Save original metrics
$orig3 = (Get-NetIPInterface -InterfaceIndex $wifi3Idx -AddressFamily IPv4).InterfaceMetric
$orig4 = (Get-NetIPInterface -InterfaceIndex $wifi4Idx -AddressFamily IPv4).InterfaceMetric
Write-Host "Original metrics: Wi-Fi 3=$orig3, Wi-Fi 4=$orig4"

# --- TEST A: Wi-Fi 3 only (disable Wi-Fi 4 route) ---
Write-Host "`n[A] Wi-Fi 3 ONLY (Wi-Fi 4 metric=9999):" -ForegroundColor Green
Set-NetIPInterface -InterfaceIndex $wifi3Idx -InterfaceMetric 1
Set-NetIPInterface -InterfaceIndex $wifi4Idx -InterfaceMetric 9999
Start-Sleep -Seconds 1
$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
$wc1 = New-Object System.Net.WebClient
$wc1.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
try {
    $d1 = $wc1.DownloadData("http://proof.ovh.net/files/10Mb.dat")
    $sw1.Stop()
    $s1 = (($d1.Length/1MB)*8)/$sw1.Elapsed.TotalSeconds
    Write-Host "  $([math]::Round($d1.Length/1MB,2)) MB in $([math]::Round($sw1.Elapsed.TotalSeconds,2))s = $([math]::Round($s1,2)) Mbps" -ForegroundColor Green
} catch { Write-Host "  FAIL: $_" -ForegroundColor Red; $s1 = 0 }

# --- TEST B: Wi-Fi 4 only (disable Wi-Fi 3 route) ---
Write-Host "`n[B] Wi-Fi 4 ONLY (Wi-Fi 3 metric=9999):" -ForegroundColor Magenta
Set-NetIPInterface -InterfaceIndex $wifi4Idx -InterfaceMetric 1
Set-NetIPInterface -InterfaceIndex $wifi3Idx -InterfaceMetric 9999
Start-Sleep -Seconds 1
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$wc2 = New-Object System.Net.WebClient
$wc2.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
try {
    $d2 = $wc2.DownloadData("http://proof.ovh.net/files/10Mb.dat")
    $sw2.Stop()
    $s2 = (($d2.Length/1MB)*8)/$sw2.Elapsed.TotalSeconds
    Write-Host "  $([math]::Round($d2.Length/1MB,2)) MB in $([math]::Round($sw2.Elapsed.TotalSeconds,2))s = $([math]::Round($s2,2)) Mbps" -ForegroundColor Magenta  
} catch { Write-Host "  FAIL: $_" -ForegroundColor Red; $s2 = 0 }

# Restore original metrics
Set-NetIPInterface -InterfaceIndex $wifi3Idx -InterfaceMetric $orig3
Set-NetIPInterface -InterfaceIndex $wifi4Idx -InterfaceMetric $orig4

# --- TEST C: BOTH via metric split (each metric=1, round-robin) ---
Write-Host "`n[C] BOTH simultaneously (parallel WebClient, no proxy):" -ForegroundColor Yellow
Set-NetIPInterface -InterfaceIndex $wifi3Idx -InterfaceMetric 25
Set-NetIPInterface -InterfaceIndex $wifi4Idx -InterfaceMetric 30
Start-Sleep -Seconds 1

$j1 = Start-Job -ScriptBlock {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $d = $wc.DownloadData("http://proof.ovh.net/files/10Mb.dat")
    $sw.Stop()
    return @{bytes=$d.Length;secs=$sw.Elapsed.TotalSeconds}
}
$j2 = Start-Job -ScriptBlock {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $d = $wc.DownloadData("http://speedtest.tele2.net/10MB.zip")
    $sw.Stop()
    return @{bytes=$d.Length;secs=$sw.Elapsed.TotalSeconds}
}
$null = Wait-Job $j1,$j2 -Timeout 60
$r1 = Receive-Job $j1; $r2 = Receive-Job $j2
Remove-Job $j1,$j2 -Force -ErrorAction SilentlyContinue
if ($r1 -and $r2) {
    $sp1 = (($r1.bytes/1MB)*8)/$r1.secs
    $sp2 = (($r2.bytes/1MB)*8)/$r2.secs
    Write-Host "  Stream 1: $([math]::Round($sp1,2)) Mbps" -ForegroundColor Green
    Write-Host "  Stream 2: $([math]::Round($sp2,2)) Mbps" -ForegroundColor Magenta
    Write-Host "  Combined: $([math]::Round($sp1+$sp2,2)) Mbps" -ForegroundColor Yellow
}

# --- TEST D: Through proxy 8-stream ---
Write-Host "`n[D] Through PROXY (8 streams x 10MB):" -ForegroundColor Cyan
$sw4 = [System.Diagnostics.Stopwatch]::StartNew()
$jobs = 1..8 | ForEach-Object {
    Start-Job -ScriptBlock {
        $wc = New-Object System.Net.WebClient
        $wc.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:8080")
        $d = $wc.DownloadData("http://proof.ovh.net/files/10Mb.dat")
        return $d.Length
    }
}
$null = $jobs | Wait-Job -Timeout 60
$sw4.Stop()
$totalBytes = ($jobs | Receive-Job | Measure-Object -Sum).Sum
$jobs | Remove-Job -Force -ErrorAction SilentlyContinue
if ($totalBytes -gt 0) {
    $tMB = $totalBytes / 1MB
    $proxySpd = ($tMB * 8) / $sw4.Elapsed.TotalSeconds
    Write-Host "  $([math]::Round($tMB,1)) MB in $([math]::Round($sw4.Elapsed.TotalSeconds,1))s"
    Write-Host "  Proxy throughput: $([math]::Round($proxySpd,2)) Mbps" -ForegroundColor Cyan
}

# Summary
Write-Host ""
Write-Host "====== SPEED TEST SUMMARY ======" -ForegroundColor White
Write-Host "  Wi-Fi 3 alone:  $([math]::Round($s1,1)) Mbps" -ForegroundColor Green
Write-Host "  Wi-Fi 4 alone:  $([math]::Round($s2,1)) Mbps" -ForegroundColor Magenta
$theoretical = $s1 + $s2
Write-Host "  Theoretical:    $([math]::Round($theoretical,1)) Mbps" -ForegroundColor Yellow
if ($totalBytes -gt 0) {
    Write-Host "  Proxy actual:   $([math]::Round($proxySpd,1)) Mbps" -ForegroundColor Cyan
    $efficiency = if ($theoretical -gt 0) { [math]::Round(($proxySpd/$theoretical)*100,0) } else { 0 }
    Write-Host "  Efficiency:     ${efficiency}%" -ForegroundColor White
}
Write-Host "================================" -ForegroundColor White
