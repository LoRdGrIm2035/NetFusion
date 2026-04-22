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
                $matchingRules = @(Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue)
                if ($matchingRules.Count -gt 0) {
                    # Remove crash-left firewall rules by concrete rule IDs and verify they are actually gone.
                    foreach ($rule in $matchingRules) {
                        try {
                            Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                        } catch {}
                    }
                }

                $remainingRules = @(Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue)
                if ($remainingRules.Count -eq 0) {
                    Write-Host "  [Cleanup] Removed orphaned rule: $r" -ForegroundColor DarkGray
                } else {
                    Write-Host "  [Cleanup] Unable to fully remove orphaned rule: $r" -ForegroundColor Yellow
                }
            }
        }
        Remove-Item $rulesFile -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  [Cleanup] Failed to parse active-fw-rules.json" -ForegroundColor Red
    }
}
