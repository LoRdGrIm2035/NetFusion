<#
.SYNOPSIS
    DashboardServer v6.2 -- Production API server with safety controls and deep observability.
.DESCRIPTION
    TcpListener-based HTTP server with endpoints:
      /api/stats      -- unified stats (interfaces, health, proxy, config)
      /api/events     -- system events
      /api/mode       -- POST to change optimization mode
      /api/config     -- GET config
      /api/telemetry  -- per-interface telemetry with extended metrics
      /api/decisions  -- recent routing decisions
      /api/learning   -- learning system data and recommendations
      /api/safety     -- GET safety state, POST toggle safe mode
      /api/safety/reset-learning -- POST to clear learning data
      /api/resources  -- CPU/memory metrics
.PARAMETER Port
    Dashboard port. Default: 9090.
#>

[CmdletBinding()]
param(
    [int]$Port = 0
)

$dashDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $dashDir -Parent
$configDir = Join-Path $projectDir "config"
$logsDir = Join-Path $projectDir "logs"
$tokenPath = Join-Path $configDir "dashboard-token.txt"
$tokenHashPath = Join-Path $configDir "dashboard-token-hash.txt"
$validModes = @("maxspeed", "download", "gaming", "streaming", "balanced")
$legacyDashboardTokens = @(
    'mpKLZzFlE5tNi3Yw7gcID2QRu06BWjby'
)
$script:AuthFailureByIp = [hashtable]::Synchronized(@{})
$script:AuthRateLock = [object]::new()
$script:AuthFailWindowSeconds = 60
$script:AuthFailLimit = 10
$script:AuthBlockSeconds = 300
$script:DashboardInstanceMutex = New-Object System.Threading.Mutex($false, "Global\NetFusion-Dashboard")
$script:DashboardInstanceHeld = $false
try {
    $script:DashboardInstanceHeld = $script:DashboardInstanceMutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $script:DashboardInstanceHeld = $true
}
if (-not $script:DashboardInstanceHeld) {
    Write-Host "  [Dashboard] Another dashboard instance is already running." -ForegroundColor Yellow
    exit 1
}

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

    if (-not (Test-Path $Path)) { return $DefaultValue }
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

function Normalize-DisplayText {
    param([AllowNull()][object]$Value, [int]$MaxLength = 160)
    if ($null -eq $Value) { return '' }
    $text = [regex]::Replace([string]$Value, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) }
    return $text
}

function Get-ValidMode {
    param([AllowNull()][object]$Mode)
    if ($null -eq $Mode) { return $null }
    $candidate = ([string]$Mode).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
    if ($candidate -in $validModes) { return $candidate }
    return $null
}

function New-RandomSecret {
    param([int]$Length = 32)
    return (-join ((65..90) + (97..122) + (48..57) | Get-Random -Count $Length | ForEach-Object { [char]$_ }))
}

function Get-TokenHash {
    param([string]$Token)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Token)
        return [Convert]::ToBase64String($sha256.ComputeHash($bytes))
    } finally {
        $sha256.Dispose()
    }
}

function Compare-FixedToken {
    param([string]$Left, [string]$Right)

    if ([string]::IsNullOrEmpty($Left) -or [string]::IsNullOrEmpty($Right)) { return $false }
    if ($Left.Length -ne $Right.Length) { return $false }

    $diff = 0
    for ($i = 0; $i -lt $Left.Length; $i++) {
        $diff = $diff -bor ([byte][char]$Left[$i] -bxor [byte][char]$Right[$i])
    }
    return ($diff -eq 0)
}

