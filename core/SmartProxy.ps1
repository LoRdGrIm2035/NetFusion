<#
.SYNOPSIS
    SmartProxy v6.2 -- Production-grade intelligent connection orchestration engine.
.DESCRIPTION
    Local HTTP/HTTPS proxy with safety-first design:
      - Session affinity: same host maps to same adapter within TTL window
      - Adaptive thread pool: scales aggressively for burst traffic
      - Connection-type detection (bulk/interactive/streaming/gaming)
      - Per-connection adaptive scheduling with health-aware weights
      - Degradation-aware routing with predictive warnings
      - Decision logging for UI observability
      - Configurable buffer sizes per traffic type
      - Health endpoint for SafetyController watchdog
      - Self-monitoring (CPU/memory reporting)
      - Graceful failover with adapter exclusion
      - Safe mode awareness (stops routing when safe mode active)
#>

[CmdletBinding()]
param(
    [int]$Port = 8080
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$configFile = Join-Path $projectDir "config\config.json"
$healthFile = Join-Path $projectDir "config\health.json"
$interfacesFile = Join-Path $projectDir "config\interfaces.json"
$statsFile = Join-Path $projectDir "config\proxy-stats.json"
$eventsFile = Join-Path $projectDir "logs\events.json"
$decisionsFile = Join-Path $projectDir "config\decisions.json"
$safetyFile = Join-Path $projectDir "config\safety-state.json"

$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

$global:ActiveCounterLock = [object]::new()
$global:HostCounterLock = [object]::new()
$global:ConnectIpv6TargetRegex = [System.Text.RegularExpressions.Regex]::new(
    '^\[(?<host>.*)\]:(?<port>\d+)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)
$global:ConnectHostPortRegex = [System.Text.RegularExpressions.Regex]::new(
    '^(?<host>.+):(?<port>\d+)$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# ===== Thread-safe state =====
$global:ProxyState = [hashtable]::Synchronized(@{
    adapters         = @()
    weights          = @()
    connectionCounts = [hashtable]::Synchronized(@{})
    successCounts    = [hashtable]::Synchronized(@{})
    failCounts       = [hashtable]::Synchronized(@{})
    totalConnections = 0
    totalFails       = 0
    activeConnections = 0        # v5.1: live active connection count
    activeCounterLock = $global:ActiveCounterLock
    hostCounterLock   = $global:HostCounterLock
    activePerAdapter  = [hashtable]::Synchronized(@{})      # v5.1: per-adapter active counts
    activePerHost     = [hashtable]::Synchronized(@{})      # v5.1: per-host active counts for dynamic bulk detection
    flowStats         = [hashtable]::Synchronized(@{})      # per-adapter flow/capacity snapshot
    throughputHistory = [hashtable]::Synchronized(@{})      # per-adapter rolling throughput snapshots
    rebalanceState    = [hashtable]::Synchronized(@{})      # congestion/rebalance memory
    forcedDrainAdapters = [hashtable]::Synchronized(@{})    # adapters that should stop receiving flows
    dnsCache          = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    connectionRegistry = [hashtable]::Synchronized(@{})     # connectionId -> adapter/socket refs
    nextConnectionId  = 0
    currentMode      = 'maxspeed'
    rrIndex          = 0
    connectTimeout   = 7000
    socketIoTimeout  = 45000
    listenerBacklog  = 2048
    staleJobTimeoutSec = 0
    statsWriteIntervalSec = 2
    configFile       = $configFile
    healthFile       = $healthFile
    interfacesFile   = $interfacesFile
    statsFile        = $statsFile
    eventsFile       = $eventsFile
    decisionsFile    = $decisionsFile
    safetyFile       = $safetyFile
    port             = $Port
    # v5.0 Intelligence State
    adapterHealth    = @{}
    degradationFlags = @{}
    connectionTypes  = [hashtable]::Synchronized(@{})
    decisions        = @()
    maxDecisions     = 100
    bandwidthEstimates = @{}
    uploadBandwidthEstimates = @{}
    uploadHostHints  = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    uploadHintTTL    = 300
    activeConns      = @{}
    adapterIpCache   = @{}
    connectIpv6Regex = $global:ConnectIpv6TargetRegex
    connectHostPortRegex = $global:ConnectHostPortRegex
    weightRefreshInterval = 2.0
    httpsBulkPromotionHostThreshold = 2
    httpsBulkPromotionGlobalThreshold = 8
    retryPolicy = 'leastLoaded'
    retryWeightFloor = 0.25
    bulkHeadroomWeight = 0.35
    bulkPressureThreshold = 24
    maxConnectRetries = 3
    bufferSizes      = @{
        'bulk'        = 4194304  # 4MB for high-BDP bulk transfers
        'interactive' = 32768    # 32KB for browsing
        'streaming'   = 1048576  # 1MB for streaming stability
        'gaming'      = 8192     # 8KB for gaming (low latency)
        'voice'       = 32768
        'default'     = 524288   # 512KB default
    }
    # v5.0 Session Affinity
    sessionMap     = [hashtable]::Synchronized(@{})    # { "host:port" -> @{ adapter=Name; time=DateTime } }
    sessionTTL     = 120    # 2 minutes (reduced from 5min so degraded adapters re-evaluated faster)
    # v5.0 Safety
    safeMode       = $false
    portClasses    = @{
        gaming = @(3074, 3478, 3479, 3480, 3659, 25565, 27015, 27036, 19132)
        voice  = @(3478, 3479, 3480, 5004, 5005, 5060, 5061)
        bulk   = @(20, 21, 22, 8080, 8443, 9000, 9090)
    }
})
$script:ProxyLogMutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")
$script:lastDecisionHash = $null
$script:ProxyInstanceMutex = New-Object System.Threading.Mutex($false, "Global\NetFusion-SmartProxy")
$script:ProxyInstanceMutexHeld = $false

function Write-AtomicJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 3
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tmp = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    try {
        $Data | ConvertTo-Json -Depth $Depth -Compress | Set-Content $tmp -Force -Encoding UTF8 -ErrorAction Stop
        Move-Item $tmp $Path -Force -ErrorAction Stop
        try { Copy-Item $Path "$Path.bak" -Force -ErrorAction SilentlyContinue } catch {}
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Read-JsonFile {
    param(
        [string]$Path,
        [object]$DefaultValue = $null
    )

    if (-not (Test-Path $Path)) {
        return $DefaultValue
    }

    try {
        return (Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        $backupPath = "$Path.bak"
        if (Test-Path $backupPath) {
            try {
                $backup = Get-Content $backupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                Copy-Item $backupPath $Path -Force -ErrorAction SilentlyContinue
                return $backup
            } catch {}
        }

        return $DefaultValue
    }
}

function Repair-EventsFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-AtomicJson -Path $Path -Data @{ events = @() } -Depth 3
        return
    }

    $data = Read-JsonFile -Path $Path -DefaultValue $null
    if (-not $data -or -not $data.events) {
        Write-AtomicJson -Path $Path -Data @{ events = @() } -Depth 3
    }
}

function Get-SafeBufferSize {
    param(
        [int]$RequestedSize,
        [int]$MaxSize = 0
    )

    if ($MaxSize -le 0) {
        $MaxSize = if ([IntPtr]::Size -le 4) { 262144 } else { 8388608 }
    }
    # Keep relay buffers at 64KB+ to reduce syscall churn under high-throughput flows.
    $safe = [Math]::Max(65536, [Math]::Min($RequestedSize, $MaxSize))
    if ([IntPtr]::Size -le 4 -and $safe -gt 262144) {
        return 262144
    }
    return [int]$safe
}

foreach ($bufferKey in @($global:ProxyState.bufferSizes.Keys)) {
    $global:ProxyState.bufferSizes[$bufferKey] = Get-SafeBufferSize -RequestedSize ([int]$global:ProxyState.bufferSizes[$bufferKey])
}

function Write-ProxyEvent {
    param([string]$Message)
    $mutexTaken = $false
    try {
        try {
            $mutexTaken = $script:ProxyLogMutex.WaitOne(3000)
        } catch [System.Threading.AbandonedMutexException] {
            try { Repair-EventsFile -Path $global:ProxyState.eventsFile } catch {}
            $mutexTaken = $true
        }

        if (-not $mutexTaken) { return }

        try {
            $ef = $global:ProxyState.eventsFile
            $events = @()
            $data = Read-JsonFile -Path $ef -DefaultValue $null
            if ($data -and $data.events) { $events = @($data.events) }
            $evt = @{ timestamp = (Get-Date).ToString('o'); type = 'proxy'; adapter = ''; message = $Message }
            $events = @($evt) + $events
            if ($events.Count -gt 200) { $events = $events[0..199] }
            Write-AtomicJson -Path $ef -Data @{ events = $events } -Depth 3
        } finally {
            if ($mutexTaken) {
                try { $script:ProxyLogMutex.ReleaseMutex() } catch {}
            }
        }
    } catch {}
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

function Get-AdapterTypeFallback {
    param(
        [object]$Adapter,
        [object]$WmiAdapter,
        [object]$IpIf4,
        [object]$IpIf6
    )

    $ifType = 0
    if ($IpIf4 -and $null -ne $IpIf4.InterfaceType) {
        $ifType = [int]$IpIf4.InterfaceType
    } elseif ($IpIf6 -and $null -ne $IpIf6.InterfaceType) {
        $ifType = [int]$IpIf6.InterfaceType
    }

    $mediaType = if ($null -ne $Adapter.MediaType) { [string]$Adapter.MediaType } else { '' }
    $physicalMediaType = if ($null -ne $Adapter.PhysicalMediaType) { [string]$Adapter.PhysicalMediaType } else { '' }
    $desc = [string]$Adapter.InterfaceDescription
    $name = [string]$Adapter.Name
    $pnp = if ($WmiAdapter -and $WmiAdapter.PNPDeviceID) { [string]$WmiAdapter.PNPDeviceID } else { '' }
    $isUsb = $pnp -match '(?i)^USB' -or $desc -match '(?i)USB'

    $isWifi = $ifType -eq 71 -or $desc -match '(?i)Wi-Fi|Wireless|802\.11|WLAN' -or $mediaType -match '(?i)Native802_11|Wireless' -or $physicalMediaType -match '(?i)Native802_11|Wireless'
    $isEthernet = $ifType -eq 6 -or $desc -match '(?i)Ethernet|GbE|RJ45' -or $mediaType -match '(?i)802\.3|Ethernet'
    $isWwan = $ifType -in @(243, 244) -or $desc -match '(?i)WWAN|Cellular|Mobile'

    if ($isWifi -and $isUsb) { return 'USB-WiFi' }
    if ($isWifi) { return 'WiFi' }
    if ($isEthernet -and $isUsb) { return 'USB-Ethernet' }
    if ($isEthernet) { return 'Ethernet' }
    if ($isWwan) { return 'Cellular' }
    return 'Unknown'
}

function Get-ProxyAdapters {
    $adapters = @()
    $ifFile = $global:ProxyState.interfacesFile
    $data = Read-JsonFile -Path $ifFile -DefaultValue $null
    if ($data -and $data.interfaces) {
        foreach ($iface in $data.interfaces) {
            $ip = $null
            if ($iface.PrimaryIPv4) {
                $ip = [string]$iface.PrimaryIPv4
            } elseif ($iface.IPAddress) {
                $ip = [string]$iface.IPAddress
            } elseif ($iface.IPAddresses -and @($iface.IPAddresses).Count -gt 0) {
                $ip = [string]@($iface.IPAddresses)[0]
            }

            if ($ip -and $iface.Status -eq 'Up') {
                $parsedIp = $null
                try { $parsedIp = [System.Net.IPAddress]::Parse([string]$ip) } catch {}
                $adapters += @{
                    Name = $iface.Name
                    IP = $ip
                    ParsedIP = $parsedIp
                    Type = if ($iface.Type) { [string]$iface.Type } else { 'Unknown' }
                    Speed = if ($iface.EstimatedCapacityMbps) { [double]$iface.EstimatedCapacityMbps } elseif ($iface.LinkSpeedMbps) { [double]$iface.LinkSpeedMbps } else { 0.0 }
                    InterfaceIndex = if ($iface.InterfaceIndex) { [int]$iface.InterfaceIndex } else { 0 }
                }
            }
        }
    }
    if ($adapters.Count -lt 1) {
        $wmiMap = @{}
        try {
            foreach ($wmi in @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue)) {
                if ($null -ne $wmi.InterfaceIndex) { $wmiMap[[int]$wmi.InterfaceIndex] = $wmi }
            }
        } catch {}

        Get-NetAdapter |
            Where-Object {
                $_.Status -eq 'Up' -and
                $_.InterfaceDescription -notmatch '(?i)Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN|OpenVPN|WireGuard|Tailscale|ZeroTier|Npcap|vEthernet|VMware|VirtualBox'
            } |
            ForEach-Object {
            $ipv4 = @(
                Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
                    Sort-Object SkipAsSource, PrefixOrigin |
                    Select-Object -ExpandProperty IPAddress
            )
            $ip = if ($ipv4.Count -gt 0) { [string]$ipv4[0] } else { '' }
            if ($ip) {
                $ipIf4 = Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                $ipIf6 = Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
                $wmi = if ($wmiMap.ContainsKey([int]$_.ifIndex)) { $wmiMap[[int]$_.ifIndex] } else { $null }
                $type = Get-AdapterTypeFallback -Adapter $_ -WmiAdapter $wmi -IpIf4 $ipIf4 -IpIf6 $ipIf6
                $parsedIp = $null
                try { $parsedIp = [System.Net.IPAddress]::Parse([string]$ip) } catch {}
                $speed = Convert-LinkSpeedToMbps -LinkSpeed $_.LinkSpeed
                $adapters += @{
                    Name = $_.Name
                    IP = $ip
                    ParsedIP = $parsedIp
                    Type = $type
                    Speed = if ($speed -gt 0) { [double]$speed } else { 100.0 }
                    InterfaceIndex = [int]$_.ifIndex
                }
            }
        }
    }
    return $adapters
}

function Update-AdaptersAndWeights {
    $s = $global:ProxyState
    $s.adapters = @(Get-ProxyAdapters)
    $s.adapterIpCache = @{}
    foreach ($adapter in $s.adapters) {
        if ($adapter.Name -and $adapter.ParsedIP) {
            $s.adapterIpCache[$adapter.Name] = $adapter.ParsedIP
        }
    }

    # v5.0: Check safe mode
    if (Test-Path $s.safetyFile) {
        $safety = Read-JsonFile -Path $s.safetyFile -DefaultValue $null
        if ($safety -and $safety.safeMode -eq $true) {
            $s.safeMode = $true
        } else {
            $s.safeMode = $false
        }
    }

    # Read health data from InterfaceMonitor
    $health = @{}
    if (Test-Path $s.healthFile) {
        try {
            $hData = Read-JsonFile -Path $s.healthFile -DefaultValue $null
            if (-not $hData) { throw "Health data unavailable." }
            $hData.adapters | ForEach-Object {
                $currentDown = if ($_.DownloadMbps) { [double]$_.DownloadMbps } else { 0.0 }
                $currentUp = if ($_.UploadMbps) { [double]$_.UploadMbps } else { 0.0 }
                $prevEstimate = if ($s.bandwidthEstimates.ContainsKey($_.Name)) { [double]$s.bandwidthEstimates[$_.Name] } else { 0.0 }
                $prevUpEstimate = if ($s.uploadBandwidthEstimates.ContainsKey($_.Name)) { [double]$s.uploadBandwidthEstimates[$_.Name] } else { 0.0 }
                if ($currentDown -gt 1.0) {
                    $estimate = if ($prevEstimate -gt 0) {
                        [math]::Round(($prevEstimate * 0.65) + ($currentDown * 0.35), 2)
                    } else {
                        [math]::Round($currentDown, 2)
                    }
                } elseif ($prevEstimate -gt 0) {
                    $estimate = [math]::Round($prevEstimate * 0.9, 2)
                } else {
                    $estimate = 0.0
                }
                if ($currentUp -gt 1.0) {
                    $upEstimate = if ($prevUpEstimate -gt 0) {
                        [math]::Round(($prevUpEstimate * 0.65) + ($currentUp * 0.35), 2)
                    } else {
                        [math]::Round($currentUp, 2)
                    }
                } elseif ($prevUpEstimate -gt 0) {
                    $upEstimate = [math]::Round($prevUpEstimate * 0.9, 2)
                } else {
                    $upEstimate = 0.0
                }
                $s.bandwidthEstimates[$_.Name] = $estimate
                $s.uploadBandwidthEstimates[$_.Name] = $upEstimate

                $health[$_.Name] = @{
                    Score       = $_.HealthScore
                    Score01     = if ($_.HealthScore01) { $_.HealthScore01 } else { [math]::Min(1.0, [math]::Max(0.0, ([double]$_.HealthScore / 100.0))) }
                    Latency     = $_.InternetLatency
                    LatencyEWMA = if ($_.InternetLatencyEWMA) { $_.InternetLatencyEWMA } else { $_.InternetLatency }
                    Jitter      = if ($_.Jitter) { $_.Jitter } else { 0 }
                    SuccessRate = if ($_.SuccessRate) { $_.SuccessRate } else { 100 }
                    Stability   = if ($_.StabilityScore) { $_.StabilityScore } else { 80 }
                    Trend       = if ($_.HealthTrend) { $_.HealthTrend } else { 0 }
                    IsDegrading = if ($_.IsDegrading) { $_.IsDegrading } else { $false }
                    DownloadMbps = if ($_.DownloadMbps) { $_.DownloadMbps } else { 0 }
                    UploadMbps = if ($_.UploadMbps) { $_.UploadMbps } else { 0 }
                    ThroughputMbps = if ($_.ThroughputMbps) { $_.ThroughputMbps } else { 0 }
                    ThroughputAvg5 = if ($_.ThroughputAvg5) { $_.ThroughputAvg5 } else { 0 }
                    ThroughputAvg30 = if ($_.ThroughputAvg30) { $_.ThroughputAvg30 } else { 0 }
                    ThroughputAvg60 = if ($_.ThroughputAvg60) { $_.ThroughputAvg60 } else { 0 }
                    ThroughputHistory = if ($_.ThroughputHistory) { @($_.ThroughputHistory) } else { @() }
                    UtilizationPct = if ($_.UtilizationPct) { $_.UtilizationPct } else { 0 }
                    EstimatedDownMbps = $estimate
                    EstimatedUpMbps = $upEstimate
                    EstimatedCapacityMbps = if ($_.EstimatedCapacityMbps) { $_.EstimatedCapacityMbps } else { 0 }
                    ErrorRate = if ($_.ErrorRate) { $_.ErrorRate } else { 0 }
                    IsQuarantined = if ($_.IsQuarantined) { $true } else { $false }
                    IsDisabled = if ($_.IsDisabled) { $true } else { $false }
                    ReintroLimitFlows = if ($_.ReintroLimitFlows) { [int]$_.ReintroLimitFlows } else { 0 }
                    ShouldAvoidNewFlows = if ($_.ShouldAvoidNewFlows) { $true } else { $false }
                    ForceDrain = if ($_.ForceDrain) { $true } else { $false }
                    LinkSpeedMbps = if ($_.LinkSpeedMbps) { $_.LinkSpeedMbps } else { 0 }
                }
            }
            $s.adapterHealth = $health
            if ($hData.degradation) {
                $degradeHash = @{}
                $hData.degradation.PSObject.Properties | ForEach-Object { $degradeHash[$_.Name] = $_.Value }
                $s.degradationFlags = $degradeHash
            }
            if ($hData.rebalance) {
                $rebalance = @{
                    trigger = if ($hData.rebalance.trigger) { $true } else { $false }
                    overUtilized = if ($hData.rebalance.overUtilized) { @($hData.rebalance.overUtilized) } else { @() }
                    underUtilized = if ($hData.rebalance.underUtilized) { @($hData.rebalance.underUtilized) } else { @() }
                    reason = if ($hData.rebalance.reason) { [string]$hData.rebalance.reason } else { '' }
                }
                $s.rebalanceState['hint'] = $rebalance
            }
            if ($hData.upstreamBottleneck) {
                $s.rebalanceState['upstreamBottleneck'] = @{
                    detected = if ($hData.upstreamBottleneck.detected) { $true } else { $false }
                    reason = if ($hData.upstreamBottleneck.reason) { [string]$hData.upstreamBottleneck.reason } else { '' }
                    sameGateway = if ($hData.upstreamBottleneck.sameGateway) { $true } else { $false }
                    samePublicIp = if ($hData.upstreamBottleneck.samePublicIp) { $true } else { $false }
                }
            }
        } catch {}
    }
    if (Test-Path $s.configFile) {
        try {
            $cfg = Read-JsonFile -Path $s.configFile -DefaultValue $null
            if (-not $cfg) { throw "Config data unavailable." }
            if ($cfg.mode) { $s.currentMode = $cfg.mode }
            $refresh = $cfg.intelligence.weightRefreshInterval
            if ($null -ne $refresh -and [double]$refresh -gt 0) {
                $s.weightRefreshInterval = [double]$refresh
            }
            if ($cfg.proxy) {
                $p = $cfg.proxy

                if ($null -ne $p.sessionAffinityTTL -and [int]$p.sessionAffinityTTL -gt 0) {
                    $s.sessionTTL = [int]$p.sessionAffinityTTL
                }
                if ($null -ne $p.maxRetries -and [int]$p.maxRetries -gt 0) {
                    $s.maxConnectRetries = [int]$p.maxRetries
                }
                if ($null -ne $p.connectTimeout -and [int]$p.connectTimeout -ge 1000) {
                    $s.connectTimeout = [int]$p.connectTimeout
                }
                if ($null -ne $p.socketIoTimeout -and [int]$p.socketIoTimeout -ge 5000) {
                    $s.socketIoTimeout = [int]$p.socketIoTimeout
                }
                if ($null -ne $p.listenerBacklog -and [int]$p.listenerBacklog -ge 128) {
                    $s.listenerBacklog = [int]$p.listenerBacklog
                }
                if ($null -ne $p.staleJobTimeoutSec -and [int]$p.staleJobTimeoutSec -ge 0) {
                    $s.staleJobTimeoutSec = [int]$p.staleJobTimeoutSec
                }

                if ($null -ne $p.httpsBulkPromotionHostThreshold -and [int]$p.httpsBulkPromotionHostThreshold -ge 1) {
                    $s.httpsBulkPromotionHostThreshold = [int]$p.httpsBulkPromotionHostThreshold
                }
                if ($null -ne $p.httpsBulkPromotionGlobalThreshold -and [int]$p.httpsBulkPromotionGlobalThreshold -ge 1) {
                    $s.httpsBulkPromotionGlobalThreshold = [int]$p.httpsBulkPromotionGlobalThreshold
                }

                if ($p.retryPolicy) {
                    $candidateRetryPolicy = ([string]$p.retryPolicy).Trim().ToLowerInvariant()
                    if ($candidateRetryPolicy -in @('leastloaded', 'weightedrandom')) {
                        $s.retryPolicy = $candidateRetryPolicy
                    }
                }
                if ($null -ne $p.retryWeightFloor -and [double]$p.retryWeightFloor -gt 0) {
                    $s.retryWeightFloor = [math]::Max(0.1, [math]::Min(3.0, [double]$p.retryWeightFloor))
                }

                if ($null -ne $p.bulkHeadroomWeight) {
                    $headroomWeight = [double]$p.bulkHeadroomWeight
                    $s.bulkHeadroomWeight = [math]::Max(0.0, [math]::Min(1.0, $headroomWeight))
                }
                if ($null -ne $p.bulkPressureThreshold -and [int]$p.bulkPressureThreshold -ge 1) {
                    $s.bulkPressureThreshold = [int]$p.bulkPressureThreshold
                }
            }
            if ($cfg.telemetry -and $null -ne $cfg.telemetry.statsWriteIntervalSec -and [int]$cfg.telemetry.statsWriteIntervalSec -ge 1) {
                $s.statsWriteIntervalSec = [int]$cfg.telemetry.statsWriteIntervalSec
            }
        } catch {}
    }

    $throughputMode = $s.currentMode -in @('maxspeed', 'download')
    if ($throughputMode) {
        # Throughput-first guardrails: prevent sticky behavior and late balancing
        # from reducing aggregate utilization in multi-adapter workloads.
        if ($s.sessionTTL -gt 120) { $s.sessionTTL = 120 }
        if ($s.httpsBulkPromotionHostThreshold -gt 1) { $s.httpsBulkPromotionHostThreshold = 1 }
        if ($s.httpsBulkPromotionGlobalThreshold -gt 4) { $s.httpsBulkPromotionGlobalThreshold = 4 }
        if ($s.bulkPressureThreshold -gt 10) { $s.bulkPressureThreshold = 10 }
        if ($s.retryPolicy -ne 'leastloaded') { $s.retryPolicy = 'leastloaded' }
    }

    $weights = @()
    foreach ($a in $s.adapters) {
        $h = $health[$a.Name]
        $w = 1.0
        $score01 = 0.55
        $measuredLoad = 0.0
        $estimatedCapacity = 0.0
        $effectiveCapacity = 0.0
        $availableCapacity = 0.0
        $utilizationPct = 0.0
        $errorRate = 0.0
        $isQuarantined = $false
        $isDisabled = $false
        $shouldAvoidNew = $false
        $forceDrain = $false
        $reintroLimit = 0

        if ($h) {
            $sc = if ($h.Score -gt 0) { $h.Score } else { 40 }
            $score01 = if ($h.Score01 -gt 0) { [double]$h.Score01 } else { [math]::Min(1.0, [math]::Max(0.0, [double]$sc / 100.0)) }
            $isDegrading = $h.IsDegrading -eq $true
            $isQuarantined = $h.IsQuarantined -eq $true
            $isDisabled = $h.IsDisabled -eq $true
            $shouldAvoidNew = $h.ShouldAvoidNewFlows -eq $true
            $forceDrain = $h.ForceDrain -eq $true
            $reintroLimit = if ($null -ne $h.ReintroLimitFlows) { [int]$h.ReintroLimitFlows } else { 0 }

            switch ($s.currentMode) {
                'maxspeed' {
                    $capacityFactor = if ($h.EstimatedCapacityMbps -gt 0) { [math]::Max(0.4, [math]::Min(2.5, [double]$h.EstimatedCapacityMbps / 100.0)) } else { 1.0 }
                    $w = [math]::Max(0.8, ($score01 * 3.5) + $capacityFactor)
                }
                'download' {
                    $baseSpeed = if ($h.EstimatedCapacityMbps -gt 0) { [double]$h.EstimatedCapacityMbps } elseif ($a.Speed -gt 0) { [double]$a.Speed } else { 100.0 }
                    $w = [math]::Max(0.5, (($baseSpeed / 100.0) * [math]::Max(0.2, $score01)))
                }
                'streaming' {
                    $lat = if ($h.LatencyEWMA -lt 998) { $h.LatencyEWMA } else { 200 }
                    $w = [math]::Max(0.25, 100 / [math]::Max(1, $lat))
                }
                'gaming' {
                    $lat = if ($h.LatencyEWMA -lt 998) { $h.LatencyEWMA } else { 200 }
                    $w = if ($lat -lt 15) { 12 } elseif ($lat -lt 30) { 6 } elseif ($lat -lt 50) { 3 } else { 1 }
                }
                default {
                    $w = [math]::Max(0.5, $sc / 100)
                }
            }

            if ($isDegrading) { $w *= 0.55 }
            if ($h.Trend -lt -2) { $w *= 0.7 }
            elseif ($h.Trend -gt 1) { $w *= 1.15 }

            if ($h.ThroughputAvg5 -gt $measuredLoad) { $measuredLoad = [double]$h.ThroughputAvg5 }
            if ($h.ThroughputAvg30 -gt $measuredLoad) { $measuredLoad = [double]$h.ThroughputAvg30 }
            if ($h.ThroughputMbps -gt $measuredLoad) { $measuredLoad = [double]$h.ThroughputMbps }
            if ($h.DownloadMbps -gt $measuredLoad) { $measuredLoad = [double]$h.DownloadMbps }
            if ($h.UploadMbps -gt $measuredLoad) { $measuredLoad = [double]$h.UploadMbps }

            if ($h.EstimatedCapacityMbps -gt 0) {
                $estimatedCapacity = [double]$h.EstimatedCapacityMbps
            } elseif ($a.Speed -gt 0) {
                $estimatedCapacity = [double]$a.Speed * 0.65
            } else {
                $estimatedCapacity = 80.0
            }

            $errorRate = if ($null -ne $h.ErrorRate -and [double]$h.ErrorRate -gt 0) { [double]$h.ErrorRate } else { 0.0 }
            $effectiveCapacity = [math]::Max(1.0, $estimatedCapacity * [math]::Max(0.05, $score01) * [math]::Max(0.1, [double]$w))
            $availableCapacity = [math]::Max(0.0, $effectiveCapacity - $measuredLoad)
            $utilizationPct = if ($effectiveCapacity -gt 0) { [math]::Round([math]::Min(100.0, [math]::Max(0.0, ($measuredLoad / $effectiveCapacity) * 100.0)), 2) } else { 0.0 }
        }

        if ($isDisabled -or $forceDrain) {
            $w = 0.01
            $s.forcedDrainAdapters[$a.Name] = $true
        } else {
            $null = $s.forcedDrainAdapters.Remove($a.Name)
            if ($isQuarantined) { $w *= 0.05 }
            elseif ($shouldAvoidNew) { $w *= 0.2 }
        }

        $weights += [math]::Max(0.01, $w)

        if (-not $s.connectionCounts.ContainsKey($a.Name)) {
            $s.connectionCounts[$a.Name] = 0
            $s.successCounts[$a.Name] = 0
            $s.failCounts[$a.Name] = 0
        }
        if (-not $s.activePerAdapter.ContainsKey($a.Name)) {
            $s.activePerAdapter[$a.Name] = 0
        }

        $activeFlowCount = [int]$s.activePerAdapter[$a.Name]
        $rollingBytesWindow = 0.0
        if ($h -and $h.ThroughputHistory) {
            foreach ($point in @($h.ThroughputHistory)) {
                $mbpsPoint = 0.0
                if ($null -ne $point.total) { $mbpsPoint = [double]$point.total }
                elseif ($null -ne $point.ThroughputMbps) { $mbpsPoint = [double]$point.ThroughputMbps }
                elseif ($null -ne $point.downloadMbps -or $null -ne $point.uploadMbps) {
                    $mbpsPoint = [double]$point.downloadMbps + [double]$point.uploadMbps
                }
                if ($mbpsPoint -gt 0) {
                    $rollingBytesWindow += ($mbpsPoint * 1000000.0 / 8.0)
                }
            }
        }
        $avgFlowThroughput = if ($activeFlowCount -gt 0) { [double]$measuredLoad / [double]$activeFlowCount } else { [double]$measuredLoad }
        $s.flowStats[$a.Name] = @{
            activeFlowCount = $activeFlowCount
            totalBytesWindow = [math]::Round($rollingBytesWindow, 0)
            averageFlowThroughputMbps = [math]::Round($avgFlowThroughput, 3)
            measuredLoadMbps = [math]::Round($measuredLoad, 3)
            estimatedCapacityMbps = [math]::Round($estimatedCapacity, 3)
            effectiveCapacityMbps = [math]::Round($effectiveCapacity, 3)
            availableCapacityMbps = [math]::Round($availableCapacity, 3)
            utilizationPct = [math]::Round($utilizationPct, 2)
            errorRate = [math]::Round($errorRate, 4)
            health01 = [math]::Round($score01, 4)
            isQuarantined = $isQuarantined
            isDisabled = $isDisabled
            shouldAvoidNewFlows = $shouldAvoidNew
            forceDrain = $forceDrain
            reintroLimitFlows = $reintroLimit
            weight = [math]::Round([double]$w, 4)
        }
    }

    # Congestion-aware migration bias:
    # If adapter stays >90% utilization for 2 refreshes while another is <50%,
    # reduce new-flow pressure on the congested adapter.
    $allFlowStats = @($s.flowStats.GetEnumerator() | ForEach-Object { $_.Value })
    foreach ($a in $s.adapters) {
        $name = [string]$a.Name
        $fs = $s.flowStats[$name]
        if (-not $fs) { continue }

        if (-not $s.rebalanceState.ContainsKey($name) -or $s.rebalanceState[$name] -isnot [hashtable]) {
            $s.rebalanceState[$name] = @{ highUtilConsecutive = 0; migrationMode = $false; lastChange = (Get-Date).ToString('o') }
        }
        $rb = $s.rebalanceState[$name]

        if ([double]$fs.utilizationPct -ge 90.0) {
            $rb.highUtilConsecutive = [int]$rb.highUtilConsecutive + 1
        } else {
            $rb.highUtilConsecutive = 0
            $rb.migrationMode = $false
        }

        $underusedExists = $false
        foreach ($other in $allFlowStats) {
            if ($other -and $other -ne $fs -and [double]$other.utilizationPct -le 50.0 -and -not $other.forceDrain -and -not $other.isDisabled) {
                $underusedExists = $true
                break
            }
        }

        if ($rb.highUtilConsecutive -ge 2 -and $underusedExists) {
            if (-not $rb.migrationMode) {
                Write-ProxyEvent "Migration bias enabled for $name (utilization=$([math]::Round([double]$fs.utilizationPct,2))%)."
            }
            $rb.migrationMode = $true
            $rb.lastChange = (Get-Date).ToString('o')
        }

        if ($rb.migrationMode -and $s.flowStats.ContainsKey($name)) {
            $s.flowStats[$name].shouldAvoidNewFlows = $true
            $s.flowStats[$name].weight = [math]::Round([double]$s.flowStats[$name].weight * 0.35, 4)
        }
    }

    for ($wi = 0; $wi -lt $s.adapters.Count; $wi++) {
        $name = [string]$s.adapters[$wi].Name
        if ($s.flowStats.ContainsKey($name) -and $null -ne $s.flowStats[$name].weight) {
            $weights[$wi] = [math]::Max(0.01, [double]$s.flowStats[$name].weight)
        }
    }

    $s.weights = $weights
}

function Update-ProxyStats {
    param(
        [bool]$Running = $true,
        [switch]$ForceDecisionWrite
    )

    $s = $global:ProxyState
    $aStats = @()
    $totalMeasuredLoadMbps = 0.0
    $totalEstimatedCapacityMbps = 0.0
    foreach ($a in $s.adapters) {
        $h = $s.adapterHealth[$a.Name]
        $flow = $s.flowStats[$a.Name]
        $measuredLoad = if ($flow) { [double]$flow.measuredLoadMbps } elseif ($h) { [double]$h.ThroughputAvg5 } else { 0.0 }
        $estimatedCapacity = if ($flow) { [double]$flow.estimatedCapacityMbps } elseif ($h) { [double]$h.EstimatedCapacityMbps } else { 0.0 }
        $totalMeasuredLoadMbps += $measuredLoad
        $totalEstimatedCapacityMbps += $estimatedCapacity
        $aStats += @{
            name = $a.Name; type = $a.Type; ip = $a.IP
            connections = $s.connectionCounts[$a.Name]
            successes = $s.successCounts[$a.Name]
            failures = $s.failCounts[$a.Name]
            health = if ($h) { $h.Score } else { 0 }
            health01 = if ($h) { $h.Score01 } else { 0 }
            latency = if ($h) { $h.LatencyEWMA } else { 999 }
            jitter = if ($h) { $h.Jitter } else { 0 }
            isDegrading = if ($h) { $h.IsDegrading } else { $false }
            throughputMbps = if ($h) { $h.ThroughputMbps } else { 0 }
            throughputAvg5 = if ($h) { $h.ThroughputAvg5 } else { 0 }
            throughputAvg30 = if ($h) { $h.ThroughputAvg30 } else { 0 }
            throughputAvg60 = if ($h) { $h.ThroughputAvg60 } else { 0 }
            measuredLoadMbps = [math]::Round($measuredLoad, 3)
            estimatedCapacityMbps = if ($flow) { $flow.estimatedCapacityMbps } elseif ($h) { $h.EstimatedCapacityMbps } else { 0 }
            effectiveCapacityMbps = if ($flow) { $flow.effectiveCapacityMbps } else { 0 }
            availableCapacityMbps = if ($flow) { $flow.availableCapacityMbps } else { 0 }
            utilizationPct = if ($flow) { $flow.utilizationPct } elseif ($h) { $h.UtilizationPct } else { 0 }
            flowCount = if ($flow) { $flow.activeFlowCount } else { 0 }
            totalBytesWindow = if ($flow) { $flow.totalBytesWindow } else { 0 }
            averageFlowThroughputMbps = if ($flow) { $flow.averageFlowThroughputMbps } else { 0 }
            errorRate = if ($flow) { $flow.errorRate } else { 0 }
            shouldAvoidNewFlows = if ($flow) { $flow.shouldAvoidNewFlows } else { $false }
            forceDrain = if ($flow) { $flow.forceDrain } else { $false }
            isQuarantined = if ($flow) { $flow.isQuarantined } else { $false }
            isDisabled = if ($flow) { $flow.isDisabled } else { $false }
            reintroLimitFlows = if ($flow) { $flow.reintroLimitFlows } else { 0 }
        }
    }
    # Build per-adapter active counts from live registry snapshot so dashboard counters
    # self-heal if any handler exits unexpectedly without decrementing shared counters.
    $activePerAdapterSnap = @{}
    foreach ($a in $s.adapters) {
        $activePerAdapterSnap[$a.Name] = 0
    }

    $staleConnectionIds = [System.Collections.Generic.List[string]]::new()
    foreach ($connId in @($s.connectionRegistry.Keys)) {
        $entry = $s.connectionRegistry[$connId]
        if (-not $entry) {
            $staleConnectionIds.Add([string]$connId)
            continue
        }

        $adapterName = if ($entry.adapter) { [string]$entry.adapter } else { '' }
        $clientConnected = $false
        $remoteConnected = $false
        try { if ($entry.client -and $entry.client.Connected) { $clientConnected = $true } } catch {}
        try { if ($entry.remote -and $entry.remote.Connected) { $remoteConnected = $true } } catch {}

        if ($clientConnected -and $remoteConnected -and $activePerAdapterSnap.ContainsKey($adapterName)) {
            $activePerAdapterSnap[$adapterName] = [int]$activePerAdapterSnap[$adapterName] + 1
        } else {
            $staleConnectionIds.Add([string]$connId)
        }
    }

    foreach ($connId in $staleConnectionIds) {
        try { [void]$s.connectionRegistry.Remove($connId) } catch {}
    }

    $activeConnectionsSnap = [int](($activePerAdapterSnap.Values | Measure-Object -Sum).Sum)
    $counterLockObj = if ($s.activeCounterLock) { $s.activeCounterLock } else { $global:ActiveCounterLock }
    [System.Threading.Monitor]::Enter($counterLockObj)
    try {
        $s.activeConnections = $activeConnectionsSnap
        foreach ($adapterName in @($activePerAdapterSnap.Keys)) {
            $s.activePerAdapter[$adapterName] = [int]$activePerAdapterSnap[$adapterName]
        }
    } finally {
        [System.Threading.Monitor]::Exit($counterLockObj)
    }
    $sessionStats = @{
        activeSessionCount = $s.sessionMap.Count
        oldestSessionAge = 0
        newestSessionAge = 0
        averageSessionAge = 0
    }
    $sessionNow = Get-Date
    $sessionKeys = @($s.sessionMap.Keys)
    if ($sessionKeys.Count -gt 512) {
        $sessionKeys = $sessionKeys[0..511]
    }
    $sampleCount = 0
    $sumAge = 0.0
    $maxAge = 0.0
    $minAge = [double]::MaxValue
    foreach ($sessionKey in $sessionKeys) {
        $entry = $s.sessionMap[$sessionKey]
        try {
            if ($entry -and $entry.time) {
                $age = [double](($sessionNow - [datetime]$entry.time).TotalSeconds)
                if ($age -lt 0) { $age = 0 }
                $sampleCount++
                $sumAge += $age
                if ($age -gt $maxAge) { $maxAge = $age }
                if ($age -lt $minAge) { $minAge = $age }
            }
        } catch {}
    }
    if ($sampleCount -gt 0) {
        $sessionStats.oldestSessionAge = [Math]::Round($maxAge, 2)
        $sessionStats.newestSessionAge = [Math]::Round($minAge, 2)
        $sessionStats.averageSessionAge = [Math]::Round(($sumAge / [double]$sampleCount), 2)
    }
    $statsSnapshot = @{
        running = $Running; port = $s.port; mode = $s.currentMode
        totalConnections = $s.totalConnections; totalFailures = $s.totalFails
        activeConnections = $activeConnectionsSnap
        activePerAdapter = $activePerAdapterSnap
        adapterCount = $s.adapters.Count; adapters = $aStats
        totalMeasuredLoadMbps = [math]::Round($totalMeasuredLoadMbps, 3)
        totalEstimatedCapacityMbps = [math]::Round($totalEstimatedCapacityMbps, 3)
        connectionRegistrySize = $s.connectionRegistry.Count
        forcedDrainAdapters = @($s.forcedDrainAdapters.Keys)
        connectionTypes = $s.connectionTypes
        safeMode = $s.safeMode
        sessionMapSize = $s.sessionMap.Count
        uploadHintHostCount = $s.uploadHostHints.Count
        sessionStats = $sessionStats
        currentMaxThreads = $s.currentMaxThreads
        scheduler = @{
            httpsBulkPromotionHostThreshold = $s.httpsBulkPromotionHostThreshold
            httpsBulkPromotionGlobalThreshold = $s.httpsBulkPromotionGlobalThreshold
            retryPolicy = $s.retryPolicy
            retryWeightFloor = $s.retryWeightFloor
            bulkHeadroomWeight = $s.bulkHeadroomWeight
            bulkPressureThreshold = $s.bulkPressureThreshold
            maxConnectRetries = $s.maxConnectRetries
            connectTimeout = $s.connectTimeout
            socketIoTimeout = $s.socketIoTimeout
            listenerBacklog = $s.listenerBacklog
            staleJobTimeoutSec = $s.staleJobTimeoutSec
        }
        rebalance = if ($s.rebalanceState.ContainsKey('hint')) { $s.rebalanceState['hint'] } else { @{ trigger = $false } }
        upstreamBottleneck = if ($s.rebalanceState.ContainsKey('upstreamBottleneck')) { $s.rebalanceState['upstreamBottleneck'] } else { @{ detected = $false } }
        timestamp = (Get-Date).ToString('o')
    }
    try { Write-AtomicJson -Path $s.statsFile -Data $statsSnapshot -Depth 3 } catch {}

    $decisionHash = "{0}|{1}" -f $s.totalConnections, $s.decisions.Count
    if ($s.decisions.Count -gt 0) {
        $latestDecision = $s.decisions[0]
        $decisionHash = "{0}|{1}|{2}|{3}|{4}|{5}" -f $s.totalConnections, $s.decisions.Count, ([string]$latestDecision.time), ([string]$latestDecision.host), ([string]$latestDecision.adapter), ([string]$latestDecision.type)
    }

    if ($ForceDecisionWrite -or $decisionHash -ne $script:lastDecisionHash) {
        try {
            Write-AtomicJson -Path $s.decisionsFile -Data @{ decisions = $s.decisions } -Depth 3
            $script:lastDecisionHash = $decisionHash
        } catch {}
    }
}

# v5.0: Clean expired session affinity entries
function Clear-ExpiredSessions {
    $s = $global:ProxyState
    $now = Get-Date
    $expired = [System.Collections.Generic.List[string]]::new()
    $snapshot = @{}

    foreach ($key in @($s.sessionMap.Keys)) {
        $snapshot[$key] = $s.sessionMap[$key]
    }

    foreach ($key in @($snapshot.Keys)) {
        $entry = $snapshot[$key]
        if (-not $entry -or -not $entry.time) {
            $expired.Add($key)
            continue
        }

        try {
            if (($now - [datetime]$entry.time).TotalSeconds -gt $s.sessionTTL) {
                $expired.Add($key)
            }
        } catch {
            $expired.Add($key)
        }
    }

    foreach ($key in @($expired)) {
        try { [void]$s.sessionMap.Remove($key) } catch {}
    }

    $purgedCount = $expired.Count
    if ($s.sessionMap.Count -gt 10000) {
        $orderedSessions = foreach ($key in @($s.sessionMap.Keys)) {
            $entry = $s.sessionMap[$key]
            [pscustomobject]@{
                Key = $key
                Entry = $entry
                Time = try { if ($entry -and $entry.time) { [datetime]$entry.time } else { [datetime]::MinValue } } catch { [datetime]::MinValue }
            }
        }

        $keepers = @($orderedSessions | Sort-Object Time -Descending | Select-Object -First 5000)
        $removedForCap = [Math]::Max(0, $orderedSessions.Count - $keepers.Count)
        $s.sessionMap.Clear()
        foreach ($item in $keepers) {
            $s.sessionMap[$item.Key] = $item.Entry
        }
        $purgedCount += $removedForCap
    }

    return $purgedCount
}

function Clear-ExpiredUploadHostHints {
    $s = $global:ProxyState
    $ttl = if ($s.uploadHintTTL -gt 0) { [int]$s.uploadHintTTL } else { 300 }
    $now = Get-Date
    $expired = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @($s.uploadHostHints.Keys)) {
        $entry = $s.uploadHostHints[$key]
        try {
            if (-not $entry -or -not $entry.time -or (($now - [datetime]$entry.time).TotalSeconds -gt $ttl)) {
                $expired.Add($key)
            }
        } catch {
            $expired.Add($key)
        }
    }

    foreach ($key in @($expired)) {
        try {
            $removedValue = $null
            [void]$s.uploadHostHints.TryRemove([string]$key, [ref]$removedValue)
        } catch {}
    }

    return $expired.Count
}

function Drain-FailingConnections {
    param([hashtable]$ProxyState)

    if (-not $ProxyState.connectionRegistry) { return 0 }
    $drainAdapters = @($ProxyState.forcedDrainAdapters.Keys)
    if ($drainAdapters.Count -eq 0) { return 0 }

    $closed = 0
    foreach ($key in @($ProxyState.connectionRegistry.Keys)) {
        $entry = $ProxyState.connectionRegistry[$key]
        if (-not $entry) { continue }
        $adapterName = if ($entry.adapter) { [string]$entry.adapter } else { '' }
        if ($adapterName -in $drainAdapters) {
            try { if ($entry.remote) { $entry.remote.Close() } } catch {}
            try { if ($entry.client) { $entry.client.Close() } } catch {}
            try { [void]$ProxyState.connectionRegistry.Remove($key) } catch {}
            $closed++
        }
    }

    return $closed
}

function Get-ActiveConnectionCount {
    param([hashtable]$ProxyState)

    $lockObj = if ($ProxyState.activeCounterLock) { $ProxyState.activeCounterLock } else { $global:ActiveCounterLock }
    [System.Threading.Monitor]::Enter($lockObj)
    try {
        return [int]$ProxyState.activeConnections
    } finally {
        [System.Threading.Monitor]::Exit($lockObj)
    }
}

# ===== Connection Handler ScriptBlock (runs in separate runspace) =====
$HandlerScript = {
    param($ClientSocket, $State)

    $prefetchedBodyBytes = [byte[]]@()
    $prefetchedBodyOffset = 0

    function Read-ClientBytes {
        param(
            [System.IO.Stream]$Stream,
            [byte[]]$Buffer,
            [int]$Offset,
            [int]$Count
        )

        $copied = 0
        $remainingPrefetch = $prefetchedBodyBytes.Length - $prefetchedBodyOffset
        if ($remainingPrefetch -gt 0) {
            $take = [math]::Min($Count, $remainingPrefetch)
            [System.Array]::Copy($prefetchedBodyBytes, $prefetchedBodyOffset, $Buffer, $Offset, $take)
            $prefetchedBodyOffset += $take
            $copied += $take
            if ($copied -ge $Count) { return $copied }
        }

        $read = $Stream.Read($Buffer, $Offset + $copied, $Count - $copied)
        if ($read -gt 0) { $copied += $read }
        return $copied
    }

    function Read-HttpHeaders {
        param(
            [System.IO.Stream]$Stream,
            [int]$MaxHeaderBytes = 65536,
            [int]$ReadChunkSize = 4096
        )

        $headerBuffer = [System.Collections.Generic.List[byte]]::new()
        $chunk = New-Object byte[] $ReadChunkSize
        $headerEnd = -1

        while ($headerBuffer.Count -lt $MaxHeaderBytes) {
            $read = $Stream.Read($chunk, 0, $chunk.Length)
            if ($read -le 0) {
                if ($headerBuffer.Count -eq 0) { return $null }
                break
            }

            $startSearch = [math]::Max(0, $headerBuffer.Count - 3)
            for ($ci = 0; $ci -lt $read; $ci++) {
                $headerBuffer.Add($chunk[$ci])
            }

            for ($si = $startSearch; $si -le ($headerBuffer.Count - 4); $si++) {
                if (
                    $headerBuffer[$si] -eq 13 -and
                    $headerBuffer[$si + 1] -eq 10 -and
                    $headerBuffer[$si + 2] -eq 13 -and
                    $headerBuffer[$si + 3] -eq 10
                ) {
                    $headerEnd = $si + 4
                    break
                }
            }

            if ($headerEnd -ge 0) { break }
        }

        if ($headerEnd -lt 0) {
            throw "HTTP header exceeded $MaxHeaderBytes bytes."
        }

        $allBytes = $headerBuffer.ToArray()
        $headerBytes = if ($headerEnd -gt 0) { $allBytes[0..($headerEnd - 1)] } else { [byte[]]@() }
        $leftoverBytes = if ($allBytes.Length -gt $headerEnd) { $allBytes[$headerEnd..($allBytes.Length - 1)] } else { [byte[]]@() }

        return @{
            HeaderBytes = [byte[]]$headerBytes
            LeftoverBytes = [byte[]]$leftoverBytes
        }
    }

    function Read-HttpLine {
        param(
            [System.IO.Stream]$Stream,
            [System.Management.Automation.PSReference]$HeaderByteCount = $null
        )

        $lineBytes = [System.Collections.Generic.List[byte]]::new()
        $oneByte = New-Object byte[] 1
        $sawCR = $false
        while ($true) {
            $read = Read-ClientBytes -Stream $Stream -Buffer $oneByte -Offset 0 -Count 1
            if ($read -le 0) {
                if ($lineBytes.Count -eq 0 -and -not $sawCR) { return $null }
                break
            }

            $b = $oneByte[0]
            if ($sawCR) {
                if ($b -eq 10) { break }
                [void]$lineBytes.Add(13)
                $sawCR = $false
            }

            if ($b -eq 13) {
                $sawCR = $true
                continue
            }

            [void]$lineBytes.Add($b)
        }
        $line = [System.Text.Encoding]::ASCII.GetString($lineBytes.ToArray())

        if ($null -ne $HeaderByteCount) {
            $HeaderByteCount.Value += [System.Text.Encoding]::ASCII.GetByteCount($line) + 2
            if ($HeaderByteCount.Value -gt 65536) {
                throw "HTTP header exceeded 65536 bytes."
            }
        }

        return $line
    }

    function Read-ExactBytes {
        param(
            [System.IO.Stream]$Stream,
            [byte[]]$Buffer,
            [int]$Count
        )

        $offset = 0
        while ($offset -lt $Count) {
            $read = Read-ClientBytes -Stream $Stream -Buffer $Buffer -Offset $offset -Count ($Count - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }

        return $offset
    }

    function Forward-ChunkedRequestBody {
        param(
            [System.IO.Stream]$InStream,
            [System.IO.Stream]$OutStream
        )

        while ($true) {
            $sizeLine = Read-HttpLine -Stream $InStream
            if ($null -eq $sizeLine) { throw "Unexpected end of stream while reading chunk size." }

            $sizeLineBytes = [System.Text.Encoding]::ASCII.GetBytes("$sizeLine`r`n")
            $OutStream.Write($sizeLineBytes, 0, $sizeLineBytes.Length)

            if ([string]::IsNullOrWhiteSpace($sizeLine)) { continue }
            $sizeToken = $sizeLine.Split(';')[0].Trim()
            $chunkSize = [Convert]::ToInt32($sizeToken, 16)

            if ($chunkSize -eq 0) {
                while ($true) {
                    $trailerLine = Read-HttpLine -Stream $InStream
                    if ($null -eq $trailerLine) { throw "Unexpected end of stream while reading chunk trailer." }
                    $trailerBytes = [System.Text.Encoding]::ASCII.GetBytes("$trailerLine`r`n")
                    $OutStream.Write($trailerBytes, 0, $trailerBytes.Length)
                    if ($trailerLine -eq '') { break }
                }
                break
            }

            $chunkBuffer = New-Object byte[] ([math]::Min($chunkSize, 65536))
            $remaining = $chunkSize
            while ($remaining -gt 0) {
                $toRead = [math]::Min($remaining, $chunkBuffer.Length)
                $read = Read-ClientBytes -Stream $InStream -Buffer $chunkBuffer -Offset 0 -Count $toRead
                if ($read -le 0) { throw "Unexpected end of stream while reading chunk body." }
                $OutStream.Write($chunkBuffer, 0, $read)
                $remaining -= $read
            }

            $chunkTerminator = New-Object byte[] 2
            if ((Read-ExactBytes -Stream $InStream -Buffer $chunkTerminator -Count 2) -ne 2) {
                throw "Unexpected end of stream while reading chunk terminator."
            }
            $OutStream.Write($chunkTerminator, 0, $chunkTerminator.Length)
        }
    }

    function Set-UploadHostHint {
        param(
            [hashtable]$ProxyState,
            [string]$TargetHost,
            [string]$Reason,
            [long]$ClientToRemoteBytes = 0,
            [long]$RemoteToClientBytes = 0
        )

        if ([string]::IsNullOrWhiteSpace($TargetHost)) { return }
        $entry = @{
            time = (Get-Date)
            reason = $Reason
            clientToRemoteBytes = $ClientToRemoteBytes
            remoteToClientBytes = $RemoteToClientBytes
        }
        [void]$ProxyState.uploadHostHints.AddOrUpdate([string]$TargetHost, $entry, { param($k, $v) $entry })
    }

    function Resolve-TargetAddresses {
        param(
            [hashtable]$ProxyState,
            [string]$TargetHost,
            [string]$AdapterName = ''
        )

        if ([string]::IsNullOrWhiteSpace($TargetHost)) { return @() }

        # If TargetHost is already an IP address, return it directly
        $parsedIp = $null
        try { $parsedIp = [System.Net.IPAddress]::Parse($TargetHost) } catch {}
        if ($parsedIp) { return @($parsedIp) }

        $adapterKey = if ([string]::IsNullOrWhiteSpace($AdapterName)) { 'any' } else { [string]$AdapterName.ToLowerInvariant() }
        $cacheKey = [string]("{0}|{1}" -f $adapterKey, $TargetHost.ToLowerInvariant())
        $cached = $null
        if ($ProxyState.dnsCache.TryGetValue($cacheKey, [ref]$cached)) {
            try {
                if ($cached -and $cached.until -and ([datetime]$cached.until -gt (Get-Date)) -and $cached.addresses) {
                    return @($cached.addresses)
                }
            } catch {}
        }

        $addresses = @()
        # Primary: system DNS resolver
        try {
            $resolved = [System.Net.Dns]::GetHostAddresses($TargetHost)
            foreach ($addr in @($resolved)) {
                if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $addresses += $addr
                }
            }
            if ($addresses.Count -eq 0 -and $resolved.Count -gt 0) {
                $addresses = @($resolved | Select-Object -First 1)
            }
        } catch {}

        # RC-6: Fallback DNS -- if system DNS failed, try direct UDP query to 8.8.8.8 / 1.1.1.1
        if ($addresses.Count -eq 0) {
            foreach ($fallbackDns in @('8.8.8.8', '1.1.1.1')) {
                try {
                    # Use .NET DNS client pointed at fallback server via raw Resolve-DnsName
                    # This is a simple A-record query bypass
                    $queryBytes = [System.Collections.Generic.List[byte]]::new()
                    # DNS header: random ID, standard query, 1 question
                    $id = Get-Random -Minimum 1 -Maximum 65535
                    $queryBytes.AddRange([System.BitConverter]::GetBytes([uint16]$id))
                    $queryBytes.AddRange([byte[]]@(0x01, 0x00))  # flags: recursion desired
                    $queryBytes.AddRange([byte[]]@(0x00, 0x01))  # 1 question
                    $queryBytes.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00))  # 0 answers/auth/additional
                    # Encode hostname as DNS labels
                    foreach ($label in $TargetHost.Split('.')) {
                        $labelBytes = [System.Text.Encoding]::ASCII.GetBytes($label)
                        $queryBytes.Add([byte]$labelBytes.Length)
                        $queryBytes.AddRange($labelBytes)
                    }
                    $queryBytes.Add(0x00)  # root label
                    $queryBytes.AddRange([byte[]]@(0x00, 0x01))  # type A
                    $queryBytes.AddRange([byte[]]@(0x00, 0x01))  # class IN

                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Client.SendTimeout = 2000
                    $udp.Client.ReceiveTimeout = 2000
                    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($fallbackDns), 53)
                    [void]$udp.Send($queryBytes.ToArray(), $queryBytes.Count, $ep)
                    $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    $resp = $udp.Receive([ref]$remoteEp)
                    $udp.Dispose()

                    # Parse A records from response (simplified: look for 4-byte answers)
                    if ($resp -and $resp.Length -gt 12) {
                        $answerCount = ([int]$resp[6] -shl 8) -bor [int]$resp[7]
                        if ($answerCount -gt 0) {
                            # Skip header (12 bytes) + query section
                            $offset = 12
                            # Skip query name
                            while ($offset -lt $resp.Length -and $resp[$offset] -ne 0) {
                                if (($resp[$offset] -band 0xC0) -eq 0xC0) { $offset += 2; break }
                                $offset += [int]$resp[$offset] + 1
                            }
                            if ($offset -lt $resp.Length -and $resp[$offset] -eq 0) { $offset++ }
                            $offset += 4  # skip QTYPE + QCLASS

                            # Parse answer records
                            for ($ai = 0; $ai -lt $answerCount -and $offset -lt ($resp.Length - 10); $ai++) {
                                # Skip name (pointer or labels)
                                if (($resp[$offset] -band 0xC0) -eq 0xC0) { $offset += 2 }
                                else { while ($offset -lt $resp.Length -and $resp[$offset] -ne 0) { $offset += [int]$resp[$offset] + 1 }; $offset++ }
                                $rtype = ([int]$resp[$offset] -shl 8) -bor [int]$resp[$offset + 1]
                                $rdlen = ([int]$resp[$offset + 8] -shl 8) -bor [int]$resp[$offset + 9]
                                $offset += 10  # skip type(2)+class(2)+ttl(4)+rdlen(2)
                                if ($rtype -eq 1 -and $rdlen -eq 4 -and ($offset + 4) -le $resp.Length) {
                                    $ip = New-Object System.Net.IPAddress(, $resp[$offset..($offset + 3)])
                                    $addresses += $ip
                                }
                                $offset += $rdlen
                            }
                        }
                    }
                    if ($addresses.Count -gt 0) { break }
                } catch {}
            }
        }

        if ($addresses.Count -gt 0) {
            $entry = @{
                until = (Get-Date).AddSeconds(30)
                addresses = $addresses
            }
            [void]$ProxyState.dnsCache.AddOrUpdate($cacheKey, $entry, { param($k, $v) $entry })
        }

        return $addresses
    }

    function Get-LockedActiveConnections {
        param([hashtable]$ProxyState)

        $lockObj = if ($ProxyState.activeCounterLock) { $ProxyState.activeCounterLock } else { $global:ActiveCounterLock }
        [System.Threading.Monitor]::Enter($lockObj)
        try {
            return [int]$ProxyState.activeConnections
        } finally {
            [System.Threading.Monitor]::Exit($lockObj)
        }
    }

    function Get-CandidateSnapshot {
        param(
            [hashtable]$ProxyState,
            [object]$Adapter,
            [double]$BaseWeight = 1.0
        )

        $name = [string]$Adapter.Name
        $flow = $ProxyState.flowStats[$name]
        $active = if ($ProxyState.activePerAdapter.ContainsKey($name)) { [int]$ProxyState.activePerAdapter[$name] } else { 0 }
        $health = $ProxyState.adapterHealth[$name]

        $measuredLoad = 0.0
        $estimatedCapacity = 80.0
        $effectiveCapacity = 10.0
        $available = 0.0
        $utilizationPct = 0.0
        $health01 = 0.5
        $shouldAvoid = $false
        $forceDrain = $false
        $isQuarantined = $false
        $isDisabled = $false
        $reintroLimit = 0
        $latency = 999.0

        if ($flow) {
            if ($flow.measuredLoadMbps -gt 0) { $measuredLoad = [double]$flow.measuredLoadMbps }
            if ($flow.estimatedCapacityMbps -gt 0) { $estimatedCapacity = [double]$flow.estimatedCapacityMbps }
            if ($flow.effectiveCapacityMbps -gt 0) { $effectiveCapacity = [double]$flow.effectiveCapacityMbps }
            if ($flow.availableCapacityMbps -gt 0) { $available = [double]$flow.availableCapacityMbps }
            if ($flow.utilizationPct -gt 0) { $utilizationPct = [double]$flow.utilizationPct }
            if ($flow.health01 -gt 0) { $health01 = [double]$flow.health01 }
            $shouldAvoid = $flow.shouldAvoidNewFlows -eq $true
            $forceDrain = $flow.forceDrain -eq $true
            $isQuarantined = $flow.isQuarantined -eq $true
            $isDisabled = $flow.isDisabled -eq $true
            $reintroLimit = if ($flow.reintroLimitFlows) { [int]$flow.reintroLimitFlows } else { 0 }
        }

        if ($health) {
            if ($health.ThroughputAvg5 -gt $measuredLoad) { $measuredLoad = [double]$health.ThroughputAvg5 }
            if ($health.ThroughputAvg30 -gt $measuredLoad) { $measuredLoad = [double]$health.ThroughputAvg30 }
            if ($health.ThroughputMbps -gt $measuredLoad) { $measuredLoad = [double]$health.ThroughputMbps }
            if ($health.EstimatedCapacityMbps -gt $estimatedCapacity) { $estimatedCapacity = [double]$health.EstimatedCapacityMbps }
            if ($health.Score01 -gt 0) { $health01 = [double]$health.Score01 }
            if ($health.LatencyEWMA -gt 0) { $latency = [double]$health.LatencyEWMA }
            if ($health.ShouldAvoidNewFlows) { $shouldAvoid = $true }
            if ($health.ForceDrain) { $forceDrain = $true }
            if ($health.IsQuarantined) { $isQuarantined = $true }
            if ($health.IsDisabled) { $isDisabled = $true }
            if ($null -ne $health.ReintroLimitFlows -and [int]$health.ReintroLimitFlows -gt $reintroLimit) { $reintroLimit = [int]$health.ReintroLimitFlows }
        }

        if ($effectiveCapacity -le 0) {
            $effectiveCapacity = [math]::Max(1.0, $estimatedCapacity * [math]::Max(0.05, $health01) * [math]::Max(0.1, $BaseWeight))
        }
        if ($available -le 0) {
            $available = [math]::Max(0.0, $effectiveCapacity - $measuredLoad)
        }
        if ($utilizationPct -le 0 -and $effectiveCapacity -gt 0) {
            $utilizationPct = [math]::Min(100.0, [math]::Max(0.0, ($measuredLoad / $effectiveCapacity) * 100.0))
        }

        return [pscustomobject]@{
            Name = $name
            Adapter = $Adapter
            ActiveFlows = $active
            BaseWeight = [double]$BaseWeight
            MeasuredLoadMbps = [double]$measuredLoad
            EstimatedCapacityMbps = [double]$estimatedCapacity
            EffectiveCapacityMbps = [double]$effectiveCapacity
            AvailableCapacityMbps = [double]$available
            UtilizationPct = [double]$utilizationPct
            Health01 = [double]$health01
            ShouldAvoidNew = $shouldAvoid
            ForceDrain = $forceDrain
            IsQuarantined = $isQuarantined
            IsDisabled = $isDisabled
            ReintroLimitFlows = [int]$reintroLimit
            Latency = [double]$latency
        }
    }

    function Select-CapacityAwareAdapter {
        param(
            [hashtable]$ProxyState,
            [array]$Adapters,
            [array]$Weights,
            [string]$ConnectionType = 'bulk'
        )

        if (-not $Adapters -or $Adapters.Count -eq 0) { return $null }

        $candidates = @()
        for ($i = 0; $i -lt $Adapters.Count; $i++) {
            $w = if ($i -lt $Weights.Count) { [double]$Weights[$i] } else { 1.0 }
            $candidates += (Get-CandidateSnapshot -ProxyState $ProxyState -Adapter $Adapters[$i] -BaseWeight $w)
        }

        $eligible = @($candidates | Where-Object { -not $_.ForceDrain -and -not $_.IsDisabled })
        if ($eligible.Count -eq 0) { $eligible = $candidates }
        $healthy = @($eligible | Where-Object { -not $_.ShouldAvoidNew -and -not $_.IsQuarantined -and $_.Health01 -ge 0.3 })
        if ($healthy.Count -eq 0) { $healthy = $eligible }

        # Minimum-flow guarantee: each healthy adapter receives at least one active flow.
        $zeroFlowHealthy = @($healthy | Where-Object { $_.ActiveFlows -le 0 })
        if ($zeroFlowHealthy.Count -gt 0) {
            return ($zeroFlowHealthy | Sort-Object @{ Expression = 'AvailableCapacityMbps'; Descending = $true }, @{ Expression = 'Health01'; Descending = $true } | Select-Object -First 1)
        }

        $minActiveHealthy = [int](($healthy | Measure-Object -Property ActiveFlows -Minimum).Minimum)
        if ($minActiveHealthy -lt 0) { $minActiveHealthy = 0 }
        $minCapacityHealthy = [double](($healthy | Measure-Object -Property EffectiveCapacityMbps -Minimum).Minimum)
        if ($minCapacityHealthy -lt 1.0) { $minCapacityHealthy = 1.0 }

        $throughputBias = if ($ConnectionType -in @('bulk', 'streaming', 'interactive')) { 1.0 } else { 0.6 }
        $latencyBias = if ($ConnectionType -eq 'gaming') { 1.25 } elseif ($ConnectionType -eq 'streaming') { 0.45 } else { 0.15 }
        $flowPenaltyFactor = if ($ConnectionType -eq 'gaming') { 0.30 } else { 0.55 }
        $rebalanceHint = $null
        if ($ProxyState.rebalanceState.ContainsKey('hint')) {
            $rebalanceHint = $ProxyState.rebalanceState['hint']
        }

        $best = $null
        $bestScore = [double]::NegativeInfinity
        foreach ($c in $healthy) {
            if ($c.ReintroLimitFlows -gt 0 -and $c.ActiveFlows -ge $c.ReintroLimitFlows) {
                continue
            }

            # Capacity-aware fairness cap:
            # Faster links are allowed to carry proportionally more concurrent flows,
            # while still preventing total starvation of slower healthy links.
            if ($healthy.Count -gt 1) {
                $capacityRatio = [math]::Max(1.0, [double]$c.EffectiveCapacityMbps / $minCapacityHealthy)
                $dynamicMultiplier = [math]::Min(24.0, [math]::Max(3.0, $capacityRatio * 1.6))
                $maxAllowed = [math]::Max(1, [int][math]::Ceiling(($minActiveHealthy + 1) * $dynamicMultiplier))
                if ($c.ActiveFlows -gt $maxAllowed) {
                    continue
                }
            }

            $flowNormalization = [math]::Max(1.0, [double]$c.EffectiveCapacityMbps / 25.0)
            $flowPenalty = ([double]$c.ActiveFlows / $flowNormalization) * $flowPenaltyFactor
            $latScore = if ($c.Latency -lt 998) { 1000.0 / [math]::Max(1.0, $c.Latency) } else { 0.1 }
            $headroomRatio = if ($c.EffectiveCapacityMbps -gt 0) { [math]::Max(0.0, [math]::Min(1.0, [double]$c.AvailableCapacityMbps / [double]$c.EffectiveCapacityMbps)) } else { 0.0 }
            $capacityScore = [math]::Max(0.0, $c.AvailableCapacityMbps) + ([double]$c.EffectiveCapacityMbps * 0.10 * $headroomRatio)
            $healthBoost = [math]::Max(0.05, $c.Health01)
            $score = (($capacityScore * $throughputBias) + ($latScore * $latencyBias)) * $healthBoost
            $score -= $flowPenalty

            if ($rebalanceHint -and $rebalanceHint.trigger) {
                $over = @()
                $under = @()
                if ($rebalanceHint.overUtilized) { $over = @($rebalanceHint.overUtilized) }
                if ($rebalanceHint.underUtilized) { $under = @($rebalanceHint.underUtilized) }
                if ($c.Name -in $over) {
                    $score *= 0.55
                } elseif ($c.Name -in $under) {
                    $score *= 1.25
                }
            }

            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = $c
            }
        }

        if (-not $best) {
            $best = ($eligible | Sort-Object @{ Expression = 'AvailableCapacityMbps'; Descending = $true }, @{ Expression = 'Health01'; Descending = $true } | Select-Object -First 1)
        }

        return $best
    }

    $connAdapter = $null  # track which adapter this connection uses
    $hostKey = $null
    $connectionId = $null
    $remoteClient = $null
    $clientStream = $null
    $remoteStream = $null
    $uri = $null
    try {
        # v5.0: Safe mode check -- if active, act as simple pass-through on default adapter
        $isSafeMode = $State.safeMode

        $clientStream = $ClientSocket.GetStream()
        $ioTimeout = if ($null -ne $State.socketIoTimeout -and [int]$State.socketIoTimeout -ge 5000) { [int]$State.socketIoTimeout } else { 45000 }
        $headerTimeoutMs = [math]::Max(5000, [math]::Min(30000, [int]($ioTimeout / 2)))
        $drainTimeoutMs = [math]::Max(5000, [math]::Min(30000, [int]($ioTimeout / 2)))
        try { $ClientSocket.Client.NoDelay = $true } catch {}
        try { $ClientSocket.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::KeepAlive, $true) } catch {}
        $clientStream.ReadTimeout = $headerTimeoutMs

        # Read request headers safely up to 64KB without losing pre-read body bytes.
        $headerPayload = Read-HttpHeaders -Stream $clientStream -MaxHeaderBytes 65536
        if (-not $headerPayload) { $ClientSocket.Close(); return }
        $prefetchedBodyBytes = if ($headerPayload.LeftoverBytes) { [byte[]]$headerPayload.LeftoverBytes } else { [byte[]]@() }
        $prefetchedBodyOffset = 0

        $headerLines = [System.Collections.Generic.List[string]]::new()
        $headerMemory = New-Object System.IO.MemoryStream(, $headerPayload.HeaderBytes)
        $headerReader = [System.IO.StreamReader]::new($headerMemory, [System.Text.Encoding]::ASCII, $false, 4096, $true)
        try {
            while ($true) {
                $line = $headerReader.ReadLine()
                if ($null -eq $line -or $line -eq '') { break }
                [void]$headerLines.Add($line)
            }
        } finally {
            try { $headerReader.Dispose() } catch {}
            try { $headerMemory.Dispose() } catch {}
        }

        if ($headerLines.Count -lt 1) { $ClientSocket.Close(); return }
        $lines = @($headerLines)
        $parts = $lines[0] -split ' '
        if ($parts.Count -lt 2) { $ClientSocket.Close(); return }
        $method = $parts[0].ToUpperInvariant()
        $text = ($lines -join "`r`n") + "`r`n`r`n"
        $requestContentLength = 0L
        if ($text -match '(?im)^Content-Length:\s*(\d+)') { $requestContentLength = [int64]$Matches[1] }
        $uploadContentLength = 0L
        if ($text -match '(?im)^X-Upload-Content-Length:\s*(\d+)') { $uploadContentLength = [int64]$Matches[1] }
        $isChunkedRequest = $text -match '(?im)^Transfer-Encoding:\s*.*\bchunked\b'
        $hasContentRange = $text -match '(?im)^Content-Range:\s*bytes\s+\d+-\d+/\d+'
        $hasExpectContinue = $text -match '(?im)^Expect:\s*100-continue'
        $hasTusResumable = $text -match '(?im)^Tus-Resumable:\s*'
        $contentType = ''
        if ($text -match '(?im)^Content-Type:\s*([^\r\n]+)') { $contentType = $Matches[1].Trim() }
        $clientStream.ReadTimeout = $ioTimeout

        # ===== v5.0: Health check endpoint for SafetyController =====
        if ($method -eq 'GET' -and $parts.Count -ge 2 -and $parts[1] -eq '/health') {
            $remoteEndPoint = $ClientSocket.Client.RemoteEndPoint -as [System.Net.IPEndPoint]
            $isLocalRequester = $remoteEndPoint -and (
                $remoteEndPoint.Address.Equals([System.Net.IPAddress]::Loopback) -or
                $remoteEndPoint.Address.Equals([System.Net.IPAddress]::IPv6Loopback)
            )
            $resp = if ($isLocalRequester) {
                [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK")
            } else {
                [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 403 Forbidden`r`nContent-Type: text/plain`r`nContent-Length: 9`r`nConnection: close`r`n`r`nForbidden")
            }
            $clientStream.Write($resp, 0, $resp.Length)
            $ClientSocket.Close()
            return
        }

        # [V5-FIX-20] HTTP/2 Multiplexing Behavior:
        # Modern browsers use HTTP/2 which multiplexes many page requests over a single TCP connection. 
        # NetFusion routes per-TCP connection, meaning all resources from one host may go through the 
        # same adapter in one session. This is correct behavior -- splitting one HTTP/2 connection 
        # across adapters would instantly corrupt and sever the tunnel.

        # ===== Connection Type Detection =====
        $connType = 'interactive'
        $targetHost = ''

        if ($method -eq 'CONNECT') {
            $target = $parts[1]
            $ipv6Match = $State.connectIpv6Regex.Match($target)
            if ($ipv6Match.Success) {
                $targetHost = $ipv6Match.Groups['host'].Value
                $rPort = [int]$ipv6Match.Groups['port'].Value
            } else {
                $hostPortMatch = $State.connectHostPortRegex.Match($target)
                if ($hostPortMatch.Success) {
                    $targetHost = $hostPortMatch.Groups['host'].Value
                    $rPort = [int]$hostPortMatch.Groups['port'].Value
                } else {
                    $targetHost = $target
                    $rPort = 443
                }
            }
        } else {
            try { $uri = [System.Uri]$parts[1] } catch { $ClientSocket.Close(); return }
            $targetHost = $uri.Host
            $rPort = if ($uri.Port -gt 0 -and $uri.Port -ne -1) { $uri.Port } else { 80 }
        }

        $isGoogleDriveServiceHost = $targetHost -match '(?i)(^|\.)drivefrontend-pa\.clients\d+\.google\.com$|(^|\.)drive-thirdparty\.googleusercontent\.com$|(^|\.)workspaceui-pa\.clients\d+\.google\.com$'
        $isGoogleDriveHost = $isGoogleDriveServiceHost -or ($targetHost -match '(?i)^drive\.google\.com$')
        $isUploadMethod = $method -in @('POST', 'PUT', 'PATCH')
        $hasUploadContentType = $contentType -match '(?i)\bmultipart/form-data\b|\bapplication/octet-stream\b|\bapplication/x-www-form-urlencoded\b|\bimage\/|\bvideo\/|\baudio\/'
        $recentUploadHint = $false
        $hint = $null
        if ($targetHost -and $State.uploadHostHints.TryGetValue([string]$targetHost, [ref]$hint)) {
            try {
                if ($hint -and $hint.time -and (((Get-Date) - [datetime]$hint.time).TotalSeconds -lt $State.uploadHintTTL)) {
                    $recentUploadHint = $true
                } else {
                    $removedHint = $null
                    [void]$State.uploadHostHints.TryRemove([string]$targetHost, [ref]$removedHint)
                }
            } catch {
                $removedHint = $null
                [void]$State.uploadHostHints.TryRemove([string]$targetHost, [ref]$removedHint)
            }
        }

        # Note: L7 connection type detection using regex heuristics was replaced by strict L4 Arbitration Table in v5.1
        $isBulkHint = $false
        if ($method -ne 'CONNECT') {
            $targetPath = if ($uri) { ($uri.AbsolutePath + $uri.Query) } else { '' }
            $hasGenericUploadPathHint = $targetPath -match '(?i)(^|/)(upload|uploads|uploading|attach|attachment|attachments|multipart|resumable|media|files|file|chunks?)(/|$)|[?&](upload|uploadType|resumable|chunk|partNumber|session)='
            $isGenericUploadHint = $hasContentRange -or
                $uploadContentLength -gt 0 -or
                $hasTusResumable -or
                (
                    $isUploadMethod -and (
                        $requestContentLength -ge 262144 -or
                        $isChunkedRequest -or
                        $hasExpectContinue -or
                        $hasUploadContentType -or
                        $hasGenericUploadPathHint
                    )
                )
            if (
                $text -match '(?im)^Range:\s*bytes=' -or
                $targetPath -match '(?i)(^|/)(__down|download|downloads?|payload|bigfile|speedtest)' -or
                $targetPath -match '(?i)\.(zip|iso|msi|exe|bin|7z|rar|tar|gz|pkg)(\?|$)' -or
                $targetHost -match '(?i)(^|\.)speed\.cloudflare\.com$|speedtest|download' -or
                $isGenericUploadHint -or
                (
                    $isGoogleDriveHost -and (
                        $isUploadMethod -or
                        $targetPath -match '(?i)(^|/)(upload|resumable|multipart)(/|$)|[?&]uploadType=' -or
                        $text -match '(?im)^X-Goog-Upload-(Command|Protocol):' -or
                        $hasContentRange
                    )
                )
            ) {
                $isBulkHint = $true
            }
        } elseif ($targetHost -match '(?i)(^|\.)speed\.cloudflare\.com$|speedtest') {
            $isBulkHint = $true
        } elseif ($recentUploadHint -and $State.currentMode -in @('maxspeed', 'download')) {
            # HTTPS uploads hide the inner request method. Reuse short-lived host hints so
            # repeated upload tunnels to the same service stop getting sticky treatment.
            $isBulkHint = $true
        } elseif ($isGoogleDriveServiceHost -and $State.currentMode -in @('maxspeed', 'download')) {
            # Drive uploads are often hidden behind HTTPS CONNECT tunnels to service hosts.
            # Treat those tunnels as bulk-capable so parallel upload channels are not kept sticky.
            $isBulkHint = $true
        }

        if ($method -ne 'CONNECT' -and $isBulkHint -and ($isUploadMethod -or $uploadContentLength -gt 0 -or $requestContentLength -ge 262144 -or $isChunkedRequest -or $hasTusResumable -or $hasContentRange)) {
            Set-UploadHostHint -ProxyState $State -TargetHost $targetHost -Reason 'http-upload-signal' -ClientToRemoteBytes ([math]::Max($requestContentLength, $uploadContentLength)) -RemoteToClientBytes 0
        }

        # v5.1: Track host concurrency for dynamic download manager detection
        $hostKey = $targetHost
        $activeHostCount = 0
        $hostLockObj = if ($State.hostCounterLock) { $State.hostCounterLock } elseif ($State.activeCounterLock) { $State.activeCounterLock } else { $global:HostCounterLock }
        [System.Threading.Monitor]::Enter($hostLockObj)
        try {
            if (-not $State.activePerHost.ContainsKey($hostKey)) { $State.activePerHost[$hostKey] = 0 }
            $State.activePerHost[$hostKey] = [int]$State.activePerHost[$hostKey] + 1
            $activeHostCount = [int]$State.activePerHost[$hostKey]
        } finally {
            [System.Threading.Monitor]::Exit($hostLockObj)
        }

        $portClasses = $State.portClasses
        $gamingPorts = if ($portClasses -and $portClasses.gaming) { @($portClasses.gaming) } else { @() }
        $voicePorts = if ($portClasses -and $portClasses.voice) { @($portClasses.voice) } else { @() }
        $bulkPorts = if ($portClasses -and $portClasses.bulk) { @($portClasses.bulk) } else { @() }

        if ($rPort -in $gamingPorts) { 
            $connType = 'gaming' 
        } elseif ($rPort -in $voicePorts) { 
            $connType = 'voice' 
        } elseif ($isBulkHint) {
            $connType = 'bulk'
        } elseif ($rPort -in $bulkPorts) { 
            $connType = 'bulk' 
        } elseif ($rPort -eq 443 -or $rPort -eq 80) {
            $aggressiveMode = $State.currentMode -in @('maxspeed', 'download')
            $globalConcurrency = Get-LockedActiveConnections -ProxyState $State
            $hostPromotionThreshold = if ($null -ne $State.httpsBulkPromotionHostThreshold -and [int]$State.httpsBulkPromotionHostThreshold -ge 1) { [int]$State.httpsBulkPromotionHostThreshold } else { 2 }
            $globalPromotionThreshold = if ($null -ne $State.httpsBulkPromotionGlobalThreshold -and [int]$State.httpsBulkPromotionGlobalThreshold -ge 1) { [int]$State.httpsBulkPromotionGlobalThreshold } else { 8 }
            if ($aggressiveMode) {
                # Max-throughput profiles should not wait long before promoting
                # HTTPS/HTTP flows to bulk scheduling.
                $hostPromotionThreshold = [math]::Min($hostPromotionThreshold, 1)
                $globalPromotionThreshold = [math]::Min($globalPromotionThreshold, 4)
            }
            if ($aggressiveMode -and ($activeHostCount -ge $hostPromotionThreshold -or $globalConcurrency -ge $globalPromotionThreshold)) {
                # Promote HTTPS/HTTP flows to bulk earlier in throughput-first modes
                # so multi-session workloads distribute across all healthy links sooner.
                $connType = 'bulk'
            } else {
                $connType = 'streaming'
            }
        } else { 
            $connType = 'bulk' 
        }

        if (-not $State.connectionTypes.ContainsKey($connType)) { $State.connectionTypes[$connType] = 0 }
        $State.connectionTypes[$connType]++

        # ===== Adapter Selection =====
        $avail = @(); $aw = @()
        for ($i = 0; $i -lt $State.adapters.Count; $i++) {
            $avail += $State.adapters[$i]
            $aw += $State.weights[$i]
        }
        if ($avail.Count -eq 0) { $ClientSocket.Close(); return }
        $counterLockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
        [System.Threading.Monitor]::Enter($counterLockObj)
        try {
            $State.totalConnections = [int]$State.totalConnections + 1
            $State.activeConnections = [int]$State.activeConnections + 1
        } finally {
            [System.Threading.Monitor]::Exit($counterLockObj)
        }

        $bufSize = if ($State.bufferSizes.ContainsKey($connType)) { $State.bufferSizes[$connType] } else { $State.bufferSizes['default'] }

        $adapter = $avail[0]
        $selectionReason = 'default'
        $affinityMode = 'none'

        if ($isSafeMode) {
            # Safe mode: avoid aggressive balancing, but still pick a healthy adapter dynamically.
            $safeSelection = Select-CapacityAwareAdapter -ProxyState $State -Adapters $avail -Weights $aw -ConnectionType 'interactive'
            if ($safeSelection -and $safeSelection.Adapter) {
                $adapter = $safeSelection.Adapter
            } else {
                $adapter = $avail | Sort-Object @{ Expression = 'Name'; Descending = $false } | Select-Object -First 1
            }
            $selectionReason = 'safe-mode(preferred-adapter)'
            $affinityMode = 'safe'
        } elseif ($avail.Count -eq 1) {
            $selectionReason = 'only-adapter'
        } else {
            # [V5-FIX-4] Resolve Round-Robin vs Session Affinity
            $sessionKey = "$targetHost`:$rPort"
            $cachedAdapter = $null

            if ($connType -eq 'bulk') {
                $skipAffinity = $true
            } else {
                $skipAffinity = $false
                if ($State.sessionMap.ContainsKey($sessionKey)) {
                    $cached = $State.sessionMap[$sessionKey]
                    $elapsed = ((Get-Date) - $cached.time).TotalSeconds
                    if ($elapsed -lt $State.sessionTTL) {
                        $found = $avail | Where-Object { $_.Name -eq $cached.adapter } | Select-Object -First 1
                        if ($found) {
                            $cachedFlow = $State.flowStats[$found.Name]
                            $cachedBlocked = $false
                            if ($cachedFlow -and ($cachedFlow.forceDrain -or $cachedFlow.isDisabled -or $cachedFlow.shouldAvoidNewFlows)) {
                                $cachedBlocked = $true
                            }
                            if (-not $cachedBlocked) {
                                $cachedAdapter = $found
                                $selectionReason = "session-affinity($connType)"
                                $affinityMode = "sticky"
                            }
                        }
                    }
                }
            }

            if ($cachedAdapter) {
                $adapter = $cachedAdapter
                $lockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
                [System.Threading.Monitor]::Enter($lockObj)
                try {
                    if (-not $State.activePerAdapter.ContainsKey($adapter.Name)) { $State.activePerAdapter[$adapter.Name] = 0 }
                    $State.activePerAdapter[$adapter.Name] = [int]$State.activePerAdapter[$adapter.Name] + 1
                    $connAdapter = $adapter.Name
                } finally {
                    [System.Threading.Monitor]::Exit($lockObj)
                }
            } else {
                $selection = Select-CapacityAwareAdapter -ProxyState $State -Adapters $avail -Weights $aw -ConnectionType $connType
                if ($selection -and $selection.Adapter) {
                    $adapter = $selection.Adapter
                    $selectionReason = "capacity-aware($connType)"
                    $affinityMode = if ($connType -eq 'bulk') { "adaptive" } else { "new-sticky" }
                } else {
                    $rrLockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
                    [System.Threading.Monitor]::Enter($rrLockObj)
                    try {
                        $idx = $State.rrIndex % $avail.Count
                        $adapter = $avail[$idx]
                        $State.rrIndex++
                    } finally {
                        [System.Threading.Monitor]::Exit($rrLockObj)
                    }
                    $selectionReason = "fallback-round-robin"
                    $affinityMode = "new-sticky"
                }

                $lockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
                [System.Threading.Monitor]::Enter($lockObj)
                try {
                    if (-not $State.activePerAdapter.ContainsKey($adapter.Name)) { $State.activePerAdapter[$adapter.Name] = 0 }
                    $State.activePerAdapter[$adapter.Name] = [int]$State.activePerAdapter[$adapter.Name] + 1
                    $connAdapter = $adapter.Name
                } finally {
                    [System.Threading.Monitor]::Exit($lockObj)
                }
            }

            if (-not $skipAffinity -and $State.sessionMap.Count -le 2000) {
                $State.sessionMap[$sessionKey] = @{ adapter = $adapter.Name; time = (Get-Date) }
            }
        }

        if (-not $connAdapter -and $adapter -and $adapter.Name) {
            $lockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
            [System.Threading.Monitor]::Enter($lockObj)
            try {
                if (-not $State.activePerAdapter.ContainsKey($adapter.Name)) { $State.activePerAdapter[$adapter.Name] = 0 }
                $State.activePerAdapter[$adapter.Name] = [int]$State.activePerAdapter[$adapter.Name] + 1
                $connAdapter = $adapter.Name
            } finally {
                [System.Threading.Monitor]::Exit($lockObj)
            }
        }

        # Track live connection ownership so failing adapters can be drained safely.
        $connectionId = [guid]::NewGuid().ToString('N')
        $State.connectionRegistry[$connectionId] = @{
            adapter = $adapter.Name
            client = $ClientSocket
            remote = $null
            created = (Get-Date)
        }

        # Log decision
        $decision = @{
            time = (Get-Date).ToString('HH:mm:ss.fff')
            host = $targetHost
            type = $connType
            adapter = $adapter.Name
            reason = $selectionReason
            affinity_mode = $affinityMode
        }
        $State.decisions = @($decision) + @($State.decisions | Select-Object -First ($State.maxDecisions - 1))

        # ===== Connect to remote via chosen adapter (with failover) =====
        $remoteClient = $null
        $maxRetries = [math]::Min($avail.Count, [math]::Max(1, [int]$State.maxConnectRetries))
        $usedNames = @()

        for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
            if ($attempt -gt 0) {
                $filteredAdapters = @(); $filteredWeights = @()
                for ($fi = 0; $fi -lt $avail.Count; $fi++) {
                    if ($avail[$fi].Name -notin $usedNames) { $filteredAdapters += $avail[$fi]; $filteredWeights += $aw[$fi] }
                }
                if ($filteredAdapters.Count -eq 0) { break }

                $retryPolicy = if ($State.retryPolicy) { ([string]$State.retryPolicy).Trim().ToLowerInvariant() } else { 'leastloaded' }
                if ($retryPolicy -eq 'weightedrandom') {
                    $ftw = 0.0
                    foreach ($w in $filteredWeights) { $ftw += [double]$w }
                    $adapter = $filteredAdapters[0]
                    if ($ftw -gt 0) {
                        $fr = Get-Random -Minimum 0.0 -Maximum $ftw
                        $fc = 0.0
                        for ($fi = 0; $fi -lt $filteredAdapters.Count; $fi++) {
                            $fc += [double]$filteredWeights[$fi]
                            if ($fr -lt $fc) { $adapter = $filteredAdapters[$fi]; break }
                        }
                    }
                } else {
                    # Default retry path: least-loaded remaining adapter normalized by learned weight/capacity.
                    $weightFloor = if ($null -ne $State.retryWeightFloor -and [double]$State.retryWeightFloor -gt 0) { [double]$State.retryWeightFloor } else { 0.25 }
                    $bestRetryIdx = 0
                    $bestRetryScore = [double]::MaxValue
                    for ($fi = 0; $fi -lt $filteredAdapters.Count; $fi++) {
                        $retryName = $filteredAdapters[$fi].Name
                        $retryActive = if ($State.activePerAdapter.ContainsKey($retryName)) { [int]$State.activePerAdapter[$retryName] } else { 0 }
                        $retryWeight = if ($fi -lt $filteredWeights.Count -and [double]$filteredWeights[$fi] -gt 0) { [double]$filteredWeights[$fi] } else { 1.0 }
                        $retryScore = [double]$retryActive / [math]::Max($weightFloor, $retryWeight)
                        if ($retryScore -lt $bestRetryScore) {
                            $bestRetryScore = $retryScore
                            $bestRetryIdx = $fi
                        }
                    }
                    $adapter = $filteredAdapters[$bestRetryIdx]
                }
            }
            $usedNames += $adapter.Name

            $rHost = $targetHost
            $resolvedTargets = Resolve-TargetAddresses -ProxyState $State -TargetHost $rHost -AdapterName ([string]$adapter.Name)
            if ($resolvedTargets.Count -eq 0) {
                $resolvedTargets = @($rHost)
            }

            try {
                if (-not $adapter.IP -or $adapter.IP -match '^169\.254\.') {
                    $State.failCounts[$adapter.Name]++
                    $State.totalFails++
                    continue
                }

                if ($connAdapter -ne $adapter.Name) {
                    $lockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
                    [System.Threading.Monitor]::Enter($lockObj)
                    try {
                        if ($connAdapter -and $State.activePerAdapter.ContainsKey($connAdapter)) {
                            $State.activePerAdapter[$connAdapter] = [math]::Max(0, [int]$State.activePerAdapter[$connAdapter] - 1)
                        }
                        if (-not $State.activePerAdapter.ContainsKey($adapter.Name)) { $State.activePerAdapter[$adapter.Name] = 0 }
                        $State.activePerAdapter[$adapter.Name] = [int]$State.activePerAdapter[$adapter.Name] + 1
                        $connAdapter = $adapter.Name
                        if ($connectionId -and $State.connectionRegistry.ContainsKey($connectionId)) {
                            $State.connectionRegistry[$connectionId].adapter = $adapter.Name
                        }
                    } finally {
                        [System.Threading.Monitor]::Exit($lockObj)
                    }
                }

                $remoteClient = New-Object System.Net.Sockets.TcpClient
                $remoteClient.Client.NoDelay = $true
                try { $remoteClient.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::KeepAlive, $true) } catch {}
                $remoteClient.SendBufferSize = $bufSize
                $remoteClient.ReceiveBufferSize = $bufSize
                $bindIp = $null
                if ($adapter.ParsedIP) {
                    $bindIp = $adapter.ParsedIP
                } elseif ($State.adapterIpCache.ContainsKey($adapter.Name)) {
                    $bindIp = $State.adapterIpCache[$adapter.Name]
                } else {
                    $bindIp = [System.Net.IPAddress]::Parse($adapter.IP)
                }
                if ($adapter.InterfaceIndex -and [int]$adapter.InterfaceIndex -gt 0) {
                    try {
                        $ifOpt = [System.Net.Sockets.SocketOptionName]31
                        $ifIndexBytes = [System.BitConverter]::GetBytes([uint32][int]$adapter.InterfaceIndex)
                        $remoteClient.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, $ifOpt, $ifIndexBytes)
                    } catch {}
                }
                $localEP = New-Object System.Net.IPEndPoint($bindIp, 0)
                $remoteClient.Client.Bind($localEP)
                $remoteClient.SendTimeout = $ioTimeout
                $remoteClient.ReceiveTimeout = $ioTimeout
                $connectTarget = $resolvedTargets[0]
                $connectHost = if ($connectTarget -is [System.Net.IPAddress]) { [string]$connectTarget } else { [string]$connectTarget }
                $ar = $remoteClient.BeginConnect($connectHost, $rPort, $null, $null)
                $connected = $ar.AsyncWaitHandle.WaitOne($State.connectTimeout, $false) -and $remoteClient.Connected
                if ($connected) {
                    try { $remoteClient.EndConnect($ar) } catch {}
                }
                if ($connected -and $remoteClient.Connected) {
                    $State.connectionCounts[$adapter.Name]++
                    $State.successCounts[$adapter.Name]++
                    if ($connectionId -and $State.connectionRegistry.ContainsKey($connectionId)) {
                        $State.connectionRegistry[$connectionId].remote = $remoteClient
                    }
                    break
                }
                try { $remoteClient.Close() } catch {}
                try { $remoteClient.Dispose() } catch {}
                $remoteClient = $null
            } catch {
                try { $remoteClient.Close() } catch {}
                try { $remoteClient.Dispose() } catch {}
                $remoteClient = $null
            }
            $State.failCounts[$adapter.Name]++; $State.totalFails++
        }

        if (-not $remoteClient) {
            $err = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 502 Bad Gateway`r`nConnection: close`r`n`r`n")
            $clientStream.Write($err, 0, $err.Length); $ClientSocket.Close(); return
        }

        $remoteStream = $remoteClient.GetStream()
        $remoteStream.ReadTimeout = $ioTimeout
        $remoteStream.WriteTimeout = $ioTimeout
        $clientStream.WriteTimeout = $ioTimeout

        if ($method -eq 'CONNECT') {
            # [V5-FIX-11] HTTPS TUNNELING: Forward tunnel without modification -- NO MITM.
            # Hostname classification already occurred. Tunnel remains entirely encrypted.
            # Event logging disabled here to avoid log spam, as millions of tunnels happen per day.
            
            $ok = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n")
            $clientStream.Write($ok, 0, $ok.Length); $clientStream.Flush()
            $prefetchRemaining = $prefetchedBodyBytes.Length - $prefetchedBodyOffset
            if ($prefetchRemaining -gt 0) {
                # Preserve any CONNECT payload bytes already read with headers (e.g. early TLS ClientHello).
                $remoteStream.Write($prefetchedBodyBytes, $prefetchedBodyOffset, $prefetchRemaining)
                $prefetchedBodyOffset += $prefetchRemaining
                $remoteStream.Flush()
            }
            # Bidirectional TCP relay -- correct teardown pattern:
            # 1. WhenAny: wait until the FIRST direction closes (server sends full response -> r2c done)
            # 2. WhenAll (short grace window): drain any remaining bytes in the other direction before closing
            # Avoid hard total-lifetime caps that would truncate valid long-lived tunnels.
            $c2r = $clientStream.CopyToAsync($remoteStream, $bufSize)
            $r2c = $remoteStream.CopyToAsync($clientStream, $bufSize)
            try { [System.Threading.Tasks.Task]::WhenAny($c2r, $r2c).Wait() } catch {}
            try { [System.Threading.Tasks.Task]::WhenAll($c2r, $r2c).Wait($drainTimeoutMs) } catch {}
        } else {
            $reqPath = $uri.PathAndQuery; if (-not $reqPath) { $reqPath = '/' }
            $req = "$method $reqPath HTTP/1.1`r`n"
            $hasHost = $false; $contentLength = 0; $isChunked = $false
            $forwardHeaders = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ($l -match '^Proxy-') { continue }
                if ($l -match '^Connection:') { continue }
                if ($l -match '^Host:') { $hasHost = $true }
                if ($l -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1]; continue }
                if ($l -match '^Transfer-Encoding:\s*(.+)$') {
                    if ($Matches[1] -match '(?i)\bchunked\b') { $isChunked = $true }
                    $forwardHeaders.Add($l)
                    continue
                }
                $forwardHeaders.Add($l)
            }
            foreach ($headerLine in $forwardHeaders) {
                $req += "$headerLine`r`n"
            }
            if (-not $hasHost) { $req += "Host: $($uri.Host)`r`n" }

            if (-not $isChunked -and $contentLength -gt 0) {
                $req += "Content-Length: $contentLength`r`n"
            }
            $req += "Connection: close`r`n`r`n"
            $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
            $remoteStream.Write($reqBytes, 0, $reqBytes.Length)

            if ($isChunked) {
                Forward-ChunkedRequestBody -InStream $clientStream -OutStream $remoteStream
            } elseif ($contentLength -gt 0) {
                $bodyBuffer = New-Object byte[] ([math]::Min($contentLength, 65536))
                while ($contentLength -gt 0) {
                    $toRead = [math]::Min($contentLength, $bodyBuffer.Length)
                    $br = Read-ClientBytes -Stream $clientStream -Buffer $bodyBuffer -Offset 0 -Count $toRead
                    if ($br -le 0) { break }
                    $remoteStream.Write($bodyBuffer, 0, $br)
                    $contentLength -= $br
                }
            }
            $remoteStream.Flush()

            # Keep response relay uncapped while using async stream IO to reduce blocking in runspace hot paths.
            try { $remoteStream.CopyToAsync($clientStream, $bufSize).GetAwaiter().GetResult() } catch {}
        }

    } catch {
        try {
            $crashLog = Join-Path (Split-Path -Parent $State.eventsFile) "runspace-crash.txt"
            $_ | Out-File -FilePath $crashLog -Append -Encoding UTF8
        } catch {}
    } finally {
        # v5.1: Decrement active connection counters
        $counterLockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
        [System.Threading.Monitor]::Enter($counterLockObj)
        try {
            if ($State.activeConnections -gt 0) { $State.activeConnections = [int]$State.activeConnections - 1 }
        } finally {
            [System.Threading.Monitor]::Exit($counterLockObj)
        }
        if ($connAdapter) {
            $lockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
            [System.Threading.Monitor]::Enter($lockObj)
            try {
                if ($State.activePerAdapter.ContainsKey($connAdapter)) {
                    $State.activePerAdapter[$connAdapter] = [math]::Max(0, [int]$State.activePerAdapter[$connAdapter] - 1)
                }
            } finally {
                [System.Threading.Monitor]::Exit($lockObj)
            }
        }
        if ($hostKey) {
            $hostLockObj = if ($State.hostCounterLock) { $State.hostCounterLock } elseif ($State.activeCounterLock) { $State.activeCounterLock } else { $global:HostCounterLock }
            [System.Threading.Monitor]::Enter($hostLockObj)
            try {
                if ($State.activePerHost.ContainsKey($hostKey)) {
                    $State.activePerHost[$hostKey] = [math]::Max(0, [int]$State.activePerHost[$hostKey] - 1)
                }
            } finally {
                [System.Threading.Monitor]::Exit($hostLockObj)
            }
        }
        if ($connectionId) {
            try { [void]$State.connectionRegistry.Remove($connectionId) } catch {}
        }
        try { if ($remoteStream) { $remoteStream.Dispose() } } catch {}
        try { if ($clientStream) { $clientStream.Dispose() } } catch {}
        try { if ($remoteClient) { $remoteClient.Close() } } catch {}
        try { if ($remoteClient) { $remoteClient.Dispose() } } catch {}
        try { if ($ClientSocket) { $ClientSocket.Close() } } catch {}
        try { if ($ClientSocket) { $ClientSocket.Dispose() } } catch {}
    }
}

