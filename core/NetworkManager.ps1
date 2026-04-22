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
    [int]$PollInterval = 15
)

# Resolve paths
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$OutputFile = Join-Path $projectDir "config\interfaces.json"
$script:AdapterCacheTtlSeconds = 60
$script:LastInterfaceRefresh = $null
$script:CachedInterfaces = @()

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
    param(
        [string]$Type,
        [double]$LinkSpeedMbps,
        [string]$Status,
        [double]$WiFiGen = 0,
        [int]$EthernetGen = 0
    )

    if ($Status -ne 'Up') { return 0 }
    $score = 30  # Base score for being active

    # Type baseline (no hardware-form-factor bias)
    switch ($Type) {
        'Ethernet'  { $score += 20 }
        'WiFi'      { $score += 20 }
        'USB-WiFi'  { $score += 20 }
        default     { $score += 10 }
    }

    # Speed bonus (normalized to 1000 Mbps scale)
    $speedBonus = [math]::Min(30, [math]::Round(($LinkSpeedMbps / 1000) * 30))
    $score += $speedBonus

    # Link speed quality tiers
    if ($LinkSpeedMbps -ge 1000) { $score += 10 }
    elseif ($LinkSpeedMbps -ge 300) { $score += 5 }

    # Wi-Fi generation bonus (Wi-Fi 1 -> latest)
    switch ($WiFiGen) {
        { $_ -ge 8 } { $score += 18 }  # Wi-Fi latest (802.11bn+)
        7 { $score += 15 }              # Wi-Fi 7 (802.11be)
        { $_ -eq 6.1 } { $score += 12 } # Wi-Fi 6E (6GHz)
        6 { $score += 10 }              # Wi-Fi 6 (802.11ax)
        5 { $score += 7 }               # Wi-Fi 5 (802.11ac)
        4 { $score += 5 }               # Wi-Fi 4 (802.11n)
        3 { $score += 3 }               # Wi-Fi 3 (802.11g)
        2 { $score += 2 }               # Wi-Fi 2 (802.11a)
        1 { $score += 1 }               # Wi-Fi 1 (802.11b)
    }

    # Ethernet generation bonus (Ethernet v1 -> latest)
    switch ($EthernetGen) {
        { $_ -ge 13 } { $score += 18 } # 800GbE+
        12 { $score += 16 }             # 400GbE
        11 { $score += 15 }             # 200GbE
        10 { $score += 14 }             # 100GbE
        9 { $score += 13 }              # 50GbE
        8 { $score += 12 }              # 40GbE
        7 { $score += 11 }              # 25GbE
        6 { $score += 10 }              # 10GbE
        5 { $score += 8 }               # 5GbE
        4 { $score += 6 }               # 2.5GbE
        3 { $score += 4 }               # 1GbE
        2 { $score += 2 }               # 100MbE
        1 { $score += 1 }               # 10MbE
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

function Get-LinkSpeedMbps {
    param([string]$LinkSpeed)

    if ($LinkSpeed -match '([\d.]+)\s*(Gbps|Mbps|Kbps)') {
        $val = [double]$Matches[1]
        switch ($Matches[2]) {
            'Gbps' { return ($val * 1000) }
            'Mbps' { return $val }
            'Kbps' { return ($val / 1000) }
        }
    }

    return 0
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

        $linkSpeedMbps = Get-LinkSpeedMbps -LinkSpeed ([string]$adapter.LinkSpeed)

        # Detect Wi-Fi generation from adapter description
        # Supports: Wi-Fi 1 (802.11b) through Wi-Fi 7 (802.11be) and latest (802.11bn+)
        $wifiGen = 0
        $wifiGenLabel = ''
        $ethernetGen = 0
        $ethernetGenLabel = ''
        $desc = $adapter.InterfaceDescription
        if ($type -match 'WiFi') {
            if ($desc -match '802\.11bn|Wi-?Fi\s*8') {
                $wifiGen = 8; $wifiGenLabel = 'Wi-Fi Latest (802.11bn+)'
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
            } elseif ($desc -match '802\.11g|Wi-?Fi\s*3|Wireless-G') {
                $wifiGen = 3; $wifiGenLabel = 'Wi-Fi 3 (802.11g)'
            } elseif ($desc -match '802\.11a|Wi-?Fi\s*2|Wireless-A') {
                $wifiGen = 2; $wifiGenLabel = 'Wi-Fi 2 (802.11a)'
            } elseif ($desc -match '802\.11b|Wi-?Fi\s*1|Wireless-B') {
                $wifiGen = 1; $wifiGenLabel = 'Wi-Fi 1 (802.11b)'
            } elseif ($desc -match '802\.11[abg]\b') {
                $wifiGen = 3; $wifiGenLabel = 'Wi-Fi 3 (802.11g, legacy fallback)'
            } else {
                # Fallback: guess from link speed if description doesn't match
                if ($linkSpeedMbps -ge 10000) { $wifiGen = 8; $wifiGenLabel = 'Wi-Fi Latest (speed-detected)' }
                elseif ($linkSpeedMbps -ge 5000) { $wifiGen = 7; $wifiGenLabel = 'Wi-Fi 7 (speed-detected)' }
                elseif ($linkSpeedMbps -ge 2400) { $wifiGen = 6; $wifiGenLabel = 'Wi-Fi 6 (speed-detected)' }
                elseif ($linkSpeedMbps -ge 866) { $wifiGen = 5; $wifiGenLabel = 'Wi-Fi 5 (speed-detected)' }
                elseif ($linkSpeedMbps -ge 72) { $wifiGen = 4; $wifiGenLabel = 'Wi-Fi 4 (speed-detected)' }
                elseif ($linkSpeedMbps -ge 54) { $wifiGen = 3; $wifiGenLabel = 'Wi-Fi 3 (speed-detected)' }
                elseif ($linkSpeedMbps -ge 11) { $wifiGen = 2; $wifiGenLabel = 'Wi-Fi 2 (speed-detected)' }
                elseif ($linkSpeedMbps -gt 0) { $wifiGen = 1; $wifiGenLabel = 'Wi-Fi 1 (speed-detected)' }
            }
        } elseif ($type -eq 'Ethernet') {
            # Ethernet version mapping from v1 (10MbE) through latest mainstream speeds.
            if ($linkSpeedMbps -ge 800000) { $ethernetGen = 13; $ethernetGenLabel = 'Ethernet v13 (800GbE)' }
            elseif ($linkSpeedMbps -ge 400000) { $ethernetGen = 12; $ethernetGenLabel = 'Ethernet v12 (400GbE)' }
            elseif ($linkSpeedMbps -ge 200000) { $ethernetGen = 11; $ethernetGenLabel = 'Ethernet v11 (200GbE)' }
            elseif ($linkSpeedMbps -ge 100000) { $ethernetGen = 10; $ethernetGenLabel = 'Ethernet v10 (100GbE)' }
            elseif ($linkSpeedMbps -ge 50000) { $ethernetGen = 9; $ethernetGenLabel = 'Ethernet v9 (50GbE)' }
            elseif ($linkSpeedMbps -ge 40000) { $ethernetGen = 8; $ethernetGenLabel = 'Ethernet v8 (40GbE)' }
            elseif ($linkSpeedMbps -ge 25000) { $ethernetGen = 7; $ethernetGenLabel = 'Ethernet v7 (25GbE)' }
            elseif ($linkSpeedMbps -ge 10000) { $ethernetGen = 6; $ethernetGenLabel = 'Ethernet v6 (10GbE)' }
            elseif ($linkSpeedMbps -ge 5000) { $ethernetGen = 5; $ethernetGenLabel = 'Ethernet v5 (5GbE)' }
            elseif ($linkSpeedMbps -ge 2500) { $ethernetGen = 4; $ethernetGenLabel = 'Ethernet v4 (2.5GbE)' }
            elseif ($linkSpeedMbps -ge 1000) { $ethernetGen = 3; $ethernetGenLabel = 'Ethernet v3 (1GbE)' }
            elseif ($linkSpeedMbps -ge 100) { $ethernetGen = 2; $ethernetGenLabel = 'Ethernet v2 (100MbE)' }
            elseif ($linkSpeedMbps -gt 0) { $ethernetGen = 1; $ethernetGenLabel = 'Ethernet v1 (10MbE)' }

            if (-not $ethernetGenLabel -and $desc -match 'Fast Ethernet|10/100') {
                $ethernetGen = 2; $ethernetGenLabel = 'Ethernet v2 (100MbE)'
            } elseif (-not $ethernetGenLabel -and $desc -match 'Gigabit|GbE|1000') {
                $ethernetGen = 3; $ethernetGenLabel = 'Ethernet v3 (1GbE)'
            }
        }

        # NetFusion-FIX-12: Capture link speed, IPv4, gateway, and DNS metadata during adapter discovery so routing and source-bound sockets use the selected WAN.
        # Get IP address
        $ipInfo = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ipAddr = if ($ipInfo) { $ipInfo.IPAddress } else { $null }

        # Get gateway
        $routeInfo = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                     Sort-Object RouteMetric | Select-Object -First 1
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

        # v5.3: Capability score with Wi-Fi and Ethernet generation awareness
        $capScore = Get-AdapterCapabilityScore -Type $type -LinkSpeedMbps $linkSpeedMbps -Status ([string]$adapter.Status) -WiFiGen ([double]$wifiGen) -EthernetGen ([int]$ethernetGen)
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
            EthernetGeneration = $ethernetGen
            EthernetGenerationLabel = $ethernetGenLabel
        }
    }

    return $results
}

function Update-NetworkState {
    param([switch]$ForceRefresh)

    try {
        # Cache adapter discovery instead of re-querying NetAdapter/NetRoute every few seconds.
        $now = Get-Date
        if (-not $ForceRefresh -and $script:CachedInterfaces.Count -gt 0 -and $script:LastInterfaceRefresh -and (($now - $script:LastInterfaceRefresh).TotalSeconds -lt $script:AdapterCacheTtlSeconds)) {
            return @($script:CachedInterfaces)
        }

        $interfaces = Get-AllNetworkInterfaces
        $data = @{
            timestamp  = (Get-Date).ToString('o')
            version    = '4.0'
            count      = $interfaces.Count
            interfaces = $interfaces
        }
        Write-AtomicJson -Path $OutputFile -Data $data -Depth 4
        $script:CachedInterfaces = @($interfaces)
        $script:LastInterfaceRefresh = $now

        # Optional UI debug
        # foreach ($iface in $interfaces) { ... }
        
        return $interfaces
    } catch {
        Write-Host "  [NetworkManager] Error: $_" -ForegroundColor Red
        return @()
    }
}
