<#
.SYNOPSIS
    InterfaceMonitor v4.0 -- Intelligent adaptive health monitoring with predictive analytics.
.DESCRIPTION
    Production-grade health monitoring with:
      - EWMA (Exponential Weighted Moving Average) smoothed latency
      - Jitter tracking via rolling window variance
      - Rolling statistics engine (min/max/avg/p95)
      - Connection success rate tracking
      - Predictive degradation detection with trend analysis
      - Preemptive rerouting signals
      - Enhanced multi-factor health scoring
    Multi-method health detection:
      1. Direct gateway ping (most reliable)
      2. Internet ping with source binding
      3. DNS resolution test
      4. Bandwidth-based health (if data flows, adapter is alive)
    Writes enriched health data to shared JSON for proxy/router consumption.
#>

[CmdletBinding()]
param(
    [int]$Interval = 2
)

# Resolve paths
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$InterfacesFile = Join-Path $projectDir "config\interfaces.json"
$HealthFile = Join-Path $projectDir "config\health.json"
$LogFile = Join-Path $projectDir "config\throughput.csv"
$EventsFile = Join-Path $projectDir "logs\events.json"

# Ensure logs dir exists
$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

# Load config
$configPath = Join-Path $projectDir "config\config.json"
<<<<<<< HEAD
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
=======
$script:cachedConfig = $null
$script:lastConfigTime = [DateTime]::MinValue
$script:configCacheTtl = [TimeSpan]::FromSeconds(15)

function Get-CachedConfig {
    $now = Get-Date
    if ($script:cachedConfig -and (($now - $script:lastConfigTime) -le $script:configCacheTtl)) {
        return $script:cachedConfig
    }

    if (Test-Path $configPath) {
        try {
            $script:cachedConfig = Get-Content $configPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            $script:lastConfigTime = $now
        } catch {}
    }

    return $script:cachedConfig
}

$config = Get-CachedConfig
>>>>>>> origin/main
$pingTarget = if ($config -and $config.healthCheck -and $config.healthCheck.pingTarget) { $config.healthCheck.pingTarget } else { '8.8.8.8' }
$pingTarget2 = '1.1.1.1'
$pingTimeout = if ($config -and $config.healthCheck -and $config.healthCheck.timeout) { $config.healthCheck.timeout } else { 1500 }

# Intelligence config
$script:ewmaAlpha = 0.30
$jitterWindowSize = if ($config -and $config.intelligence -and $config.intelligence.jitterWindow) { $config.intelligence.jitterWindow } else { 30 }
$healthTrendWindow = if ($config -and $config.intelligence -and $config.intelligence.healthTrendWindow) { $config.intelligence.healthTrendWindow } else { 20 }
$degradationThreshold = if ($config -and $config.intelligence -and $config.intelligence.degradationThreshold) { $config.intelligence.degradationThreshold } else { -2.0 }

# ===== State Tracking =====
$script:prevBytes = @{}     # @{ name = @{ rx=N; tx=N; time=[DateTime] } }
$script:startTime = Get-Date
$script:events = @()
$script:prevStates = @{}
$script:maxCSVLines = 2000

# v4.0 Intelligence State
$script:latencyHistory = @{}        # Rolling latency samples per adapter: @{ name = @(samples) }
$script:ewmaLatency = @{}           # EWMA-smoothed latency per adapter: @{ name = [double] }
$script:ewmaGwLatency = @{}         # EWMA-smoothed gateway latency per adapter
$script:jitterValues = @{}          # Computed jitter per adapter
$script:healthTrend = @{}           # Rolling health scores for trend: @{ name = @(scores) }
$script:successRates = @{}          # Success/fail tracking: @{ name = @{ success=N; fail=N; rate=0.0 } }
$script:degradationWarnings = @{}   # Predictive warnings: @{ name = @{ warned=$bool; trend=$val; since=$time } }
$script:stabilityScores = @{}       # Health variance tracking for stability: @{ name = [double] }

