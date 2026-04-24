<#
.SYNOPSIS
    RouteAdapter v5.0 -- OS-level networking abstraction layer
.DESCRIPTION
    Abstracts all `route add/delete`, `Set-NetIPInterface`, and `Get-NetAdapter` calls.
    Provides robust logging and a dry-run mode for testing.
#>

[CmdletBinding()]
param(
    [bool]$DryRun = $false
)

$adapterScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$adapterProjectDir = Split-Path $adapterScriptDir -Parent
$adapterLogsDir = Join-Path $adapterProjectDir "logs"
$adapterEventsFile = Join-Path $adapterLogsDir "events.json"

function Write-AdapterLog {
    param([string]$Message, [string]$Level="info")
    $ts = (Get-Date).ToString('o')
    $prefix = if ($global:RouteAdapterDryRun) { "[DRY-RUN]" } else { "[EXEC]" }
    
    try {
        if (-not (Test-Path $adapterEventsFile)) { return }
        $data = Get-Content $adapterEventsFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        $events = if ($data -and $data.events) { @($data.events) } else { @() }
        $events = @(@{ timestamp = $ts; type = 'adapter'; message = "$prefix $Message"; level = $Level }) + $events
        if ($events.Count -gt 200) { $events = $events[0..199] }
        @{ events = $events } | ConvertTo-Json -Depth 3 -Compress | Set-Content $adapterEventsFile -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Get-NetworkAdapters {
    Write-AdapterLog "Querying OS network adapters..." "debug"
    if ($global:RouteAdapterDryRun) {
        Write-Output @()
    } else {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|OpenVPN|WireGuard|TAP-Windows|Cisco AnyConnect|Tailscale|ZeroTier' } | Sort-Object InterfaceMetric
        Write-Output $adapters
    }
}

function Set-InterfaceMetric {
    param([int]$InterfaceIndex, [int]$Metric)
    Write-AdapterLog "Set-NetIPInterface -InterfaceIndex $InterfaceIndex -InterfaceMetric $Metric" "info"
    if (-not $global:RouteAdapterDryRun) {
        Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Disabled -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -InterfaceMetric $Metric -ErrorAction SilentlyContinue
    }
}

function Enable-AutomaticMetric {
    param([int]$InterfaceIndex)
    Write-AdapterLog "Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AutomaticMetric Enabled" "info"
    if (-not $global:RouteAdapterDryRun) {
        Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue
    }
}

function Add-Route {
    param([string]$DestinationPrefix, [int]$InterfaceIndex, [string]$NextHop, [int]$RouteMetric)
    Write-AdapterLog "New-NetRoute -DestinationPrefix '$DestinationPrefix' -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric $RouteMetric" "info"
    if (-not $global:RouteAdapterDryRun) {
        New-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric $RouteMetric -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Remove-Route {
    param([string]$DestinationPrefix, [int]$InterfaceIndex, [string]$NextHop)
    Write-AdapterLog "Remove-NetRoute -DestinationPrefix '$DestinationPrefix' -InterfaceIndex $InterfaceIndex -NextHop $NextHop" "info"
    if (-not $global:RouteAdapterDryRun) {
        Remove-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -Confirm:$false -ErrorAction SilentlyContinue
    }
}
