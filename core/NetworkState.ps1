[CmdletBinding()]
param(
    [ValidateSet('Status', 'Save', 'Restore', 'RestoreIfDirty', 'EnsureRoutes', 'SetProxy', 'ClearProxy', 'TestInternet')]
    [string]$Action = 'Status',
    [int]$ProxyPort = 8080,
    [switch]$ThroughProxy,
    [switch]$Quiet
)

$script:NetworkStateDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:NetworkStateProjectDir = Split-Path $script:NetworkStateDir -Parent
$script:StateFile = Join-Path $script:NetworkStateProjectDir 'config\network-state.json'
$script:InternetSettingsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:IdmSettingsKey = 'HKCU:\Software\DownloadManager'
$script:DefaultProxyOverride = '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'

function Write-NetworkStateMessage {
    param(
        [string]$Message,
        [string]$Color = 'DarkGray'
    )

    if (-not $Quiet) {
        Write-Host "  [State] $Message" -ForegroundColor $Color
    }
}

function Write-NetworkStateJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 8
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

function Read-NetworkState {
    if (-not (Test-Path $script:StateFile)) {
        return $null
    }

    try {
        return (Get-Content $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Save-NetworkState {
    param([object]$State)
    Write-NetworkStateJson -Path $script:StateFile -Data $State -Depth 8
}

function Get-RegistryValueOrNull {
    param(
        [string]$Path,
        [string]$Name
    )

    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch {
        return $null
    }
}

function Get-OriginalProxySettings {
    return @{
        ProxyEnable = Get-RegistryValueOrNull -Path $script:InternetSettingsKey -Name 'ProxyEnable'
        ProxyServer = Get-RegistryValueOrNull -Path $script:InternetSettingsKey -Name 'ProxyServer'
        ProxyOverride = Get-RegistryValueOrNull -Path $script:InternetSettingsKey -Name 'ProxyOverride'
    }
}

function Get-OriginalIdmSettings {
    if (-not (Test-Path $script:IdmSettingsKey)) {
        return @{ Exists = $false }
    }

    return @{
        Exists = $true
        nProxyMode = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'nProxyMode'
        UseHttpProxy = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'UseHttpProxy'
        HttpProxyAddr = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'HttpProxyAddr'
        HttpProxyPort = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'HttpProxyPort'
        nHttpPrChbSt = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'nHttpPrChbSt'
        UseHttpsProxy = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'UseHttpsProxy'
        HttpsProxyAddr = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'HttpsProxyAddr'
        HttpsProxyPort = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'HttpsProxyPort'
        nHttpsPrChbSt = Get-RegistryValueOrNull -Path $script:IdmSettingsKey -Name 'nHttpsPrChbSt'
    }
}

function Get-OriginalMetrics {
    return @(
        Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object InterfaceIndex, InterfaceAlias, InterfaceMetric, AutomaticMetric
    )
}

function Get-OriginalRoutes {
    return @(
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object InterfaceIndex, InterfaceAlias, DestinationPrefix, NextHop, RouteMetric, PolicyStore
    )
}

function Get-MetricLookup {
    param([object]$Metrics)

    $lookup = @{}
    foreach ($metric in @($Metrics)) {
        $lookup[[string]$metric.InterfaceIndex] = [int]$metric.InterfaceMetric
    }
    return $lookup
}

function Resolve-PrimaryInterfaceIndex {
    param(
        [object]$State,
        [object[]]$Interfaces = @()
    )

    if ($State -and $State.primaryInterfaceIndex) {
        if ($Interfaces.Count -eq 0 -or ($Interfaces | Where-Object { $_.InterfaceIndex -eq [int]$State.primaryInterfaceIndex })) {
            return [int]$State.primaryInterfaceIndex
        }
    }

    $metricCandidates = @()
    foreach ($metric in @($State.originalMetrics)) {
        $metricCandidates += [pscustomobject]@{
            InterfaceIndex = [int]$metric.InterfaceIndex
            InterfaceMetric = [int]$metric.InterfaceMetric
        }
    }

    if ($Interfaces.Count -gt 0) {
        $liveIndexes = @($Interfaces | ForEach-Object { [int]$_.InterfaceIndex })
        $metricCandidates = @($metricCandidates | Where-Object { $_.InterfaceIndex -in $liveIndexes })
    }

    $primaryByMetric = $metricCandidates | Sort-Object InterfaceMetric, InterfaceIndex | Select-Object -First 1
    if ($primaryByMetric) {
        return [int]$primaryByMetric.InterfaceIndex
    }

    $metricLookup = Get-MetricLookup -Metrics $State.originalMetrics
    $candidates = @()
    foreach ($route in @($State.originalRoutes)) {
        $ifMetric = if ($metricLookup.ContainsKey([string]$route.InterfaceIndex)) { [int]$metricLookup[[string]$route.InterfaceIndex] } else { 9999 }
        $effectiveMetric = [int]$route.RouteMetric + $ifMetric
        $candidates += [pscustomobject]@{
            InterfaceIndex = [int]$route.InterfaceIndex
            EffectiveMetric = $effectiveMetric
        }
    }

    if ($Interfaces.Count -gt 0) {
        $liveIndexes = @($Interfaces | ForEach-Object { [int]$_.InterfaceIndex })
        $candidates = @($candidates | Where-Object { $_.InterfaceIndex -in $liveIndexes })
    }

    $primary = $candidates | Sort-Object EffectiveMetric, InterfaceIndex | Select-Object -First 1
    if ($primary) {
        return [int]$primary.InterfaceIndex
    }

    if ($Interfaces.Count -gt 0) {
        return [int]($Interfaces | Sort-Object InterfaceMetric, InterfaceIndex | Select-Object -First 1).InterfaceIndex
    }

    return $null
}

function Get-OriginalMetricValue {
    param(
        [object]$State,
        [int]$InterfaceIndex,
        [int]$FallbackMetric = 25
    )

    $metric = @($State.originalMetrics | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex } | Select-Object -First 1)
    if ($metric) {
        return [int]$metric[0].InterfaceMetric
    }
    return $FallbackMetric
}

function Resolve-NextHopString {
    param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$NextHop
    )

    if ($null -eq $NextHop) {
        return $null
    }

    if ($NextHop -is [string]) {
        $candidate = $NextHop.Trim()
        if ($candidate -ne '') {
            return $candidate
        }
        return $null
    }

    if ($NextHop -is [System.Array] -or $NextHop -is [System.Collections.IEnumerable]) {
        foreach ($item in $NextHop) {
            $resolved = Resolve-NextHopString -NextHop $item
            if ($resolved) {
                return $resolved
            }
        }
        return $null
    }

    foreach ($propertyName in @('NextHop', 'IPAddress', 'Address')) {
        if ($NextHop.PSObject -and $NextHop.PSObject.Properties[$propertyName]) {
            $resolved = Resolve-NextHopString -NextHop $NextHop.$propertyName
            if ($resolved) {
                return $resolved
            }
        }
    }

    $text = [string]$NextHop
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text.Trim()
}

function Get-LiveInterfaces {
    $interfaces = @()
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|OpenVPN|WireGuard|TAP-Windows|Cisco AnyConnect|Tailscale|ZeroTier'
    }

    foreach ($adapter in $adapters) {
        $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
            Select-Object -First 1

        if (-not $ip) {
            continue
        }

        $metricInfo = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
        $gateway = $null
        if ($ipConfig -and $ipConfig.IPv4DefaultGateway -and $ipConfig.IPv4DefaultGateway.NextHop) {
            $gateway = Resolve-NextHopString -NextHop $ipConfig.IPv4DefaultGateway.NextHop
        }
        if (-not $gateway) {
            $route = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Sort-Object RouteMetric | Select-Object -First 1
            if ($route) {
                $gateway = Resolve-NextHopString -NextHop $route.NextHop
            }
        }

        $linkSpeedMbps = 0.0
        if ($adapter.LinkSpeed -match '([\d.]+)\s*(Gbps|Mbps|Kbps)') {
            $value = [double]$Matches[1]
            switch ($Matches[2]) {
                'Gbps' { $linkSpeedMbps = $value * 1000.0 }
                'Mbps' { $linkSpeedMbps = $value }
                'Kbps' { $linkSpeedMbps = $value / 1000.0 }
            }
        }

        $interfaces += [pscustomobject]@{
            Name = $adapter.Name
            InterfaceIndex = [int]$adapter.ifIndex
            InterfaceAlias = $adapter.Name
            IPAddress = $ip.IPAddress
            Gateway = $gateway
            InterfaceMetric = if ($metricInfo) { [int]$metricInfo.InterfaceMetric } else { 9999 }
            AutomaticMetric = if ($metricInfo) { [string]$metricInfo.AutomaticMetric } else { 'Unknown' }
            LinkSpeedMbps = $linkSpeedMbps
        }
    }

    return $interfaces
}

