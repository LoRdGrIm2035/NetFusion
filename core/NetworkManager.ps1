<#
.SYNOPSIS
    NetworkManager v5.0 -- Robust multi-interface discovery and classification.
.DESCRIPTION
    Discovers and classifies all usable adapters using multiple data sources:
      - Get-NetAdapter / Get-NetIPAddress / Get-NetIPInterface
      - Win32_NetworkAdapter (WMI/CIM)
      - ifType + media type + bus hints
    Produces N-adapter metadata for downstream health, routing, and proxy engines.
#>

[CmdletBinding()]
param(
    [int]$PollInterval = 3
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$OutputFile = Join-Path $projectDir "config\interfaces.json"
$script:gatewayProbeCache = @{}

function Write-AtomicJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 6
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

function Convert-LinkSpeedToMbps {
    param([object]$LinkSpeed)

    $raw = [string]$LinkSpeed
    if ([string]::IsNullOrWhiteSpace($raw)) { return 0.0 }
    if ($raw -match '([\d.]+)\s*(Gbps|Mbps|Kbps)') {
        $val = [double]$Matches[1]
        switch ($Matches[2]) {
            'Gbps' { return [math]::Round($val * 1000.0, 2) }
            'Mbps' { return [math]::Round($val, 2) }
            'Kbps' { return [math]::Round($val / 1000.0, 2) }
        }
    }
    return 0.0
}

function Get-AdapterFingerprint {
    param([string]$MacAddress, [string]$Description, [int]$InterfaceIndex)

    $raw = "$MacAddress|$Description|$InterfaceIndex"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return [BitConverter]::ToString($hash[0..7]).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
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
        $pinger = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $pinger.Send($Gateway, 500)
            if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $ok = $true
            }
        } finally {
            $pinger.Dispose()
        }
    } catch {}

    $script:gatewayProbeCache[$key] = @{ time = $now; ok = $ok }
    return $ok
}

function Get-PreferredDefaultRoute {
    param(
        [int]$InterfaceIndex,
        [ValidateSet('IPv4','IPv6')]
        [string]$AddressFamily = 'IPv4'
    )

    $prefix = if ($AddressFamily -eq 'IPv6') { '::/0' } else { '0.0.0.0/0' }
    $routes = @(
        Get-NetRoute -InterfaceIndex $InterfaceIndex -AddressFamily $AddressFamily -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric
    )
    if ($routes.Count -eq 0) { return $null }

    foreach ($route in $routes) {
        if ($AddressFamily -eq 'IPv4') {
            if (Test-GatewayReachable -Gateway ([string]$route.NextHop)) {
                return $route
            }
        } else {
            return $route
        }
    }

    return ($routes | Select-Object -First 1)
}

function Get-WifiRuntimeMap {
    $map = @{}
    try {
        $netshOutput = netsh wlan show interfaces 2>$null
        if (-not $netshOutput) { return $map }

        $current = $null
        foreach ($line in @($netshOutput -split "`r?`n")) {
            if ($line -match '^\s*Name\s*:\s*(.+)$') {
                $current = $Matches[1].Trim()
                if (-not $map.ContainsKey($current)) {
                    $map[$current] = @{ SSID = ''; Signal = 0; RadioType = '' }
                }
                continue
            }

            if (-not $current) { continue }

            if ($line -match '^\s*SSID\s*:\s*(.+)$') {
                $map[$current].SSID = $Matches[1].Trim()
            } elseif ($line -match '^\s*Signal\s*:\s*(\d+)%') {
                $map[$current].Signal = [int]$Matches[1]
            } elseif ($line -match '^\s*Radio\s+type\s*:\s*(.+)$') {
                $map[$current].RadioType = $Matches[1].Trim()
            }
        }
    } catch {}

    return $map
}

function Get-WmiAdapterMap {
    $map = @{}
    try {
        $items = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue
        foreach ($item in @($items)) {
            if ($null -eq $item.InterfaceIndex) { continue }
            $map[[int]$item.InterfaceIndex] = $item
        }
    } catch {}
    return $map
}

