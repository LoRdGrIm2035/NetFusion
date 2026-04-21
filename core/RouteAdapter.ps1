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
$script:InterfaceMetricBackup = @{}

function Write-AtomicAdapterJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 4
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ([System.IO.Path]::GetRandomFileName())
    try {
        $Data | ConvertTo-Json -Depth $Depth -Compress | Set-Content $tmp -Force -Encoding UTF8 -ErrorAction Stop
        Move-Item $tmp $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

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
        Write-AtomicAdapterJson -Path $adapterEventsFile -Data @{ events = $events } -Depth 3
    } catch {}
}

function Get-NetworkAdapters {
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
        if (-not $script:InterfaceMetricBackup.ContainsKey($InterfaceIndex)) {
            $existing = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($existing) {
                $script:InterfaceMetricBackup[$InterfaceIndex] = @{
                    AutomaticMetric = [string]$existing.AutomaticMetric
                    InterfaceMetric = if ($null -ne $existing.InterfaceMetric) { [int]$existing.InterfaceMetric } else { 0 }
                }
            }
        }
        try {
            Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Disabled -ErrorAction Stop
            Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -InterfaceMetric $Metric -ErrorAction Stop
        } catch {
            Write-AdapterLog "Metric update failed on ifIndex=${InterfaceIndex}: $($_.Exception.Message)" "error"
            throw
        }
    }
}

function Enable-AutomaticMetric {
    param([int]$InterfaceIndex)
    Write-AdapterLog "Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AutomaticMetric Enabled" "info"
    if (-not $global:RouteAdapterDryRun) {
        Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue
    }
}

function Restore-InterfaceMetric {
    param([int]$InterfaceIndex)

    if (-not $script:InterfaceMetricBackup.ContainsKey($InterfaceIndex)) { return }
    if ($global:RouteAdapterDryRun) { return }

    $backup = $script:InterfaceMetricBackup[$InterfaceIndex]
    try {
        if ($backup.AutomaticMetric -match 'Enabled|True|1') {
            Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue
        } else {
            Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Disabled -ErrorAction SilentlyContinue
            if ($null -ne $backup.InterfaceMetric) {
                Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -InterfaceMetric ([int]$backup.InterfaceMetric) -ErrorAction SilentlyContinue
            }
        }
        Write-AdapterLog "Restored interface metric snapshot for ifIndex=$InterfaceIndex" "info"
    } catch {
        Write-AdapterLog "Failed to restore interface metric for ifIndex=${InterfaceIndex}: $($_.Exception.Message)" "error"
    }
}

function Add-Route {
    param([string]$DestinationPrefix, [int]$InterfaceIndex, [string]$NextHop, [int]$RouteMetric)
    if ($DestinationPrefix -in @('0.0.0.0/0', '::/0')) {
        Write-AdapterLog "Blocked default-route add request for ifIndex=$InterfaceIndex (prefix=$DestinationPrefix)" "warn"
        return
    }
    Write-AdapterLog "New-NetRoute -DestinationPrefix '$DestinationPrefix' -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric $RouteMetric" "info"
    if (-not $global:RouteAdapterDryRun) {
        New-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric $RouteMetric -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Remove-Route {
    param([string]$DestinationPrefix, [int]$InterfaceIndex, [string]$NextHop)
    if ($DestinationPrefix -in @('0.0.0.0/0', '::/0')) {
        Write-AdapterLog "Blocked default-route remove request for ifIndex=$InterfaceIndex (prefix=$DestinationPrefix)" "warn"
        return
    }
    Write-AdapterLog "Remove-NetRoute -DestinationPrefix '$DestinationPrefix' -InterfaceIndex $InterfaceIndex -NextHop $NextHop" "info"
    if (-not $global:RouteAdapterDryRun) {
        Remove-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -Confirm:$false -ErrorAction SilentlyContinue
    }
}