function Test-RouteExists {
    param(
        [string]$DestinationPrefix,
        [int]$InterfaceIndex,
        [string]$NextHop
    )

    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -eq $NextHop } |
        Select-Object -First 1
    return $null -ne $route
}

function Get-RouteRecords {
    param(
        [string]$DestinationPrefix,
        [int]$InterfaceIndex,
        [string]$NextHop
    )

    @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.NextHop -eq [string]$NextHop })
}

function Get-MinRouteMetric {
    param(
        [object[]]$Routes,
        [int]$InterfaceIndex,
        [int]$FallbackMetric = 15
    )

    $matches = @($Routes | Where-Object { [int]$_.InterfaceIndex -eq $InterfaceIndex })
    if ($matches.Count -gt 0) {
        return [int](($matches | Measure-Object -Property RouteMetric -Minimum).Minimum)
    }

    return $FallbackMetric
}

function Ensure-RouteMetric {
    param(
        [string]$DestinationPrefix,
        [int]$InterfaceIndex,
        [string]$NextHop,
        [int]$DesiredMetric
    )

    foreach ($route in @(Get-RouteRecords -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop)) {
        try {
            if ([int]$route.RouteMetric -ne [int]$DesiredMetric) {
                Set-NetRoute -AddressFamily IPv4 -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric $DesiredMetric -Confirm:$false -ErrorAction Stop | Out-Null
            }
        } catch {
            Write-NetworkStateMessage ("Failed to update route metric for interface {0} via {1}: {2}" -f $InterfaceIndex, $NextHop, $_.Exception.Message) 'Yellow'
        }
    }
}