function Write-Event {
    param([string]$Type, [string]$Adapter, [string]$Message)
    $evt = @{
        timestamp = (Get-Date).ToString('o')
        type      = $Type
        adapter   = $Adapter
        message   = $Message
    }
    
    try {
        $mutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")
        try {
            $mutex.WaitOne(3000) | Out-Null
            $fileEvents = @()
            if (Test-Path $EventsFile) {
                $data = Get-Content $EventsFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($data -and $data.events) { $fileEvents = @($data.events) }
            }
            $fileEvents = @($evt) + $fileEvents
            if ($fileEvents.Count -gt 200) { $fileEvents = $fileEvents[0..199] }
            
            $tmp = [System.IO.Path]::GetTempFileName()
            @{ events = $fileEvents } | ConvertTo-Json -Depth 3 -Compress | Set-Content $tmp -Force -Encoding UTF8 -ErrorAction SilentlyContinue
            Move-Item $tmp $EventsFile -Force -ErrorAction SilentlyContinue
        } finally {
            $mutex.ReleaseMutex()
        }
    } catch {}
}

# ===== Latency Testing =====

function Test-GatewayLatency {
    param([string]$Gateway)
    if (-not $Gateway) { return 999 }
    try {
        $result = ping.exe -n 1 -w 1000 $Gateway 2>$null
        $joined = $result -join "`n"
        if ($joined -match 'time[=<](\d+)\s*ms') { return [int]$Matches[1] }
        if ($joined -match 'time[=<](\d+)') { return [int]$Matches[1] }
        if ($joined -match 'Reply from') { return 1 }
    } catch {}
    return 999
}

function Test-InternetLatency {
    param([string]$SourceIP, [string]$Target, [int]$Timeout)
    # Method 1: ping with source binding
    try {
        $result = ping.exe -S $SourceIP -n 1 -w $Timeout $Target 2>$null
        $joined = $result -join "`n"
        if ($joined -match 'time[=<](\d+)\s*ms') { return [int]$Matches[1] }
        if ($joined -match 'time[=<](\d+)') { return [int]$Matches[1] }
        if ($joined -match 'Reply from') { return 1 }
    } catch {}

    # Method 2: plain ping (no source binding)
    try {
        $result = ping.exe -n 1 -w $Timeout $Target 2>$null
        $joined = $result -join "`n"
        if ($joined -match 'time[=<](\d+)\s*ms') { return [int]$Matches[1] }
        if ($joined -match 'time[=<](\d+)') { return [int]$Matches[1] }
        if ($joined -match 'Reply from') { return 1 }
    } catch {}

    # Method 3: TCP connect test to DNS port
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcp.BeginConnect($Target, 53, $null, $null)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $connected = $asyncResult.AsyncWaitHandle.WaitOne($Timeout, $false)
        $sw.Stop()
        $tcp.Close()
        if ($connected) { return [math]::Max(1, [int]$sw.ElapsedMilliseconds) }
    } catch {}

    return 999
}

# ===== v4.0 Intelligence Functions =====

function Update-EWMALatency {
    <# Smooth latency using Exponential Weighted Moving Average to prevent single spikes from causing routing changes. #>
    param([string]$Name, [double]$RawLatency, [string]$Type)

    $store = if ($Type -eq 'gateway') { $script:ewmaGwLatency } else { $script:ewmaLatency }

    if ($store.ContainsKey($Name) -and $store[$Name] -lt 998) {
        $prev = $store[$Name]
        if ($RawLatency -ge 999) {
            # Timeout: don't fully switch, increase gradually
            $store[$Name] = [math]::Min(999, $prev + ($script:ewmaAlpha * (999 - $prev)))
        } else {
            $store[$Name] = ($script:ewmaAlpha * $RawLatency) + ((1 - $script:ewmaAlpha) * $prev)
        }
    } else {
        $store[$Name] = $RawLatency
    }

    if ($Type -eq 'gateway') { $script:ewmaGwLatency = $store } else { $script:ewmaLatency = $store }
    return [math]::Round($store[$Name], 1)
}

