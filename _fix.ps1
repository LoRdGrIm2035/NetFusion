[CmdletBinding()]
param(
    [string]$AdapterName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repair = Join-Path $root "test-wifi4-fix.ps1"
if (-not (Test-Path $repair)) {
    throw "Missing repair script: $repair"
}

Write-Host "Running compatibility repair wrapper (_fix.ps1)..." -ForegroundColor Cyan
& $repair -AdapterName $AdapterName
