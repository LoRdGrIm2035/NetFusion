<#
.SYNOPSIS
    SmartProxy v5.0 -- Production-grade intelligent connection orchestration engine.
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
    activePerAdapter  = [hashtable]::Synchronized(@{})      # v5.1: per-adapter active counts
    activePerHost     = [hashtable]::Synchronized(@{})      # v5.1: per-host active counts for dynamic bulk detection
    currentMode      = 'maxspeed'
    rrIndex          = 0
    connectTimeout   = 5000
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
    activeConns      = @{}
    bufferSizes      = @{
        'bulk'        = 524288   # 512KB for downloads (maximum throughput pipes)
        'interactive' = 32768    # 32KB for browsing
        'streaming'   = 262144   # 256KB for streaming (smooth 4K playback)
        'gaming'      = 8192     # 8KB for gaming (low latency)
        'default'     = 131072   # 128KB default
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

function Write-ProxyEvent {
    param([string]$Message)
    try {
        $ef = $global:ProxyState.eventsFile
        $events = @()
        if (Test-Path $ef) {
            $data = Get-Content $ef -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($data -and $data.events) { $events = @($data.events) }
        }
        $evt = @{ timestamp = (Get-Date).ToString('o'); type = 'proxy'; adapter = ''; message = $Message }
        $events = @($evt) + $events
        if ($events.Count -gt 200) { $events = $events[0..199] }
        @{ events = $events } | ConvertTo-Json -Depth 3 -Compress | Set-Content $ef -Force -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Get-ProxyAdapters {
    $adapters = @()
    $ifFile = $global:ProxyState.interfacesFile
    if (Test-Path $ifFile) {
        try {
            $data = Get-Content $ifFile -Raw | ConvertFrom-Json
            foreach ($iface in $data.interfaces) {
                if ($iface.IPAddress -and $iface.Status -eq 'Up') {
                    $adapters += @{ Name = $iface.Name; IP = $iface.IPAddress; Type = $iface.Type; Speed = $iface.LinkSpeedMbps }
                }
            }
        } catch {}
    }
    if ($adapters.Count -lt 1) {
        Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN' } | ForEach-Object {
            $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            if ($ip) {
                $type = if ($_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11' -or $_.Name -match 'Wi-Fi') { if ($_.InterfaceDescription -match 'USB') { 'USB-WiFi' } else { 'WiFi' } } elseif ($_.InterfaceDescription -match 'Ethernet') { 'Ethernet' } else { 'Unknown' }
                $adapters += @{ Name = $_.Name; IP = $ip; Type = $type; Speed = 100 }
            }
        }
    }
    return $adapters
}

function Update-AdaptersAndWeights {
    $s = $global:ProxyState
    $s.adapters = @(Get-ProxyAdapters)

    # v5.0: Check safe mode
    if (Test-Path $s.safetyFile) {
        try {
            $safety = Get-Content $s.safetyFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($safety -and $safety.safeMode -eq $true) {
                $s.safeMode = $true
            } else {
                $s.safeMode = $false
            }
        } catch {}
    }

    # Read health data from InterfaceMonitor
    $health = @{}
    if (Test-Path $s.healthFile) {
        try {
            $hData = Get-Content $s.healthFile -Raw | ConvertFrom-Json
            $hData.adapters | ForEach-Object {
                $health[$_.Name] = @{
                    Score       = $_.HealthScore
                    Latency     = $_.InternetLatency
                    LatencyEWMA = if ($_.InternetLatencyEWMA) { $_.InternetLatencyEWMA } else { $_.InternetLatency }
                    Jitter      = if ($_.Jitter) { $_.Jitter } else { 0 }
                    SuccessRate = if ($_.SuccessRate) { $_.SuccessRate } else { 100 }
                    Stability   = if ($_.StabilityScore) { $_.StabilityScore } else { 80 }
                    Trend       = if ($_.HealthTrend) { $_.HealthTrend } else { 0 }
                    IsDegrading = if ($_.IsDegrading) { $_.IsDegrading } else { $false }
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
        try { $s.currentMode = (Get-Content $s.configFile -Raw | ConvertFrom-Json).mode } catch {}
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
    @{
        running = $true; port = $s.port; mode = $s.currentMode
        totalConnections = $s.totalConnections; totalFailures = $s.totalFails
        activeConnections = $s.activeConnections
        activePerAdapter = $activePerAdapterSnap
        adapterCount = $s.adapters.Count; adapters = $aStats
        connectionTypes = $s.connectionTypes
        safeMode = $s.safeMode
        sessionMapSize = $s.sessionMap.Count
        currentMaxThreads = $s.currentMaxThreads
        timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 3 -Compress | Set-Content $s.statsFile -Force -ErrorAction SilentlyContinue

    try {
        @{ decisions = $s.decisions } | ConvertTo-Json -Depth 3 -Compress | Set-Content $s.decisionsFile -Force -ErrorAction SilentlyContinue
    } catch {}
}

# v5.0: Clean expired session affinity entries
function Clear-ExpiredSessions {
    $s = $global:ProxyState
    $now = Get-Date
    $expired = @()
    foreach ($key in @($s.sessionMap.Keys)) {
        $entry = $s.sessionMap[$key]
        if ($entry -and $entry.time -and (($now - $entry.time).TotalSeconds -gt $s.sessionTTL)) {
            $expired += $key
        }
    }
    foreach ($key in $expired) {
        $s.sessionMap.Remove($key)
    }
}

# ===== Connection Handler ScriptBlock (runs in separate runspace) =====
$HandlerScript = {
    param($ClientSocket, $State)

    $connAdapter = $null  # track which adapter this connection uses
    try {
        # v5.0: Safe mode check -- if active, act as simple pass-through on default adapter
        $isSafeMode = $State.safeMode

        $clientStream = $ClientSocket.GetStream()
        $clientStream.ReadTimeout = 10000

        # Read initial request
        $buf = New-Object byte[] 16384
        $n = $clientStream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { $ClientSocket.Close(); return }
        $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        $lines = $text -split "`r`n"
        $parts = $lines[0] -split ' '
        $method = $parts[0].ToUpper()

        # ===== v5.0: Health check endpoint for SafetyController =====
        if ($method -eq 'GET' -and $parts.Count -ge 2 -and $parts[1] -eq '/health') {
            $resp = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK")
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
            if ($target -match '^\[(.*)\]:(\d+)$') {
                $targetHost = $Matches[1]
                $rPort = [int]$Matches[2]
            } else {
                $idx = $target.LastIndexOf(':')
                if ($idx -gt 0) {
                    $targetHost = $target.Substring(0, $idx)
                    $rPort = [int]($target.Substring($idx + 1))
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

        # Note: L7 connection type detection using regex heuristics was replaced by strict L4 Arbitration Table in v5.1

        # v5.1: Track host concurrency for dynamic download manager detection
        $hostKey = $targetHost
        if (-not $State.activePerHost.ContainsKey($hostKey)) { $State.activePerHost[$hostKey] = 0 }
        $State.activePerHost[$hostKey]++
        $activeHostCount = $State.activePerHost[$hostKey]

        $portClasses = $State.portClasses
        $gamingPorts = if ($portClasses -and $portClasses.gaming) { @($portClasses.gaming) } else { @() }
        $voicePorts = if ($portClasses -and $portClasses.voice) { @($portClasses.voice) } else { @() }
        $bulkPorts = if ($portClasses -and $portClasses.bulk) { @($portClasses.bulk) } else { @() }

        if ($rPort -in $gamingPorts) { 
            $connType = 'gaming' 
        } elseif ($rPort -in $voicePorts) { 
            $connType = 'voice' 
        } elseif ($rPort -in $bulkPorts) { 
            $connType = 'bulk' 
        } elseif ($rPort -eq 443 -or $rPort -eq 80) { 
            if ($activeHostCount -gt 2 -and $State.currentMode -in @('maxspeed', 'download')) {
                $connType = 'bulk'  # High concurrency detected -> Multi-part download aggregation!
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
        $State.totalConnections++
        $State.activeConnections++

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
                # Bulk Traffic: Active-load-aware round-robin
                # v6.1: Uses actual health score to weight distribution, NOT theoretical link speed.
                # Link speed (866 vs 130 Mbps) reflects radio capability, not ISP throughput.
                # When adapters share the same gateway, their real internet speed is similar,
                # so we balance by active connection count weighted by health score.
                $bestBulkIdx = 0
                $bestBulkScore = [double]::MaxValue
                for ($bi = 0; $bi -lt $avail.Count; $bi++) {
                    $aName  = $avail[$bi].Name
                    $active = if ($State.activePerAdapter.ContainsKey($aName)) { [int]($State.activePerAdapter[$aName]) } else { 0 }
                    # Use health score as capacity proxy (0-100). Higher health = more capacity.
                    $aHealth = $State.adapterHealth[$aName]
                    $capacity = if ($aHealth -and $aHealth.Score -gt 0) { [double]$aHealth.Score } else { 50.0 }
                    # Score = active connections / capacity. Lower = better candidate.
                    $score = [double]$active / [math]::Max(1.0, $capacity)
                    if ($score -lt $bestBulkScore) { $bestBulkScore = $score; $bestBulkIdx = $bi }
                }
                $adapter = $avail[$bestBulkIdx]
                $selectionReason = "active-load-balanced-bulk"
            }

            if (-not $skipAffinity) {
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
        $maxRetries = [math]::Min($avail.Count, 3)
        $usedNames = @()

        for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
            if ($attempt -gt 0) {
                $filteredAdapters = @(); $filteredWeights = @()
                for ($fi = 0; $fi -lt $avail.Count; $fi++) {
                    if ($avail[$fi].Name -notin $usedNames) { $filteredAdapters += $avail[$fi]; $filteredWeights += $aw[$fi] }
                }
                if ($filteredAdapters.Count -eq 0) { break }
                $ftw = 0; $filteredWeights | ForEach-Object { $ftw += $_ }
                $adapter = $filteredAdapters[0]
                if ($ftw -gt 0) {
                    $fr = Get-Random -Minimum 0.0 -Maximum $ftw; $fc = 0
                    for ($fi = 0; $fi -lt $filteredAdapters.Count; $fi++) { $fc += $filteredWeights[$fi]; if ($fr -lt $fc) { $adapter = $filteredAdapters[$fi]; break } }
                }
            }
            $usedNames += $adapter.Name

            if ($method -ne 'CONNECT') {
                try { $uri = [System.Uri]$parts[1] } catch { $ClientSocket.Close(); return }
                $rHost = $uri.Host; $rPort = if ($uri.Port -gt 0 -and $uri.Port -ne -1) { $uri.Port } else { 80 }
            } else {
                $rHost = $targetHost
            }

            try {
                if ($connAdapter -ne $adapter.Name) {
                    if ($connAdapter -and $State.activePerAdapter.ContainsKey($connAdapter)) {
                        $State.activePerAdapter[$connAdapter] = [math]::Max(0, [int]$State.activePerAdapter[$connAdapter] - 1)
                    }
                    if (-not $State.activePerAdapter.ContainsKey($adapter.Name)) { $State.activePerAdapter[$adapter.Name] = 0 }
                    $State.activePerAdapter[$adapter.Name] = [int]$State.activePerAdapter[$adapter.Name] + 1
                    $connAdapter = $adapter.Name
                }

                $remoteClient = New-Object System.Net.Sockets.TcpClient
                $remoteClient.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::Linger, (New-Object System.Net.Sockets.LingerOption($true, 1)))
                $remoteClient.SendBufferSize = $bufSize
                $remoteClient.ReceiveBufferSize = $bufSize
                $localEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($adapter.IP), 0)
                $remoteClient.Client.Bind($localEP)
                $remoteClient.SendTimeout = 15000; $remoteClient.ReceiveTimeout = 15000
                $ar = $remoteClient.BeginConnect($rHost, $rPort, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(5000, $false) -and $remoteClient.Connected) {
                    try { $remoteClient.EndConnect($ar) } catch {}
                    $State.connectionCounts[$adapter.Name]++
                    $State.successCounts[$adapter.Name]++
                    break
                }
                try { $remoteClient.Close() } catch {}; $remoteClient = $null
            } catch {
                try { $remoteClient.Close() } catch {}; $remoteClient = $null
            }
            $State.failCounts[$adapter.Name]++; $State.totalFails++
        }

        if (-not $remoteClient) {
            $err = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 502 Bad Gateway`r`nConnection: close`r`n`r`n")
            $clientStream.Write($err, 0, $err.Length); $ClientSocket.Close(); return
        }

        $remoteStream = $remoteClient.GetStream()

        if ($method -eq 'CONNECT') {
            # [V5-FIX-11] HTTPS TUNNELING: Forward tunnel without modification -- NO MITM.
            # Hostname classification already occurred. Tunnel remains entirely encrypted.
            # Event logging disabled here to avoid log spam, as millions of tunnels happen per day.
            
            $ok = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n")
            $clientStream.Write($ok, 0, $ok.Length); $clientStream.Flush()
            # Bidirectional TCP relay -- correct teardown pattern:
            # 1. WhenAny: wait until the FIRST direction closes (server sends full response -> r2c done)
            # 2. WhenAll (8s grace): drain any remaining bytes in the other direction before closing
            # This prevents thread starvation (WhenAll alone held threads for 90s per tunnel)
            $c2r = $clientStream.CopyToAsync($remoteStream, $bufSize)
            $r2c = $remoteStream.CopyToAsync($clientStream, $bufSize)
            try { [System.Threading.Tasks.Task]::WhenAny($c2r, $r2c).Wait(85000) } catch {}
            try { [System.Threading.Tasks.Task]::WhenAll($c2r, $r2c).Wait(5000) } catch {}
        } else {
            $remoteStream.ReadTimeout = 15000
            try { $uri = [System.Uri]$parts[1] } catch { $ClientSocket.Close(); return }
            $reqPath = $uri.PathAndQuery; if (-not $reqPath) { $reqPath = '/' }
            $req = "$method $reqPath HTTP/1.1`r`n"
            $hasHost = $false; $contentLength = 0
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]; if ($l -eq '' -or $l -eq "`r") { break }
                if ($l -match '^Proxy-') { continue }
                if ($l -match '^Connection:') { continue }
                if ($l -match '^Host:') { $hasHost = $true }
                if ($l -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
                $req += "$l`r`n"
            }
            if (-not $hasHost) { $req += "Host: $($uri.Host)`r`n" }
            $req += "Connection: close`r`n`r`n"
            $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
            $remoteStream.Write($reqBytes, 0, $reqBytes.Length)

            if ($contentLength -gt 0) {
                $headerEnd = $text.IndexOf("`r`n`r`n")
                if ($headerEnd -gt 0) {
                    $bodyOffset = $headerEnd + 4
                    $bodyInBuf = $n - [System.Text.Encoding]::ASCII.GetByteCount($text.Substring(0, $bodyOffset))
                    if ($bodyInBuf -gt 0) {
                        $remoteStream.Write($buf, ($n - $bodyInBuf), $bodyInBuf)
                        $contentLength -= $bodyInBuf
                    }
                    while ($contentLength -gt 0) {
                        $toRead = [math]::Min($contentLength, $buf.Length)
                        $br = $clientStream.Read($buf, 0, $toRead)
                        if ($br -le 0) { break }
                        $remoteStream.Write($buf, 0, $br)
                        $contentLength -= $br
                    }
                }
            }
            $remoteStream.Flush()

            # v6.0 SPEED BOOST: Use optimized async pipeline instead of slow string loop
            try { $remoteStream.CopyToAsync($clientStream, $bufSize).Wait(120000) } catch {}
        }

    } catch {} finally {
        # v5.1: Decrement active connection counters
        if ($State.activeConnections -gt 0) { $State.activeConnections-- }
        if ($connAdapter -and $State.activePerAdapter.ContainsKey($connAdapter)) {
            $State.activePerAdapter[$connAdapter] = [math]::Max(0, $State.activePerAdapter[$connAdapter] - 1)
        }
        if ($hostKey -and $State.activePerHost.ContainsKey($hostKey)) {
            $State.activePerHost[$hostKey] = [math]::Max(0, $State.activePerHost[$hostKey] - 1)
        }
        try { if ($remoteClient) { $remoteClient.Close() } } catch {}
        try { if ($ClientSocket) { $ClientSocket.Close() } } catch {}
    }
}

# ===== Dynamic Adaptive Runspace Pool =====
$cfgProxy = $null
if (Test-Path $configFile) {
    try { $cfgProxy = (Get-Content $configFile -Raw | ConvertFrom-Json).proxy } catch {}
}
$minThreads = if ($cfgProxy -and $cfgProxy.minThreads -gt 0) { [int]$cfgProxy.minThreads } else { 64 }
$maxThreads = if ($cfgProxy -and $cfgProxy.maxThreads -gt 0) { [int]$cfgProxy.maxThreads } else { 256 }
$currentMaxThreads = [math]::Min($maxThreads, [math]::Max($minThreads, 96))
$global:ProxyState.currentMaxThreads = $currentMaxThreads

$rsPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($minThreads, $currentMaxThreads)
$rsPool.Open()
$jobs = [System.Collections.Generic.List[object]]::new()

# ===== Main =====
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "    NETFUSION SMART PROXY v5.0                       " -ForegroundColor Cyan
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
Write-Host "  Health endpoint: /health" -ForegroundColor Green
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

Write-ProxyEvent "Proxy v5.0 started on port $Port with $($global:ProxyState.adapters.Count) adapters (Session affinity + Safety)"

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } catch { Write-Host "  [ERROR] Port ${Port} in use. $_" -ForegroundColor Red; exit 1 }

Update-ProxyStats
$lastRefresh = Get-Date
$lastLog = Get-Date
$lastCleanup = Get-Date
$lastSessionClean = Get-Date

try {
    while ($true) {
        $now = Get-Date

        # Refresh adapter data and weights every 5 seconds
        if (($now - $lastRefresh).TotalSeconds -gt 5) {
            Update-AdaptersAndWeights
            Update-ProxyStats
            $lastRefresh = $now
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
                    if ($j.StartTime -and (($now - $j.StartTime).TotalSeconds -gt 180)) {
                        # Stale job -- force dispose (180s timeout, reduced from 600s)
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
            $queueDepth = if ($listener.Pending()) { 5 } else { 0 } # Estimate pending requests
            
            if ($queueDepth -gt 0 -and $activeThreads -ge ($currentMaxThreads - 8) -and $currentMaxThreads -lt $maxThreads) {
                $targetThreads = [math]::Max($currentMaxThreads + 16, $activeThreads + 16)
                $currentMaxThreads = [math]::Min($maxThreads, $targetThreads)
                $rsPool.SetMaxRunspaces($currentMaxThreads)
                $global:ProxyState.currentMaxThreads = $currentMaxThreads
                Write-ProxyEvent "Pool scaled UP: $currentMaxThreads (queue pending, active=$activeThreads)"
                Write-Host "  [Scale UP] Thread pool expanded to $currentMaxThreads" -ForegroundColor Cyan
                $lowThreadTimestamp = $null
            } elseif ($activeThreads -lt [math]::Floor($currentMaxThreads * 0.4) -and $currentMaxThreads -gt $minThreads) {
                if ($null -eq $lowThreadTimestamp) {
                    $lowThreadTimestamp = $now
                } elseif (($now - $lowThreadTimestamp).TotalSeconds -gt 120) {
                    $currentMaxThreads = [math]::Max($minThreads, $currentMaxThreads - 8)
                    $rsPool.SetMaxRunspaces($currentMaxThreads)
                    $global:ProxyState.currentMaxThreads = $currentMaxThreads
                    Write-ProxyEvent "Pool scaled DOWN: $currentMaxThreads (low usage for 120s, active=$activeThreads)"
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
            Clear-ExpiredSessions
            $lastSessionClean = $now
        }

        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 5  # 5ms poll (was 15ms) -- 3x faster new connection acceptance
            continue
        }

        $client = $listener.AcceptTcpClient()

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
    $listener.Stop()
    $rsPool.Close()
    @{ running = $false } | ConvertTo-Json | Set-Content $global:ProxyState.statsFile -Force -ErrorAction SilentlyContinue
    Write-ProxyEvent "Proxy stopped"
    Write-Host "`n  Proxy stopped." -ForegroundColor Yellow
}

