<#
.SYNOPSIS
    LearningEngine v4.0 Ã¢â‚¬â€ Continuous adaptive learning system for network optimization.
.DESCRIPTION
    Background service that learns routing effectiveness over time:
      - Tracks per-adapter performance by time-of-day and connection type
      - Computes long-term adapter reliability scores
      - Generates routing recommendations based on historical data
      - Detects time-of-day usage patterns
      - Persists learned data across sessions in learning-data.json
      - Uses exponential decay so recent data has more weight
#>

[CmdletBinding()]
param(
    [int]$Interval = 60
)

# Resolve paths
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$HealthFile = Join-Path $projectDir "config\health.json"
$ProxyStatsFile = Join-Path $projectDir "config\proxy-stats.json"
$InterfacesFile = Join-Path $projectDir "config\interfaces.json"
$configPath = Join-Path $projectDir "config\config.json"

# Load config
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
$learningFile = if ($config -and $config.learning -and $config.learning.dataFile) {
    Join-Path $projectDir $config.learning.dataFile
} else {
    Join-Path $projectDir "config\learning-data.json"
}
$maxEntries = if ($config -and $config.learning -and $config.learning.maxEntries) { $config.learning.maxEntries } else { 5000 }
$decayFactor = if ($config -and $config.learning -and $config.learning.decayFactor) { $config.learning.decayFactor } else { 0.95 }
$minSamples = if ($config -and $config.learning -and $config.learning.minSamplesForRecommendation) { $config.learning.minSamplesForRecommendation } else { 20 }
$EventsFile = Join-Path $projectDir "logs\events.json"

# Ensure logs dir
$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$script:LearningEngineLogMutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")

function Write-AtomicJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 5
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

# ===== Learning Data Model =====
# Structure:
# {
#   "version": "4.0",
#   "lastUpdated": "ISO8601",
#   "totalSessions": N,
#   "adapterProfiles": {
#     "fingerprint": {
#       "name": "Wi-Fi 3",
#       "type": "WiFi",
#       "totalSamples": N,
#       "avgHealth": N,
#       "avgLatency": N,
#       "reliability": N (0-100),
#       "disconnectCount": N,
#       "timeOfDay": { "0": {...}, "1": {...}, ... "23": {...} },
#       "connectionTypes": { "bulk": {...}, "interactive": {...}, ... }
#     }
#   },
#   "recommendations": {
#     "bulk": "adapter_name",
#     "streaming": "adapter_name",
#     ...
#   },
#   "patterns": [...]
# }

function Write-LearningEvent {
    param([string]$Message)
    $mutexTaken = $false
    try {
        try {
            $mutexTaken = $script:LearningEngineLogMutex.WaitOne(3000)
        } catch [System.Threading.AbandonedMutexException] {
            $mutexTaken = $true
        }

        if (-not $mutexTaken) { return }

        try {
            $events = @()
            if (Test-Path $EventsFile) {
                $data = Get-Content $EventsFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($data -and $data.events) { $events = @($data.events) }
            }
            $evt = @{ timestamp = (Get-Date).ToString('o'); type = 'learning'; adapter = ''; message = $Message }
            $events = @($evt) + $events
            if ($events.Count -gt 200) { $events = $events[0..199] }

            Write-AtomicJson -Path $EventsFile -Data @{ events = $events } -Depth 3
        } finally {
            if ($mutexTaken) {
                try { $script:LearningEngineLogMutex.ReleaseMutex() } catch {}
            }
        }
    } catch {}
}

