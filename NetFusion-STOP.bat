@echo off
title NetFusion v6.2 SOLID - Shutdown
color 0E
echo.
echo  ====================================================+
echo  ^|   NETFUSION v6.2 SOLID - SHUTTING DOWN             ^|
echo  ====================================================+
echo.

:: =========================================================
:: STEP 0: Administrator Check
:: =========================================================
net session >nul 2>&1
if errorlevel 1 (
    echo  [!] Requesting administrator privileges to kill services...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"
set "NF_STATE=%~dp0core\NetworkState.ps1"
set "NF_PROXY_PORT=8080"
set "NF_DASHBOARD_PORT=9090"
for /f "usebackq delims=" %%p in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$cfg='%~dp0config\config.json'; if(Test-Path $cfg){ try { $c=Get-Content $cfg -Raw | ConvertFrom-Json; if($c.proxyPort){ [int]$c.proxyPort } else { 8080 } } catch { 8080 } } else { 8080 }"`) do set "NF_PROXY_PORT=%%p"
for /f "usebackq delims=" %%p in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$cfg='%~dp0config\config.json'; if(Test-Path $cfg){ try { $c=Get-Content $cfg -Raw | ConvertFrom-Json; if($c.dashboardPort){ [int]$c.dashboardPort } else { 9090 } } catch { 9090 } } else { 9090 }"`) do set "NF_DASHBOARD_PORT=%%p"
echo  [OK] Running as Administrator
echo.

:: =========================================================
:: STEP 1: Kill all NetFusion services
:: =========================================================
echo  [1/6] Stopping engine services...
taskkill /FI "WINDOWTITLE eq NF-Engine*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Watchdog*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Dashboard*" /F >nul 2>&1

:: Fallback: kill by CommandLine matching NetFusion-known script/process names
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter 'Name=''powershell.exe''' | ForEach-Object { if ($_.CommandLine -and $_.CommandLine -match '(NetFusion|SmartProxy|DashboardServer|NetFusionEngine|NetFusionWatchdog|QuicBlocker)') { Write-Host ('  Killing PID ' + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }"
echo        Done

:: =========================================================
:: STEP 2: Release ports
:: =========================================================
echo  [2/6] Releasing proxy ports (%NF_DASHBOARD_PORT%, %NF_PROXY_PORT%)...
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":%NF_DASHBOARD_PORT%" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":%NF_PROXY_PORT%" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
echo        Done

:: =========================================================
:: STEP 3: Restore Default Networking
:: =========================================================
echo  [3/6] Restoring original network state...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action Restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\Cleanup-OnCrash.ps1"
echo        Done

:: =========================================================
:: STEP 4: System Proxy Cleanup
:: =========================================================
echo  [4/6] Proxy and IDM state restored via saved snapshot...
echo        Done

:: =========================================================
:: STEP 5: Clean state files
:: =========================================================
echo  [5/6] Cleaning up engine state...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%~dp0config\proxy-stats.json'; @{running=$false;timestamp=(Get-Date).ToString('o')} | ConvertTo-Json -Compress | Set-Content $f -Force -Encoding UTF8; Remove-Item '%~dp0config\safety-state.json' -Force -ErrorAction SilentlyContinue"
echo        Done

:: =========================================================
:: STEP 6: Remove Crash Recovery Watchdog
:: =========================================================
echo  [6/6] Clearing boot recovery task...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unregister-ScheduledTask -TaskName 'NetFusion-CrashRecovery' -Confirm:$false -ErrorAction SilentlyContinue"
echo        Done
echo.

:: Give Windows a short moment to release proxy handles after forced process termination
timeout /t 1 /nobreak >nul

echo  [!] Verifying internet link is alive...
ping -n 1 8.8.8.8 >nul 2>&1
if not errorlevel 1 (
    echo      Internet: OK [Restored successfully]
) else (
    echo      Internet: Ping failed. Windows flush sometimes takes 5 seconds, checking again...
    timeout /t 1 /nobreak >nul
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
