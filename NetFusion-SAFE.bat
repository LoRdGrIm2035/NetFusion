@echo off
title NetFusion - EMERGENCY SAFE MODE
color 0C
echo.
echo  =====================================================
echo  ^|   NETFUSION EMERGENCY SAFE MODE                   ^|
echo  ^|   Restoring default internet connectivity          ^|
echo  =====================================================
echo.

:: ---- Kill ALL NetFusion processes ----
echo  [1/6] Killing all NetFusion services...
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
echo  [2/6] Releasing network ports...
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":9090" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":8080" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1

:: ---- Restore IDM ----
echo  [3/6] Restoring IDM to direct connection...
reg query "HKCU\Software\DownloadManager" >nul 2>&1
if not errorlevel 1 (
    reg add "HKCU\Software\DownloadManager" /v nProxyMode /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKCU\Software\DownloadManager" /v UseHttpProxy /t REG_DWORD /d 0 /f >nul 2>&1
    reg add "HKCU\Software\DownloadManager" /v nHttpPrChbSt /t REG_DWORD /d 0 /f >nul 2>&1
    reg add "HKCU\Software\DownloadManager" /v UseHttpsProxy /t REG_DWORD /d 0 /f >nul 2>&1
    reg add "HKCU\Software\DownloadManager" /v nHttpsPrChbSt /t REG_DWORD /d 0 /f >nul 2>&1
    echo       IDM proxy removed
)

:: ---- Remove system proxy (CRITICAL - was missing!) ----
echo  [4/7] Removing system proxy...
powershell -ExecutionPolicy Bypass -Command "$inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; Set-ItemProperty $inetKey 'ProxyEnable' 0 -Type DWord -Force -ErrorAction SilentlyContinue; Remove-ItemProperty $inetKey 'ProxyServer' -Force -ErrorAction SilentlyContinue; Remove-ItemProperty $inetKey 'ProxyOverride' -Force -ErrorAction SilentlyContinue; Write-Host '       System proxy cleared' -ForegroundColor Green"

:: ---- Restore routes ----
echo  [5/7] Restoring default routing...
net session >nul 2>&1
if errorlevel 1 (
    powershell -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-ExecutionPolicy Bypass -Command \"Remove-NetRoute -DestinationPrefix 0.0.0.0/1 -Confirm:$false -ErrorAction SilentlyContinue; Remove-NetRoute -DestinationPrefix 128.0.0.0/1 -Confirm:$false -ErrorAction SilentlyContinue; Remove-NetRoute -DestinationPrefix 0.0.0.0/2 -Confirm:$false -ErrorAction SilentlyContinue; Remove-NetRoute -DestinationPrefix 64.0.0.0/2 -Confirm:$false -ErrorAction SilentlyContinue; Get-NetAdapter | Where-Object { $_.Status -eq ''Up'' -and $_.InterfaceDescription -notmatch ''Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel'' } | ForEach-Object { Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue }\"'"
) else (
    powershell -ExecutionPolicy Bypass -Command "Remove-NetRoute -DestinationPrefix '0.0.0.0/1' -Confirm:$false -ErrorAction SilentlyContinue; Remove-NetRoute -DestinationPrefix '128.0.0.0/1' -Confirm:$false -ErrorAction SilentlyContinue; Remove-NetRoute -DestinationPrefix '0.0.0.0/2' -Confirm:$false -ErrorAction SilentlyContinue; Remove-NetRoute -DestinationPrefix '64.0.0.0/2' -Confirm:$false -ErrorAction SilentlyContinue; Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel' } | ForEach-Object { Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue }"
)

:: ---- Set safe mode flag ----
echo  [6/7] Setting safe mode flag...
powershell -ExecutionPolicy Bypass -Command "$f = '%~dp0config\safety-state.json'; @{safeMode=$true; circuitBreakerOpen=$true; proxyHealthy=$false; version='5.0'; lastEvent='Emergency safe mode activated'} | ConvertTo-Json -Compress | Set-Content $f -Force -Encoding UTF8"

:: ---- Done ----
echo  [7/7] Verifying internet connectivity...
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
