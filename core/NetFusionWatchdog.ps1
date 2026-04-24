<#
.SYNOPSIS
    NetFusionWatchdog v6.2 -- Failsafe Guardian
.DESCRIPTION
    A micro-script that ensures if the local proxy port stops responding, the
    system clears the Windows proxy, preventing the "No Internet" offline state.
    Engine process loss alone is not treated as fatal while the proxy is still
    listening, because killing a working proxy creates avoidable throughput drops.
#>

[CmdletBinding()]
param()

$failCount = 0
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$configPath = Join-Path $projectDir 'config\config.json'
$proxyStatsPath = Join-Path $projectDir 'config\proxy-stats.json'
$proxyPort = 8080
try {
    if (Test-Path $configPath) {
        $watchdogConfig = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($watchdogConfig.proxyPort) { $proxyPort = [int]$watchdogConfig.proxyPort }
    }
} catch {}
$networkStateScript = Join-Path $scriptDir 'NetworkState.ps1'

Write-Host "  [Watchdog] Active. Guarding proxy on port $proxyPort..." -ForegroundColor Cyan

function Clear-Proxy {
    Write-Host "  [Watchdog] Critical Failure Detected! Restoring saved network state..." -ForegroundColor Red
    try {
        & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $networkStateScript -Action Restore -Quiet | Out-Null
        Write-Host "  [Watchdog] Saved network state restored." -ForegroundColor Green
    } catch {
        Write-Host "  [Watchdog] Failed to restore network state! $_" -ForegroundColor Red
    }
}

function Test-ProxyHealthEndpoint {
    param([int]$Port)

    $tcp = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.NoDelay = $true
        $tcp.ReceiveTimeout = 1000
        $tcp.SendTimeout = 1000
        $ar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(700, $false)) {
            return $false
        }
        try { $tcp.EndConnect($ar) } catch { return $false }
        if (-not $tcp.Connected) { return $false }

        $stream = $tcp.GetStream()
        $requestBytes = [System.Text.Encoding]::ASCII.GetBytes("GET /health HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
        $stream.Write($requestBytes, 0, $requestBytes.Length)
        $stream.Flush()

        $buffer = New-Object byte[] 256
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $false }
        $response = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        return ($response -match 'HTTP/1\.[01]\s+200' -and $response -match 'OK')
    } catch {
        return $false
    } finally {
        try { if ($tcp) { $tcp.Close() } } catch {}
        try { if ($tcp) { $tcp.Dispose() } } catch {}
    }
}

function Test-ProxyStatsFresh {
    param(
        [string]$Path,
        [double]$MaxAgeSeconds = 10
    )

    try {
        if (-not (Test-Path $Path)) { return $false }
        $data = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $data -or -not $data.running -or -not $data.timestamp) { return $false }
        $age = ([System.DateTimeOffset]::UtcNow - [System.DateTimeOffset]::Parse([string]$data.timestamp)).TotalSeconds
        return ($age -le $MaxAgeSeconds)
    } catch {
        return $false
    }
}

while ($true) {
    Start-Sleep -Seconds 3
    
    # Check if NetFusionEngine is running
    $engineProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -match 'NetFusionEngine' })
    
    # A TCP connect alone is not enough. A frozen proxy can keep the port open
    # while failing requests, leaving Windows proxy enabled and the browser with
    # "no internet." Require the local /health endpoint to answer quickly. If
    # the relay pool is saturated during a speed test, fresh proxy stats still
    # prove the accept/monitor loop is alive, so avoid false rollback.
    $healthOk = Test-ProxyHealthEndpoint -Port $proxyPort
    $statsFresh = Test-ProxyStatsFresh -Path $proxyStatsPath -MaxAgeSeconds 10
    $isListening = ($healthOk -or $statsFresh)

    if (-not $isListening) {
        $failCount++
        if ($failCount -ge 2) {
            Clear-Proxy
            # Attempt to kill lingering dead processes
            $deadProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('powershell.exe','pwsh.exe') -and $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match '(NetFusion|SmartProxy|DashboardServer|NetFusionEngine|NetFusionWatchdog)' })
            foreach ($p in (@($engineProcs) + $deadProcs)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            exit 1
        }
    } else {
        if ($engineProcs.Count -eq 0) {
            Write-Host "  [Watchdog] Engine process not detected, but proxy is alive; keeping internet path active." -ForegroundColor Yellow
        }
        $failCount = 0
    }
}