function Update-LatencyHistory {
    <# Maintain rolling window of raw latency samples for jitter calculation. #>
    param([string]$Name, [double]$RawLatency)

    if (-not $script:latencyHistory.ContainsKey($Name)) {
        $script:latencyHistory[$Name] = [System.Collections.Generic.List[double]]::new()
    }
    $history = $script:latencyHistory[$Name]
    if ($RawLatency -lt 999) {
        $history.Add($RawLatency)
    }
    while ($history.Count -gt $jitterWindowSize) {
        $history.RemoveAt(0)
    }
}

function Measure-Jitter {
    <# Compute jitter as standard deviation of latency samples in rolling window. Low jitter = stable connection. #>
    param([string]$Name)

    if (-not $script:latencyHistory.ContainsKey($Name)) { return 0.0 }
    $samples = $script:latencyHistory[$Name]
    if ($samples.Count -lt 3) { return 0.0 }

    $avg = ($samples | Measure-Object -Average).Average
    $variance = 0.0
    foreach ($s in $samples) {
        $variance += ($s - $avg) * ($s - $avg)
    }
    $variance /= $samples.Count
    $jitter = [math]::Round([math]::Sqrt($variance), 2)
    $script:jitterValues[$Name] = $jitter
    return $jitter
}

function Update-HealthTrend {
    <# Track health score history for trend analysis. Returns slope of recent health scores. #>
    param([string]$Name, [double]$HealthScore)

    if (-not $script:healthTrend.ContainsKey($Name)) {
        $script:healthTrend[$Name] = [System.Collections.Generic.List[double]]::new()
    }
    $trend = $script:healthTrend[$Name]
    $trend.Add($HealthScore)
    while ($trend.Count -gt $healthTrendWindow) {
        $trend.RemoveAt(0)
    }

    # Calculate linear regression slope
    if ($trend.Count -lt 5) { return 0.0 }
    $n = $trend.Count
    $sumX = 0.0; $sumY = 0.0; $sumXY = 0.0; $sumX2 = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $sumX += $i
        $sumY += $trend[$i]
        $sumXY += $i * $trend[$i]
        $sumX2 += $i * $i
    }
    $denom = ($n * $sumX2) - ($sumX * $sumX)
    if ([math]::Abs($denom) -lt 0.001) { return 0.0 }
    $slope = [math]::Round((($n * $sumXY) - ($sumX * $sumY)) / $denom, 3)
    return $slope
}

function Test-PredictiveDegradation {
    <# Detect declining health trend and flag adapter for preemptive rerouting. #>
    param([string]$Name, [double]$Slope, [double]$CurrentHealth)

    $wasWarned = $script:degradationWarnings.ContainsKey($Name) -and $script:degradationWarnings[$Name].warned

    if ($Slope -lt $degradationThreshold -and $CurrentHealth -lt 80) {
        # Health is declining -- warn
        if (-not $wasWarned) {
            $script:degradationWarnings[$Name] = @{
                warned = $true
                trend  = $Slope
                since  = (Get-Date).ToString('o')
                health = $CurrentHealth
            }
            Write-Event -Type 'prediction' -Adapter $Name -Message "Degradation predicted (trend: $Slope/cycle, health: $CurrentHealth%) -- reducing traffic"
            Write-Host "  [!] PREDICTION: $Name degrading (trend=$Slope) -- preemptive rerouting" -ForegroundColor Magenta
        } else {
            $script:degradationWarnings[$Name].trend = $Slope
            $script:degradationWarnings[$Name].health = $CurrentHealth
        }
        return $true
    } elseif ($wasWarned -and $Slope -ge ($degradationThreshold / 2)) {
        # Health recovering -- clear warning
        $script:degradationWarnings[$Name] = @{ warned = $false; trend = $Slope; since = $null; health = $CurrentHealth }
        Write-Event -Type 'prediction' -Adapter $Name -Message "Degradation resolved (trend: $Slope/cycle, health: $CurrentHealth%) -- restoring traffic"
        Write-Host "  [OK] RECOVERY: $Name stabilized (trend=$Slope)" -ForegroundColor Green
        return $false
    }
    return $wasWarned
}

