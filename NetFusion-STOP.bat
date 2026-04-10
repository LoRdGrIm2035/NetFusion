@echo off
title NetFusion v6.0 SOLID - Shutdown
color 0E
echo.
echo  ====================================================+
echo  ^|   NETFUSION v6.0 SOLID - SHUTTING DOWN             ^|
echo  ====================================================+
echo.

:: =========================================================
:: STEP 0: Administrator Check
:: =========================================================
net session >nul 2>&1
if errorlevel 1 (
    echo  [!] Requesting administrator privileges to kill services...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"
echo  [OK] Running as Administrator
echo.

:: =========================================================
:: STEP 1: Kill all NetFusion services
:: =========================================================
echo  [1/6] Stopping engine services...
taskkill /FI "WINDOWTITLE eq NF-Engine*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Watchdog*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Dashboard*" /F >nul 2>&1

:: Fallback: kill by CommandLine matching DualWifi + known script names
powershell -ExecutionPolicy Bypass -Command "Get-WmiObject Win32_Process -Filter 'Name=''powershell.exe''' | ForEach-Object { if ($_.CommandLine -and $_.CommandLine -match 'DualWifi' -and $_.CommandLine -match '(NetFusionEngine|NetFusionWatchdog|DashboardServer|QuicBlocker)') { Write-Host ('  Killing PID ' + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }"
ping -n 2 127.0.0.1 >nul
echo        Done

:: =========================================================
:: STEP 2: Release ports
:: =========================================================
echo  [2/6] Releasing proxy ports (9090, 8080)...
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":9090" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":8080" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
echo        Done

:: =========================================================
:: STEP 3: Restore Default Networking
:: =========================================================
echo  [3/6] Restoring default routing...
powershell -ExecutionPolicy Bypass -Command "Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel' } | ForEach-Object { Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue }"
powershell -ExecutionPolicy Bypass -File "%~dp0core\Cleanup-OnCrash.ps1"
echo        Done

:: =========================================================
:: STEP 4: System Proxy Cleanup
:: =========================================================
echo  [4/6] Removing SYSTEM intercept...
powershell -ExecutionPolicy Bypass -Command "$inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; Set-ItemProperty $inetKey 'ProxyEnable' 0 -Type DWord -Force -ErrorAction SilentlyContinue; Remove-ItemProperty $inetKey 'ProxyServer' -Force -ErrorAction SilentlyContinue; Remove-ItemProperty $inetKey 'ProxyOverride' -Force -ErrorAction SilentlyContinue; Write-Host '       System proxy cleared' -ForegroundColor Green"
powershell -ExecutionPolicy Bypass -Command "$k = 'HKCU:\Software\DownloadManager'; if (Test-Path $k) { Set-ItemProperty $k 'nProxyMode' 1 -Type DWord -Force; Set-ItemProperty $k 'UseHttpProxy' 0 -Type DWord -Force; Set-ItemProperty $k 'nHttpPrChbSt' 0 -Type DWord -Force; Set-ItemProperty $k 'UseHttpsProxy' 0 -Type DWord -Force; Set-ItemProperty $k 'nHttpsPrChbSt' 0 -Type DWord -Force; Write-Host '       IDM restored to direct' -ForegroundColor Green } else { Write-Host '       IDM not installed' -ForegroundColor DarkGray }"

:: =========================================================
:: STEP 5: Clean state files
:: =========================================================
echo  [5/6] Cleaning up engine state...
powershell -ExecutionPolicy Bypass -Command "$f='%~dp0config\proxy-stats.json'; @{running=$false;timestamp=(Get-Date).ToString('o')} | ConvertTo-Json -Compress | Set-Content $f -Force -Encoding UTF8; Remove-Item '%~dp0config\safety-state.json' -Force -ErrorAction SilentlyContinue"
echo        Done

:: =========================================================
:: STEP 6: Remove Crash Recovery Watchdog
:: =========================================================
echo  [6/6] Clearing boot recovery task...
powershell -ExecutionPolicy Bypass -Command "Unregister-ScheduledTask -TaskName 'NetFusion-CrashRecovery' -Confirm:$false -ErrorAction SilentlyContinue"
echo        Done
echo.

:: Give System time to flush Windows adapters
ping -n 3 127.0.0.1 >nul

echo  [!] Verifying internet link is alive...
ping -n 1 8.8.8.8 >nul 2>&1
if not errorlevel 1 (
    echo      Internet: OK [Restored successfully]
) else (
    echo      Internet: Ping failed. Windows flush sometimes takes 5 seconds, checking again...
    ping -n 3 127.0.0.1 >nul
    ping -n 1 1.1.1.1 >nul 2>&1
    if not errorlevel 1 ( echo      Internet: OK ) else ( echo      Internet: FAILED. Check network adapters! )
)

echo.
echo  ====================================================+
echo  ^|   NETFUSION STOPPED                               ^|
echo  ^|                                                   ^|
echo  ^|   All services terminated                          ^|
echo  ^|   Internet restored to normal                      ^|
echo  ====================================================+
echo.
pause
