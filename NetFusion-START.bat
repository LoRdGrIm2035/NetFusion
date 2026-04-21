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
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"
set "NF_STATE=%~dp0core\NetworkState.ps1"
echo  [OK] Running as Administrator
echo.

:: =========================================================
:: STEP 0.5: Crash Cleanup & Stale Proxy Guard
:: =========================================================
if exist "%~dp0config\active-fw-rules.json" (
    echo  [!] Recovering orphaned firewall rules from previous session...
    powershell -ExecutionPolicy Bypass -File "%~dp0core\Cleanup-OnCrash.ps1"
    echo      Cleaned up orphaned firewall rules.
)
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action RestoreIfDirty
if exist "%~dp0config\safety-state.json" del /q "%~dp0config\safety-state.json"
if exist "%~dp0config\routes-applied.flag" del /q "%~dp0config\routes-applied.flag"
powershell -ExecutionPolicy Bypass -Command "& { $f = '%~dp0config\safety-state.json'; @{ safeMode = $false; circuitBreakerOpen = $false; proxyHealthy = $false; version = '6.2'; lastEvent = 'Normal startup requested'; startTime = ([System.DateTimeOffset]::UtcNow.ToString('o')) } | ConvertTo-Json -Compress | Set-Content $f -Force -Encoding UTF8 }"

:: =========================================================
:: HIGH-SPEED CONSOLIDATED LAUNCH
:: =========================================================

:: [1] ConfigValidator
echo  [1/4] ConfigValidator          [schema check]
powershell -ExecutionPolicy Bypass -Command "Set-Location '%~dp0'; & '.\core\ConfigValidator.ps1'"
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
start "" /min powershell -WindowStyle Hidden -ExecutionPolicy Bypass -NoExit -Command "$Host.UI.RawUI.WindowTitle='NF-Engine'; Set-Location '%~dp0'; & '.\core\NetFusionEngine.ps1'"

:: Force Gateway safety check BEFORE enabling internet proxy
echo        ...Waiting for Core Engine proxy thread binding (Port 8080)...
powershell -ExecutionPolicy Bypass -NoProfile -Command "$deadline=[System.DateTimeOffset]::UtcNow.AddSeconds(15); while($true) { if([System.DateTimeOffset]::UtcNow -gt $deadline){ Write-Host '  [!] TIMEOUT: Engine Proxy Binding Failed' -ForegroundColor Red; exit 1 }; try { $t=New-Object Net.Sockets.TcpClient; $t.NoDelay=$true; $t.ReceiveBufferSize=524288; $t.SendBufferSize=524288; $a=$t.BeginConnect('127.0.0.1',8080,$null,$null); if($a.AsyncWaitHandle.WaitOne(500,$false) -and $t.Connected){ try{$t.EndConnect($a)}catch{}; $t.Close(); exit 0 }; $t.Close() } catch {}; Start-Sleep -Milliseconds 500 }"
if errorlevel 1 goto :START_FAIL

echo        ...Ensuring secondary adapter routes exist without touching the primary...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action EnsureRoutes
if errorlevel 1 goto :START_FAIL

echo        ...Verifying local proxy can reach the internet before system proxy enable...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action TestInternet -ThroughProxy -ProxyPort 8080 -Quiet
if errorlevel 1 goto :START_FAIL

:: [3] Watchdog & Proxy Application
echo  [3/4] Failsafe Watchdog        [system proxy injection]
start "" /min powershell -WindowStyle Hidden -ExecutionPolicy Bypass -NoExit -Command "$Host.UI.RawUI.WindowTitle='NF-Watchdog'; Set-Location '%~dp0'; & '.\core\NetFusionWatchdog.ps1'"

:: Safely inject proxy NOW that we proved the Port is active.
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action SetProxy -ProxyPort 8080
if errorlevel 1 goto :START_FAIL

echo        ...Verifying internet after proxy enable...
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action TestInternet -ThroughProxy -ProxyPort 8080 -Quiet
if errorlevel 1 goto :START_FAIL
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action TestInternet -Quiet
if errorlevel 1 goto :START_FAIL

:: [4] DashboardServer
echo  [4/4] Dashboard UI Server      [web telemetry stream]
start "" /min powershell -WindowStyle Hidden -ExecutionPolicy Bypass -NoExit -Command "$Host.UI.RawUI.WindowTitle='NF-Dashboard'; Set-Location '%~dp0'; & '.\dashboard\DashboardServer.ps1'"

:: Register BSOD/crash recovery task (auto-clears proxy on next boot if unclean shutdown)
powershell -ExecutionPolicy Bypass -Command "$action = New-ScheduledTaskAction -Execute 'reg.exe' -Argument 'add HKCU\Software\Microsoft\Windows\CurrentVersion\Internet` Settings /v ProxyEnable /t REG_DWORD /d 0 /f'; $trigger = New-ScheduledTaskTrigger -AtLogOn; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries; Register-ScheduledTask -TaskName 'NetFusion-CrashRecovery' -Action $action -Trigger $trigger -Settings $settings -Description 'Clears proxy if NetFusion crashed. Removed on clean shutdown.' -Force | Out-Null; Write-Host '  [OK] BSOD recovery task registered' -ForegroundColor DarkGray"

echo.
echo  ====================================================+
echo  ^|   NETFUSION v6.2 SOLID ACTIVE                      ^|
echo  ^|                                                   ^|
echo  ^|   Proxy:      127.0.0.1:8080                      ^|
echo  ^|   Emergency:  Run NetFusion-SAFE.bat              ^|
echo  ====================================================+
echo  System is ready. Auto-launching dashboard...
powershell -Command "Start-Sleep -Seconds 1; Start-Process \"http://127.0.0.1:9090/\""
echo  Press any key to safely close this console...
echo.
pause
exit /b 0

:START_FAIL
echo  [FAIL] Startup verification failed. Restoring saved network state...
taskkill /FI "WINDOWTITLE eq NF-Engine*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Watchdog*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq NF-Dashboard*" /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":9090" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":8080" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>&1
powershell -ExecutionPolicy Bypass -NoProfile -File "%NF_STATE%" -Action Restore
pause
exit /b 1
