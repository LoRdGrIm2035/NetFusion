[CmdletBinding()]
param(
    [int]$PerAdapterConnections = 2,
    [int]$CombinedConnectionsPerAdapter = 2,
    [int]$BytesPerConnection = 6000000,
    [string]$TestHost = 'speed.cloudflare.com',
    [int]$ConnectTimeoutMs = 6000,
    [int]$IoTimeoutMs = 20000,
    [string]$OutputPath = "logs\test-adapter-matrix.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$validator = Join-Path $root "test-validate-throughput.ps1"
if (-not (Test-Path $validator)) {
    throw "Missing validator script: $validator"
}
. $validator

function Get-Combinations {
    param([object[]]$Items, [int]$Size)
    $results = [System.Collections.Generic.List[object]]::new()
    $n = $Items.Count
    if ($Size -le 0 -or $Size -gt $n) { return @() }

    $indexes = 0..($Size - 1)
    while ($true) {
        $combo = @()
        foreach ($idx in $indexes) { $combo += $Items[$idx] }
        $results.Add($combo) | Out-Null

        $i = $Size - 1
        while ($i -ge 0 -and $indexes[$i] -eq $n - $Size + $i) { $i-- }
        if ($i -lt 0) { break }
        $indexes[$i]++
        for ($j = $i + 1; $j -lt $Size; $j++) {
            $indexes[$j] = $indexes[$j - 1] + 1
        }
    }
    return @($results)
}

$allAdapters = @(Get-ActiveAdapters)
if ($allAdapters.Count -eq 0) {
    throw "No active adapters discovered."
}

$matrixRows = [System.Collections.Generic.List[object]]::new()
$fullResults = [System.Collections.Generic.List[object]]::new()

$scenarios = [System.Collections.Generic.List[object]]::new()
foreach ($adapter in $allAdapters) {
    $scenarios.Add(@($adapter.Name)) | Out-Null
}

if ($allAdapters.Count -ge 2) {
    foreach ($pair in @(Get-Combinations -Items $allAdapters -Size 2)) {
        $names = @($pair | ForEach-Object { $_.Name })
        $scenarios.Add($names) | Out-Null
    }
}

if ($allAdapters.Count -ge 3) {
    $scenarios.Add(@($allAdapters | ForEach-Object { $_.Name })) | Out-Null
}

foreach ($scenario in $scenarios) {
    $label = [string]($scenario -join ' + ')
    Write-Host ""
    Write-Host ("[Matrix] Testing: {0}" -f $label) -ForegroundColor Cyan

    $safeLabel = (($scenario -join '_') -replace '[^A-Za-z0-9_-]', '_')
    $scenarioOutput = Join-Path $root ("logs\matrix-{0}.json" -f $safeLabel)
    $result = Invoke-NetFusionThroughputValidation `
        -AdapterNames $scenario `
        -PerAdapterConnections $PerAdapterConnections `
        -CombinedConnectionsPerAdapter $CombinedConnectionsPerAdapter `
        -BytesPerConnection $BytesPerConnection `
        -TestHost $TestHost `
        -ConnectTimeoutMs $ConnectTimeoutMs `
        -IoTimeoutMs $IoTimeoutMs `
        -OutputPath $scenarioOutput `
        -IncludeCombinedTest `
        -WriteMonitoringLog

    $fullResults.Add($result) | Out-Null
    $matrixRows.Add([pscustomobject]@{
        Scenario = $label
        AdapterCount = $result.AdapterCount
        CombinedMbps = [math]::Round([double]$result.Combined.CombinedMbps, 2)
        SumIndividualMbps = [math]::Round([double]$result.Aggregates.SumIndividualMbps, 2)
        EfficiencyPct = [math]::Round([double]$result.Aggregates.EfficiencyPct, 2)
        PeakCombinedMbps = [math]::Round([double]$result.Aggregates.PeakCombinedMbps, 2)
        Sustained30SecMbps = [math]::Round([double]$result.Aggregates.Sustained30SecMbps, 2)
        UnderContributing = $result.UnderContributing.Count
    }) | Out-Null
}

$matrixRows | Sort-Object AdapterCount, Scenario | Format-Table -AutoSize

$final = [pscustomobject]@{
    Timestamp = (Get-Date).ToString('o')
    AdapterInventory = @($allAdapters | ForEach-Object { $_.Name })
    Matrix = @($matrixRows)
    Results = @($fullResults)
}

if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $root $OutputPath
}
Write-AtomicJson -Path $OutputPath -Data $final -Depth 9

Write-Host ""
Write-Host ("Matrix results written: {0}" -f $OutputPath) -ForegroundColor Green
$final | ConvertTo-Json -Depth 9
