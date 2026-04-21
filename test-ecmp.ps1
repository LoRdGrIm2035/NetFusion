[CmdletBinding()]
param(
    [int]$TargetMetric = 25,
    [switch]$RestoreAutomaticMetric
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UsableAdapters {
    return @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq 'Up' -and
                $_.InterfaceDescription -notmatch '(?i)Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN|OpenVPN|WireGuard|Tailscale|ZeroTier|Npcap|vEthernet|VMware|VirtualBox'
            }
    )
}

$adapters = Get-UsableAdapters
if ($adapters.Count -eq 0) {
    Write-Host "[FAIL] No usable adapters found." -ForegroundColor Red
    exit 1
}

Write-Host "Applying ECMP-style harmonized metrics across $($adapters.Count) adapter(s)..." -ForegroundColor Cyan

foreach ($adapter in $adapters) {
    $ifIndex = [int]$adapter.ifIndex
    try {
        if ($RestoreAutomaticMetric) {
            Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue
        } else {
            Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric $TargetMetric -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "  [WARN] Failed to update $($adapter.Name): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object InterfaceAlias, RouteMetric |
    Format-Table InterfaceAlias, InterfaceIndex, NextHop, RouteMetric -AutoSize

if ($RestoreAutomaticMetric) {
    Write-Host "Automatic metrics restored for active adapters." -ForegroundColor Green
} else {
    Write-Host "Interface metrics harmonized to $TargetMetric for active adapters (default-route entries unchanged)." -ForegroundColor Green
}
