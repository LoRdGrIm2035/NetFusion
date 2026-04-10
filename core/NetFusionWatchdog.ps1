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
    $engineProcs = @(Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | 
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
            exit 1
        }
    } else {
        $failCount = 0
    }
}