# ===== Dynamic Adaptive Runspace Pool =====
$cfgProxy = $null
$startupMode = 'maxspeed'
if (Test-Path $configFile) {
    try {
        $cfgData = Read-JsonFile -Path $configFile -DefaultValue $null
        if ($cfgData) {
            $cfgProxy = $cfgData.proxy
            if ($cfgData.mode) { $startupMode = [string]$cfgData.mode }
        }
    } catch {}
}
$minThreads = if ($cfgProxy -and $cfgProxy.minThreads -gt 0) { [int]$cfgProxy.minThreads } else { 64 }
$maxThreads = if ($cfgProxy -and $cfgProxy.maxThreads -gt 0) { [int]$cfgProxy.maxThreads } else { 768 }
$listenerBacklog = if ($cfgProxy -and $cfgProxy.listenerBacklog -gt 0) { [int]$cfgProxy.listenerBacklog } else { 2048 }
$staleJobTimeoutSec = if ($cfgProxy -and $null -ne $cfgProxy.staleJobTimeoutSec -and [int]$cfgProxy.staleJobTimeoutSec -ge 0) { [int]$cfgProxy.staleJobTimeoutSec } else { 0 }
$throughputStartup = $startupMode -in @('maxspeed', 'download')
if ($throughputStartup) {
    $minThreads = [math]::Max($minThreads, 96)
    $maxThreads = [math]::Max($maxThreads, 512)
}
$currentMaxThreads = if ($throughputStartup) {
    [math]::Min($maxThreads, [math]::Max($minThreads, 192))
} else {
    [math]::Min($maxThreads, [math]::Max($minThreads, 96))
}
$global:ProxyState.currentMaxThreads = $currentMaxThreads
$global:ProxyState.listenerBacklog = $listenerBacklog
$global:ProxyState.staleJobTimeoutSec = $staleJobTimeoutSec

$rsPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($minThreads, $currentMaxThreads)
$rsPool.Open()
$jobs = [System.Collections.Generic.List[object]]::new()

# ===== Main =====
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "    NETFUSION SMART PROXY v6.2                       " -ForegroundColor Cyan
Write-Host "    Production Connection Orchestration Engine        " -ForegroundColor DarkGray
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

try {
    $script:ProxyInstanceMutexHeld = $script:ProxyInstanceMutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $script:ProxyInstanceMutexHeld = $true
}
if (-not $script:ProxyInstanceMutexHeld) {
    Write-Host "  [ERROR] SmartProxy is already running (instance mutex is held)." -ForegroundColor Red
    exit 1
}

Update-AdaptersAndWeights

if ($global:ProxyState.adapters.Count -lt 1) {
    Write-Host "  [ERROR] No usable network adapters found." -ForegroundColor Red
    exit 1
}

Write-Host "  HTTP Proxy:      127.0.0.1:${Port}" -ForegroundColor Green
Write-Host "  Mode:            $($global:ProxyState.currentMode)" -ForegroundColor Green
Write-Host "  Thread pool:     $minThreads-$maxThreads (adaptive)" -ForegroundColor Green
Write-Host "  Session affinity: $($global:ProxyState.sessionTTL)s TTL" -ForegroundColor Green
Write-Host "  Health endpoint: /health (loopback only)" -ForegroundColor Green
Write-Host "  Safety aware:    yes" -ForegroundColor Green
Write-Host ""
foreach ($a in $global:ProxyState.adapters) {
    $i = [array]::IndexOf($global:ProxyState.adapters, $a)
    $w = if ($i -ge 0 -and $i -lt $global:ProxyState.weights.Count) { [math]::Round($global:ProxyState.weights[$i], 2) } else { '?' }
    $h = $global:ProxyState.adapterHealth[$a.Name]
    $flags = ''
    if ($h -and $h.IsDegrading) { $flags = ' [DEGRADING]' }
    Write-Host "  $($a.Name) ($($a.IP)) [$($a.Type)] weight=$w$flags" -ForegroundColor White
}
Write-Host ""
Write-Host "  Configure apps: proxy 127.0.0.1 port ${Port}" -ForegroundColor Yellow
Write-Host ""