function Get-StabilityScore {
    <# Score based on health variance over time. Low variance = high stability. Returns 0-100. #>
    param([string]$Name)

    if (-not $script:healthTrend.ContainsKey($Name)) { return 80 }
    $trend = $script:healthTrend[$Name]
    if ($trend.Count -lt 5) { return 80 }

    $avg = ($trend | Measure-Object -Average).Average
    $variance = 0.0
    foreach ($s in $trend) {
        $variance += ($s - $avg) * ($s - $avg)
    }
    $variance /= $trend.Count
    $stddev = [math]::Sqrt($variance)

    # Low stddev = stable = high score. StdDev of 0 â†’ 100, StdDev of 30+ â†’ 0
    $stability = [math]::Max(0, [math]::Min(100, [math]::Round(100 - ($stddev * 3.3))))
    $script:stabilityScores[$Name] = $stability
    return $stability
}

function Update-SuccessRate {
    <# Track connection success/failure rate per adapter. #>
    param([string]$Name, [bool]$GatewayOk, [bool]$InternetOk)

    if (-not $script:successRates.ContainsKey($Name)) {
        $script:successRates[$Name] = @{ success = 0; fail = 0; rate = 100.0 }
    }
    $sr = $script:successRates[$Name]

    if ($InternetOk) {
        $sr.success++
    } elseif ($GatewayOk) {
        $sr.success++  # Gateway OK still counts as partial success
    } else {
        $sr.fail++
    }

    $total = $sr.success + $sr.fail
    if ($total -gt 0) {
        $sr.rate = [math]::Round(($sr.success / $total) * 100, 1)
    }

    # Decay old counters every 100 samples to stay responsive
    if ($total -gt 200) {
        $sr.success = [math]::Floor($sr.success * 0.5)
        $sr.fail = [math]::Floor($sr.fail * 0.5)
    }
}

# ===== Enhanced Health Measurement =====