function Load-LearningData {
    if (Test-Path $learningFile) {
        try {
            $data = Get-Content $learningFile -Raw | ConvertFrom-Json
            # Convert to hashtable for easier manipulation
            $result = @{
                version = if ($data.version) { $data.version } else { '4.0' }
                lastUpdated = if ($data.lastUpdated) { $data.lastUpdated } else { (Get-Date).ToString('o') }
                totalSessions = if ($data.totalSessions) { [int]$data.totalSessions } else { 0 }
                adapterProfiles = @{}
                recommendations = @{}
                patterns = @()
            }
            if ($data.adapterProfiles) {
                $data.adapterProfiles.PSObject.Properties | ForEach-Object {
                    $adapterProfile = @{}
                    $_.Value.PSObject.Properties | ForEach-Object { 
                        if ($_.Name -match 'timeOfDay|bestForTypes') {
                            $subHash = @{}
                            if ($_.Value) {
                                $_.Value.PSObject.Properties | ForEach-Object { $subHash[$_.Name] = $_.Value }
                            }
                            $adapterProfile[$_.Name] = $subHash
                        } else {
                            $adapterProfile[$_.Name] = $_.Value 
                        }
                    }
                    $result.adapterProfiles[$_.Name] = $adapterProfile
                }
            }
            if ($data.recommendations) {
                $data.recommendations.PSObject.Properties | ForEach-Object {
                    $result.recommendations[$_.Name] = $_.Value
                }
            }
            if ($data.patterns) { $result.patterns = @($data.patterns) }
            return $result
        } catch {
            Write-Host "  [Learning] Error loading data: $_ -- starting fresh" -ForegroundColor Yellow
        }
    }
    return @{
        version = '4.0'
        lastUpdated = (Get-Date).ToString('o')
        totalSessions = 0
        adapterProfiles = @{}
        recommendations = @{}
        patterns = @()
    }
}

function Save-LearningData {
    param($Data)
    $Data.lastUpdated = (Get-Date).ToString('o')
    try {
        Write-AtomicJson -Path $learningFile -Data $Data -Depth 5
    } catch {
        Write-Host "  [Learning] Error saving data: $_" -ForegroundColor Red
    }
}

function Get-HourBucket {
    return (Get-Date).Hour
}

function Update-AdapterProfile {
    <# Update an adapter's learning profile with current performance data. #>
    param($LearningData, $HealthAdapter, $Fingerprint)

    $name = $HealthAdapter.Name
    $type = if ($HealthAdapter.Type) { $HealthAdapter.Type } else { 'Unknown' }
    $key = if ($Fingerprint) { $Fingerprint } else { $name }

    if (-not $LearningData.adapterProfiles.ContainsKey($key)) {
        $LearningData.adapterProfiles[$key] = @{
            name = $name
            type = $type
            totalSamples = 0
            avgHealth = 0
            avgLatency = 0
            avgJitter = 0
            reliability = 100
            disconnectCount = 0
            degradeCount = 0
            timeOfDay = @{}
            bestForTypes = @{}
        }
    }

    $adapterProfile = $LearningData.adapterProfiles[$key]
    $adapterProfile.name = $name

    # Bad-sample rejection: skip offline adapters to avoid corrupting the model
    $health = if ($HealthAdapter.HealthScore) { $HealthAdapter.HealthScore } else { 0 }
    if ($health -eq 0) {
        $adapterProfile.disconnectCount++
        return  # Don't update averages with offline data
    }
    $adapterProfile.totalSamples++

    # EWMA update for averages (smooth, recent-biased)
    $alpha = 0.1
    $latency = if ($HealthAdapter.InternetLatencyEWMA) { $HealthAdapter.InternetLatencyEWMA } else {
        if ($HealthAdapter.InternetLatency -and $HealthAdapter.InternetLatency -lt 999) { $HealthAdapter.InternetLatency } else { 200 }
    }
    $jitter = if ($HealthAdapter.Jitter) { $HealthAdapter.Jitter } else { 0 }

    $adapterProfile.avgHealth = if ($adapterProfile.totalSamples -le 1) { $health } else { [math]::Round(($alpha * $health) + ((1 - $alpha) * $adapterProfile.avgHealth), 1) }
    $adapterProfile.avgLatency = if ($adapterProfile.totalSamples -le 1) { $latency } else { [math]::Round(($alpha * $latency) + ((1 - $alpha) * $adapterProfile.avgLatency), 1) }
    $adapterProfile.avgJitter = if ($adapterProfile.totalSamples -le 1) { $jitter } else { [math]::Round(($alpha * $jitter) + ((1 - $alpha) * $adapterProfile.avgJitter), 1) }

    # Track degradation and disconnects
    if ($HealthAdapter.IsDegrading) { $adapterProfile.degradeCount++ }
    if ($health -eq 0) { $adapterProfile.disconnectCount++ }

    # Reliability score based on historical data
    $total = $adapterProfile.totalSamples
    $fails = $adapterProfile.disconnectCount + $adapterProfile.degradeCount
    $adapterProfile.reliability = [math]::Round([math]::Max(0, (1 - ($fails / [math]::Max(1, $total))) * 100), 1)

    # Time-of-day performance tracking
    $hour = [string](Get-HourBucket)
    if (-not $adapterProfile.timeOfDay.ContainsKey($hour)) {
        $adapterProfile.timeOfDay[$hour] = @{ avgHealth = $health; avgLatency = $latency; samples = 0 }
    }
    $tod = $adapterProfile.timeOfDay[$hour]
    $tod.samples++
    $tod.avgHealth = [math]::Round(($alpha * $health) + ((1 - $alpha) * $tod.avgHealth), 1)
    $tod.avgLatency = [math]::Round(($alpha * $latency) + ((1 - $alpha) * $tod.avgLatency), 1)

    $LearningData.adapterProfiles[$key] = $adapterProfile
}

