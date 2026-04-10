<#
.SYNOPSIS
    Cleanup-OnCrash.ps1 -- Removes orphaned firewall rules using the sentinel explicitly.
#>
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$rulesFile = Join-Path $projectDir "config\active-fw-rules.json"

if (Test-Path $rulesFile) {
    try {
        $data = Get-Content $rulesFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($data -and $data.rules) {
            foreach ($r in $data.rules) {
                Remove-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue
                Write-Host "  [Cleanup] Removed orphaned rule: $r" -ForegroundColor DarkGray
            }
        }
        Remove-Item $rulesFile -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  [Cleanup] Failed to parse active-fw-rules.json" -ForegroundColor Red
    }
}