Write-ProxyEvent "Proxy v6.2 started on port $Port with $($global:ProxyState.adapters.Count) adapters (Session affinity + Safety)"

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start($listenerBacklog) } catch { Write-Host "  [ERROR] Port ${Port} in use. $_" -ForegroundColor Red; exit 1 }

Update-ProxyStats
$lastRefresh = Get-Date
$lastStatsWrite = Get-Date
$lastLog = Get-Date
$lastCleanup = Get-Date
$lastSessionClean = Get-Date
$lowThreadTimestamp = $null
$acceptTask = $listener.AcceptTcpClientAsync()

try {
    while ($true) {
        $now = Get-Date

        # Refresh adapter data and weights every 5 seconds
        $refreshInterval = if ($global:ProxyState.weightRefreshInterval -gt 0) { [double]$global:ProxyState.weightRefreshInterval } else { 2.0 }
        if (($now - $lastRefresh).TotalSeconds -gt $refreshInterval) {
            Update-AdaptersAndWeights
            $drained = Drain-FailingConnections -ProxyState $global:ProxyState
            if ($drained -gt 0) {
                Write-ProxyEvent "Forced drain closed $drained active connection(s) on failing adapters."
            }
            $lastRefresh = $now
        }
        $statsWriteInterval = if ($global:ProxyState.statsWriteIntervalSec -gt 0) { [double]$global:ProxyState.statsWriteIntervalSec } else { 2.0 }
        if (($now - $lastStatsWrite).TotalSeconds -gt $statsWriteInterval) {
            Update-ProxyStats
            $lastStatsWrite = $now
        }

        # Clean completed jobs and evaluate scaling twice per second so short speed bursts can expand quickly.
        if (($now - $lastCleanup).TotalMilliseconds -gt 500) {
            $toRemove = @()
            $activeCount = 0
            foreach ($j in $jobs) {
                if ($j.Handle.IsCompleted) {
                    $toRemove += $j
                } else {
                    $activeCount++
                    if ($staleJobTimeoutSec -gt 0 -and $null -ne $j['StartTime'] -and (($now - [datetime]$j.StartTime).TotalSeconds -gt $staleJobTimeoutSec)) {
                        # Optional stale-job protection. Disabled by default for long-lived tunnels.
                        try { $j.PS.Stop() } catch {}
                        $toRemove += $j
                    }
                }
            }
            foreach ($j in $toRemove) {
                try { $j.PS.Dispose() } catch {}
                [void]$jobs.Remove($j)
            }
            
            # [V5-FIX-8] Dynamic Thread Pool Scaling Policy
            $activeThreads = $activeCount
            $activeConnectionsForScale = Get-ActiveConnectionCount -ProxyState $global:ProxyState
            $throughputRuntime = $global:ProxyState.currentMode -in @('maxspeed', 'download')
            $headroomTrigger = if ($throughputRuntime) { 20 } else { 8 }
            $scaleStep = if ($throughputRuntime) { 32 } else { 16 }
            $nearCapacity = ($activeThreads -ge ($currentMaxThreads - $headroomTrigger)) -or ($activeConnectionsForScale -ge ($currentMaxThreads - $headroomTrigger))
             
            if ($nearCapacity -and $currentMaxThreads -lt $maxThreads) {
                $targetThreads = [math]::Max(
                    [math]::Max($currentMaxThreads + $scaleStep, $activeThreads + $scaleStep),
                    $activeConnectionsForScale + $scaleStep
                )
                $currentMaxThreads = [math]::Min($maxThreads, $targetThreads)
                $rsPool.SetMaxRunspaces($currentMaxThreads)
                $global:ProxyState.currentMaxThreads = $currentMaxThreads
                Write-ProxyEvent "Pool scaled UP: $currentMaxThreads (activeThreads=$activeThreads, activeConns=$activeConnectionsForScale)"
                Write-Host "  [Scale UP] Thread pool expanded to $currentMaxThreads" -ForegroundColor Cyan
                $lowThreadTimestamp = $null
            } elseif ($activeThreads -lt [math]::Floor($currentMaxThreads * 0.4) -and $activeConnectionsForScale -lt [math]::Floor($currentMaxThreads * 0.4) -and $currentMaxThreads -gt $minThreads) {
                if ($null -eq $lowThreadTimestamp) {
                    $lowThreadTimestamp = $now
                } elseif (($now - $lowThreadTimestamp).TotalSeconds -gt 120) {
                    $currentMaxThreads = [math]::Max($minThreads, $currentMaxThreads - 8)
                    $rsPool.SetMaxRunspaces($currentMaxThreads)
                    $global:ProxyState.currentMaxThreads = $currentMaxThreads
                    Write-ProxyEvent "Pool scaled DOWN: $currentMaxThreads (low usage for 120s, activeThreads=$activeThreads, activeConns=$activeConnectionsForScale)"
                    Write-Host "  [Scale DOWN] Thread pool reduced to $currentMaxThreads" -ForegroundColor Cyan
                    $lowThreadTimestamp = $null
                }
            } else {
                $lowThreadTimestamp = $null
            }

            $lastCleanup = $now
        }

        # v5.0: Clean expired session affinity entries every 60s
        if (($now - $lastSessionClean).TotalSeconds -gt 60) {
            $removedSessions = Clear-ExpiredSessions
            if ($removedSessions -gt 0) {
                Write-ProxyEvent "Cleared $removedSessions expired or invalid session affinity entr$(if($removedSessions -eq 1){'y'}else{'ies'})"
            }
            $removedUploadHints = Clear-ExpiredUploadHostHints
            if ($removedUploadHints -gt 0) {
                Write-ProxyEvent "Cleared $removedUploadHints expired upload-host hint$(if($removedUploadHints -eq 1){''}else{'s'})"
            }
            $lastSessionClean = $now
        }

        if (-not $acceptTask.Wait(100)) {
            continue
        }
        try {
            $client = $acceptTask.GetAwaiter().GetResult()
        } catch {
            $acceptTask = $listener.AcceptTcpClientAsync()
            continue
        }
        $acceptTask = $listener.AcceptTcpClientAsync()

        # Spawn handler in runspace
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $rsPool
        $ps.AddScript($HandlerScript).AddArgument($client).AddArgument($global:ProxyState) | Out-Null
        $handle = $ps.BeginInvoke()
        $jobs.Add(@{ PS = $ps; Handle = $handle; StartTime = $now })

        # Log connection activity
        if (($now - $lastLog).TotalSeconds -gt 1) {
            $s = $global:ProxyState
            $connParts = @()
            foreach ($a in $s.adapters) { $connParts += "$($a.Name):$($s.connectionCounts[$a.Name])" }
            $typeStr = @()
            foreach ($k in @('bulk','interactive','streaming','gaming')) {
                if ($s.connectionTypes.ContainsKey($k)) { $typeStr += "$k=$($s.connectionTypes[$k])" }
            }
            $safeFlag = if ($s.safeMode) { ' [SAFE]' } else { '' }
            $ts = Get-Date -Format 'HH:mm:ss'
            Write-Host "  [$ts] conns=$($s.totalConnections) | $($connParts -join ' | ') | threads=$($jobs.Count) | sessions=$($s.sessionMap.Count)$safeFlag | $($typeStr -join ' ')" -ForegroundColor DarkGray
            $lastLog = $now
        }
    }
} finally {
    try { Update-ProxyStats -Running:$false -ForceDecisionWrite } catch {}
    try { Write-AtomicJson -Path $global:ProxyState.statsFile -Data @{ running = $false } -Depth 3 } catch {}
    $listener.Stop()
    $rsPool.Close()
    # RC-6: Clear system proxy on proxy exit so internet isn't broken
    try {
        $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Set-ItemProperty $inetKey 'ProxyEnable' 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty $inetKey 'ProxyServer' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty $inetKey 'ProxyOverride' -Force -ErrorAction SilentlyContinue
    } catch {
        try { & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyEnable /t REG_DWORD /d 0 /f 2>$null | Out-Null } catch {}
    }
    if ($script:ProxyInstanceMutexHeld -and $script:ProxyInstanceMutex) {
        try { $script:ProxyInstanceMutex.ReleaseMutex() } catch {}
    }
    if ($script:ProxyInstanceMutex) {
        try { $script:ProxyInstanceMutex.Dispose() } catch {}
    }
    Write-ProxyEvent "Proxy stopped -- system proxy cleared"
    Write-Host "`n  Proxy stopped. System proxy cleared." -ForegroundColor Yellow
}