function Get-IfTypeLabel {
    param([int]$IfType)

    switch ($IfType) {
        6 { 'Ethernet'; break }
        23 { 'PPP'; break }
        24 { 'Loopback'; break }
        71 { 'WiFi'; break }
        131 { 'Tunnel'; break }
        144 { 'IEEE1394'; break }
        243 { 'WWAN'; break }
        244 { 'WWAN'; break }
        default { 'Unknown' }
    }
}

function Test-IsVirtualAdapter {
    param(
        [object]$Adapter,
        [object]$WmiAdapter
    )

    $wmiName = ''
    $wmiPnp = ''
    $wmiType = ''
    if ($WmiAdapter) {
        $wmiName = [string]$WmiAdapter.Name
        $wmiPnp = [string]$WmiAdapter.PNPDeviceID
        $wmiType = [string]$WmiAdapter.AdapterType
    }

    $candidates = @(
        [string]$Adapter.Name,
        [string]$Adapter.InterfaceDescription,
        $wmiName,
        $wmiPnp,
        $wmiType
    )

    $joined = ($candidates -join ' | ')
    return [bool]($joined -match '(?i)Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN|OpenVPN|WireGuard|Tailscale|ZeroTier|Npcap|vEthernet|VMware|VirtualBox|Software Loopback')
}

function Get-WiFiGeneration {
    param(
        [string]$Description,
        [string]$RadioType,
        [double]$LinkSpeedMbps
    )

    $desc = [string]$Description
    $radio = [string]$RadioType

    if ($radio -match '(?i)802\.11be' -or $desc -match '(?i)802\.11be|Wi-?Fi\s*7|\bBE\d{3}\b|QCN9274|MT7925') {
        return @{ Gen = 7; Label = 'Wi-Fi 7 (802.11be)' }
    }
    if ($radio -match '(?i)802\.11ax' -or $desc -match '(?i)802\.11ax|Wi-?Fi\s*6E?|\bAX\d{3}\b|MT7921|MT7922|RTL8852') {
        if ($desc -match '(?i)6E|6\s*GHz') {
            return @{ Gen = 6.1; Label = 'Wi-Fi 6E (6GHz)' }
        }
        return @{ Gen = 6; Label = 'Wi-Fi 6 (802.11ax)' }
    }
    if ($radio -match '(?i)802\.11ac' -or $desc -match '(?i)802\.11ac|Wi-?Fi\s*5|Wireless-AC|\bAC\d{3,4}\b') {
        return @{ Gen = 5; Label = 'Wi-Fi 5 (802.11ac)' }
    }
    if ($radio -match '(?i)802\.11n' -or $desc -match '(?i)802\.11n|Wi-?Fi\s*4|Wireless-N') {
        return @{ Gen = 4; Label = 'Wi-Fi 4 (802.11n)' }
    }

    if ($LinkSpeedMbps -ge 1376) { return @{ Gen = 7; Label = 'Wi-Fi 7 (speed heuristic)' } }
    if ($LinkSpeedMbps -ge 574) { return @{ Gen = 6; Label = 'Wi-Fi 6/6E (speed heuristic)' } }
    if ($LinkSpeedMbps -ge 433) { return @{ Gen = 5; Label = 'Wi-Fi 5 (speed heuristic)' } }
    if ($LinkSpeedMbps -ge 72) { return @{ Gen = 4; Label = 'Wi-Fi 4 (speed heuristic)' } }

    return @{ Gen = 0; Label = '' }
}