function Normalize-RouteRecord {
    param([object]$Route)
    return @{
        InterfaceIndex = [int]$Route.InterfaceIndex
        InterfaceAlias = [string]$Route.InterfaceAlias
        DestinationPrefix = [string]$Route.DestinationPrefix
        NextHop = Resolve-NextHopString -NextHop $Route.NextHop
        RouteMetric = [int]$Route.RouteMetric
        PolicyStore = [string]$Route.PolicyStore
    }
}

function Ensure-NetFusionRoutes {
    $state = Read-NetworkState
    if (-not $state) {
        throw 'Original network state has not been saved yet.'
    }

    $interfaces = @(Get-LiveInterfaces | Where-Object { $_.Gateway })
    if ($interfaces.Count -lt 1) {
        throw 'No active interfaces with IPv4 gateways were found.'
    }

    $primaryInterfaceIndex = Resolve-PrimaryInterfaceIndex -State $state -Interfaces $interfaces
    if ($null -eq $primaryInterfaceIndex) {
        throw 'Unable to determine the primary interface.'
    }

    $state.primaryInterfaceIndex = [int]$primaryInterfaceIndex
    $primaryMetric = Get-OriginalMetricValue -State $state -InterfaceIndex $primaryInterfaceIndex -FallbackMetric (
        ($interfaces | Where-Object { $_.InterfaceIndex -eq $primaryInterfaceIndex } | Select-Object -First 1).InterfaceMetric
    )
    $primaryRouteMetric = Get-MinRouteMetric -Routes $state.originalRoutes -InterfaceIndex $primaryInterfaceIndex -FallbackMetric 15
    $secondaryRank = 0

    foreach ($iface in ($interfaces | Sort-Object @{ Expression = { if ($_.InterfaceIndex -eq $primaryInterfaceIndex) { 0 } else { 1 } } }, @{ Expression = { -1 * $_.LinkSpeedMbps } }, InterfaceIndex)) {
        if ($iface.InterfaceIndex -eq $primaryInterfaceIndex) {
            Write-NetworkStateMessage "Keeping primary adapter metric unchanged: $($iface.Name) -> $primaryMetric" 'Green'
            continue
        }

        $secondaryRank++
        $originalMetric = Get-OriginalMetricValue -State $state -InterfaceIndex $iface.InterfaceIndex -FallbackMetric $iface.InterfaceMetric
        # NetFusion-FIX: 9 - Keep secondary routes usable by avoiding pathological high metrics while preserving clean restore data.
        if ($originalMetric -ge 9000) {
            $originalMetric = $primaryMetric + ($secondaryRank * 5)
        }
        $desiredMetric = [Math]::Min(50, [Math]::Max($originalMetric, $primaryMetric + ($secondaryRank * 5)))
        $desiredRouteMetric = [Math]::Min(50, [Math]::Max(15, $primaryRouteMetric + ($secondaryRank * 5)))

        try {
            Set-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Disabled -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -InterfaceMetric $desiredMetric -ErrorAction SilentlyContinue
            Write-NetworkStateMessage "Set secondary adapter metric: $($iface.Name) -> $desiredMetric" 'Green'
        } catch {
            Write-NetworkStateMessage "Failed to set metric for $($iface.Name): $($_.Exception.Message)" 'Yellow'
        }

        foreach ($liveRoute in @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $iface.InterfaceIndex -ErrorAction SilentlyContinue)) {
            Ensure-RouteMetric -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $iface.InterfaceIndex -NextHop ([string]$liveRoute.NextHop) -DesiredMetric $desiredRouteMetric
        }

        if (-not (Test-RouteExists -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $iface.InterfaceIndex -NextHop $iface.Gateway)) {
            New-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $iface.InterfaceIndex -NextHop $iface.Gateway -RouteMetric $desiredRouteMetric -Confirm:$false -ErrorAction Stop | Out-Null
            if (-not (Test-RouteExists -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $iface.InterfaceIndex -NextHop $iface.Gateway)) {
                throw "Default route verification failed for $($iface.Name)"
            }

            $addedRoute = Normalize-RouteRecord -Route @{
                InterfaceIndex = $iface.InterfaceIndex
                InterfaceAlias = $iface.Name
                DestinationPrefix = '0.0.0.0/0'
                NextHop = $iface.Gateway
                RouteMetric = $desiredRouteMetric
                PolicyStore = 'ActiveStore'
            }

            $state.addedRoutes = @($state.addedRoutes | Where-Object {
                -not (
                    [int]$_.InterfaceIndex -eq [int]$addedRoute.InterfaceIndex -and
                    [string]$_.DestinationPrefix -eq [string]$addedRoute.DestinationPrefix -and
                    [string]$_.NextHop -eq [string]$addedRoute.NextHop
                )
            }) + @($addedRoute)

            Write-NetworkStateMessage "Added secondary default route: $($iface.Name) via $($iface.Gateway)" 'Green'
        }
    }

    Save-NetworkState -State $state
    return $true
}

