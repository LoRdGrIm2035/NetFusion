@echo off
title NetFusion v6.2 SOLID - Production Engine
color 0A
echo.
echo  ====================================================+
echo  ^|   NETFUSION v6.2 SOLID (Unified Core)              ^|
echo  ^|   Safety-First Multi-Interface Optimizer           ^|
echo  ====================================================+
echo.

:: =========================================================
:: STEP 0: Administrator Check
:: =========================================================
net session >nul 2>&1
if errorlevel 1 (
    echo  [!] Requesting administrator privileges...
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
:: STEP 0.5: Crash Cleanup & Stale Proxy Guard
:: =========================================================
if exist "%~dp0config\active-fw-rules.json" (
    echo  [!] Recovering orphaned firewall rules from previous session...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\Cleanup-OnCrash.ps1"
    echo      Cleaned up orphaned firewall rules.
)
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action RestoreIfDirty
if exist "%~dp0config\safety-state.json" del /q "%~dp0config\safety-state.json"
if exist "%~dp0config\routes-applied.flag" del /q "%~dp0config\routes-applied.flag"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $f = '%~dp0config\safety-state.json'; @{ safeMode = $false; circuitBreakerOpen = $false; proxyHealthy = $false; version = '6.2'; lastEvent = 'Normal startup requested'; startTime = ([System.DateTimeOffset]::UtcNow.ToString('o')) } | ConvertTo-Json -Compress | Set-Content $f -Force -Encoding UTF8 }"

:: =========================================================
:: HIGH-SPEED CONSOLIDATED LAUNCH
:: =========================================================

:: [1] ConfigValidator
echo  [1/4] ConfigValidator          [schema check]
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '%~dp0'; & '.\core\ConfigValidator.ps1'"
if errorlevel 1 ( echo  [ABORT] Configuration invalid. & pause & exit /b 1 )

echo        ...Saving original network state...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action Save
if errorlevel 1 (
    echo  [ABORT] Failed to save original routes, metrics, and proxy state.
    pause
    exit /b 1
)

:: [2] NetFusion Engine (Replaces 6 previous background processes)
echo  [2/4] NetFusion Core Engine    [proxy + router + monitor]
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -NoExit -Command "$Host.UI.RawUI.WindowTitle='NF-Engine'; Set-Location '%~dp0'; & '.\core\NetFusionEngine.ps1'"

:: Force Gateway safety check BEFORE enabling internet proxy
echo        ...Waiting for Core Engine proxy thread binding (Port %NF_PROXY_PORT%)...
powershell -ExecutionPolicy Bypass -NoProfile -Command "$port=[int]'%NF_PROXY_PORT%'; $deadline=[System.DateTimeOffset]::UtcNow.AddSeconds(15); while($true) { if([System.DateTimeOffset]::UtcNow -gt $deadline){ Write-Host '  [!] TIMEOUT: Engine Proxy Binding Failed' -ForegroundColor Red; exit 1 }; try { $t=New-Object Net.Sockets.TcpClient; $t.NoDelay=$true; $t.ReceiveBufferSize=524288; $t.SendBufferSize=524288; $a=$t.BeginConnect('127.0.0.1',$port,$null,$null); if($a.AsyncWaitHandle.WaitOne(500,$false) -and $t.Connected){ try{$t.EndConnect($a)}catch{}; $t.Close(); exit 0 }; $t.Close() } catch {}; Start-Sleep -Milliseconds 250 }"
if errorlevel 1 goto :START_FAIL

echo        ...Ensuring secondary adapter routes exist without touching the primary...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action EnsureRoutes
if errorlevel 1 goto :START_FAIL

echo        ...Verifying local proxy can reach the internet before system proxy enable...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action TestInternet -ThroughProxy -ProxyPort %NF_PROXY_PORT% -Quiet
if errorlevel 1 goto :START_FAIL

:: [3] Watchdog & Proxy Application
echo  [3/4] Failsafe Watchdog        [system proxy injection]
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -NoExit -Command "$Host.UI.RawUI.WindowTitle='NF-Watchdog'; Set-Location '%~dp0'; & '.\core\NetFusionWatchdog.ps1'"

:: Safely inject proxy NOW that we proved the Port is active.
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action SetProxy -ProxyPort %NF_PROXY_PORT%
if errorlevel 1 goto :START_FAIL

echo        ...Verifying internet after proxy enable...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action TestInternet -ThroughProxy -ProxyPort %NF_PROXY_PORT% -Quiet
if errorlevel 1 goto :START_FAIL
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action TestInternet -Quiet
if errorlevel 1 goto :START_FAIL

:: [4] DashboardServer
echo  [4/4] Dashboard UI Server      [web telemetry stream]
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -NoExit -Command "$Host.UI.RawUI.WindowTitle='NF-Dashboard'; Set-Location '%~dp0'; & '.\dashboard\DashboardServer.ps1'"

:: Register BSOD/crash recovery task (auto-clears proxy on next boot if unclean shutdown)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$action = New-ScheduledTaskAction -Execute 'reg.exe' -Argument 'add HKCU\Software\Microsoft\Windows\CurrentVersion\Internet` Settings /v ProxyEnable /t REG_DWORD /d 0 /f'; $trigger = New-ScheduledTaskTrigger -AtLogOn; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries; Register-ScheduledTask -TaskName 'NetFusion-CrashRecovery' -Action $action -Trigger $trigger -Settings $settings -Description 'Clears proxy if NetFusion crashed. Removed on clean shutdown.' -Force | Out-Null; Write-Host '  [OK] BSOD recovery task registered' -ForegroundColor DarkGray"

echo.
echo  ====================================================+
echo  ^|   NETFUSION v6.2 SOLID ACTIVE                      ^|
echo  ^|                                                   ^|
echo  ^|   Proxy:      127.0.0.1:%NF_PROXY_PORT%                      ^|
echo  ^|   Emergency:  Run NetFusion-SAFE.bat              ^|
echo  ====================================================+
echo  System is ready. Auto-launching dashboard...
powershell -NoProfile -Command "Start-Sleep -Seconds 1; Start-Process \"http://127.0.0.1:%NF_DASHBOARD_PORT%/\""
echo  Press any key to safely close this console...
echo.
pause
exit /b 0

:START_FAIL
echo  [FAIL] Startup verification failed. Restoring saved network state...
taskkill /FI "WINDOWTITLE eq NF-Engine*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Watchdog*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Dashboard*" /F >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | ForEach-Object { if ($_.CommandLine -and $_.CommandLine -match '(NetFusion|SmartProxy|DashboardServer|NetFusionEngine|NetFusionWatchdog)') { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }"
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":%NF_DASHBOARD_PORT%" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":%NF_PROXY_PORT%" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action Restore
pause
exit /b 1
