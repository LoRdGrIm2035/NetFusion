@echo off
setlocal
title NetFusion SAFE MODE
color 0C
cd /d "%~dp0"

echo.
echo  ====================================================+
echo  ^|   NETFUSION SAFE MODE                             ^|
echo  ====================================================+
echo.

powershell -NoProfile -Command "$id=[Security.Principal.WindowsIdentity]::GetCurrent(); $p=New-Object Security.Principal.WindowsPrincipal($id); if($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 0}else{exit 1}"
if errorlevel 1 (
    echo  [!] Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\NetFusionControl.ps1" -Action Safe
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" (
    echo.
    echo  [OK] Safe mode cleanup complete. Direct internet should be active.
) else (
    echo.
    echo  [FAIL] Safe mode encountered an error. Check logs.
)

echo.
pause
exit /b %RC%
