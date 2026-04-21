[CmdletBinding()]
param(
    [string]$AdapterName = '',
    [int]$Metric = 25
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

function Repair-Adapter {
    param([object]$Adapter)

    Write-Host "Repairing adapter: $($Adapter.Name)" -ForegroundColor Cyan
    try {
        Disable-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Enable-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    } catch {}

    try {
        ipconfig /renew "$($Adapter.Name)" | Out-Null
    } catch {}

    try {
        Set-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric $Metric -ErrorAction SilentlyContinue
    } catch {}

    $ip = @(
        Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
            Select-Object -ExpandProperty IPAddress
    )
    $hasDefault = @(
        Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    ).Count -gt 0
    Write-Host ("  IPv4: {0}" -f ($(if ($ip.Count -gt 0) { $ip[0] } else { 'none' }))) -ForegroundColor Gray
    Write-Host ("  Default route: {0}" -f ($(if ($hasDefault) { 'yes' } else { 'no' }))) -ForegroundColor Gray
}

$adapters = Get-UsableAdapters
if ([string]::IsNullOrWhiteSpace($AdapterName)) {
    foreach ($adapter in $adapters) { Repair-Adapter -Adapter $adapter }
} else {
    $adapter = $adapters | Where-Object { $_.Name -eq $AdapterName } | Select-Object -First 1
    if (-not $adapter) { throw "Adapter not found or not usable: $AdapterName" }
    Repair-Adapter -Adapter $adapter
}

Write-Host ""
Write-Host "Post-repair default routes:" -ForegroundColor Yellow
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object InterfaceAlias, RouteMetric |
    Format-Table InterfaceAlias, NextHop, RouteMetric -AutoSize
