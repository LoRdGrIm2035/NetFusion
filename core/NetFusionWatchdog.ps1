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

while ($true) {
    Start-Sleep -Seconds 3
    
    # Check if NetFusionEngine is running
    $engineProcs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | 
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'NetFusionEngine' })
    
    # Check if proxy port is listening
    $isListening = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcpSocket = $tcp.Client
        $tcpSocket.NoDelay = $true
        $tcpSocket.ReceiveBufferSize = 1048576
        $tcpSocket.SendBufferSize = 1048576
        $ar = $tcp.BeginConnect('127.0.0.1', $proxyPort, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(500, $false)) {
            $isListening = $true
            $tcp.Close()
        }
    } catch {}

    if (-not $isListening) {
        $failCount++
        if ($failCount -ge 2) {
            Clear-Proxy
            # Attempt to kill lingering dead processes
            foreach ($p in $engineProcs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            exit 1
        }
    } else {
        if ($engineProcs.Count -eq 0) {
            Write-Host "  [Watchdog] Engine process not detected, but proxy is alive; keeping internet path active." -ForegroundColor Yellow
        }
        $failCount = 0
    }
}
