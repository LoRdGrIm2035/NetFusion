# === NetFusion Maximum Proxy Bottleneck & Thread Profiler ===
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "   NETFUSION MAXIMUM ENGINE LIMIT PROFILER   " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "This test measures absolute proxy capacity by bypassing the internet"
Write-Host "and pushing local loopback data to max out the proxy thread pool."

function Get-DashboardStats {
    $tokenFile = Join-Path $PSScriptRoot "config\dashboard-token.txt"
    if (-not (Test-Path $tokenFile)) {
        throw "Dashboard token file not found: $tokenFile"
    }

    $token = (Get-Content $tokenFile -Raw -ErrorAction Stop).Trim()
    return Invoke-RestMethod -Uri "http://127.0.0.1:9090/api/stats" -Headers @{ "X-NetFusion-Token" = $token } -Method Get
}

# 1. Start Local Test Server (Bypassing Internet)
$port = 9095
$code = @"
using System;
using System.Net;
public class LocalStressServer {
    public static HttpListener listener = new HttpListener();
    public static void Start() {
        listener.Prefixes.Add("http://127.0.0.1:9095/");
        try { listener.Start(); } catch { return; }
        listener.BeginGetContext(new AsyncCallback(ListenerCallback), listener);
    }
    public static void Stop() {
        listener.Stop();
        listener.Close();
    }
    public static void ListenerCallback(IAsyncResult result) {
        try {
            HttpListenerContext context = listener.EndGetContext(result);
            listener.BeginGetContext(new AsyncCallback(ListenerCallback), listener);
            // Serve 10MB chunk
            byte[] buffer = new byte[10 * 1024 * 1024]; 
            context.Response.ContentLength64 = buffer.Length;
            context.Response.OutputStream.Write(buffer, 0, buffer.Length);
            context.Response.OutputStream.Close();
        } catch {}
    }
}
"@
try { Add-Type -TypeDefinition $code -Language CSharp -ErrorAction SilentlyContinue } catch {}
[LocalStressServer]::Start()
Write-Host "`n[+] Ultra-fast Local HTTP Server started on port $port" -ForegroundColor Green

# 2. Configure Stress Test parameters
$threadCount = 120   # 120 concurrent connections
$totalDataMB = $threadCount * 10
Write-Host "[+] Preparing to burst $threadCount concurrent proxy threads ($totalDataMB MB total)" -ForegroundColor Yellow

# Reset Proxy stats via API (if possible, else we just measure locally)
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 3. Fire the Connections!
$jobs = 1..$threadCount | ForEach-Object {
    Start-Job -ScriptBlock {
        $wc = New-Object System.Net.WebClient
        $wc.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:8080")
        try {
            # Use TLS1.2 to mimic secure traffic but we test HTTP locally for raw loopback speed
            $data = $wc.DownloadData("http://127.0.0.1:9095/payload")
            return @{ status = "OK"; bytes = $data.Length }
        } catch {
            return @{ status = "FAIL"; error = $_.Exception.Message }
        }
    }
}

Write-Host "    -> $threadCount streams engaged. Proxy is under maximum load..." -ForegroundColor Yellow

# Wait for completion (Timeout after 60s)
$null = Wait-Job -Job $jobs -Timeout 60
$sw.Stop()

$results = Receive-Job -Job $jobs
Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
[LocalStressServer]::Stop()

# 4. Analyze Results
$successes = @($results | Where-Object { $_.status -eq "OK" })
$failures = @($results | Where-Object { $_.status -ne "OK" })

$bytesHandled = 0
foreach ($s in $successes) { $bytesHandled += $s.bytes }
$mbps = (($bytesHandled / 1MB) * 8) / $sw.Elapsed.TotalSeconds

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "            STRESS TEST RESULTS              " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Duration:         $([math]::Round($sw.Elapsed.TotalSeconds, 2)) seconds"
Write-Host "Total Threads:    $threadCount"
Write-Host "Successful:       $($successes.Count)" -ForegroundColor Green
if ($failures.Count -gt 0) {
    Write-Host "Failed:           $($failures.Count) (Proxy thread pool starved or socket drop)" -ForegroundColor Red
    $failures | Select-Object -First 3 | ForEach-Object { Write-Host "     Error: $($_.error)" -ForegroundColor DarkRed }
} else {
    Write-Host "Failed:           0 (Pool scaled perfectly)" -ForegroundColor Green
}
Write-Host "Total Data:       $([math]::Round($bytesHandled / 1MB, 2)) MB"
Write-Host "RAW ENGINE SPEED: $([math]::Round($mbps, 2)) Mbps" -ForegroundColor Cyan

$stats = Get-DashboardStats
if ($stats) {
    Write-Host "`nMax Proxy Threads Registered: $($stats.proxy.currentMaxThreads)"
    Write-Host "Total Connections Handled:    $($stats.proxy.totalConnections)"
}
