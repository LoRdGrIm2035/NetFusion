@echo off
setlocal
title NetFusion START
color 0A
cd /d "%~dp0"

echo.
echo  ====================================================+
echo  ^|   NETFUSION START                                 ^|
echo  ====================================================+
echo.

powershell -NoProfile -Command "$id=[Security.Principal.WindowsIdentity]::GetCurrent(); $p=New-Object Security.Principal.WindowsPrincipal($id); if($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 0}else{exit 1}"
if errorlevel 1 (
    echo  [!] Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\NetFusionControl.ps1" -Action Start
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" (
    for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$cfgPath='%~dp0config\config.json'; $port=9090; if(Test-Path $cfgPath){ try { $cfg=Get-Content $cfgPath -Raw | ConvertFrom-Json -ErrorAction Stop; if($cfg.dashboardPort){$port=[int]$cfg.dashboardPort} } catch {} }; Write-Output $port"`) do set "DASH_PORT=%%P"
    if not defined DASH_PORT set "DASH_PORT=9090"
    echo.
    echo  [OK] NetFusion is active.
    echo      Proxy:     127.0.0.1 (from config)
    echo      Dashboard: http://127.0.0.1:%DASH_PORT%/
    powershell -NoProfile -Command "Start-Process ('http://127.0.0.1:%DASH_PORT%/')"
) else (
    echo.
    echo  [FAIL] NetFusion start failed. System was rolled back to direct internet.
)

echo.
pause
exit /b %RC%
