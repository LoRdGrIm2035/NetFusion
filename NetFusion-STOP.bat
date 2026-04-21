@echo off
setlocal
title NetFusion STOP
color 0E
cd /d "%~dp0"

echo.
echo  ====================================================+
echo  ^|   NETFUSION STOP                                  ^|
echo  ====================================================+
echo.

powershell -NoProfile -Command "$id=[Security.Principal.WindowsIdentity]::GetCurrent(); $p=New-Object Security.Principal.WindowsPrincipal($id); if($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 0}else{exit 1}"
if errorlevel 1 (
    echo  [!] Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\NetFusionControl.ps1" -Action Stop
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" (
    echo.
    echo  [OK] NetFusion stopped and direct internet restored.
) else (
    echo.
    echo  [FAIL] NetFusion stop encountered an error. Check logs.
)

echo.
pause
exit /b %RC%
