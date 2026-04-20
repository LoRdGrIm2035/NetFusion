<#
.SYNOPSIS
    NetworkManager v4.0 — Intelligent auto-detection and scoring of network interfaces.
.DESCRIPTION
    Central orchestrator that discovers Wi-Fi, Ethernet, and USB network adapters.
    v4.0 enhancements:
      - Adapter capability scoring (link speed, type bonus, historical reliability)
      - Adapter fingerprinting for cross-session identification
      - Extended metadata for intelligence engine consumption
    Writes interface data to a shared JSON file for other components.
#>

[CmdletBinding()]
param(
    [int]$PollInterval = 3
)

# Resolve paths
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$OutputFile = Join-Path $projectDir "config\interfaces.json"
$script:gatewayProbeCache = @{}

function Write-AtomicJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 4
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tmp = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    try {
        $Data | ConvertTo-Json -Depth $Depth -Compress | Set-Content $tmp -Force -Encoding UTF8 -ErrorAction Stop
        Move-Item $tmp $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-AdapterCapabilityScore {
    <# Score an adapter based on its inherent capabilities (0-100). #>
    param([string]$Type, [double]$LinkSpeedMbps, [string]$Status, [int]$WiFiGen = 0)

    if ($Status -ne 'Up') { return 0 }
    $score = 30  # Base score for being active

    # Type bonus
    switch ($Type) {
        'Ethernet'  { $score += 30 }   # Most reliable
        'WiFi'      { $score += 20 }   # Good, internal
        'USB-WiFi'  { $score += 15 }   # USB overhead penalty
        default     { $score += 10 }
    }

    # Speed bonus (normalized to 1000 Mbps scale)
    $speedBonus = [math]::Min(30, [math]::Round(($LinkSpeedMbps / 1000) * 30))
    $score += $speedBonus

    # Link speed quality tiers
    if ($LinkSpeedMbps -ge 1000) { $score += 10 }
    elseif ($LinkSpeedMbps -ge 300) { $score += 5 }

    # Wi-Fi generation bonus (newer = better radios, MU-MIMO, OFDMA)
    switch ($WiFiGen) {
        8 { $score += 18 }  # Wi-Fi 8 (802.11bn, future)
        7 { $score += 15 }  # Wi-Fi 7 (802.11be, MLO, 320MHz, 4096-QAM)
        { $_ -eq 6.1 } { $score += 12 }  # Wi-Fi 6E (6GHz band)
        6 { $score += 10 }  # Wi-Fi 6 (802.11ax, OFDMA, MU-MIMO)
        5 { $score += 5 }   # Wi-Fi 5 (802.11ac, 5GHz)
        4 { $score += 2 }   # Wi-Fi 4 (802.11n)
    }

    return [math]::Min(100, $score)
}

function Get-AdapterFingerprint {
    <# Generate a stable fingerprint for cross-session adapter identification. #>
    param([string]$MacAddress, [string]$Description)
    $raw = "$MacAddress|$Description"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($bytes)
    return [BitConverter]::ToString($hash[0..7]).Replace('-', '').ToLower()
}

function Test-GatewayReachable {
    param(
        [string]$Gateway,
        [int]$CacheTtlSec = 20
    )

    if ([string]::IsNullOrWhiteSpace($Gateway)) { return $false }
    $key = [string]$Gateway
    $now = Get-Date
    if ($script:gatewayProbeCache.ContainsKey($key)) {
        $cached = $script:gatewayProbeCache[$key]
        try {
            if ($cached -and $cached.time -and (($now - [datetime]$cached.time).TotalSeconds -lt $CacheTtlSec)) {
                return [bool]$cached.ok
            }
        } catch {}
    }

    $ok = $false
    try {
        $ping = ping.exe -n 1 -w 500 $Gateway 2>$null
        $joined = ($ping | Out-String)
        if (
            ($joined -match 'TTL=' -or $joined -match 'time[=<]\d+\s*ms') -and
            $joined -notmatch '(?i)unreachable|timed out|general failure'
        ) {
            $ok = $true
        }
    } catch {}

    $script:gatewayProbeCache[$key] = @{
        time = $now
        ok = $ok
    }
    return $ok
}

function Get-PreferredDefaultRoute {
    param([int]$InterfaceIndex)

    $routes = @(
        Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric
    )
    if ($routes.Count -eq 0) { return $null }

    $reachableRoute = $null
    foreach ($r in $routes) {
        if (Test-GatewayReachable -Gateway ([string]$r.NextHop)) {
            $reachableRoute = $r
            break
        }
    }

    if ($reachableRoute) { return $reachableRoute }
    return ($routes | Select-Object -First 1)
}

function Get-AllNetworkInterfaces {
    <#
    .SYNOPSIS
        Discovers all usable network adapters with full metadata and capability scoring.
    #>
    $adapters = Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'TAP-Windows|OpenVPN|WireGuard|Cisco|Tailscale|ZeroTier|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel'
    }

    $results = @()

    foreach ($adapter in $adapters) {
        # Determine adapter type
        $type = 'Unknown'
        if ($adapter.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11|WLAN' -or $adapter.Name -match 'Wi-Fi|Wireless') {
            if ($adapter.InterfaceDescription -match 'USB|TP-Link|Realtek.*USB|Ralink.*USB|MediaTek.*USB') {
                $type = 'USB-WiFi'
            } else {
                $type = 'WiFi'
            }
        } elseif ($adapter.InterfaceDescription -match 'Ethernet|Realtek.*GbE|Intel.*Ethernet|Killer.*Ethernet' -or $adapter.Name -match 'Ethernet') {
            $type = 'Ethernet'
        }

        # Detect Wi-Fi generation from adapter description
        # Supports: Wi-Fi 4 (802.11n), 5 (802.11ac), 6 (802.11ax), 6E (6GHz), 7 (802.11be), 8+ (802.11bn+)
        $wifiGen = 0
        $wifiGenLabel = ''
        $desc = $adapter.InterfaceDescription
        if ($type -match 'WiFi') {
            if ($desc -match '802\.11bn|Wi-?Fi\s*8') {
                $wifiGen = 8; $wifiGenLabel = 'Wi-Fi 8 (802.11bn)'
            } elseif ($desc -match '802\.11be|Wi-?Fi\s*7|BE200|BE202|KILLER.*BE|QCA6698|QCN9274|MT7925|RTL8922') {
                $wifiGen = 7; $wifiGenLabel = 'Wi-Fi 7 (802.11be)'
            } elseif ($desc -match '6\s*GHz|Wi-?Fi\s*6E|AX2[01]1|AX411|AX1690|KILLER.*AX.*6E') {
                $wifiGen = 6.1; $wifiGenLabel = 'Wi-Fi 6E (6GHz)'
            } elseif ($desc -match '802\.11ax|Wi-?Fi\s*6|AX200|AX201|AX210|AX211|MT7921|MT7922|Killer.*AX|RTL8852') {
                $wifiGen = 6; $wifiGenLabel = 'Wi-Fi 6 (802.11ax)'
            } elseif ($desc -match '802\.11ac|Wi-?Fi\s*5|Wireless-AC|Dual Band.*AC|AC[\s-]?\d{4}|RTL8812|RTL8821') {
                $wifiGen = 5; $wifiGenLabel = 'Wi-Fi 5 (802.11ac)'
            } elseif ($desc -match '802\.11n|Wi-?Fi\s*4|Wireless-N|RTL8188|RT3572|AR9271|AR9462') {
                $wifiGen = 4; $wifiGenLabel = 'Wi-Fi 4 (802.11n)'
            } elseif ($desc -match '802\.11[abg]\b') {
                $wifiGen = 3; $wifiGenLabel = 'Legacy (802.11a/b/g)'
            } else {
                # Fallback: guess from link speed if description doesn't match
                if ($adapter.LinkSpeed -match '[\d.]+') {
                    $rawSpeed = 0
                    if ($adapter.LinkSpeed -match '([\d.]+)\s*Gbps') { $rawSpeed = [double]$Matches[1] * 1000 }
                    elseif ($adapter.LinkSpeed -match '([\d.]+)\s*Mbps') { $rawSpeed = [double]$Matches[1] }
                    if ($rawSpeed -ge 5000) { $wifiGen = 7; $wifiGenLabel = 'Wi-Fi 7 (speed-detected)' }
                    elseif ($rawSpeed -ge 2400) { $wifiGen = 6; $wifiGenLabel = 'Wi-Fi 6 (speed-detected)' }
                    elseif ($rawSpeed -ge 866) { $wifiGen = 5; $wifiGenLabel = 'Wi-Fi 5 (speed-detected)' }
                    elseif ($rawSpeed -ge 72) { $wifiGen = 4; $wifiGenLabel = 'Wi-Fi 4 (speed-detected)' }
                }
            }
        }

        # Get IP address
        $ipInfo = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ipAddr = if ($ipInfo) { $ipInfo.IPAddress } else { $null }

        # Get gateway once here so InterfaceMonitor can consume it from interfaces.json
        # instead of issuing duplicate Get-NetRoute queries every health cycle.
        $routeInfo = Get-PreferredDefaultRoute -InterfaceIndex $adapter.ifIndex
        $gateway = if ($routeInfo) { $routeInfo.NextHop } else { $null }

        # Get interface metric
        $metricInfo = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $metric = if ($metricInfo) { $metricInfo.InterfaceMetric } else { 9999 }
        $autoMetric = if ($metricInfo) { [string]$metricInfo.AutomaticMetric } else { 'Unknown' }

        # Get SSID for Wi-Fi adapters
        $ssid = ''
        if ($type -match 'WiFi') {
            try {
                $netshOutput = netsh wlan show interfaces
                $currentAdapter = $null
                foreach ($line in ($netshOutput -split "`n")) {
                    if ($line -match '^\s*Name\s*:\s*(.+)$') {
                        $currentAdapter = $Matches[1].Trim()
                    }
                    if ($currentAdapter -eq $adapter.Name -and $line -match '^\s*SSID\s*:\s*(.+)$') {
                        $ssid = $Matches[1].Trim()
                        break
                    }
                }
            } catch {}
        }

        # Get DNS servers
        $dnsServers = @()
        try {
            $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dnsInfo -and $dnsInfo.ServerAddresses) { $dnsServers = @($dnsInfo.ServerAddresses) }
        } catch {}

        # Get adapter statistics
        $stats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue

        # Parse link speed to Mbps
        $linkSpeedMbps = 0
        if ($adapter.LinkSpeed -match '([\d.]+)\s*(Gbps|Mbps|Kbps)') {
            $val = [double]$Matches[1]
            switch ($Matches[2]) {
                'Gbps' { $linkSpeedMbps = $val * 1000 }
                'Mbps' { $linkSpeedMbps = $val }
                'Kbps' { $linkSpeedMbps = $val / 1000 }
            }
        }

        # v5.2: Capability score with Wi-Fi generation awareness
        $capScore = Get-AdapterCapabilityScore -Type $type -LinkSpeedMbps $linkSpeedMbps -Status ([string]$adapter.Status) -WiFiGen ([int]$wifiGen)
        $fingerprint = Get-AdapterFingerprint -MacAddress $adapter.MacAddress -Description $adapter.InterfaceDescription

        $results += @{
            Name            = $adapter.Name
            Description     = $adapter.InterfaceDescription
            Type            = $type
            Status          = [string]$adapter.Status
            InterfaceIndex  = $adapter.ifIndex
            MacAddress      = $adapter.MacAddress
            LinkSpeed       = $adapter.LinkSpeed
            LinkSpeedMbps   = $linkSpeedMbps
            IPAddress       = $ipAddr
            Gateway         = $gateway
            SSID            = $ssid
            Metric          = $metric
            AutomaticMetric = $autoMetric
            DNSServers      = $dnsServers
            SentBytes       = if ($stats) { $stats.SentBytes } else { 0 }
            ReceivedBytes   = if ($stats) { $stats.ReceivedBytes } else { 0 }
            CapabilityScore = $capScore
            Fingerprint     = $fingerprint
            WiFiGeneration  = $wifiGen
            WiFiGenerationLabel = $wifiGenLabel
        }
    }

    return $results
}

function Update-NetworkState {
    try {
        $interfaces = Get-AllNetworkInterfaces
        $data = @{
            timestamp  = (Get-Date).ToString('o')
            version    = '4.0'
            count      = $interfaces.Count
            interfaces = $interfaces
        }
        Write-AtomicJson -Path $OutputFile -Data $data -Depth 4

        # Optional UI debug
        # foreach ($iface in $interfaces) { ... }
        
        return $interfaces
    } catch {
        Write-Host "  [NetworkManager] Error: $_" -ForegroundColor Red
        return @()
    }
}
