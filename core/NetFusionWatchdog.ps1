<#
.SYNOPSIS
    NetFusionWatchdog v6.0 -- Failsafe Guardian
.DESCRIPTION
    A micro-script that ensures if NetFusionEngine dies or port 8080 stops responding,
    the system instantly clears the Windows proxy, preventing the "No Internet" offline state.
#>

[CmdletBinding()]
param()

$proxyPort = 8080
$failCount = 0

Write-Host "  [Watchdog] Active. Guarding proxy on port $proxyPort..." -ForegroundColor Cyan

function Clear-Proxy {
    Write-Host "  [Watchdog] Critical Failure Detected! Clearing proxy..." -ForegroundColor Red
    try {
        $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Set-ItemProperty -Path $inetKey -Name 'ProxyEnable' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $inetKey -Name 'ProxyServer' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $inetKey -Name 'ProxyOverride' -Force -ErrorAction SilentlyContinue
        
        $idmKey = 'HKCU:\Software\DownloadManager'
        if (Test-Path $idmKey) {
            Set-ItemProperty -Path $idmKey -Name 'nProxyMode' -Value 1 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $idmKey -Name 'UseHttpProxy' -Value 0 -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $idmKey -Name 'UseHttpsProxy' -Value 0 -ErrorAction SilentlyContinue
        }
        Write-Host "  [Watchdog] Direct internet restored successfully." -ForegroundColor Green
    } catch {
        Write-Host "  [Watchdog] Failed to clear proxy! $_" -ForegroundColor Red
    }
}

while ($true) {
    Start-Sleep -Seconds 3
    
    # Check if NetFusionEngine is running
    $engineProcs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | 
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'NetFusionEngine' })
    
    # Check if proxy port is listening
    $isListening = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect('127.0.0.1', $proxyPort, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(500, $false)) {
            $isListening = $true
            $tcp.Close()
        }
    } catch {}

    if (-not $isListening -or $engineProcs.Count -eq 0) {
        $failCount++
        if ($failCount -ge 2) {
            Clear-Proxy
            # Attempt to kill lingering dead processes
            foreach ($p in $engineProcs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }

            # v6.0: Restart the engine instead of just exiting
            Write-Host "  [Watchdog] Restarting NetFusion Engine..." -ForegroundColor Yellow
            $engineScript = Join-Path $PSScriptRoot "NetFusionEngine.ps1"
            try {
                Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$engineScript`"" -WindowStyle Hidden
                Write-Host "  [Watchdog] Engine restart triggered. Grace period 20s..." -ForegroundColor Green
            } catch {
                Write-Host "  [Watchdog] Engine restart failed: $_" -ForegroundColor Red
            }

            # v6.0 Fix: Grace period BEFORE resetting failCount and BEFORE re-entering the poll loop.
            # The new engine process needs time to appear in WMI with 'NetFusionEngine' in its CommandLine.
            # Without this, the next poll fires immediately and triggers a second restart.
            Start-Sleep -Seconds 20
            $failCount = 0
            continue  # Skip directly to next iteration without the 3s sleep at top
        }
    } else {
        $failCount = 0
    }
}