function Measure-InterfaceHealth {
    param([hashtable]$Interface)

    $ip = $Interface.IPAddress
    $gateway = $Interface.Gateway
    $name = $Interface.Name

    # --- Gateway latency ---
    $gwLatencyRaw = Test-GatewayLatency -Gateway $gateway
    $gwLatencySmoothed = Update-EWMALatency -Name $name -RawLatency $gwLatencyRaw -Type 'gateway'

    # --- Internet latency (try primary then secondary target) ---
    $inetLatencyRaw = 999
    if ($ip) {
        $inetLatencyRaw = Test-InternetLatency -SourceIP $ip -Target $pingTarget -Timeout $pingTimeout
        if ($inetLatencyRaw -ge 999) {
            $inetLatencyRaw = Test-InternetLatency -SourceIP $ip -Target $pingTarget2 -Timeout $pingTimeout
        }
    }
    $inetLatencySmoothed = Update-EWMALatency -Name $name -RawLatency $inetLatencyRaw -Type 'internet'

    # --- Update latency history and measure jitter ---
    Update-LatencyHistory -Name $name -RawLatency $inetLatencyRaw
    $jitter = Measure-Jitter -Name $name

    # --- Update success rate ---
    $gwOk = $gwLatencyRaw -lt 999
    $inetOk = $inetLatencyRaw -lt 999
    Update-SuccessRate -Name $name -GatewayOk $gwOk -InternetOk $inetOk

    # --- Bandwidth calculation (with counter wraparound protection) ---
    $stats = Get-NetAdapterStatistics -Name $name -ErrorAction SilentlyContinue
    $rxBytes = if ($stats) { [long]$stats.ReceivedBytes } else { 0 }
    $txBytes = if ($stats) { [long]$stats.SentBytes } else { 0 }

    $rxSpeed = 0.0
    $txSpeed = 0.0

    if ($script:prevBytes.ContainsKey($name)) {
        $prev = $script:prevBytes[$name]
        $timeDelta = ((Get-Date) - $prev.time).TotalSeconds
        if ($timeDelta -gt 0.5) {
            $rxDelta = $rxBytes - $prev.rx
            $txDelta = $txBytes - $prev.tx
            if ($rxDelta -lt 0) { $rxDelta = $rxBytes }  # Counter wraparound
            if ($txDelta -lt 0) { $txDelta = $txBytes }
            $rxSpeed = [math]::Round($rxDelta * 8 / $timeDelta / 1000000, 2)
            $txSpeed = [math]::Round($txDelta * 8 / $timeDelta / 1000000, 2)
        }
    }
    $script:prevBytes[$name] = @{ rx = $rxBytes; tx = $txBytes; time = (Get-Date) }

    # --- Packet loss estimation ---
    $packetLoss = 0
    if ($inetLatencyRaw -ge 999 -and $gwLatencyRaw -ge 999) { $packetLoss = 100 }
    elseif ($inetLatencyRaw -ge 999) { $packetLoss = 50 }

    # ===== Enhanced Health Score (0-100) -- 7-Factor Weighted =====
    $score = 0
    $hasIP = [bool]$ip

    if ($hasIP) {
        # Factor 1: Gateway reachable (15 points)
        if ($gwLatencySmoothed -lt 998) {
            $score += 15
            if ($gwLatencySmoothed -lt 5) { $score += 3 }      # Ultra-low gateway bonus
            elseif ($gwLatencySmoothed -lt 20) { $score += 2 }
            elseif ($gwLatencySmoothed -lt 50) { $score += 1 }
        }

        # Factor 2: Internet reachable (25 points)
        if ($inetLatencySmoothed -lt 998) {
            $score += 25
            if ($inetLatencySmoothed -lt 15) { $score += 5 }   # Ultra-low latency
            elseif ($inetLatencySmoothed -lt 30) { $score += 3 }
            elseif ($inetLatencySmoothed -lt 60) { $score += 2 }
            elseif ($inetLatencySmoothed -lt 100) { $score += 1 }
        }

        # Factor 3: Jitter score (10 points) -- low jitter = stable
        if ($jitter -lt 3) { $score += 10 }
        elseif ($jitter -lt 10) { $score += 7 }
        elseif ($jitter -lt 25) { $score += 4 }
        elseif ($jitter -lt 50) { $score += 2 }

        # Factor 4: Success rate (15 points)
        $sr = if ($script:successRates.ContainsKey($name)) { $script:successRates[$name].rate } else { 100.0 }
        $score += [math]::Round(($sr / 100) * 15)

        # Factor 5: Bandwidth activity (10 points)
        if ($rxSpeed -gt 1.0 -or $txSpeed -gt 1.0) {
            $score += 10
        } elseif ($rxSpeed -gt 0.1 -or $txSpeed -gt 0.1) {
            $score += 7
            if ($score -lt 50) { $score = 50 }  # If data flowing, adapter is working
        }

        # Factor 6: Stability score (15 points)
        $stability = Get-StabilityScore -Name $name
        $score += [math]::Round(($stability / 100) * 15)

        # Factor 7: Trend bonus/penalty (10 points)
        $trendSlope = Update-HealthTrend -Name $name -HealthScore $score
        if ($trendSlope -gt 1) { $score += 5 }          # Improving trend
        elseif ($trendSlope -gt 0) { $score += 3 }
        elseif ($trendSlope -lt -2) { $score -= 5 }      # Declining trend
        elseif ($trendSlope -lt -1) { $score -= 3 }

        # Packet loss penalty
        if ($packetLoss -gt 0) { $score -= [math]::Min(15, [int]($packetLoss / 5)) }

<<<<<<< HEAD
=======
        # Strong latency/jitter penalties so unusable links are not mislabeled as healthy.
        if ($inetLatencySmoothed -ge 400) { $score -= 25 }
        elseif ($inetLatencySmoothed -ge 250) { $score -= 18 }
        elseif ($inetLatencySmoothed -ge 150) { $score -= 12 }
        elseif ($inetLatencySmoothed -ge 100) { $score -= 6 }

        if ($gwLatencySmoothed -ge 250) { $score -= 15 }
        elseif ($gwLatencySmoothed -ge 120) { $score -= 10 }
        elseif ($gwLatencySmoothed -ge 60) { $score -= 5 }

        if ($jitter -ge 150) { $score -= 20 }
        elseif ($jitter -ge 80) { $score -= 12 }
        elseif ($jitter -ge 40) { $score -= 6 }

>>>>>>> origin/main
        $score = [math]::Max(0, [math]::Min(100, [math]::Round($score)))

        # --- Predictive degradation check ---
        $isDegrading = Test-PredictiveDegradation -Name $name -Slope $trendSlope -CurrentHealth $score
    } else {
        $trendSlope = 0
        $jitter = 0
        $stability = 0
        $isDegrading = $false
    }

    # --- Status ---
    $status = 'offline'
<<<<<<< HEAD
    if ($score -ge 70) { $status = 'healthy' }
    elseif ($score -ge 40) { $status = 'degraded' }
=======
    if ($score -ge 80) { $status = 'healthy' }
    elseif ($score -ge 50) { $status = 'degraded' }
>>>>>>> origin/main
    elseif ($score -gt 0) { $status = 'critical' }

    # --- State change events ---
    $prevState = $script:prevStates[$name]
    if ($prevState -and $prevState -ne $status) {
        Write-Event -Type 'state_change' -Adapter $name -Message "Status: $prevState -> $status (HP: $score)"
    }
    $script:prevStates[$name] = $status

    return @{
        Name              = $name
        Type              = $Interface.Type
        InterfaceIndex    = $Interface.InterfaceIndex
        GatewayLatency    = $gwLatencyRaw
        GatewayLatencyEWMA = [math]::Round($gwLatencySmoothed, 1)
        InternetLatency   = $inetLatencyRaw
        InternetLatencyEWMA = [math]::Round($inetLatencySmoothed, 1)
        Jitter            = $jitter
        DownloadMbps      = $rxSpeed
        UploadMbps        = $txSpeed
        PacketLoss        = $packetLoss
        HealthScore       = $score
        Status            = $status
        SuccessRate       = if ($script:successRates.ContainsKey($name)) { $script:successRates[$name].rate } else { 100.0 }
        StabilityScore    = if ($script:stabilityScores.ContainsKey($name)) { $script:stabilityScores[$name] } else { 80 }
        HealthTrend       = $trendSlope
        IsDegrading       = $isDegrading
        LinkSpeedMbps     = $Interface.LinkSpeedMbps
        IPAddress         = $ip
        Gateway           = $gateway
        SSID              = $Interface.SSID
    }
}