function Get-AdapterType {
    param(
        [object]$Adapter,
        [object]$WmiAdapter,
        [int]$IfType,
        [string]$MediaType,
        [string]$PhysicalMediaType
    )

    $desc = [string]$Adapter.InterfaceDescription
    $name = [string]$Adapter.Name
    $pnp = if ($WmiAdapter) { [string]$WmiAdapter.PNPDeviceID } else { '' }

    $isWifi = $IfType -eq 71 -or $desc -match '(?i)Wi-Fi|Wireless|802\.11|WLAN' -or $MediaType -match '(?i)Native802_11|Wireless' -or $PhysicalMediaType -match '(?i)Native802_11|Wireless'
    $isEthernet = $IfType -eq 6 -or $desc -match '(?i)Ethernet|GbE|RJ45' -or $MediaType -match '(?i)802\.3|Ethernet'
    $isWwan = $IfType -in @(243, 244) -or $desc -match '(?i)WWAN|Cellular|Mobile'
    $isUsb = $pnp -match '(?i)^USB' -or $desc -match '(?i)USB'

    if ($isWifi -and $isUsb) { return 'USB-WiFi' }
    if ($isWifi) { return 'WiFi' }
    if ($isEthernet -and $isUsb) { return 'USB-Ethernet' }
    if ($isEthernet) { return 'Ethernet' }
    if ($isWwan) { return 'Cellular' }
    if ($name -match '(?i)Ethernet') { return 'Ethernet' }
    if ($name -match '(?i)Wi-?Fi|Wireless') { return 'WiFi' }
    return 'Unknown'
}

function Get-EstimatedCapacityMbps {
    param(
        [string]$Type,
        [double]$LinkSpeedMbps,
        [double]$WiFiGeneration
    )

    if ($LinkSpeedMbps -le 0) { return 50.0 }

    if ($Type -match 'WiFi') {
        $efficiency = 0.58
        if ($WiFiGeneration -ge 7) { $efficiency = 0.65 }
        elseif ($WiFiGeneration -ge 6) { $efficiency = 0.62 }
        elseif ($WiFiGeneration -ge 5) { $efficiency = 0.58 }
        elseif ($WiFiGeneration -gt 0) { $efficiency = 0.52 }
        return [math]::Round([math]::Max(20.0, $LinkSpeedMbps * $efficiency), 2)
    }

    if ($Type -match 'Ethernet') {
        return [math]::Round([math]::Max(50.0, $LinkSpeedMbps * 0.92), 2)
    }

    if ($Type -eq 'Cellular') {
        return [math]::Round([math]::Max(10.0, $LinkSpeedMbps * 0.45), 2)
    }

    return [math]::Round([math]::Max(20.0, $LinkSpeedMbps * 0.60), 2)
}

function Get-AdapterCapabilityScore {
    param(
        [string]$Type,
        [double]$LinkSpeedMbps,
        [string]$Status,
        [double]$WiFiGeneration = 0,
        [double]$SignalQuality = 0
    )

    if ($Status -ne 'Up') { return 0 }
    $score = 20

    # Keep capability scoring type-agnostic by default and derive most weight
    # from observed/advertised link capacity plus Wi-Fi PHY/signal detail.
    if ($LinkSpeedMbps -gt 0) {
        $score += [math]::Min(55, [math]::Round([math]::Sqrt([math]::Max(1.0, $LinkSpeedMbps)) * 2.5))
    } else {
        $score += 8
    }

    if ($Type -match 'WiFi') {
        switch ($WiFiGeneration) {
            { $_ -ge 7 } { $score += 12; break }
            { $_ -ge 6 } { $score += 9; break }
            5 { $score += 6; break }
            4 { $score += 3; break }
            default { $score += 1 }
        }
        if ($SignalQuality -gt 0) {
            $score += [math]::Round([math]::Min(8, $SignalQuality / 12.5))
        }
    }

    return [math]::Min(100, [math]::Max(0, [math]::Round($score)))
}