function Update-Recommendations {
    <# Generate routing recommendations based on accumulated learning data. #>
    param($LearningData)

    $profiles = $LearningData.adapterProfiles
    if ($profiles.Count -lt 1) { return }

    # Find best adapter for each traffic type
    $bestBulk = $null; $bestBulkScore = -1
    $bestStreaming = $null; $bestStreamingScore = -1
    $bestGaming = $null; $bestGamingScore = -1
    $bestGeneral = $null; $bestGeneralScore = -1

    foreach ($key in $profiles.Keys) {
        $p = $profiles[$key]
        if ($p.totalSamples -lt $minSamples) { continue }

        # Bulk: prioritize health and reliability
        $bulkScore = ($p.avgHealth * 0.4) + ($p.reliability * 0.4) + (100 - [math]::Min(100, $p.avgLatency)) * 0.2
        if ($bulkScore -gt $bestBulkScore) { $bestBulkScore = $bulkScore; $bestBulk = $p.name }

        # Streaming: prioritize low latency and stability
        $streamScore = (100 - [math]::Min(100, $p.avgLatency)) * 0.4 + (100 - [math]::Min(100, $p.avgJitter * 2)) * 0.35 + ($p.reliability * 0.25)
        if ($streamScore -gt $bestStreamingScore) { $bestStreamingScore = $streamScore; $bestStreaming = $p.name }

        # Gaming: ultra-low latency and zero jitter
        $gameScore = (100 - [math]::Min(100, $p.avgLatency)) * 0.5 + (100 - [math]::Min(100, $p.avgJitter * 3)) * 0.35 + ($p.reliability * 0.15)
        if ($gameScore -gt $bestGamingScore) { $bestGamingScore = $gameScore; $bestGaming = $p.name }

        # General: balanced
        $genScore = ($p.avgHealth * 0.3) + ($p.reliability * 0.3) + (100 - [math]::Min(100, $p.avgLatency)) * 0.2 + (100 - [math]::Min(100, $p.avgJitter)) * 0.2
        if ($genScore -gt $bestGeneralScore) { $bestGeneralScore = $genScore; $bestGeneral = $p.name }
    }

    $LearningData.recommendations = @{
        bulk = if ($bestBulk) { $bestBulk } else { 'auto' }
        streaming = if ($bestStreaming) { $bestStreaming } else { 'auto' }
        gaming = if ($bestGaming) { $bestGaming } else { 'auto' }
        general = if ($bestGeneral) { $bestGeneral } else { 'auto' }
        updatedAt = (Get-Date).ToString('o')
        confidence = if ($profiles.Values | Where-Object { $_.totalSamples -ge $minSamples }) { 'high' } else { 'low' }
    }
}

function Apply-Decay {
    <# Apply exponential decay to old data so system stays responsive to changes. #>
    param($LearningData)

    foreach ($key in $LearningData.adapterProfiles.Keys) {
        $p = $LearningData.adapterProfiles[$key]
        if ($p.totalSamples -gt $maxEntries) {
            $p.totalSamples = [math]::Floor($p.totalSamples * $decayFactor)
            $p.disconnectCount = [math]::Floor($p.disconnectCount * $decayFactor)
            $p.degradeCount = [math]::Floor($p.degradeCount * $decayFactor)
        }
    }
}