function Rotate-CSVLog {
    if (Test-Path $LogFile) {
        $lines = Get-Content $LogFile -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt $script:maxCSVLines) {
            $header = $lines[0]
            $kept = $lines[($lines.Count - 1000)..($lines.Count - 1)]
            @($header) + $kept | Set-Content $LogFile -Encoding UTF8 -Force
        }
    }
}

# --- Main Loop ---
Write-Host ""
Write-Host "  [InterfaceMonitor v4.0] Intelligent health monitoring every ${Interval}s" -ForegroundColor Yellow
Write-Host "  Ping targets: $pingTarget, $pingTarget2" -ForegroundColor DarkGray
Write-Host "  Multi-method: Gateway + Internet + DNS + Bandwidth" -ForegroundColor DarkGray
Write-Host "  Intelligence: Dynamic EWMA + Jitter(w=$jitterWindowSize) + Trend(w=$healthTrendWindow) + Prediction(t=$degradationThreshold)" -ForegroundColor DarkGray
Write-Host ""

# Init CSV log (extended columns)
if (-not (Test-Path $LogFile)) {
    "Timestamp,Adapter,DownloadMbps,UploadMbps,GwLatency,GwLatencyEWMA,InetLatency,InetLatencyEWMA,Jitter,PacketLoss,HealthScore,SuccessRate,Stability,Trend" | Set-Content $LogFile -Encoding UTF8
}

