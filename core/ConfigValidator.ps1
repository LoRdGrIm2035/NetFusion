# CHANGELOG: V5-FIX-12 Config Input Sanitization
# Runs before any service to ensure config.json is safe and strictly typed.

[CmdletBinding()]
param()

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$configPath = Join-Path $projectDir "config\config.json"

try {
    $rawText = Get-Content $configPath -Raw -ErrorAction Stop
    $config = $rawText | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "  [ConfigValidator] FATAL: config.json is missing or invalid JSON: $_" -ForegroundColor Red
    Write-Host "                    Restoring from config/config.default.json..." -ForegroundColor Yellow
    $defaultPath = Join-Path $projectDir "config\config.default.json"
    if (Test-Path $defaultPath) {
        Copy-Item $defaultPath $configPath -Force
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
    } else {
        Write-Host "  [ConfigValidator] CRITICAL: config.default.json missing too. Cannot recover." -ForegroundColor Red
        exit 1
    }
}

$validModes = @("maxspeed", "download", "gaming", "streaming", "balanced")
$warnings = 0

function Check-Number($obj, $prop, $min, $max, $default) {
    if ($null -eq $obj.$prop) {
        $obj | Add-Member -MemberType NoteProperty -Name $prop -Value $default -Force
        $script:warnings++
        return
    }
    if ($obj.$prop -as [double] -isnot [double] -and $obj.$prop -as [int] -isnot [int]) {
        Write-Host "  [Config] WARNING: '$prop' must be a number. Using $default." -ForegroundColor Yellow
        $obj.$prop = $default
        $script:warnings++
    } elseif ($obj.$prop -lt $min -or $obj.$prop -gt $max) {
        Write-Host "  [Config] WARNING: '$prop' ($($obj.$prop)) out of range [$min-$max]. Using $default." -ForegroundColor Yellow
        $obj.$prop = $default
        $script:warnings++
    }
}

function Check-Bool($obj, $prop, $default) {
    if ($null -eq $obj.$prop) {
        $obj | Add-Member -MemberType NoteProperty -Name $prop -Value $default -Force
        return
    }
    if ($obj.$prop -isnot [bool]) {
        $val = $obj.$prop.ToString().ToLower()
        if ($val -eq "true" -or $val -eq "1") { $obj.$prop = $true }
        elseif ($val -eq "false" -or $val -eq "0") { $obj.$prop = $false }
        else {
            Write-Host "  [Config] WARNING: '$prop' must be boolean. Using $default." -ForegroundColor Yellow
            $obj.$prop = $default
            $script:warnings++
        }
    }
}

function Check-Enum($obj, $prop, $allowed, $default) {
    if ($null -eq $obj.$prop) {
        $obj | Add-Member -MemberType NoteProperty -Name $prop -Value $default -Force
        return
    }
    if ($obj.$prop -notin $allowed) {
        Write-Host "  [Config] WARNING: '$prop' ($($obj.$prop)) invalid. Allowed: $($allowed -join ', '). Using $default." -ForegroundColor Yellow
        $obj.$prop = $default
        $script:warnings++
    }
}

# Validate Core
Check-Number $config 'proxyPort' 1024 65535 8888
Check-Number $config 'dashboardPort' 1024 65535 8877
Check-Enum $config 'mode' $validModes 'maxspeed'
Check-Bool $config 'dashboardAllowLAN' $false
Check-Bool $config 'blockQUICOnSecondaryAdapters' $true

# Validate proxy settings
if ($config.proxy) {
<<<<<<< HEAD
    Check-Number $config.proxy 'minThreads' 4 64 16
    Check-Number $config.proxy 'maxThreads' 8 128 64
=======
    Check-Number $config.proxy 'minThreads' 4 64 32
    Check-Number $config.proxy 'maxThreads' 8 256 256
    Check-Number $config.proxy 'maxConcurrentPerAdapter' 4 256 48
>>>>>>> origin/main
    Check-Number $config.proxy 'bufferSize' 8192 1048576 65536
    Check-Number $config.proxy 'jobTimeoutSec' 10 3600 120
    Check-Number $config.proxy 'sessionAffinityTTL' 10 3600 300
}

# Validate circuit breaker
if ($config.safety) {
    Check-Number $config.safety 'maxProxyRestarts' 1 10 3
    Check-Number $config.safety 'memoryThresholdMB' 100 8000 800
    if ($config.safety.circuitBreaker) {
        $cb = $config.safety.circuitBreaker
        Check-Number $cb 'proxyErrorRateThreshold' 0.01 1.0 0.15
        Check-Number $cb 'consecutiveFailedPings' 2 20 5
        Check-Number $cb 'memoryThresholdMB' 100 8000 800
        Check-Number $cb 'cpuThresholdPercent' 10 100 85
        Check-Number $cb 'tripCooldownSeconds' 10 600 60
    }
}

<<<<<<< HEAD
# Check traffic rules
if ($config.trafficRules) {
    foreach ($category in $config.trafficRules.PSObject.Properties.Name) {
        Check-Enum $config.trafficRules.$category 'mode' $validModes 'maxspeed'
    }
}
=======
# trafficRules section was removed in v6.0 (proxy has no process-awareness at TCP level)
>>>>>>> origin/main

if ($warnings -gt 0) {
    try {
        $config | ConvertTo-Json -Depth 5 | Set-Content $configPath -Force
        Write-Host "  [ConfigValidator] Sanitized config.json ($warnings warnings fixed)." -ForegroundColor DarkGray
    } catch {
        Write-Host "  [ConfigValidator] Failed to overwrite config.json!" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  [ConfigValidator] config.json OK." -ForegroundColor Green
}

exit 0
