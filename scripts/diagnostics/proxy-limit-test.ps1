[CmdletBinding()]
param(
    [int]$ThreadCount = 64,
    [int]$PayloadMegabytes = 10,
    [int]$ProxyPort = 8080,
    [int]$ServerPort = 9095,
    [int]$TimeoutSeconds = 45
)

# === NetFusion Maximum Proxy Bottleneck & Thread Profiler ===
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "   NETFUSION MAXIMUM ENGINE LIMIT PROFILER   " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "This test measures absolute proxy capacity by bypassing the internet"
Write-Host "and pushing local loopback data to max out the proxy thread pool."

function Get-DashboardStats {
    $projectDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $tokenFile = Join-Path $projectDir "config\dashboard-token.txt"
    if (-not (Test-Path $tokenFile)) {
        throw "Dashboard token file not found: $tokenFile"
    }

    $token = (Get-Content $tokenFile -Raw -ErrorAction Stop).Trim()
    return Invoke-RestMethod -Uri "http://127.0.0.1:9090/api/stats" -Headers @{ "X-NetFusion-Token" = $token } -Method Get
}

# 1. Start Local Test Server (Bypassing Internet)
$port = $ServerPort
$payloadBytes = [Math]::Max(1, $PayloadMegabytes) * 1024 * 1024
$code = @"
using System;
using System.Net;
public class LocalStressServer {
    public static HttpListener listener = new HttpListener();
    private static byte[] Payload;
    public static void Start(int port, int payloadBytes) {
        Payload = new byte[payloadBytes];
        listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
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
            context.Response.ContentLength64 = Payload.Length;
            context.Response.OutputStream.Write(Payload, 0, Payload.Length);
            context.Response.OutputStream.Close();
        } catch {}
    }
}
"@
try { Add-Type -TypeDefinition $code -Language CSharp -ErrorAction SilentlyContinue } catch {}
[LocalStressServer]::Start($port, $payloadBytes)
Write-Host "`n[+] Ultra-fast Local HTTP Server started on port $port" -ForegroundColor Green

# 2. Configure Stress Test parameters
$threadCount = [Math]::Max(1, $ThreadCount)
$totalDataMB = $threadCount * $PayloadMegabytes
Write-Host "[+] Preparing to burst $threadCount concurrent proxy threads ($totalDataMB MB total)" -ForegroundColor Yellow

# Reset Proxy stats via API (if possible, else we just measure locally)
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# 3. Fire the Connections!
$jobs = @()
try {
    $jobs = 1..$threadCount | ForEach-Object {
        Start-Job -ScriptBlock {
            param($proxyPort, $serverPort, $timeoutSeconds)
            try {
                $result = & curl.exe -x "http://127.0.0.1:$proxyPort" --noproxy "" --connect-timeout 5 --max-time $timeoutSeconds --speed-time 10 --speed-limit 1024 -s -o NUL -w "CODE=%{http_code};SIZE=%{size_download}" "http://127.0.0.1:$serverPort/payload?nf=$([Guid]::NewGuid().ToString('N'))"
                if ($result -match 'CODE=200;SIZE=(\d+)') {
                    return @{ status = "OK"; bytes = [int64]$Matches[1] }
                }
                return @{ status = "FAIL"; error = $result }
            } catch {
                return @{ status = "FAIL"; error = $_.Exception.Message }
            }
        } -ArgumentList $ProxyPort, $port, $TimeoutSeconds
    }

    Write-Host "    -> $threadCount streams engaged. Proxy is under maximum load..." -ForegroundColor Yellow

    # Wait for completion, then force-stop unfinished jobs before receiving output.
    $null = Wait-Job -Job $jobs -Timeout $TimeoutSeconds
    $sw.Stop()

    $runningJobs = @($jobs | Where-Object { $_.State -eq 'Running' })
    if ($runningJobs.Count -gt 0) {
        Write-Host "    -> Stopping $($runningJobs.Count) unfinished client job(s) after timeout." -ForegroundColor Yellow
        $runningJobs | Stop-Job -ErrorAction SilentlyContinue
    }

    $results = @($jobs | Receive-Job -ErrorAction SilentlyContinue)
} finally {
    if ($jobs.Count -gt 0) {
        Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
    }
    try { [LocalStressServer]::Stop() } catch {}
}

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