function Get-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Write-DashboardTokenFilesAtomically {
    param(
        [string]$Token,
        [string]$Hash
    )

    $enc = Get-Utf8NoBomEncoding
    $tokenTemp = Join-Path $configDir ([System.IO.Path]::GetRandomFileName())
    $hashTemp = Join-Path $configDir ([System.IO.Path]::GetRandomFileName())

    $tokenExisted = Test-Path $tokenPath
    $hashExisted = Test-Path $tokenHashPath
    $tokenOriginal = $null
    $hashOriginal = $null

    if ($tokenExisted) {
        try { $tokenOriginal = [System.IO.File]::ReadAllText($tokenPath, $enc) } catch {}
    }
    if ($hashExisted) {
        try { $hashOriginal = [System.IO.File]::ReadAllText($tokenHashPath, $enc) } catch {}
    }

    try {
        [System.IO.File]::WriteAllText($tokenTemp, $Token, $enc)
        [System.IO.File]::WriteAllText($hashTemp, $Hash, $enc)

        if ($tokenExisted) {
            [System.IO.File]::Replace($tokenTemp, $tokenPath, $null, $true)
        } else {
            [System.IO.File]::Move($tokenTemp, $tokenPath)
        }

        if ($hashExisted) {
            [System.IO.File]::Replace($hashTemp, $tokenHashPath, $null, $true)
        } else {
            [System.IO.File]::Move($hashTemp, $tokenHashPath)
        }
    } catch {
        # Roll back to original state if either replacement fails.
        try {
            if ($tokenExisted) {
                [System.IO.File]::WriteAllText($tokenPath, [string]$tokenOriginal, $enc)
            } else {
                Remove-Item $tokenPath -Force -ErrorAction SilentlyContinue
            }
        } catch {}

        try {
            if ($hashExisted) {
                [System.IO.File]::WriteAllText($tokenHashPath, [string]$hashOriginal, $enc)
            } else {
                Remove-Item $tokenHashPath -Force -ErrorAction SilentlyContinue
            }
        } catch {}

        throw
    } finally {
        Remove-Item $tokenTemp -Force -ErrorAction SilentlyContinue
        Remove-Item $hashTemp -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-DashboardToken {
    $existing = ''
    if (Test-Path $tokenPath) {
        try { $existing = (Get-Content $tokenPath -Raw -ErrorAction Stop).Trim() } catch {}
    }
    $tokenRegenerated = $false
    if ([string]::IsNullOrWhiteSpace($existing) -or $existing.Length -lt 24 -or $existing -in $legacyDashboardTokens) {
        $existing = New-RandomSecret -Length 32
        $tokenRegenerated = $true
    }

    $hash = Get-TokenHash -Token $existing
    $storedHash = ''
    if (Test-Path $tokenHashPath) {
        try { $storedHash = (Get-Content $tokenHashPath -Raw -ErrorAction Stop).Trim() } catch {}
    }
    $needsWrite = $tokenRegenerated -or [string]::IsNullOrWhiteSpace($storedHash) -or -not (Compare-FixedToken -Left $storedHash -Right $hash)
    if ($needsWrite) {
        Write-DashboardTokenFilesAtomically -Token $existing -Hash $hash
    }
    return $existing
}

function Parse-Cookies {
    param([hashtable]$Headers)

    $cookies = @{}
    $cookieHeader = if ($Headers) { $Headers['cookie'] } else { $null }
    if ([string]::IsNullOrWhiteSpace($cookieHeader)) { return $cookies }

    foreach ($segment in ($cookieHeader -split ';')) {
        $part = $segment.Trim()
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $idx = $part.IndexOf('=')
        if ($idx -le 0) { continue }
        $name = $part.Substring(0, $idx).Trim()
        $value = $part.Substring($idx + 1).Trim()
        $cookies[$name] = $value
    }

    return $cookies
}

function Parse-QueryParams {
    param([string]$Path)

    $query = @{}
    $queryStart = $Path.IndexOf('?')
    if ($queryStart -lt 0 -or $queryStart -ge ($Path.Length - 1)) { return $query }

    foreach ($pair in ($Path.Substring($queryStart + 1) -split '&')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair.Split('=', 2)
        $name = [Uri]::UnescapeDataString($parts[0])
        $value = if ($parts.Count -gt 1) { [Uri]::UnescapeDataString($parts[1]) } else { '' }
        $query[$name] = $value
    }

    return $query
}

function Test-DashboardTokenValue {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }

    $storedHash = ''
    if (Test-Path $tokenHashPath) {
        try { $storedHash = (Get-Content $tokenHashPath -Raw -ErrorAction Stop).Trim() } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($storedHash)) {
        $storedHash = Get-TokenHash -Token $global:DashToken
        try { Write-DashboardTokenFilesAtomically -Token $global:DashToken -Hash $storedHash } catch {}
    }

    return (Compare-FixedToken -Left (Get-TokenHash -Token $Token) -Right $storedHash)
}

function Get-RequestAuthContext {
    param(
        [hashtable]$Headers,
        [hashtable]$QueryParams
    )

    $cookies = Parse-Cookies -Headers $Headers
    $headerToken = Normalize-DisplayText $Headers['x-netfusion-token'] 256
    $queryToken = Normalize-DisplayText $QueryParams['token'] 256
    $cookieToken = Normalize-DisplayText $cookies['NetFusion-Token'] 256

    $resolvedToken = $null
    $source = 'none'
    foreach ($candidate in @(
        @{ Value = $headerToken; Source = 'header' },
        @{ Value = $queryToken; Source = 'query' },
        @{ Value = $cookieToken; Source = 'cookie' }
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) { continue }
        if (Test-DashboardTokenValue -Token $candidate.Value) {
            $resolvedToken = $candidate.Value
            $source = $candidate.Source
            break
        }
    }

    return @{
        IsAuthenticated = ($null -ne $resolvedToken)
        Token = $resolvedToken
        Source = $source
        HeaderTokenPresent = -not [string]::IsNullOrWhiteSpace($headerToken)
        QueryTokenPresent = -not [string]::IsNullOrWhiteSpace($queryToken)
    }
}

function Get-ClientIpAddress {
    param([System.Net.Sockets.TcpClient]$Client)
    try {
        $remote = $Client.Client.RemoteEndPoint -as [System.Net.IPEndPoint]
        if ($remote) { return $remote.Address.ToString() }
    } catch {}
    return 'unknown'
}

function Test-AuthRateLimited {
    param([string]$ClientIP)

    if ([string]::IsNullOrWhiteSpace($ClientIP)) { $ClientIP = 'unknown' }
    $now = Get-Date

    [System.Threading.Monitor]::Enter($script:AuthRateLock)
    try {
        if (-not $script:AuthFailureByIp.ContainsKey($ClientIP)) {
            $script:AuthFailureByIp[$ClientIP] = @{
                failures = [System.Collections.Generic.List[datetime]]::new()
                blockedUntil = [datetime]::MinValue
            }
        }

        $entry = $script:AuthFailureByIp[$ClientIP]
        $cutoff = $now.AddSeconds(-$script:AuthFailWindowSeconds)
        for ($i = $entry.failures.Count - 1; $i -ge 0; $i--) {
            if ($entry.failures[$i] -lt $cutoff) { $entry.failures.RemoveAt($i) }
        }

        if ($entry.blockedUntil -gt $now) {
            return @{
                IsBlocked = $true
                RetryAfterSec = [int][math]::Max(1, [math]::Ceiling(($entry.blockedUntil - $now).TotalSeconds))
            }
        }

        if ($entry.blockedUntil -ne [datetime]::MinValue) {
            $entry.blockedUntil = [datetime]::MinValue
            $entry.failures.Clear()
        }

        return @{
            IsBlocked = $false
            RetryAfterSec = 0
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:AuthRateLock)
    }
}

function Register-AuthFailure {
    param([string]$ClientIP)

    if ([string]::IsNullOrWhiteSpace($ClientIP)) { $ClientIP = 'unknown' }
    $now = Get-Date

    [System.Threading.Monitor]::Enter($script:AuthRateLock)
    try {
        if (-not $script:AuthFailureByIp.ContainsKey($ClientIP)) {
            $script:AuthFailureByIp[$ClientIP] = @{
                failures = [System.Collections.Generic.List[datetime]]::new()
                blockedUntil = [datetime]::MinValue
            }
        }

        $entry = $script:AuthFailureByIp[$ClientIP]
        $cutoff = $now.AddSeconds(-$script:AuthFailWindowSeconds)
        for ($i = $entry.failures.Count - 1; $i -ge 0; $i--) {
            if ($entry.failures[$i] -lt $cutoff) { $entry.failures.RemoveAt($i) }
        }

        $entry.failures.Add($now)
        if ($entry.failures.Count -ge $script:AuthFailLimit) {
            $entry.blockedUntil = $now.AddSeconds($script:AuthBlockSeconds)
            $entry.failures.Clear()
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:AuthRateLock)
    }
}

function Clear-AuthFailureHistory {
    param([string]$ClientIP)

    if ([string]::IsNullOrWhiteSpace($ClientIP)) { return }

    [System.Threading.Monitor]::Enter($script:AuthRateLock)
    try {
        if ($script:AuthFailureByIp.ContainsKey($ClientIP)) {
            [void]$script:AuthFailureByIp.Remove($ClientIP)
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:AuthRateLock)
    }
}

function Parse-Headers {
    param([string]$RequestText)
    $headers = @{}
    foreach ($line in (($RequestText -split "`r`n") | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $idx = $line.IndexOf(':')
        if ($idx -le 0) { continue }
        $headers[$line.Substring(0, $idx).Trim().ToLowerInvariant()] = $line.Substring($idx + 1).Trim()
    }
    return $headers
}

function Get-RequestBody {
    param([string]$RequestText)
    $bodyStart = $RequestText.IndexOf("`r`n`r`n")
    if ($bodyStart -lt 0) { return '' }
    return $RequestText.Substring($bodyStart + 4)
}

function Test-AllowedOrigin {
    param([string]$OriginHeader)
    if ([string]::IsNullOrWhiteSpace($OriginHeader)) { return $true }
    try { return (([System.Uri]$OriginHeader).Host -in @('127.0.0.1', 'localhost', '::1')) } catch { return $false }
}

function Test-IsLocalReferer {
    param([string]$RefererHeader)
    if ([string]::IsNullOrWhiteSpace($RefererHeader)) { return $false }
    try { return (([System.Uri]$RefererHeader).Host -in @('127.0.0.1', 'localhost', '::1')) } catch { return $false }
}

function Test-IsMutationAuthorized {
    param(
        [hashtable]$Headers,
        [hashtable]$AuthContext
    )

    if (-not $AuthContext.IsAuthenticated) { return $false }
    if ($AuthContext.HeaderTokenPresent) { return $true }
    if ($Headers['origin']) { return (Test-AllowedOrigin $Headers['origin']) }
    return (Test-IsLocalReferer $Headers['referer'])
}

function Get-DataFreshness {
    param(
        [string]$Path,
        [AllowNull()][object]$Data,
        [string]$TimestampField = 'timestamp',
        [int]$StaleAfterSec = 8
    )

    $ageSec = [double]::PositiveInfinity
    $source = 'none'

    if ($Data -and $Data.PSObject.Properties[$TimestampField] -and $Data.$TimestampField) {
        try {
            $ts = [datetime]$Data.$TimestampField
            $ageSec = [double]((Get-Date) - $ts).TotalSeconds
            $source = 'payload'
        } catch {}
    }

    if ([double]::IsInfinity($ageSec) -and (Test-Path $Path)) {
        try {
            $ageSec = [double]((Get-Date) - (Get-Item $Path).LastWriteTime).TotalSeconds
            $source = 'file'
        } catch {}
    }

    if ([double]::IsInfinity($ageSec)) { $ageSec = 999999.0 }
    if ($ageSec -lt 0) { $ageSec = 0.0 }

    return @{
        ageSec = [math]::Round($ageSec, 2)
        isStale = ($ageSec -gt $StaleAfterSec)
        staleAfterSec = [int]$StaleAfterSec
        source = $source
    }
}

function Get-ClientInterfaces {
    $data = Read-JsonFile (Join-Path $configDir "interfaces.json")
    $interfaces = @()
    if ($data -and $data.interfaces) {
        foreach ($iface in @($data.interfaces)) {
            $interfaces += @{
                Name = Normalize-DisplayText $iface.Name 64
                WiFiGeneration = if ($null -ne $iface.WiFiGeneration) { [double]$iface.WiFiGeneration } else { 0 }
                WiFiGenerationLabel = Normalize-DisplayText $iface.WiFiGenerationLabel 48
                SSID = Normalize-DisplayText $iface.SSID 64
                LinkSpeedMbps = if ($null -ne $iface.LinkSpeedMbps) { [double]$iface.LinkSpeedMbps } else { 0 }
            }
        }
    }
    return @{ timestamp = (Get-Date).ToString('o'); version = '6.2'; count = $interfaces.Count; interfaces = $interfaces }
}

function Get-ClientHealth {
    $healthPath = Join-Path $configDir "health.json"
    $data = Read-JsonFile $healthPath
    $adapters = @()
    $degradation = @{}
    $rebalance = @{ trigger = $false; overUtilized = @(); underUtilized = @(); reason = '' }
    $upstreamBottleneck = @{ detected = $false; reason = '' }
    if ($data -and $data.adapters) {
        foreach ($a in @($data.adapters)) {
            $healthScore = if ($null -ne $a.HealthScore) { [double]$a.HealthScore } else { 0.0 }
            $healthScore01 = if ($null -ne $a.HealthScore01) { [double]$a.HealthScore01 } else { [math]::Round($healthScore / 100.0, 3) }
            $adapters += @{
                Name = Normalize-DisplayText $a.Name 64
                Type = Normalize-DisplayText $a.Type 24
                HealthScore = $healthScore
                HealthScore01 = $healthScore01
                InternetLatency = if ($null -ne $a.InternetLatency) { [double]$a.InternetLatency } else { 999 }
                InternetLatencyEWMA = if ($null -ne $a.InternetLatencyEWMA) { [double]$a.InternetLatencyEWMA } elseif ($null -ne $a.InternetLatency) { [double]$a.InternetLatency } else { 999 }
                GatewayLatency = if ($null -ne $a.GatewayLatency) { [double]$a.GatewayLatency } else { 999 }
                DNSLatency = if ($null -ne $a.DNSLatency) { [double]$a.DNSLatency } else { 999 }
                PacketLoss = if ($null -ne $a.PacketLoss) { [double]$a.PacketLoss } else { 0 }
                Jitter = if ($null -ne $a.Jitter) { [double]$a.Jitter } else { 0 }
                DownloadMbps = if ($null -ne $a.DownloadMbps) { [double]$a.DownloadMbps } else { 0 }
                UploadMbps = if ($null -ne $a.UploadMbps) { [double]$a.UploadMbps } else { 0 }
                ThroughputMbps = if ($null -ne $a.ThroughputMbps) { [double]$a.ThroughputMbps } else { 0 }
                ThroughputAvg5 = if ($null -ne $a.ThroughputAvg5) { [double]$a.ThroughputAvg5 } else { 0 }
                ThroughputAvg30 = if ($null -ne $a.ThroughputAvg30) { [double]$a.ThroughputAvg30 } else { 0 }
                ThroughputAvg60 = if ($null -ne $a.ThroughputAvg60) { [double]$a.ThroughputAvg60 } else { 0 }
                ThroughputHistory = if ($a.ThroughputHistory) { @($a.ThroughputHistory) } else { @() }
                EstimatedCapacityMbps = if ($null -ne $a.EstimatedCapacityMbps) { [double]$a.EstimatedCapacityMbps } else { 0 }
                UtilizationPct = if ($null -ne $a.UtilizationPct) { [double]$a.UtilizationPct } else { 0 }
                ErrorRate = if ($null -ne $a.ErrorRate) { [double]$a.ErrorRate } else { 0 }
                SuccessRate = if ($null -ne $a.SuccessRate) { [double]$a.SuccessRate } else { 100 }
                StabilityScore = if ($null -ne $a.StabilityScore) { [double]$a.StabilityScore } else { 80 }
                HealthTrend = if ($null -ne $a.HealthTrend) { [double]$a.HealthTrend } else { 0 }
                IsDegrading = [bool]$a.IsDegrading
                IsQuarantined = [bool]$a.IsQuarantined
                IsDisabled = [bool]$a.IsDisabled
                ShouldAvoidNewFlows = [bool]$a.ShouldAvoidNewFlows
                ForceDrain = [bool]$a.ForceDrain
                ReintroLimitFlows = if ($null -ne $a.ReintroLimitFlows) { [int]$a.ReintroLimitFlows } else { 0 }
                ActiveFlows = if ($null -ne $a.ActiveFlows) { [int]$a.ActiveFlows } else { 0 }
                Status = Normalize-DisplayText $a.Status 24
                PublicIP = Normalize-DisplayText $a.PublicIP 64
            }
        }
    }
    if ($data -and $data.degradation) {
        foreach ($prop in $data.degradation.PSObject.Properties) {
            $degradation[(Normalize-DisplayText $prop.Name 64)] = @{
                health = if ($null -ne $prop.Value.health) { [double]$prop.Value.health } else { 0 }
                warned = [bool]$prop.Value.warned
                trend = if ($null -ne $prop.Value.trend) { [double]$prop.Value.trend } else { 0 }
                since = if ($prop.Value.since) { Normalize-DisplayText $prop.Value.since 48 } else { $null }
            }
        }
    }
    if ($data -and $data.rebalance) {
        $rebalance = @{
            trigger = [bool]$data.rebalance.trigger
            overUtilized = if ($data.rebalance.overUtilized) { @($data.rebalance.overUtilized | ForEach-Object { Normalize-DisplayText $_ 64 }) } else { @() }
            underUtilized = if ($data.rebalance.underUtilized) { @($data.rebalance.underUtilized | ForEach-Object { Normalize-DisplayText $_ 64 }) } else { @() }
            reason = Normalize-DisplayText $data.rebalance.reason 96
        }
    }
    if ($data -and $data.upstreamBottleneck) {
        $upstreamBottleneck = @{
            detected = [bool]$data.upstreamBottleneck.detected
            reason = Normalize-DisplayText $data.upstreamBottleneck.reason 96
            sameGateway = [bool]$data.upstreamBottleneck.sameGateway
            samePublicIp = [bool]$data.upstreamBottleneck.samePublicIp
            ratioCombinedToSingle = if ($null -ne $data.upstreamBottleneck.ratioCombinedToSingle) { [double]$data.upstreamBottleneck.ratioCombinedToSingle } else { 0 }
            combinedThroughputMbps = if ($null -ne $data.upstreamBottleneck.combinedThroughputMbps) { [double]$data.upstreamBottleneck.combinedThroughputMbps } else { 0 }
            maxSingleThroughputMbps = if ($null -ne $data.upstreamBottleneck.maxSingleThroughputMbps) { [double]$data.upstreamBottleneck.maxSingleThroughputMbps } else { 0 }
        }
    }
    $freshness = Get-DataFreshness -Path $healthPath -Data $data -TimestampField 'timestamp' -StaleAfterSec 8
    return @{
        timestamp = if ($data -and $data.timestamp) { Normalize-DisplayText $data.timestamp 48 } else { (Get-Date).ToString('o') }
        version = '6.2'
        uptime = if ($data -and $null -ne $data.uptime) { [double]$data.uptime } else { 0 }
        adapters = $adapters
        degradation = $degradation
        rebalance = $rebalance
        upstreamBottleneck = $upstreamBottleneck
        ageSec = [double]$freshness.ageSec
        isStale = [bool]$freshness.isStale
        staleAfterSec = [int]$freshness.staleAfterSec
        freshnessSource = Normalize-DisplayText $freshness.source 24
    }
}

function Get-ClientProxy {
    $proxyPath = Join-Path $configDir "proxy-stats.json"
    $data = Read-JsonFile $proxyPath
    $adapters = @()
    $activePerAdapter = @{}
    $connectionTypes = @{}
    if ($data -and $data.adapters) {
        foreach ($a in @($data.adapters)) {
            $adapters += @{
                name = Normalize-DisplayText $a.name 64
                type = Normalize-DisplayText $a.type 24
                connections = if ($null -ne $a.connections) { [int]$a.connections } else { 0 }
                successes = if ($null -ne $a.successes) { [int]$a.successes } else { 0 }
                failures = if ($null -ne $a.failures) { [int]$a.failures } else { 0 }
                health = if ($null -ne $a.health) { [double]$a.health } else { 0 }
                latency = if ($null -ne $a.latency) { [double]$a.latency } else { 999 }
                jitter = if ($null -ne $a.jitter) { [double]$a.jitter } else { 0 }
                isDegrading = [bool]$a.isDegrading
                activeFlowCount = if ($null -ne $a.activeFlowCount) { [int]$a.activeFlowCount } elseif ($null -ne $a.flowCount) { [int]$a.flowCount } else { 0 }
                flowCount = if ($null -ne $a.flowCount) { [int]$a.flowCount } elseif ($null -ne $a.activeFlowCount) { [int]$a.activeFlowCount } else { 0 }
                measuredLoadMbps = if ($null -ne $a.measuredLoadMbps) { [double]$a.measuredLoadMbps } else { 0 }
                estimatedCapacityMbps = if ($null -ne $a.estimatedCapacityMbps) { [double]$a.estimatedCapacityMbps } else { 0 }
                effectiveCapacityMbps = if ($null -ne $a.effectiveCapacityMbps) { [double]$a.effectiveCapacityMbps } else { 0 }
                availableCapacityMbps = if ($null -ne $a.availableCapacityMbps) { [double]$a.availableCapacityMbps } else { 0 }
                utilizationPct = if ($null -ne $a.utilizationPct) { [double]$a.utilizationPct } else { 0 }
                avgFlowThroughputMbps = if ($null -ne $a.avgFlowThroughputMbps) { [double]$a.avgFlowThroughputMbps } elseif ($null -ne $a.averageFlowThroughputMbps) { [double]$a.averageFlowThroughputMbps } else { 0 }
                bytesWindow = if ($null -ne $a.bytesWindow) { [double]$a.bytesWindow } elseif ($null -ne $a.totalBytesWindow) { [double]$a.totalBytesWindow } else { 0 }
                score01 = if ($null -ne $a.score01) { [double]$a.score01 } elseif ($null -ne $a.health01) { [double]$a.health01 } else { 0 }
                errorRate = if ($null -ne $a.errorRate) { [double]$a.errorRate } else { 0 }
                shouldAvoidNewFlows = [bool]$a.shouldAvoidNewFlows
                forceDrain = [bool]$a.forceDrain
                isQuarantined = [bool]$a.isQuarantined
                isDisabled = [bool]$a.isDisabled
            }
        }
    }
    if ($data -and $data.activePerAdapter) { foreach ($prop in $data.activePerAdapter.PSObject.Properties) { $activePerAdapter[(Normalize-DisplayText $prop.Name 64)] = [int]$prop.Value } }
    if ($data -and $data.connectionTypes) { foreach ($prop in $data.connectionTypes.PSObject.Properties) { $connectionTypes[(Normalize-DisplayText $prop.Name 24)] = [int]$prop.Value } }
    $freshness = Get-DataFreshness -Path $proxyPath -Data $data -TimestampField 'timestamp' -StaleAfterSec 8
    return @{
        running = if ($data) { [bool]$data.running } else { $false }
        timestamp = if ($data -and $data.timestamp) { Normalize-DisplayText $data.timestamp 48 } else { (Get-Date).ToString('o') }
        totalConnections = if ($data -and $null -ne $data.totalConnections) { [int]$data.totalConnections } else { 0 }
        totalFailures = if ($data -and $null -ne $data.totalFailures) { [int]$data.totalFailures } else { 0 }
        activeConnections = if ($data -and $null -ne $data.activeConnections) { [int]$data.activeConnections } else { 0 }
        activePerAdapter = $activePerAdapter
        adapterCount = $adapters.Count
        adapters = $adapters
        connectionTypes = $connectionTypes
        safeMode = if ($data) { [bool]$data.safeMode } else { $false }
        currentMaxThreads = if ($data -and $null -ne $data.currentMaxThreads) { [int]$data.currentMaxThreads } else { 0 }
        rebalance = if ($data -and $data.rebalance) { $data.rebalance } else { @{ trigger = $false } }
        upstreamBottleneck = if ($data -and $data.upstreamBottleneck) { $data.upstreamBottleneck } else { @{ detected = $false } }
        totalMeasuredLoadMbps = if ($data -and $null -ne $data.totalMeasuredLoadMbps) { [double]$data.totalMeasuredLoadMbps } else { 0 }
        totalEstimatedCapacityMbps = if ($data -and $null -ne $data.totalEstimatedCapacityMbps) { [double]$data.totalEstimatedCapacityMbps } else { 0 }
        connectionRegistrySize = if ($data -and $null -ne $data.connectionRegistrySize) { [int]$data.connectionRegistrySize } else { 0 }
        ageSec = [double]$freshness.ageSec
        isStale = [bool]$freshness.isStale
        staleAfterSec = [int]$freshness.staleAfterSec
        freshnessSource = Normalize-DisplayText $freshness.source 24
    }
}

function Get-ClientConfig {
    $cfg = Read-JsonFile (Join-Path $configDir "config.json")
    $mode = Get-ValidMode $cfg.mode
    if (-not $mode) { $mode = 'maxspeed' }
    return @{ mode = $mode; version = '6.2' }
}

function Get-ClientSafety {
    $state = Read-JsonFile (Join-Path $configDir "safety-state.json")
    return @{ safeMode = if ($state) { [bool]$state.safeMode } else { $false }; circuitBreakerOpen = if ($state) { [bool]$state.circuitBreakerOpen } else { $false }; proxyHealthy = if ($state -and $null -ne $state.proxyHealthy) { [bool]$state.proxyHealthy } else { $true }; uptime = if ($state -and $null -ne $state.uptime) { [double]$state.uptime } else { 0 }; version = if ($state -and $state.version) { Normalize-DisplayText $state.version 16 } else { '6.2' }; lastEvent = if ($state -and $state.lastEvent) { Normalize-DisplayText $state.lastEvent 120 } else { '' } }
}

function Get-UnifiedStats {
    return (@{ timestamp = (Get-Date).ToString('o'); version = '6.2'; interfaces = (Get-ClientInterfaces); health = (Get-ClientHealth); proxy = (Get-ClientProxy); config = (Get-ClientConfig); safety = (Get-ClientSafety) } | ConvertTo-Json -Depth 6 -Compress)
}

function Get-Events {
    $data = Read-JsonFile (Join-Path $logsDir "events.json")
    $events = @()
    if ($data -and $data.events) {
        foreach ($e in @($data.events)) {
            $events += @{ timestamp = if ($e.timestamp) { Normalize-DisplayText $e.timestamp 48 } else { '' }; type = Normalize-DisplayText $e.type 24; adapter = Normalize-DisplayText $e.adapter 64; message = Normalize-DisplayText $e.message 200 }
        }
    }
    return (@{ events = $events } | ConvertTo-Json -Depth 4 -Compress)
}

function Get-Decisions {
    $data = Read-JsonFile (Join-Path $configDir "decisions.json")
    $decisions = @()
    if ($data -and $data.decisions) {
        foreach ($d in @($data.decisions)) {
            $decisions += @{ time = Normalize-DisplayText $d.time 16; host = Normalize-DisplayText $d.host 120; type = Normalize-DisplayText $d.type 24; adapter = Normalize-DisplayText $d.adapter 64; reason = Normalize-DisplayText $d.reason 64; affinity_mode = Normalize-DisplayText $d.affinity_mode 24 }
        }
    }
    return (@{ decisions = $decisions } | ConvertTo-Json -Depth 4 -Compress)
}

function Get-LearningData {
    $data = Read-JsonFile (Join-Path $configDir "learning-data.json")
    $profiles = [ordered]@{}
    $rawProfiles = @{}

    if ($data -and $data.adapterProfiles) {
        foreach ($prop in $data.adapterProfiles.PSObject.Properties) {
            $rawProfiles[(Normalize-DisplayText $prop.Name 64)] = $prop.Value
        }
    }

    $interfaceData = Read-JsonFile (Join-Path $configDir "interfaces.json")
    if ($interfaceData -and $interfaceData.interfaces -and $rawProfiles.Count -gt 0) {
        foreach ($iface in @($interfaceData.interfaces)) {
            $ifaceName = Normalize-DisplayText $iface.Name 64
            if ([string]::IsNullOrWhiteSpace($ifaceName) -or $profiles.Contains($ifaceName)) { continue }

            $ifaceFingerprint = Normalize-DisplayText $iface.Fingerprint 64
            $matchedKey = $null
            if (-not [string]::IsNullOrWhiteSpace($ifaceFingerprint) -and $rawProfiles.ContainsKey($ifaceFingerprint)) {
                $matchedKey = $ifaceFingerprint
            } else {
                foreach ($entry in $rawProfiles.GetEnumerator()) {
                    $entryName = Normalize-DisplayText $entry.Value.name 64
                    if ($entryName -eq $ifaceName -or $entry.Key -eq $ifaceName) {
                        $matchedKey = $entry.Key
                        break
                    }
                }
            }

            if ($matchedKey) {
                $p = $rawProfiles[$matchedKey]
                $profiles[$ifaceName] = @{
                    name = $ifaceName
                    totalSamples = if ($null -ne $p.totalSamples) { [int]$p.totalSamples } else { 0 }
                    avgHealth = if ($null -ne $p.avgHealth) { [double]$p.avgHealth } else { 0 }
                    reliability = if ($null -ne $p.reliability) { [double]$p.reliability } else { 0 }
                }
            }
        }
    }

    if ($profiles.Count -eq 0 -and $rawProfiles.Count -gt 0) {
        foreach ($entry in $rawProfiles.GetEnumerator()) {
            $p = $entry.Value
            $profileName = if ($p.name) { Normalize-DisplayText $p.name 64 } else { Normalize-DisplayText $entry.Key 64 }
            $profiles[$entry.Key] = @{
                name = $profileName
                totalSamples = if ($null -ne $p.totalSamples) { [int]$p.totalSamples } else { 0 }
                avgHealth = if ($null -ne $p.avgHealth) { [double]$p.avgHealth } else { 0 }
                reliability = if ($null -ne $p.reliability) { [double]$p.reliability } else { 0 }
            }
        }
    }
    return (@{ version = if ($data -and $data.version) { Normalize-DisplayText $data.version 16 } else { '6.2' }; lastUpdated = if ($data -and $data.lastUpdated) { Normalize-DisplayText $data.lastUpdated 48 } else { (Get-Date).ToString('o') }; totalSessions = if ($data -and $null -ne $data.totalSessions) { [int]$data.totalSessions } else { 0 }; adapterProfiles = $profiles; recommendations = @{}; patterns = @() } | ConvertTo-Json -Depth 5 -Compress)
}

function Get-SafetyState {
    return ((Get-ClientSafety) | ConvertTo-Json -Depth 4 -Compress)
}

function Get-Telemetry {
    $health = Get-ClientHealth
    return (@{ timestamp = (Get-Date).ToString('o'); adapters = @($health.adapters | ForEach-Object { @{ name = $_.Name; type = $_.Type; health = $_.HealthScore; latency = $_.InternetLatency; latencyEWMA = $_.InternetLatencyEWMA; jitter = $_.Jitter; downloadMbps = $_.DownloadMbps; uploadMbps = $_.UploadMbps; successRate = $_.SuccessRate; stability = $_.StabilityScore; trend = $_.HealthTrend; isDegrading = $_.IsDegrading } }); degradation = $health.degradation } | ConvertTo-Json -Depth 4 -Compress)
}

function Get-Resources {
    $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    return (@{ processId = $PID; workingSetMB = if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB, 1) } else { 0 }; privateMB = if ($proc) { [math]::Round($proc.PrivateMemorySize64 / 1MB, 1) } else { 0 }; cpuSeconds = if ($proc) { [math]::Round($proc.CPU, 1) } else { 0 }; timestamp = (Get-Date).ToString('o') } | ConvertTo-Json -Depth 3 -Compress)
}

