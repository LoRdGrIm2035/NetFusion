[CmdletBinding()]
param(
    [string]$OutputPath = "logs\test-speed-summary.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$validator = Join-Path $root "test-validate-throughput.ps1"
if (-not (Test-Path $validator)) {
    throw "Missing validation script: $validator"
}

. $validator
$result = Invoke-NetFusionThroughputValidation -OutputPath $OutputPath -IncludeCombinedTest -WriteMonitoringLog

Write-Host ""
Write-Host "====== SPEED TEST SUMMARY ======" -ForegroundColor White
Write-Host ("Adapters tested:   {0}" -f $result.AdapterCount) -ForegroundColor White
Write-Host ("Combined Mbps:     {0}" -f ([math]::Round([double]$result.Combined.CombinedMbps, 2))) -ForegroundColor Cyan
Write-Host ("Sum individual:    {0}" -f ([math]::Round([double]$result.Aggregates.SumIndividualMbps, 2))) -ForegroundColor Yellow
Write-Host ("Efficiency:        {0}%" -f ([math]::Round([double]$result.Aggregates.EfficiencyPct, 1))) -ForegroundColor Green
Write-Host "================================" -ForegroundColor White