function Set-SystemProxyState {
    param(
        [switch]$Enabled,
        [int]$Port = 8080
    )

    if ($Enabled) {
        Set-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyEnable' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyServer' -Value ("127.0.0.1:{0}" -f $Port) -Type String -Force
        Set-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyOverride' -Value $script:DefaultProxyOverride -Type String -Force

        if (Test-Path $script:IdmSettingsKey) {
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nProxyMode' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'UseHttpProxy' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'HttpProxyAddr' -Value '127.0.0.1' -Type String -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'HttpProxyPort' -Value $Port -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nHttpPrChbSt' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'UseHttpsProxy' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'HttpsProxyAddr' -Value '127.0.0.1' -Type String -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'HttpsProxyPort' -Value $Port -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nHttpsPrChbSt' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    } else {
        Set-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyEnable' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyServer' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyOverride' -Force -ErrorAction SilentlyContinue

        if (Test-Path $script:IdmSettingsKey) {
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nProxyMode' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'UseHttpProxy' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'UseHttpsProxy' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nHttpPrChbSt' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nHttpsPrChbSt' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-ProxySettings {
    param([object]$State)

    if (-not $State) {
        Set-SystemProxyState -Enabled:$false
        return
    }

    $proxy = $State.originalProxySettings
    if ($null -ne $proxy.ProxyEnable) {
        Set-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyEnable' -Value ([int]$proxy.ProxyEnable) -Type DWord -Force -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyEnable' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $proxy.ProxyServer -and [string]$proxy.ProxyServer -ne '') {
        Set-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyServer' -Value ([string]$proxy.ProxyServer) -Type String -Force -ErrorAction SilentlyContinue
    } else {
        Remove-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyServer' -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $proxy.ProxyOverride -and [string]$proxy.ProxyOverride -ne '') {
        Set-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyOverride' -Value ([string]$proxy.ProxyOverride) -Type String -Force -ErrorAction SilentlyContinue
    } else {
        Remove-ItemProperty -Path $script:InternetSettingsKey -Name 'ProxyOverride' -Force -ErrorAction SilentlyContinue
    }
}

function Restore-IdmSettings {
    param([object]$State)

    if (-not $State -or -not $State.originalIdmSettings -or -not $State.originalIdmSettings.Exists) {
        if (Test-Path $script:IdmSettingsKey) {
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nProxyMode' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'UseHttpProxy' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'UseHttpsProxy' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nHttpPrChbSt' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $script:IdmSettingsKey -Name 'nHttpsPrChbSt' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        return
    }

    $idm = $State.originalIdmSettings
    foreach ($name in @('nProxyMode', 'UseHttpProxy', 'HttpProxyAddr', 'HttpProxyPort', 'nHttpPrChbSt', 'UseHttpsProxy', 'HttpsProxyAddr', 'HttpsProxyPort', 'nHttpsPrChbSt')) {
        if ($null -ne $idm.$name -and [string]$idm.$name -ne '') {
            $type = if ($name -match 'Port|Mode|Use|ChbSt') { 'DWord' } else { 'String' }
            Set-ItemProperty -Path $script:IdmSettingsKey -Name $name -Value $idm.$name -Type $type -Force -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $script:IdmSettingsKey -Name $name -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-OriginalMetrics {
    param([object]$State)

    foreach ($metric in @($State.originalMetrics)) {
        try {
            $autoMetric = [string]$metric.AutomaticMetric
            if ($autoMetric -match 'Enabled|True') {
                Set-NetIPInterface -InterfaceIndex $metric.InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue
            } else {
                Set-NetIPInterface -InterfaceIndex $metric.InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Disabled -ErrorAction SilentlyContinue
                Set-NetIPInterface -InterfaceIndex $metric.InterfaceIndex -AddressFamily IPv4 -InterfaceMetric ([int]$metric.InterfaceMetric) -ErrorAction SilentlyContinue
            }
        } catch {
            Write-NetworkStateMessage ("Failed to restore interface metric for index {0}: {1}" -f $metric.InterfaceIndex, $_.Exception.Message) 'Yellow'
        }
    }
}

function Restore-OriginalRoutes {
    param([object]$State)

    foreach ($route in @($State.originalRoutes)) {
        try {
            if (-not (Test-RouteExists -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop ([string]$route.NextHop))) {
                New-NetRoute -AddressFamily IPv4 -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop ([string]$route.NextHop) -RouteMetric ([int]$route.RouteMetric) -PolicyStore ([string]$route.PolicyStore) -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            } else {
                Ensure-RouteMetric -DestinationPrefix ([string]$route.DestinationPrefix) -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop ([string]$route.NextHop) -DesiredMetric ([int]$route.RouteMetric)
            }
        } catch {
            Write-NetworkStateMessage ("Failed to restore route {0} via {1} on interface {2}: {3}" -f $route.DestinationPrefix, $route.NextHop, $route.InterfaceIndex, $_.Exception.Message) 'Yellow'
        }
    }
}

function Remove-AddedRoutes {
    param([object]$State)

    foreach ($route in @($State.addedRoutes)) {
        try {
            $matchesOriginal = @($State.originalRoutes | Where-Object {
                [int]$_.InterfaceIndex -eq [int]$route.InterfaceIndex -and
                [string]$_.DestinationPrefix -eq [string]$route.DestinationPrefix -and
                [string]$_.NextHop -eq [string]$route.NextHop
            }).Count -gt 0

            if (-not $matchesOriginal -and (Test-RouteExists -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop ([string]$route.NextHop))) {
                Remove-NetRoute -AddressFamily IPv4 -DestinationPrefix $route.DestinationPrefix -InterfaceIndex ([int]$route.InterfaceIndex) -NextHop ([string]$route.NextHop) -Confirm:$false -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Test-DirectInternet {
    try {
        if (Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return $true
        }
    } catch {}

    try {
        if (Test-Connection -ComputerName '1.1.1.1' -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return $true
        }
    } catch {}

    return $false
}

function Test-ProxyInternet {
    param([int]$Port = 8080)

    foreach ($uri in @('https://example.com/', 'http://example.com/')) {
        try {
            $response = Invoke-WebRequest -Uri $uri -Proxy ("http://127.0.0.1:{0}" -f $Port) -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                return $true
            }
        } catch {}
    }

    return $false
}

function Invoke-NetworkRestore {
    $state = Read-NetworkState

    try { Restore-ProxySettings -State $state } catch {}
    try { Restore-IdmSettings -State $state } catch {}
    try { if ($state) { Restore-OriginalRoutes -State $state } } catch {}
    try { if ($state) { Remove-AddedRoutes -State $state } } catch {}
    try { if ($state) { Restore-OriginalMetrics -State $state } } catch {}
    try { ipconfig /flushdns | Out-Null } catch {}

    if (Test-Path $script:StateFile) {
        Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
    }

    $internetWorks = Test-DirectInternet
    if ($internetWorks) {
        Write-NetworkStateMessage 'Direct internet connectivity verified after restore.' 'Green'
    } else {
        Write-NetworkStateMessage 'Direct internet connectivity could not be verified after restore.' 'Yellow'
    }

    return $internetWorks
}

function Save-OriginalNetworkState {
    $state = @{
        version = '6.2'
        savedAt = [System.DateTimeOffset]::UtcNow.ToString('o')
        activeSession = $true
        originalRoutes = @(Get-OriginalRoutes)
        originalMetrics = @(Get-OriginalMetrics)
        originalProxySettings = Get-OriginalProxySettings
        originalIdmSettings = Get-OriginalIdmSettings
        addedRoutes = @()
        primaryInterfaceIndex = $null
    }

    $state.primaryInterfaceIndex = Resolve-PrimaryInterfaceIndex -State $state
    Save-NetworkState -State $state
    Write-NetworkStateMessage 'Saved original routes, metrics, proxy, and IDM state.' 'Green'
    return $true
}

$script:IsDotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $script:IsDotSourced) {
    $result = $true

    try {
        switch ($Action) {
            'Save' {
                $result = Save-OriginalNetworkState
            }
            'Restore' {
                $result = Invoke-NetworkRestore
            }
            'RestoreIfDirty' {
                $state = Read-NetworkState
                if ($state -and $state.activeSession) {
                    Write-NetworkStateMessage 'Detected previous unclean NetFusion state. Restoring saved network state first.' 'Yellow'
                    $result = Invoke-NetworkRestore
                }
            }
            'EnsureRoutes' {
                $result = Ensure-NetFusionRoutes
            }
            'SetProxy' {
                Set-SystemProxyState -Enabled -Port $ProxyPort
                Write-NetworkStateMessage ("System proxy set to 127.0.0.1:{0}" -f $ProxyPort) 'Green'
            }
            'ClearProxy' {
                Set-SystemProxyState -Enabled:$false -Port $ProxyPort
                Write-NetworkStateMessage 'System proxy cleared.' 'Green'
            }
            'TestInternet' {
                if ($ThroughProxy) {
                    $result = Test-ProxyInternet -Port $ProxyPort
                } else {
                    $result = Test-DirectInternet
                }
            }
            'Status' {
                $state = Read-NetworkState
                if ($state) {
                    $state | ConvertTo-Json -Depth 8
                } else {
                    Write-Output '{}'
                }
            }
        }
    } catch {
        Write-Error $_
        $result = $false
    }

    if ($result -is [bool] -and -not $result) {
        exit 1
    }
}