function Get-AllNetworkInterfaces {
    $wmiMap = Get-WmiAdapterMap
    $wifiRuntimeMap = Get-WifiRuntimeMap

    $netAdapters = @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' }
    )

    $results = @()

    foreach ($adapter in $netAdapters) {
        $ifIndex = [int]$adapter.ifIndex
        $wmi = if ($wmiMap.ContainsKey($ifIndex)) { $wmiMap[$ifIndex] } else { $null }

        if (Test-IsVirtualAdapter -Adapter $adapter -WmiAdapter $wmi) {
            continue
        }

        $ipInterface4 = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ipInterface6 = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue

        $ifType = 0
        if ($ipInterface4 -and $null -ne $ipInterface4.InterfaceType) {
            $ifType = [int]$ipInterface4.InterfaceType
        } elseif ($ipInterface6 -and $null -ne $ipInterface6.InterfaceType) {
            $ifType = [int]$ipInterface6.InterfaceType
        } elseif ($wmi -and $null -ne $wmi.AdapterTypeID) {
            # WMI AdapterTypeID is not identical to IF_TYPE, but this is safer than
            # incorrectly using InterfaceIndex as a type code.
            switch ([int]$wmi.AdapterTypeID) {
                0 { $ifType = 6; break }   # Ethernet 802.3
                9 { $ifType = 71; break }  # Wireless
                default { $ifType = 0 }
            }
        }

        $mediaType = if ($null -ne $adapter.MediaType) { [string]$adapter.MediaType } else { '' }
        $physicalMediaType = if ($null -ne $adapter.PhysicalMediaType) { [string]$adapter.PhysicalMediaType } else { '' }

        if ($ifType -in @(24, 131)) { continue }

        $type = Get-AdapterType -Adapter $adapter -WmiAdapter $wmi -IfType $ifType -MediaType $mediaType -PhysicalMediaType $physicalMediaType
        if ($type -eq 'Unknown' -and $ifType -in @(24, 131)) { continue }

        $ipv4List = @(
            Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
                Sort-Object SkipAsSource, PrefixOrigin |
                Select-Object -ExpandProperty IPAddress
        )
        $ipv6List = @(
            Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^fe80:' } |
                Sort-Object SkipAsSource, PrefixOrigin |
                Select-Object -ExpandProperty IPAddress
        )

        if ($ipv4List.Count -eq 0 -and $ipv6List.Count -eq 0) {
            continue
        }

        $route4 = Get-PreferredDefaultRoute -InterfaceIndex $ifIndex -AddressFamily IPv4
        $route6 = Get-PreferredDefaultRoute -InterfaceIndex $ifIndex -AddressFamily IPv6

        $gateway4 = if ($route4) { [string]$route4.NextHop } else { '' }
        $gateway6 = if ($route6) { [string]$route6.NextHop } else { '' }

        $dns4 = @()
        $dns6 = @()
        try {
            $dnsInfo4 = Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dnsInfo4 -and $dnsInfo4.ServerAddresses) { $dns4 = @($dnsInfo4.ServerAddresses) }
        } catch {}
        try {
            $dnsInfo6 = Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
            if ($dnsInfo6 -and $dnsInfo6.ServerAddresses) { $dns6 = @($dnsInfo6.ServerAddresses) }
        } catch {}

        $stats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
        $linkSpeedMbps = Convert-LinkSpeedToMbps -LinkSpeed $adapter.LinkSpeed

        if ($linkSpeedMbps -le 0 -and $adapter.ReceiveLinkSpeed -gt 0) {
            $linkSpeedMbps = [math]::Round([double]$adapter.ReceiveLinkSpeed / 1MB, 2)
        }

        $wifiRuntime = if ($wifiRuntimeMap.ContainsKey($adapter.Name)) { $wifiRuntimeMap[$adapter.Name] } else { @{ SSID = ''; Signal = 0; RadioType = '' } }
        $wifiMeta = Get-WiFiGeneration -Description ([string]$adapter.InterfaceDescription) -RadioType ([string]$wifiRuntime.RadioType) -LinkSpeedMbps $linkSpeedMbps

        $signalQuality = 0
        if ($type -match 'WiFi' -and $wifiRuntime.Signal -gt 0) {
            $signalQuality = [int]$wifiRuntime.Signal
        }

        $capabilityScore = Get-AdapterCapabilityScore -Type $type -LinkSpeedMbps $linkSpeedMbps -Status ([string]$adapter.Status) -WiFiGeneration ([double]$wifiMeta.Gen) -SignalQuality $signalQuality
        $estimatedCapacity = Get-EstimatedCapacityMbps -Type $type -LinkSpeedMbps $linkSpeedMbps -WiFiGeneration ([double]$wifiMeta.Gen)

        $mac = if ($adapter.MacAddress) { [string]$adapter.MacAddress } elseif ($wmi -and $wmi.MACAddress) { [string]$wmi.MACAddress } else { '' }
        $fingerprint = Get-AdapterFingerprint -MacAddress $mac -Description ([string]$adapter.InterfaceDescription) -InterfaceIndex $ifIndex

        $busType = if ($wmi -and $wmi.PNPDeviceID -match '(?i)^USB') { 'USB' } elseif ($wmi -and $wmi.PNPDeviceID) { ([string]$wmi.PNPDeviceID -split '\\')[0] } else { 'Unknown' }

        $metric4 = if ($ipInterface4 -and $null -ne $ipInterface4.InterfaceMetric) { [int]$ipInterface4.InterfaceMetric } else { 9999 }
        $metric6 = if ($ipInterface6 -and $null -ne $ipInterface6.InterfaceMetric) { [int]$ipInterface6.InterfaceMetric } else { 9999 }

        $primary4 = if ($ipv4List.Count -gt 0) { [string]$ipv4List[0] } else { '' }
        $primary6 = if ($ipv6List.Count -gt 0) { [string]$ipv6List[0] } else { '' }
        $primaryIp = if ($primary4) { $primary4 } else { $primary6 }

        $results += [pscustomobject]@{
            Name               = [string]$adapter.Name
            Description        = [string]$adapter.InterfaceDescription
            Type               = $type
            Status             = [string]$adapter.Status
            InterfaceIndex     = $ifIndex
            IfType             = $ifType
            IfTypeLabel        = (Get-IfTypeLabel -IfType $ifType)
            MediaType          = $mediaType
            PhysicalMediaType  = $physicalMediaType
            BusType            = $busType
            IsVirtual          = $false
            IsUSB              = [bool]($busType -eq 'USB' -or [string]$adapter.InterfaceDescription -match '(?i)USB')
            MacAddress         = $mac
            Fingerprint        = $fingerprint
            LinkSpeed          = [string]$adapter.LinkSpeed
            LinkSpeedMbps      = [double]$linkSpeedMbps
            EstimatedCapacityMbps = [double]$estimatedCapacity
            CapabilityScore    = [int]$capabilityScore
            SignalQuality      = [int]$signalQuality
            RadioType          = if ($type -match 'WiFi') { [string]$wifiRuntime.RadioType } else { '' }
            WiFiGeneration     = [double]$wifiMeta.Gen
            WiFiGenerationLabel = [string]$wifiMeta.Label
            SSID               = if ($type -match 'WiFi') { [string]$wifiRuntime.SSID } else { '' }
            IPAddress          = $primaryIp
            PrimaryIPv4        = $primary4
            PrimaryIPv6        = $primary6
            IPAddresses        = $ipv4List
            IPv6Addresses      = $ipv6List
            Gateway            = $gateway4
            GatewayIPv6        = $gateway6
            Metric             = $metric4
            MetricIPv6         = $metric6
            AutomaticMetric    = if ($ipInterface4) { [string]$ipInterface4.AutomaticMetric } else { 'Unknown' }
            AutomaticMetricIPv6 = if ($ipInterface6) { [string]$ipInterface6.AutomaticMetric } else { 'Unknown' }
            DNSServers         = $dns4
            DNSServersIPv6     = $dns6
            SentBytes          = if ($stats) { [long]$stats.SentBytes } else { 0 }
            ReceivedBytes      = if ($stats) { [long]$stats.ReceivedBytes } else { 0 }
            DefaultRouteMetric = if ($route4 -and $null -ne $route4.RouteMetric) { [int]$route4.RouteMetric } else { 0 }
            DefaultRouteMetricIPv6 = if ($route6 -and $null -ne $route6.RouteMetric) { [int]$route6.RouteMetric } else { 0 }
            Timestamp          = (Get-Date).ToString('o')
        }
    }

    return @($results | Sort-Object -Property @{ Expression = 'CapabilityScore'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
}

function Update-NetworkState {
    try {
        $interfaces = Get-AllNetworkInterfaces
        $interfacesArray = @($interfaces)
        $data = @{
            timestamp = (Get-Date).ToString('o')
            version = '5.0'
            count = $interfacesArray.Count
            interfaces = $interfacesArray
        }
        Write-AtomicJson -Path $OutputFile -Data $data -Depth 6
        return $interfacesArray
    } catch {
        Write-Host "  [NetworkManager] Error: $_" -ForegroundColor Red
        return @()
    }
}
