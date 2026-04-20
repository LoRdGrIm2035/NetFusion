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
    $safe = [Math]::Max(8192, [Math]::Min($RequestedSize, $MaxSize))
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

function Get-ProxyAdapters {
    $adapters = @()
    $ifFile = $global:ProxyState.interfacesFile
    $data = Read-JsonFile -Path $ifFile -DefaultValue $null
    if ($data -and $data.interfaces) {
        foreach ($iface in $data.interfaces) {
            if ($iface.IPAddress -and $iface.Status -eq 'Up') {
                $parsedIp = $null
                try { $parsedIp = [System.Net.IPAddress]::Parse([string]$iface.IPAddress) } catch {}
                $adapters += @{
                    Name = $iface.Name
                    IP = $iface.IPAddress
                    ParsedIP = $parsedIp
                    Type = $iface.Type
                    Speed = $iface.LinkSpeedMbps
                }
            }
        }
    }
    if ($adapters.Count -lt 1) {
        Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN' } | ForEach-Object {
            $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            if ($ip) {
                $type = if ($_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11' -or $_.Name -match 'Wi-Fi') { if ($_.InterfaceDescription -match 'USB') { 'USB-WiFi' } else { 'WiFi' } } elseif ($_.InterfaceDescription -match 'Ethernet') { 'Ethernet' } else { 'Unknown' }
                $parsedIp = $null
                try { $parsedIp = [System.Net.IPAddress]::Parse([string]$ip) } catch {}
                $adapters += @{
                    Name = $_.Name
                    IP = $ip
                    ParsedIP = $parsedIp
                    Type = $type
                    Speed = 100
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
                    Latency     = $_.InternetLatency
                    LatencyEWMA = if ($_.InternetLatencyEWMA) { $_.InternetLatencyEWMA } else { $_.InternetLatency }
                    Jitter      = if ($_.Jitter) { $_.Jitter } else { 0 }
                    SuccessRate = if ($_.SuccessRate) { $_.SuccessRate } else { 100 }
                    Stability   = if ($_.StabilityScore) { $_.StabilityScore } else { 80 }
                    Trend       = if ($_.HealthTrend) { $_.HealthTrend } else { 0 }
                    IsDegrading = if ($_.IsDegrading) { $_.IsDegrading } else { $false }
                    DownloadMbps = if ($_.DownloadMbps) { $_.DownloadMbps } else { 0 }
                    UploadMbps = if ($_.UploadMbps) { $_.UploadMbps } else { 0 }
                    EstimatedDownMbps = $estimate
                    EstimatedUpMbps = $upEstimate
                    LinkSpeedMbps = if ($_.LinkSpeedMbps) { $_.LinkSpeedMbps } else { 0 }
                }
            }
            $s.adapterHealth = $health
            if ($hData.degradation) {
                $degradeHash = @{}
                $hData.degradation.PSObject.Properties | ForEach-Object { $degradeHash[$_.Name] = $_.Value }
                $s.degradationFlags = $degradeHash
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
        # from reducing aggregate utilization in dual-link workloads.
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

        if ($h) {
            $sc = if ($h.Score -gt 0) { $h.Score } else { 40 }
            $isDegrading = $h.IsDegrading -eq $true

            switch ($s.currentMode) {
                'maxspeed' {
                    $w = [math]::Max(1.0, ($sc / 100) * 5.0)
                    if ($a.Type -eq 'Ethernet') { $w *= 2.0 }
                    if ($h.Jitter -gt 30) { $w *= 0.7 }
                    elseif ($h.Jitter -gt 15) { $w *= 0.85 }
                }
                'download' {
                    $w = [math]::Max(0.5, ($a.Speed / 100) * ($sc / 100))
                    if ($a.Type -eq 'Ethernet') { $w *= 1.5 }
                    $w *= [math]::Max(0.5, $h.SuccessRate / 100)
                }
                'streaming' {
                    $lat = if ($h.LatencyEWMA -lt 998) { $h.LatencyEWMA } else { 200 }
                    $w = [math]::Max(0.3, 100 / [math]::Max(1, $lat))
                    if ($a.Type -eq 'Ethernet') { $w *= 2.0 }
                    $w *= [math]::Max(0.5, $h.Stability / 100)
                }
                'gaming' {
                    $lat = if ($h.LatencyEWMA -lt 998) { $h.LatencyEWMA } else { 200 }
                    $w = if ($lat -lt 15) { 12 } elseif ($lat -lt 30) { 6 } elseif ($lat -lt 50) { 3 } else { 1 }
                    if ($a.Type -eq 'Ethernet') { $w *= 3.0 }
                    if ($h.Jitter -gt 20) { $w *= 0.3 }
                    elseif ($h.Jitter -gt 10) { $w *= 0.6 }
                }
                default {
                    $w = [math]::Max(0.5, $sc / 100)
                }
            }

            if ($isDegrading) { $w *= 0.4 }
            if ($h.Trend -lt -2) { $w *= 0.7 }
            elseif ($h.Trend -gt 1) { $w *= 1.15 }
        }

        $weights += [math]::Max(0.1, $w)
        if (-not $s.connectionCounts.ContainsKey($a.Name)) {
            $s.connectionCounts[$a.Name] = 0
            $s.successCounts[$a.Name] = 0
            $s.failCounts[$a.Name] = 0
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
    foreach ($a in $s.adapters) {
        $h = $s.adapterHealth[$a.Name]
        $aStats += @{
            name = $a.Name; type = $a.Type; ip = $a.IP
            connections = $s.connectionCounts[$a.Name]
            successes = $s.successCounts[$a.Name]
            failures = $s.failCounts[$a.Name]
            health = if ($h) { $h.Score } else { 0 }
            latency = if ($h) { $h.LatencyEWMA } else { 999 }
            jitter = if ($h) { $h.Jitter } else { 0 }
            isDegrading = if ($h) { $h.IsDegrading } else { $false }
        }
    }
    # Build per-adapter active counts
    $activePerAdapterSnap = @{}
    foreach ($a in $s.adapters) {
        $activePerAdapterSnap[$a.Name] = if ($s.activePerAdapter.ContainsKey($a.Name)) { $s.activePerAdapter[$a.Name] } else { 0 }
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
        activeConnections = $s.activeConnections
        activePerAdapter = $activePerAdapterSnap
        adapterCount = $s.adapters.Count; adapters = $aStats
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
        timestamp = (Get-Date).ToString('o')
    }
    try { Write-AtomicJson -Path $s.statsFile -Data $statsSnapshot -Depth 3 } catch {}

    $decisionHash = ''
    if ($s.decisions.Count -gt 0 -and $s.decisions[0].time) {
        $decisionHash = [string]$s.decisions[0].time
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
            [string]$Host,
            [string]$Reason,
            [long]$ClientToRemoteBytes = 0,
            [long]$RemoteToClientBytes = 0
        )

        if ([string]::IsNullOrWhiteSpace($Host)) { return }
        $entry = @{
            time = (Get-Date)
            reason = $Reason
            clientToRemoteBytes = $ClientToRemoteBytes
            remoteToClientBytes = $RemoteToClientBytes
        }
        [void]$ProxyState.uploadHostHints.AddOrUpdate([string]$Host, $entry, { param($k, $v) $entry })
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

    $connAdapter = $null  # track which adapter this connection uses
    $hostKey = $null
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
            Set-UploadHostHint -ProxyState $State -Host $targetHost -Reason 'http-upload-signal' -ClientToRemoteBytes ([math]::Max($requestContentLength, $uploadContentLength)) -RemoteToClientBytes 0
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
                # so multi-session workloads distribute across both links sooner.
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
            # Safe mode: use first adapter only (most reliable, default Windows behavior)
            $selectionReason = 'safe-mode(single-adapter)'
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
                            $cachedAdapter = $found
                            $selectionReason = "session-affinity($connType)"
                            $affinityMode = "sticky"
                        }
                    }
                }
            }

            if ($cachedAdapter) {
                $adapter = $cachedAdapter
            } elseif ($connType -eq 'gaming') {
                # Gaming: strict lowest-latency, single best adapter only
                $bestIdx = 0; $bestScore = -1
                for ($i = 0; $i -lt $avail.Count; $i++) {
                    $aHealth = $State.adapterHealth[$avail[$i].Name]
                    $latScore = 0
                    if ($aHealth) {
                        $lat = if ($aHealth.LatencyEWMA -lt 998) { $aHealth.LatencyEWMA } else { 200 }
                        $latScore = 1000 / [math]::Max(1, $lat)
                        if ($avail[$i].Type -eq 'Ethernet') { $latScore *= 3 }
                        if ($aHealth.IsDegrading) { $latScore *= 0.3 }
                    }
                    if ($latScore -gt $bestScore) { $bestScore = $latScore; $bestIdx = $i }
                }
                $adapter = $avail[$bestIdx]
                $selectionReason = "lowest-latency(gaming)"
                $affinityMode = "new-sticky"
            } elseif ($connType -eq 'streaming') {
                # Streaming: weighted selection heavily favoring best adapter (~80/20 split)
                # This gives secondary adapter some traffic without breaking session affinity
                $latWeights = @()
                for ($i = 0; $i -lt $avail.Count; $i++) {
                    $aHealth = $State.adapterHealth[$avail[$i].Name]
                    $latW = 1.0
                    if ($aHealth) {
                        $lat = if ($aHealth.LatencyEWMA -lt 998) { $aHealth.LatencyEWMA } else { 200 }
                        $latW = [math]::Max(0.5, 1000 / [math]::Max(1, $lat))
                        if ($avail[$i].Type -eq 'Ethernet') { $latW *= 2.5 }
                        if ($aHealth.IsDegrading) { $latW *= 0.2 }
                    }
                    $latWeights += $latW
                }
                $sumLW = 0; foreach ($lw in $latWeights) { $sumLW += $lw }
                if ($sumLW -gt 0) {
                    $rnd = Get-Random -Maximum $sumLW
                    $cum = 0; $selIdx = 0
                    for ($k = 0; $k -lt $latWeights.Count; $k++) {
                        $cum += $latWeights[$k]
                        if ($rnd -lt $cum) { $selIdx = $k; break }
                    }
                    $adapter = $avail[$selIdx]
                } else { $adapter = $avail[0] }
                $selectionReason = "weighted-latency(streaming)"
                $affinityMode = "new-sticky"
            } elseif ($connType -eq 'interactive') {
                # Strict round-robin per NEW HOST
                $idx = $State.rrIndex % $avail.Count
                $adapter = $avail[$idx]
                $State.rrIndex++
                $selectionReason = "round-robin(new-host)"
                $affinityMode = "new-sticky"
            } else {
                # Bulk Traffic: capacity-aware least-busy scheduling.
                # Health-only balancing can overload the slower adapter and reduce
                # total throughput, so bias by link capability as well.
                $bulkPressureThreshold = if ($null -ne $State.bulkPressureThreshold -and [int]$State.bulkPressureThreshold -ge 1) { [int]$State.bulkPressureThreshold } else { 24 }
                $throughputMode = $State.currentMode -in @('maxspeed', 'download')
                if ($throughputMode) {
                    $bulkPressureThreshold = [math]::Min($bulkPressureThreshold, [math]::Max(6, $avail.Count * 4))
                }
                $bulkHeadroomWeight = if ($null -ne $State.bulkHeadroomWeight) { [double]$State.bulkHeadroomWeight } else { 0.35 }
                $bulkHeadroomWeight = [math]::Max(0.0, [math]::Min(1.0, $bulkHeadroomWeight))

                # Throughput mode: serialize bulk selection + reservation so concurrent bursts
                # cannot herd to one adapter before active counters update.
                $bulkLockObj = if ($State.activeCounterLock) { $State.activeCounterLock } else { $global:ActiveCounterLock }
                $bulkLockTaken = $false
                if ($throughputMode) {
                    [System.Threading.Monitor]::Enter($bulkLockObj)
                    $bulkLockTaken = $true
                }
                try {
                    $bulkGlobalActive = Get-LockedActiveConnections -ProxyState $State
                    $trackedActive = 0
                    foreach ($ta in $avail) {
                        $trackedActive += if ($State.activePerAdapter.ContainsKey($ta.Name)) { [int]$State.activePerAdapter[$ta.Name] } else { 0 }
                    }
                    if ($trackedActive -gt 0) { $bulkGlobalActive = $trackedActive }

                    $bestBulkIdx = 0
                    $bestBulkScore = [double]::MaxValue
                    for ($bi = 0; $bi -lt $avail.Count; $bi++) {
                        $aName  = $avail[$bi].Name
                        $active = if ($State.activePerAdapter.ContainsKey($aName)) { [int]($State.activePerAdapter[$aName]) } else { 0 }
                        $aHealth = $State.adapterHealth[$aName]
                        $linkMbps = 100.0
                        if ($null -ne $avail[$bi].Speed -and [double]$avail[$bi].Speed -gt 0) {
                            $linkMbps = [double]$avail[$bi].Speed
                        }
                        if ($aHealth -and $null -ne $aHealth.LinkSpeedMbps -and [double]$aHealth.LinkSpeedMbps -gt 0) {
                            $linkMbps = [double]$aHealth.LinkSpeedMbps
                        }

                        # Bulk flows can be upload-heavy or download-heavy. Use the strongest
                        # observed direction so scheduling is not biased by download-only telemetry.
                        $observedMbps = 0.0
                        if ($aHealth -and $null -ne $aHealth.EstimatedDownMbps -and [double]$aHealth.EstimatedDownMbps -gt $observedMbps) {
                            $observedMbps = [double]$aHealth.EstimatedDownMbps
                        }
                        if ($aHealth -and $null -ne $aHealth.EstimatedUpMbps -and [double]$aHealth.EstimatedUpMbps -gt $observedMbps) {
                            $observedMbps = [double]$aHealth.EstimatedUpMbps
                        }
                        if ($aHealth -and $null -ne $aHealth.DownloadMbps -and [double]$aHealth.DownloadMbps -gt $observedMbps) {
                            $observedMbps = [double]$aHealth.DownloadMbps
                        }
                        if ($aHealth -and $null -ne $aHealth.UploadMbps -and [double]$aHealth.UploadMbps -gt $observedMbps) {
                            $observedMbps = [double]$aHealth.UploadMbps
                        }

                        $linkSpeedFactor = [math]::Max(1.0, [math]::Min(6.0, [math]::Sqrt([math]::Max(50.0, $linkMbps) / 50.0)))
                        # Do not treat tiny/idle observed throughput as hard capacity; it causes
                        # starvation loops where an underused adapter never gets enough new flows.
                        $observedEligibleMbps = if ($observedMbps -ge 15.0) { $observedMbps } else { 0.0 }
                        if ($observedEligibleMbps -gt 0) {
                            $speedFactor = [math]::Max(1.0, [math]::Min(12.0, $observedEligibleMbps / 5.0))
                            $speedFactor = [math]::Max($linkSpeedFactor, $speedFactor)
                        } else {
                            $speedFactor = $linkSpeedFactor
                        }

                        $healthFactor = 0.6
                        $successFactor = 1.0
                        $stabilityFactor = 0.8
                        $latencyPenalty = 1.0
                        if ($aHealth) {
                            if ($null -ne $aHealth.Score -and [double]$aHealth.Score -gt 0) {
                                $healthFactor = [math]::Max(0.35, [double]$aHealth.Score / 100.0)
                            }
                            if ($null -ne $aHealth.SuccessRate -and [double]$aHealth.SuccessRate -gt 0) {
                                $successFactor = [math]::Max(0.4, [double]$aHealth.SuccessRate / 100.0)
                            }
                            if ($null -ne $aHealth.Stability -and [double]$aHealth.Stability -gt 0) {
                                $stabilityFactor = [math]::Max(0.5, [double]$aHealth.Stability / 100.0)
                            }

                            $lat = if ($null -ne $aHealth.LatencyEWMA) { [double]$aHealth.LatencyEWMA } else { 999.0 }
                            if ($lat -gt 150) {
                                $latencyPenalty = 0.55
                            } elseif ($lat -gt 80) {
                                $latencyPenalty = 0.75
                            } elseif ($lat -gt 40) {
                                $latencyPenalty = 0.9
                            }

                            if ($aHealth.IsDegrading) { $latencyPenalty *= 0.5 }
                        }

                        $capacity = [math]::Max(0.25, ($speedFactor * $healthFactor * $successFactor * $stabilityFactor * $latencyPenalty))

                        # Headroom feedback: bias toward adapters with available observed throughput room.
                        $capacityEstimateMbps = 0.0
                        if ($linkMbps -gt 0 -and $linkMbps -lt 10000) {
                            $capacityEstimateMbps = [math]::Max(50.0, $linkMbps * 0.35)
                        }
                        if ($observedEligibleMbps -gt 0) {
                            $observedCeiling = [math]::Max(50.0, $observedEligibleMbps * 1.6)
                            if ($capacityEstimateMbps -gt 0) {
                                $capacityEstimateMbps = [math]::Min([math]::Max($capacityEstimateMbps, $observedCeiling), [math]::Max($linkMbps, $observedCeiling))
                            } else {
                                $capacityEstimateMbps = $observedCeiling
                            }
                        }
                        if ($capacityEstimateMbps -le 0) { $capacityEstimateMbps = 120.0 }

                        $utilizationBasis = if ($observedEligibleMbps -gt 0) { $observedEligibleMbps } else { 0.0 }
                        $utilization = if ($capacityEstimateMbps -gt 0) { [math]::Min(1.0, [math]::Max(0.0, $utilizationBasis / $capacityEstimateMbps)) } else { 0.0 }
                        $headroom = [math]::Max(0.1, [math]::Min(1.0, 1.0 - $utilization))
                        $headroomFactor = 1.0 + (($headroom - 0.5) * 2.0 * $bulkHeadroomWeight)
                        $headroomFactor = [math]::Max(0.6, [math]::Min(1.6, $headroomFactor))
                        $capacity *= $headroomFactor

                        # High-pressure fairness boost: discourage over-concentrating bulk flows on one adapter
                        # during sustained multi-flow workloads.
                        if ($bulkGlobalActive -ge $bulkPressureThreshold -and $avail.Count -gt 1) {
                            $targetShare = 1.0 / [double]$avail.Count
                            $activeShare = if ($bulkGlobalActive -gt 0) { [double]$active / [double]$bulkGlobalActive } else { 0.0 }
                            $penaltyStrength = if ($throughputMode) { 0.55 } else { 0.35 }
                            $boostStrength = if ($throughputMode) { 0.25 } else { 0.15 }
                            if ($activeShare -gt $targetShare) {
                                $excessRatio = [math]::Min(1.0, ($activeShare - $targetShare) / [math]::Max(0.01, $targetShare))
                                $capacity *= [math]::Max(0.55, 1.0 - ($penaltyStrength * $excessRatio))
                            } else {
                                $spareRatio = [math]::Min(1.0, ($targetShare - $activeShare) / [math]::Max(0.01, $targetShare))
                                $capacity *= [math]::Min(1.35, 1.0 + ($boostStrength * $spareRatio))
                            }
                        }

                        # Score = active connections / capacity. Lower = better candidate.
                        # Add a small constant so zero-active ties are still resolved by capacity.
                        $score = ([double]$active + 0.25) / [math]::Max(1.0, $capacity)
                        if ($score -lt $bestBulkScore) { $bestBulkScore = $score; $bestBulkIdx = $bi }
                    }
                    $adapter = $avail[$bestBulkIdx]
                    if ($throughputMode) {
                        if (-not $State.activePerAdapter.ContainsKey($adapter.Name)) { $State.activePerAdapter[$adapter.Name] = 0 }
                        $State.activePerAdapter[$adapter.Name] = [int]$State.activePerAdapter[$adapter.Name] + 1
                        $connAdapter = $adapter.Name
                    }
                    $selectionReason = "active-load-balanced-bulk"
                } finally {
                    if ($bulkLockTaken) {
                        [System.Threading.Monitor]::Exit($bulkLockObj)
                    }
                }
            }

            if (-not $skipAffinity -and $State.sessionMap.Count -le 2000) {
                $State.sessionMap[$sessionKey] = @{ adapter = $adapter.Name; time = (Get-Date) }
            }
        }

        # Log decision
        $decision = @{
            time = (Get-Date).ToString('HH:mm:ss')
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
                    } finally {
                        [System.Threading.Monitor]::Exit($lockObj)
                    }
                }

                $remoteClient = New-Object System.Net.Sockets.TcpClient
                $remoteClient.Client.NoDelay = $true
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
                $localEP = New-Object System.Net.IPEndPoint($bindIp, 0)
                $remoteClient.Client.Bind($localEP)
                $remoteClient.SendTimeout = $ioTimeout
                $remoteClient.ReceiveTimeout = $ioTimeout
                $ar = $remoteClient.BeginConnect($rHost, $rPort, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne($State.connectTimeout, $false) -and $remoteClient.Connected) {
                    try { $remoteClient.EndConnect($ar) } catch {}
                    $State.connectionCounts[$adapter.Name]++
                    $State.successCounts[$adapter.Name]++
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

            # Keep response relay uncapped to avoid truncating valid long-running transfers.
            try { $remoteStream.CopyTo($clientStream, $bufSize) } catch {}
        }

    } catch {} finally {
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
                $targetThreads = [math]::Max($currentMaxThreads + $scaleStep, $activeThreads + $scaleStep, $activeConnectionsForScale + $scaleStep)
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
    Write-ProxyEvent "Proxy stopped"
    Write-Host "`n  Proxy stopped." -ForegroundColor Yellow
}

