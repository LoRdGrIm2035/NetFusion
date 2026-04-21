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

if (-not [string]::IsNullOrWhiteSpace($AdapterName)) {
    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    if ($adapter) {
        try {
            Remove-NetNeighbor -InterfaceIndex $adapter.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        } catch {}
    }
}

Write-Host "Running adapter repair with ARP refresh path..." -ForegroundColor Cyan
& $repair -AdapterName $AdapterName
