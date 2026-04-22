# CHANGELOG: V5-FIX-12 Config Input Sanitization
# Runs before any service to ensure config.json is safe and strictly typed.

[CmdletBinding()]
param()

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$configPath = Join-Path $projectDir "config\config.json"
$script:configChanged = $false

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
        $Data | ConvertTo-Json -Depth $Depth | Set-Content $tmp -Force -Encoding UTF8 -ErrorAction Stop
        Move-Item $tmp $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

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
        $script:configChanged = $true
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
        $script:configChanged = $true
        return
    }
    if ($obj.$prop -as [double] -isnot [double] -and $obj.$prop -as [int] -isnot [int]) {
        Write-Host "  [Config] WARNING: '$prop' must be a number. Using $default." -ForegroundColor Yellow
        $obj.$prop = $default
        $script:warnings++
        $script:configChanged = $true
    } elseif ($obj.$prop -lt $min -or $obj.$prop -gt $max) {
        Write-Host "  [Config] WARNING: '$prop' ($($obj.$prop)) out of range [$min-$max]. Using $default." -ForegroundColor Yellow
        $obj.$prop = $default
        $script:warnings++
        $script:configChanged = $true
    }
}

function Check-Bool($obj, $prop, $default) {
    if ($null -eq $obj.$prop) {
        $obj | Add-Member -MemberType NoteProperty -Name $prop -Value $default -Force
        $script:configChanged = $true
        return
    }
    if ($obj.$prop -isnot [bool]) {
        $val = $obj.$prop.ToString().ToLower()
        if ($val -eq "true" -or $val -eq "1") { $obj.$prop = $true; $script:configChanged = $true }
        elseif ($val -eq "false" -or $val -eq "0") { $obj.$prop = $false; $script:configChanged = $true }
        else {
            Write-Host "  [Config] WARNING: '$prop' must be boolean. Using $default." -ForegroundColor Yellow
            $obj.$prop = $default
            $script:warnings++
            $script:configChanged = $true
        }
    }
}

function Check-Enum($obj, $prop, $allowed, $default) {
    if ($null -eq $obj.$prop) {
        $obj | Add-Member -MemberType NoteProperty -Name $prop -Value $default -Force
        $script:configChanged = $true
        return
    }
    if ($obj.$prop -notin $allowed) {
        Write-Host "  [Config] WARNING: '$prop' ($($obj.$prop)) invalid. Allowed: $($allowed -join ', '). Using $default." -ForegroundColor Yellow
        $obj.$prop = $default
        $script:warnings++
        $script:configChanged = $true
    }
}

# Validate Core
Check-Number $config 'proxyPort' 1024 65535 8080
Check-Number $config 'dashboardPort' 1024 65535 9090
Check-Number $config 'monitorInterval' 1000 60000 10000
Check-Enum $config 'mode' $validModes 'maxspeed'
Check-Bool $config 'dashboardAllowLAN' $false
Check-Bool $config 'blockQUICOnSecondaryAdapters' $true
if ($config.proxyPort -eq $config.dashboardPort) {
    Write-Host "  [Config] WARNING: 'dashboardPort' cannot match 'proxyPort'. Using 9090." -ForegroundColor Yellow
    $config.dashboardPort = 9090
    $script:warnings++
    $script:configChanged = $true
}

# Validate proxy settings
if ($config.proxy) {
    Check-Number $config.proxy 'minThreads' 4 128 64
    Check-Number $config.proxy 'maxThreads' 8 256 256
    Check-Number $config.proxy 'bufferSize' 8192 1048576 262144
    Check-Number $config.proxy 'jobTimeoutSec' 10 3600 120
    Check-Number $config.proxy 'sessionAffinityTTL' 10 3600 60
}

if ($config.healthCheck) {
    Check-Number $config.healthCheck 'timeout' 250 10000 1500
    Check-Number $config.healthCheck 'failThreshold' 1 20 3
    Check-Number $config.healthCheck 'primaryIntervalSeconds' 10 120 10
    Check-Number $config.healthCheck 'fullMeasurementIntervalSeconds' 30 600 60
    Check-Number $config.healthCheck 'tcpPort' 1 65535 80
}

# Validate circuit breaker
if ($config.safety) {
    Check-Number $config.safety 'maxProxyRestarts' 1 10 3
    Check-Number $config.safety 'memoryThresholdMB' 100 8000 2000
    if ($config.safety.circuitBreaker) {
        $cb = $config.safety.circuitBreaker
        Check-Number $cb 'proxyErrorRateThreshold' 0.01 1.0 0.15
        Check-Number $cb 'consecutiveFailedPings' 2 20 5
        Check-Number $cb 'memoryThresholdMB' 100 8000 800
        Check-Number $cb 'cpuThresholdPercent' 10 100 85
        Check-Number $cb 'tripCooldownSeconds' 10 600 60
    }
}

# Check traffic rules
if ($config.trafficRules) {
    foreach ($category in $config.trafficRules.PSObject.Properties.Name) {
        Check-Enum $config.trafficRules.$category 'mode' $validModes 'maxspeed'
    }
}

if ($warnings -gt 0 -or $script:configChanged) {
    try {
        Write-AtomicJson -Path $configPath -Data $config -Depth 5
        if ($warnings -gt 0) {
            Write-Host "  [ConfigValidator] Sanitized config.json ($warnings warnings fixed)." -ForegroundColor DarkGray
        } else {
            Write-Host "  [ConfigValidator] Normalized config.json." -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  [ConfigValidator] Failed to overwrite config.json!" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  [ConfigValidator] config.json OK." -ForegroundColor Green
}

exit 0
