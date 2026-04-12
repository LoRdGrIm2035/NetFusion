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
if exist "%~dp0config\safety-state.json" del /q "%~dp0config\safety-state.json"
if exist "%~dp0config\routes-applied.flag" del /q "%~dp0config\routes-applied.flag"
powershell -ExecutionPolicy Bypass -Command "& { $f = '%~dp0config\safety-state.json'; @{ safeMode = $false; circuitBreakerOpen = $false; proxyHealthy = $false; version = '6.2'; lastEvent = 'Normal startup requested'; startTime = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Set-Content $f -Force -Encoding UTF8 }"

:: Stale proxy guard: if ProxyEnable=1 from a crash, clear it immediately
powershell -ExecutionPolicy Bypass -Command "$k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; $pe=(Get-ItemProperty $k -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable; if($pe -eq 1){Write-Host '  [!] Stale proxy detected from previous crash -- clearing...' -ForegroundColor Yellow; Set-ItemProperty $k 'ProxyEnable' 0 -Type DWord -Force; Remove-ItemProperty $k 'ProxyServer' -Force -ErrorAction SilentlyContinue; Remove-ItemProperty $k 'ProxyOverride' -Force -ErrorAction SilentlyContinue; Write-Host '      Proxy cleared. Fresh init starting.' -ForegroundColor Green}"

:: =========================================================
:: HIGH-SPEED CONSOLIDATED LAUNCH
:: =========================================================

:: [1] ConfigValidator
echo  [1/4] ConfigValidator          [schema check]
powershell -ExecutionPolicy Bypass -Command "Set-Location '%~dp0'; & '.\core\ConfigValidator.ps1'"
if errorlevel 1 ( echo  [ABORT] Configuration invalid. & pause & exit /b )

:: [2] NetFusion Engine (Replaces 6 previous background processes)
echo  [2/4] NetFusion Core Engine    [proxy + router + monitor]
start "" /min powershell -WindowStyle Hidden -ExecutionPolicy Bypass -NoExit -Command "$Host.UI.RawUI.WindowTitle='NF-Engine'; Set-Location '%~dp0'; & '.\core\NetFusionEngine.ps1'"

:: Force Gateway safety check BEFORE enabling internet proxy
echo        ...Waiting for Core Engine proxy thread binding (Port 8080)...
powershell -Command "$d=(Get-Date).AddSeconds(15); while($true) { if((Get-Date) -gt $d){ Write-Host '  [!] TIMEOUT: Engine Proxy Binding Failed' -ForegroundColor Red; Start-Process '%~dp0NetFusion-STOP.bat'; exit 1 }; try { $t=New-Object Net.Sockets.TcpClient; $a=$t.BeginConnect('127.0.0.1',8080,$null,$null); if($a.AsyncWaitHandle.WaitOne(500,$false)){ $t.Close(); break } } catch{}; Start-Sleep -Milliseconds 500 }"
if errorlevel 1 exit /b

:: [3] Watchdog & Proxy Application
echo  [3/4] Failsafe Watchdog        [system proxy injection]
start "" /min powershell -WindowStyle Hidden -ExecutionPolicy Bypass -NoExit -Command "$Host.UI.RawUI.WindowTitle='NF-Watchdog'; Set-Location '%~dp0'; & '.\core\NetFusionWatchdog.ps1'"

:: Safely inject proxy NOW that we proved the Port is active.
powershell -Command "$inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; Set-ItemProperty $inetKey 'ProxyEnable' 1 -Type DWord -Force; Set-ItemProperty $inetKey 'ProxyServer' '127.0.0.1:8080' -Type String -Force; Set-ItemProperty $inetKey 'ProxyOverride' '<local>;127.0.0.1;localhost;::1' -Type String -Force; $idmKey = 'HKCU:\Software\DownloadManager'; if (Test-Path $idmKey) { Set-ItemProperty $idmKey 'nProxyMode' 2 -Type DWord -Force; Set-ItemProperty $idmKey 'UseHttpProxy' 1 -Type DWord -Force; Set-ItemProperty $idmKey 'HttpProxyAddr' '127.0.0.1' -Type String -Force; Set-ItemProperty $idmKey 'HttpProxyPort' 8080 -Type DWord -Force; Set-ItemProperty $idmKey 'nHttpPrChbSt' 1 -Type DWord -Force; Set-ItemProperty $idmKey 'UseHttpsProxy' 1 -Type DWord -Force; Set-ItemProperty $idmKey 'HttpsProxyAddr' '127.0.0.1' -Type String -Force; Set-ItemProperty $idmKey 'HttpsProxyPort' 8080 -Type DWord -Force; Set-ItemProperty $idmKey 'nHttpsPrChbSt' 1 -Type DWord -Force }"

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
