@echo off
title NetFusion - EMERGENCY SAFE MODE
color 0C
echo.
echo  =====================================================
echo  ^|   NETFUSION EMERGENCY SAFE MODE                   ^|
echo  ^|   Restoring default internet connectivity          ^|
echo  =====================================================
echo.

set "NF_STATE=%~dp0core\NetworkState.ps1"

:: ---- Kill ALL NetFusion processes ----
echo  [1/5] Killing all NetFusion services...
taskkill /FI "WINDOWTITLE eq NF-NetworkManager*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-InterfaceMonitor*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-RouteController*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-SmartProxy*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Dashboard*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-LearningEngine*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-SafetyController*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-WatchdogSupervisor*" /F >nul 2>&1
powershell -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | ForEach-Object { if ($_.CommandLine -and $_.CommandLine -match 'NetFusion' -and $_.CommandLine -match '(SmartProxy|NetworkManager|InterfaceMonitor|DashboardServer|RouteController|LearningEngine|SafetyController|WatchdogSupervisor)') { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }"
timeout /t 1 /nobreak >nul

:: ---- Release ports ----
echo  [2/5] Releasing network ports...
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":9090" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":8080" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1

:: ---- Restore original proxy, routes, and metrics ----
echo  [3/5] Restoring saved network state...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action Restore

:: ---- Set safe mode flag ----
echo  [4/5] Setting safe mode flag...
powershell -ExecutionPolicy Bypass -Command "$f = '%~dp0config\safety-state.json'; @{safeMode=$true; circuitBreakerOpen=$true; proxyHealthy=$false; version='5.0'; lastEvent='Emergency safe mode activated'} | ConvertTo-Json -Compress | Set-Content $f -Force -Encoding UTF8"

:: ---- Done ----
echo  [5/5] Verifying internet connectivity...
ping -n 1 8.8.8.8 >nul 2>&1
if not errorlevel 1 (
    echo       Internet is working!
) else (
    echo       Warning: Internet ping failed. Check your network connection.
)

echo.
echo  =====================================================
echo  ^|   SAFE MODE ACTIVE                                ^|
echo  ^|                                                   ^|
echo  ^|   All NetFusion services stopped                   ^|
echo  ^|   All routes restored to default                   ^|
echo  ^|   IDM proxy removed                                ^|
echo  ^|   Internet should be working normally              ^|
echo  ^|                                                   ^|
echo  ^|   To restart NetFusion:                            ^|
echo  ^|   Run NetFusion-START.bat                          ^|
echo  =====================================================
echo.
pause