function Set-Mode {
    param([AllowNull()][object]$Mode)
    $safeMode = Get-ValidMode $Mode
    if (-not $safeMode) { return $null }
    $cfgFile = Join-Path $configDir "config.json"
    if (-not (Test-Path $cfgFile)) { return $null }
    $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
    $cfg.mode = $safeMode
    Write-AtomicJson -Path $cfgFile -Data $cfg -Depth 5
    return $safeMode
}

function Set-SafeMode {
    param([bool]$Enabled)
    $safetyFile = Join-Path $configDir "safety-state.json"
    $state = @{ safeMode = $Enabled; version = '6.2'; lastEvent = "Safe mode toggled via dashboard" }
    if (Test-Path $safetyFile) {
        try {
            $existing = Get-Content $safetyFile -Raw | ConvertFrom-Json
            $existing.PSObject.Properties | ForEach-Object {
                if ($_.Name -ne 'safeMode') { $state[$_.Name] = $_.Value }
            }
        } catch {}
    }
    $state.safeMode = $Enabled
    Write-AtomicJson -Path $safetyFile -Data $state -Depth 3
}

function Reset-LearningData {
    $learningFile = Join-Path $configDir "learning-data.json"
    $empty = @{
        version = '6.2'
        lastUpdated = (Get-Date).ToString('o')
        totalSessions = 0
        adapterProfiles = @{}
        recommendations = @{}
        patterns = @()
    }
    Write-AtomicJson -Path $learningFile -Data $empty -Depth 3
}

