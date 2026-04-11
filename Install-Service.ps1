<#
.SYNOPSIS
    Installs NetFusion as a Windows Task Scheduler auto-start task.
.PARAMETER Install
    Register the scheduled task.
.PARAMETER Uninstall
    Remove the scheduled task.
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall
)

$TaskName = "NetFusion-AutoStart"
$projectDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$batPath = Join-Path $projectDir "NetFusion-START.bat"

if ($Install) {
    Write-Host ""
    Write-Host "  Installing NetFusion auto-start..." -ForegroundColor Cyan

    # Remove existing
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$batPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    # v6.0 #19: 15s delay so network adapters have time to initialize after login/sleep
    $trigger.Delay = 'PT15S'
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description "NetFusion Multi-Interface Network Optimizer" | Out-Null

    Write-Host "  Task '$TaskName' registered!" -ForegroundColor Green
    Write-Host "  NetFusion will start automatically on login." -ForegroundColor DarkGray
    Write-Host ""

} elseif ($Uninstall) {
    Write-Host ""
    Write-Host "  Removing NetFusion auto-start..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "  Task removed." -ForegroundColor Green
    Write-Host ""

} else {
    Write-Host ""
    Write-Host "  Usage:" -ForegroundColor Yellow
    Write-Host "    .\Install-Service.ps1 -Install     # Enable auto-start" -ForegroundColor White
    Write-Host "    .\Install-Service.ps1 -Uninstall   # Disable auto-start" -ForegroundColor White
    Write-Host ""
}