function Detect-Patterns {
    <# Detect usage patterns like "USB-WiFi degrades during peak hours". #>
    param($LearningData)

    $patterns = @()
    foreach ($key in $LearningData.adapterProfiles.Keys) {
        $p = $LearningData.adapterProfiles[$key]
        if ($p.totalSamples -lt $minSamples) { continue }

        # Check for time-of-day degradation
        $peakHours = @('18','19','20','21','22')
        $offPeakHours = @('2','3','4','5','6')
        $peakHealth = 0; $peakCount = 0
        $offPeakHealth = 0; $offPeakCount = 0

        foreach ($h in $p.timeOfDay.Keys) {
            $tod = $p.timeOfDay[$h]
            if ($h -in $peakHours -and $tod.samples -gt 3) {
                $peakHealth += $tod.avgHealth; $peakCount++
            }
            if ($h -in $offPeakHours -and $tod.samples -gt 3) {
                $offPeakHealth += $tod.avgHealth; $offPeakCount++
            }
        }

        if ($peakCount -gt 0 -and $offPeakCount -gt 0) {
            $peakAvg = $peakHealth / $peakCount
            $offPeakAvg = $offPeakHealth / $offPeakCount
            if ($peakAvg -lt ($offPeakAvg - 15)) {
                $patterns += @{
                    type = 'peak_degradation'
                    adapter = $p.name
                    message = "$($p.name) health drops by $([math]::Round($offPeakAvg - $peakAvg))% during peak hours 6pm-10pm"
                    severity = 'info'
                }
            }
        }

        # High reliability warning
        if ($p.reliability -lt 70 -and $p.totalSamples -gt 50) {
            $patterns += @{
                type = 'low_reliability'
                adapter = $p.name
                message = "$($p.name) has $($p.reliability) pct reliability with $($p.disconnectCount) disconnects and $($p.degradeCount) degradations"
                severity = 'warning'
            }
        }
    }

    $LearningData.patterns = $patterns
}

# ===== Main Loop =====
Write-Host ""
Write-Host "  [LearningEngine v4.0] Adaptive learning every ${Interval}s" -ForegroundColor Magenta
Write-Host "  Data file: $learningFile" -ForegroundColor DarkGray
Write-Host "  Decay factor: $decayFactor | Min samples: $minSamples" -ForegroundColor DarkGray
Write-Host ""
$script:learningData = Load-LearningData
$script:learningData.totalSessions++
Write-LearningEvent "Learning engine started (session #$($script:learningData.totalSessions))"
$script:sessionStart = Get-Date
$script:lastSave = Get-Date

function Update-LearningState {
    try {
        # Read current health data
        if (Test-Path $HealthFile) {
            $hData = Get-Content $HealthFile -Raw | ConvertFrom-Json
            $adapters = $hData.adapters

            # Read interface fingerprints
            $fingerprints = @{}
            if (Test-Path $InterfacesFile) {
                try {
                    $ifData = Get-Content $InterfacesFile -Raw | ConvertFrom-Json
                    foreach ($iface in $ifData.interfaces) {
                        if ($iface.Fingerprint) { $fingerprints[$iface.Name] = $iface.Fingerprint }
                    }
                } catch {}
            }

            # Update profiles for each adapter
            foreach ($adapter in $adapters) {
                $aHash = @{}
                $adapter.PSObject.Properties | ForEach-Object { $aHash[$_.Name] = $_.Value }
                $fp = if ($fingerprints[$aHash.Name]) { $fingerprints[$aHash.Name] } else { $aHash.Name }
                Update-AdapterProfile -LearningData $script:learningData -HealthAdapter $aHash -Fingerprint $fp
            }

            # Update recommendations every 5 minutes
            $elapsed = ((Get-Date) - $script:sessionStart).TotalMinutes
            if ($elapsed -gt 0 -and [math]::Floor($elapsed) % 5 -eq 0) {
                Update-Recommendations -LearningData $script:learningData
                Detect-Patterns -LearningData $script:learningData
            }

            # Apply decay periodically
            if (((Get-Date) - $script:sessionStart).TotalMinutes -gt 30) {
                Apply-Decay -LearningData $script:learningData
            }

            # Display learning summary silently (or UI debug)
            # $profileCount = $script:learningData.adapterProfiles.Count
            # Write-Host "  [Learning] Profiles: $profileCount" -ForegroundColor DarkGray
        }

        # Save periodically (every 5 minutes)
        if (((Get-Date) - $script:lastSave).TotalMinutes -ge 5) {
            Save-LearningData -Data $script:learningData
            $script:lastSave = Get-Date
            Write-Host "  [Learning] Data saved to disk" -ForegroundColor DarkGray
        }

    } catch {
        Write-Host "  [LearningEngine] Error: $_" -ForegroundColor Red
    }
}
