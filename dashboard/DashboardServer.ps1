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
    Dashboard port. Default: 8877.
#>

[CmdletBinding()]
param(
    [int]$Port = 9090
)

$dashDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $dashDir -Parent
$configDir = Join-Path $projectDir "config"
$logsDir = Join-Path $projectDir "logs"
$tokenPath = Join-Path $configDir "dashboard-token.txt"
$validModes = @("maxspeed", "download", "gaming", "streaming", "balanced")
$legacyDashboardTokens = @(
    'mpKLZzFlE5tNi3Yw7gcID2QRu06BWjby'
)

function New-RandomSecret {
    param([int]$Length = 32)
    return (-join ((65..90) + (97..122) + (48..57) | Get-Random -Count $Length | ForEach-Object { [char]$_ }))
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
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
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

function Ensure-DashboardToken {
    $existing = ''
    if (Test-Path $tokenPath) {
        try { $existing = (Get-Content $tokenPath -Raw -ErrorAction Stop).Trim() } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($existing) -or $existing.Length -lt 24 -or $existing -in $legacyDashboardTokens) {
        $existing = New-RandomSecret -Length 32
        Set-Content $tokenPath -Value $existing -NoNewline -Force -Encoding UTF8
    }
    return $existing
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
    param([hashtable]$Headers)
    $headerToken = Normalize-DisplayText $Headers['x-netfusion-token'] 128
    if ($headerToken -and $headerToken -eq $global:DashToken) { return $true }
    if ($Headers['origin']) { return (Test-AllowedOrigin $Headers['origin']) }
    return (Test-IsLocalReferer $Headers['referer'])
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
    $data = Read-JsonFile (Join-Path $configDir "health.json")
    $adapters = @()
    $degradation = @{}
    if ($data -and $data.adapters) {
        foreach ($a in @($data.adapters)) {
            $adapters += @{
                Name = Normalize-DisplayText $a.Name 64
                Type = Normalize-DisplayText $a.Type 24
                HealthScore = if ($null -ne $a.HealthScore) { [double]$a.HealthScore } else { 0 }
                InternetLatency = if ($null -ne $a.InternetLatency) { [double]$a.InternetLatency } else { 999 }
                InternetLatencyEWMA = if ($null -ne $a.InternetLatencyEWMA) { [double]$a.InternetLatencyEWMA } elseif ($null -ne $a.InternetLatency) { [double]$a.InternetLatency } else { 999 }
                Jitter = if ($null -ne $a.Jitter) { [double]$a.Jitter } else { 0 }
                DownloadMbps = if ($null -ne $a.DownloadMbps) { [double]$a.DownloadMbps } else { 0 }
                UploadMbps = if ($null -ne $a.UploadMbps) { [double]$a.UploadMbps } else { 0 }
                SuccessRate = if ($null -ne $a.SuccessRate) { [double]$a.SuccessRate } else { 100 }
                StabilityScore = if ($null -ne $a.StabilityScore) { [double]$a.StabilityScore } else { 80 }
                HealthTrend = if ($null -ne $a.HealthTrend) { [double]$a.HealthTrend } else { 0 }
                IsDegrading = [bool]$a.IsDegrading
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
    return @{ timestamp = if ($data -and $data.timestamp) { Normalize-DisplayText $data.timestamp 48 } else { (Get-Date).ToString('o') }; version = '6.2'; uptime = if ($data -and $null -ne $data.uptime) { [double]$data.uptime } else { 0 }; adapters = $adapters; degradation = $degradation }
}

function Get-ClientProxy {
    $data = Read-JsonFile (Join-Path $configDir "proxy-stats.json")
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
            }
        }
    }
    if ($data -and $data.activePerAdapter) { foreach ($prop in $data.activePerAdapter.PSObject.Properties) { $activePerAdapter[(Normalize-DisplayText $prop.Name 64)] = [int]$prop.Value } }
    if ($data -and $data.connectionTypes) { foreach ($prop in $data.connectionTypes.PSObject.Properties) { $connectionTypes[(Normalize-DisplayText $prop.Name 24)] = [int]$prop.Value } }
    return @{ running = if ($data) { [bool]$data.running } else { $false }; timestamp = if ($data -and $data.timestamp) { Normalize-DisplayText $data.timestamp 48 } else { (Get-Date).ToString('o') }; totalConnections = if ($data -and $null -ne $data.totalConnections) { [int]$data.totalConnections } else { 0 }; totalFailures = if ($data -and $null -ne $data.totalFailures) { [int]$data.totalFailures } else { 0 }; activeConnections = if ($data -and $null -ne $data.activeConnections) { [int]$data.activeConnections } else { 0 }; activePerAdapter = $activePerAdapter; adapterCount = $adapters.Count; adapters = $adapters; connectionTypes = $connectionTypes; safeMode = if ($data) { [bool]$data.safeMode } else { $false }; currentMaxThreads = if ($data -and $null -ne $data.currentMaxThreads) { [int]$data.currentMaxThreads } else { 0 } }
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
    $profiles = @{}
    if ($data -and $data.adapterProfiles) {
        foreach ($prop in $data.adapterProfiles.PSObject.Properties) {
            $p = $prop.Value
            $profiles[(Normalize-DisplayText $prop.Name 64)] = @{ name = if ($p.name) { Normalize-DisplayText $p.name 64 } else { Normalize-DisplayText $prop.Name 64 }; totalSamples = if ($null -ne $p.totalSamples) { [int]$p.totalSamples } else { 0 }; avgHealth = if ($null -ne $p.avgHealth) { [double]$p.avgHealth } else { 0 }; reliability = if ($null -ne $p.reliability) { [double]$p.reliability } else { 0 } }
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
Write-Host "    Local Session Auth + Reduced Telemetry Surface    " -ForegroundColor DarkGray
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

$listener = $null
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $listener.Start()

    $global:DashToken = Ensure-DashboardToken

    Write-Host "  Dashboard: http://127.0.0.1:${Port}" -ForegroundColor Green
    Write-Host "  Script token: config\\dashboard-token.txt (for local automation)" -ForegroundColor DarkGray
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
            $bodyText = Get-RequestBody -RequestText $requestText

            if ($method -eq 'OPTIONS') {
                Send-TcpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -ContentType 'text/plain; charset=utf-8' -Body ([byte[]]@())
                continue
            }

            if (-not (Test-AllowedOrigin $headers['origin'])) {
                $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"origin_not_allowed"}')
                Send-TcpResponse -Stream $stream -StatusCode 403 -StatusText 'Forbidden' -ContentType 'application/json; charset=utf-8' -Body $msg
                continue
            }

            $isMutation = $method -in @('POST', 'PUT', 'PATCH', 'DELETE')
            if ($isMutation -and -not (Test-IsMutationAuthorized -Headers $headers)) {
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
    Write-Host "`n  Dashboard stopped." -ForegroundColor Yellow
}