function Update-HealthState {
    try {
        try {
<<<<<<< HEAD
            $liveCfg = Get-Content $configPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
=======
            $liveCfg = Get-CachedConfig
>>>>>>> origin/main
            $activeMode = if ($liveCfg -and $liveCfg.mode) { $liveCfg.mode } else { 'maxspeed' }
            
            $alphaMap = @{ gaming = 0.65; streaming = 0.25; balanced = 0.45; download = 0.15; maxspeed = 0.15 }
            if ($liveCfg -and $liveCfg.intelligence -and $liveCfg.intelligence.ewmaAlphas) {
                $a = $liveCfg.intelligence.ewmaAlphas
                if ($a.gaming) { $alphaMap.gaming = $a.gaming }
                if ($a.streaming) { $alphaMap.streaming = $a.streaming }
                if ($a.interactive) { $alphaMap.balanced = $a.interactive }
                if ($a.bulk) { $alphaMap.download = $a.bulk; $alphaMap.maxspeed = $a.bulk }
            }
            $script:ewmaAlpha = if ($alphaMap.ContainsKey($activeMode)) { $alphaMap[$activeMode] } else { 0.30 }
        } catch {}

        if (-not (Test-Path $InterfacesFile)) {
            return $null
        }

        $ifaceData = Get-Content $InterfacesFile -Raw | ConvertFrom-Json
        $healthResults = @()

        foreach ($iface in $ifaceData.interfaces) {
            $ifHash = @{}
            $iface.PSObject.Properties | ForEach-Object { $ifHash[$_.Name] = $_.Value }

            $health = Measure-InterfaceHealth -Interface $ifHash
            $healthResults += $health

            # Optional UI Console Output
            # Write-Host "$($health.Name) health: $($health.HealthScore)"
            
            # CSV log (extended)
            $logLine = "$(Get-Date -Format 'o'),$($health.Name),$($health.DownloadMbps),$($health.UploadMbps),$($health.GatewayLatency),$($health.GatewayLatencyEWMA),$($health.InternetLatency),$($health.InternetLatencyEWMA),$($health.Jitter),$($health.PacketLoss),$($health.HealthScore),$($health.SuccessRate),$($health.StabilityScore),$($health.HealthTrend)"
            Add-Content $LogFile $logLine -ErrorAction SilentlyContinue
        }

        # Write enriched health data
        $healthOutput = @{
            timestamp   = (Get-Date).ToString('o')
            version     = '4.0'
            uptime      = [math]::Round(((Get-Date) - $script:startTime).TotalMinutes, 1)
            adapters    = $healthResults
            degradation = $script:degradationWarnings
        }
        $healthOutput | ConvertTo-Json -Depth 4 | Set-Content $HealthFile -Force -Encoding UTF8

        # Rotate CSV and Events log every 50 loops
        $script:loopCount++
        if ($script:loopCount % 50 -eq 0) {
            Rotate-CSVLog
            try { & (Join-Path $projectDir "core\LogRotation.ps1") } catch {}
        }
        
        return $healthOutput

    } catch {
        Write-Host "  [InterfaceMonitor] Error: $_" -ForegroundColor Red
        return $null
    }
}