function Send-TcpResponse {
    param(
        [System.IO.Stream]$Stream, [int]$StatusCode, [string]$StatusText,
        [string]$ContentType, [byte[]]$Body, [hashtable]$ExtraHeaders = @{}
    )

    $headers = [ordered]@{
        'Content-Type' = $ContentType
        'Content-Length' = $Body.Length
        'Cache-Control' = 'no-store'
        'Referrer-Policy' = 'no-referrer'
        'X-Content-Type-Options' = 'nosniff'
        'X-Frame-Options' = 'DENY'
        'Cross-Origin-Resource-Policy' = 'same-origin'
        'Content-Security-Policy' = "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        'Connection' = 'close'
    }

    foreach ($key in $ExtraHeaders.Keys) {
        $headers[$key] = $ExtraHeaders[$key]
    }

    $rawHeaders = "HTTP/1.1 $StatusCode $StatusText`r`n"
    foreach ($key in $headers.Keys) {
        $rawHeaders += "${key}: $($headers[$key])`r`n"
    }
    $rawHeaders += "`r`n"

    $hBytes = [System.Text.Encoding]::UTF8.GetBytes($rawHeaders)
    $Stream.Write($hBytes, 0, $hBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Get-AutoLoginCookie {
    return "NetFusion-Token=$($global:DashToken); Path=/; HttpOnly; SameSite=Strict; Max-Age=28800"
}

function Send-RedirectResponse {
    param(
        [System.IO.Stream]$Stream,
        [string]$Location,
        [string]$CookieValue = ''
    )

    $headers = @{ Location = $Location }
    if (-not [string]::IsNullOrWhiteSpace($CookieValue)) {
        $headers['Set-Cookie'] = $CookieValue
    }

    $body = [System.Text.Encoding]::UTF8.GetBytes('Redirecting')
    Send-TcpResponse -Stream $Stream -StatusCode 302 -StatusText 'Found' -ContentType 'text/plain; charset=utf-8' -Body $body -ExtraHeaders $headers
}

function Send-AuthenticationChallenge {
    param([System.IO.Stream]$Stream)

    $payload = @{
        error = 'authentication_required'
        message = 'Open the dashboard root once to establish the local session automatically.'
    } | ConvertTo-Json -Compress
    $body = [System.Text.Encoding]::UTF8.GetBytes($payload)
    Send-TcpResponse -Stream $Stream -StatusCode 401 -StatusText 'Unauthorized' -ContentType 'application/json; charset=utf-8' -Body $body
}

function Get-MimeType {
    param([string]$Ext)
    switch ($Ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.png'  { 'image/png' }
        '.svg'  { 'image/svg+xml' }
        '.ico'  { 'image/x-icon' }
        default { 'text/plain; charset=utf-8' }
    }
}

# --- Main ---
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "    NETFUSION DASHBOARD SERVER v6.2                  " -ForegroundColor Cyan
Write-Host "    Local Auto-Login + Reduced Telemetry Surface      " -ForegroundColor DarkGray
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

if ($Port -le 0) {
    $cfg = Read-JsonFile (Join-Path $configDir "config.json")
    if ($cfg -and $cfg.dashboardPort) {
        $Port = [int]$cfg.dashboardPort
    } else {
        $Port = 9090
    }
}

$listener = $null
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $listener.Start()

    $global:DashToken = Ensure-DashboardToken

    Write-Host "  Dashboard: http://127.0.0.1:${Port}" -ForegroundColor Green
    Write-Host "  Script token: config\\dashboard-token.txt (browser login is automatic)" -ForegroundColor DarkGray
    Write-Host "  APIs: /api/stats | /api/safety | /api/resources" -ForegroundColor DarkGray
    Write-Host ""
} catch {
    Write-Host "  [ERROR] Port ${Port} in use." -ForegroundColor Red
    exit 1
}

try {
    while ($true) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 50
            continue
        }

        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000

        try {
            $buffer = New-Object byte[] 65536
            $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) { $stream.Close(); $client.Close(); continue }
            $requestText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)

            $firstLine = ($requestText -split "`r`n")[0]
            $reqParts = $firstLine -split ' '
            if ($reqParts.Length -lt 2) {
                $msg = [System.Text.Encoding]::UTF8.GetBytes("Bad Request")
                Send-TcpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -ContentType 'text/plain; charset=utf-8' -Body $msg
                continue
            }
            $method = $reqParts[0].ToUpperInvariant()
            $path = $reqParts[1]
            $parsedPath = $path.Split('?')[0]
            $headers = Parse-Headers -RequestText $requestText
            $queryParams = Parse-QueryParams -Path $path
            $authContext = Get-RequestAuthContext -Headers $headers -QueryParams $queryParams
            $clientIp = Get-ClientIpAddress -Client $client
            $bodyText = Get-RequestBody -RequestText $requestText
            $autoLoginCookie = Get-AutoLoginCookie

            if ($method -eq 'OPTIONS') {
                Send-TcpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -ContentType 'text/plain; charset=utf-8' -Body ([byte[]]@())
                continue
            }

            if (-not (Test-AllowedOrigin $headers['origin'])) {
                $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"origin_not_allowed"}')
                Send-TcpResponse -Stream $stream -StatusCode 403 -StatusText 'Forbidden' -ContentType 'application/json; charset=utf-8' -Body $msg
                continue
            }

            if ($parsedPath -in @('/', '/index.html', '/login') -and -not $authContext.IsAuthenticated -and -not $authContext.HeaderTokenPresent -and -not $authContext.QueryTokenPresent) {
                Send-RedirectResponse -Stream $stream -Location '/' -CookieValue $autoLoginCookie
                continue
            }

            if (($parsedPath -eq '/login' -or $authContext.Source -eq 'query') -and $authContext.IsAuthenticated) {
                Send-RedirectResponse -Stream $stream -Location '/' -CookieValue $autoLoginCookie
                continue
            }

            if ($authContext.IsAuthenticated) {
                Clear-AuthFailureHistory -ClientIP $clientIp
            } else {
                $rateLimit = Test-AuthRateLimited -ClientIP $clientIp
                if ($rateLimit.IsBlocked) {
                    $retryAfter = [int][math]::Max(1, $rateLimit.RetryAfterSec)
                    $body = [System.Text.Encoding]::UTF8.GetBytes("{""error"":""rate_limited"",""retryAfterSec"":$retryAfter}")
                    Send-TcpResponse -Stream $stream -StatusCode 429 -StatusText 'Too Many Requests' -ContentType 'application/json; charset=utf-8' -Body $body -ExtraHeaders @{ 'Retry-After' = $retryAfter }
                    continue
                }
            }

            if (-not $authContext.IsAuthenticated) {
                if ($parsedPath -eq '/favicon.ico') {
                    Send-TcpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -ContentType 'text/plain; charset=utf-8' -Body ([byte[]]@())
                } else {
                    Register-AuthFailure -ClientIP $clientIp
                    Send-AuthenticationChallenge -Stream $stream
                }
                continue
            }

            $isMutation = $method -in @('POST', 'PUT', 'PATCH', 'DELETE')
            if ($isMutation -and -not (Test-IsMutationAuthorized -Headers $headers -AuthContext $authContext)) {
                $err = [System.Text.Encoding]::UTF8.GetBytes('{"error":"unauthorized"}')
                Send-TcpResponse -Stream $stream -StatusCode 403 -StatusText 'Forbidden' -ContentType 'application/json; charset=utf-8' -Body $err
                continue
            }

            switch -Wildcard ($parsedPath) {
                '/api/stats' {
                    $json = Get-UnifiedStats
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/stream' {
                    $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"streaming_disabled","message":"Dashboard now uses authenticated polling."}')
                    Send-TcpResponse -Stream $stream -StatusCode 410 -StatusText 'Gone' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/events' {
                    $json = Get-Events
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/telemetry' {
                    $json = Get-Telemetry
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/decisions' {
                    $json = Get-Decisions
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/learning' {
                    $json = Get-LearningData
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/safety' {
                    if ($method -eq 'POST') {
                        try {
                            $safeData = $bodyText | ConvertFrom-Json -ErrorAction Stop
                            Set-SafeMode -Enabled ([bool]$safeData.safeMode)
                            $resp = @{ ok = $true; safeMode = [bool]$safeData.safeMode } | ConvertTo-Json -Compress
                            $body = [System.Text.Encoding]::UTF8.GetBytes($resp)
                            Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                            $modeStr = if ($safeData.safeMode) { 'ENABLED' } else { 'DISABLED' }
                            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Safe Mode -> $modeStr" -ForegroundColor Yellow
                        } catch {
                            $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"invalid"}')
                            Send-TcpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -ContentType 'application/json; charset=utf-8' -Body $body
                        }
                    } else {
                        $json = Get-SafetyState
                        $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                        Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                    }
                }
                '/api/safety/reset-learning' {
                    if ($method -eq 'POST') {
                        Reset-LearningData
                        $resp = @{ ok = $true; message = 'Learning data cleared' } | ConvertTo-Json -Compress
                        $body = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Learning data RESET" -ForegroundColor Magenta
                    } else {
                        $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"method_not_allowed"}')
                        Send-TcpResponse -Stream $stream -StatusCode 405 -StatusText 'Method Not Allowed' -ContentType 'application/json; charset=utf-8' -Body $body
                    }
                }
                '/api/mode' {
                    if ($method -eq 'POST') {
                        try {
                            $modeData = $bodyText | ConvertFrom-Json -ErrorAction Stop
                            $updatedMode = Set-Mode -Mode $modeData.mode
                            if (-not $updatedMode) { throw "Invalid mode" }
                            $resp = @{ ok = $true; mode = $updatedMode } | ConvertTo-Json -Compress
                            $body = [System.Text.Encoding]::UTF8.GetBytes($resp)
                            Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                            Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Mode -> $updatedMode" -ForegroundColor Green
                        } catch {
                            $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"invalid_mode"}')
                            Send-TcpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -ContentType 'application/json; charset=utf-8' -Body $body
                        }
                    } else {
                        $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"method_not_allowed"}')
                        Send-TcpResponse -Stream $stream -StatusCode 405 -StatusText 'Method Not Allowed' -ContentType 'application/json; charset=utf-8' -Body $body
                    }
                }
                '/api/resources' {
                    $json = Get-Resources
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/config' {
                    $json = (Get-ClientConfig | ConvertTo-Json -Depth 3 -Compress)
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/' {
                    $filePath = Join-Path $dashDir "index.html"
                    if (Test-Path $filePath) {
                        $content = [System.IO.File]::ReadAllBytes($filePath)
                        Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'text/html; charset=utf-8' -Body $content
                    }
                }
                '/index.html' {
                    $filePath = Join-Path $dashDir "index.html"
                    if (Test-Path $filePath) {
                        $content = [System.IO.File]::ReadAllBytes($filePath)
                        Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'text/html; charset=utf-8' -Body $content
                    }
                }
                '/favicon.ico' {
                    Send-TcpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -ContentType 'text/plain; charset=utf-8' -Body ([byte[]]@())
                }
                default {
                    $msg = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                    Send-TcpResponse -Stream $stream -StatusCode 404 -StatusText 'Not Found' -ContentType 'text/plain; charset=utf-8' -Body $msg
                }
            }
        } catch {
            try {
                $err = [System.Text.Encoding]::UTF8.GetBytes("Error")
                Send-TcpResponse -Stream $stream -StatusCode 500 -StatusText 'Error' -ContentType 'text/plain; charset=utf-8' -Body $err
            } catch {}
        } finally {
            try { $stream.Close() } catch {}
            try { $client.Close() } catch {}
        }
    }
} finally {
    if ($listener) { $listener.Stop() }
    if ($script:DashboardInstanceHeld -and $script:DashboardInstanceMutex) {
        try { $script:DashboardInstanceMutex.ReleaseMutex() } catch {}
    }
    if ($script:DashboardInstanceMutex) {
        try { $script:DashboardInstanceMutex.Dispose() } catch {}
    }
    Write-Host "`n  Dashboard stopped." -ForegroundColor Yellow
}
