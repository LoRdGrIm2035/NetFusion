<#
.SYNOPSIS
    DashboardServer v5.0 -- Production API server with safety controls and deep observability.
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

function Get-UnifiedStats {
    $result = @{ timestamp = (Get-Date).ToString('o'); version = '5.0' }
    $files = @{
        interfaces = "interfaces.json"
        health     = "health.json"
        proxy      = "proxy-stats.json"
        config     = "config.json"
        safety     = "safety-state.json"
    }
    foreach ($key in $files.Keys) {
        $path = Join-Path $configDir $files[$key]
        if (Test-Path $path) {
            try { $result[$key] = Get-Content $path -Raw | ConvertFrom-Json } catch {}
        }
    }
    return ($result | ConvertTo-Json -Depth 6 -Compress)
}

function Get-Events {
    $eventsFile = Join-Path $logsDir "events.json"
    if (Test-Path $eventsFile) {
        try { return Get-Content $eventsFile -Raw } catch {}
    }
    return '{"events":[]}'
}

function Get-Decisions {
    $decisionsFile = Join-Path $configDir "decisions.json"
    if (Test-Path $decisionsFile) {
        try { return Get-Content $decisionsFile -Raw } catch {}
    }
    return '{"decisions":[]}'
}

function Get-LearningData {
    $learningFile = Join-Path $configDir "learning-data.json"
    if (Test-Path $learningFile) {
        try { return Get-Content $learningFile -Raw } catch {}
    }
    return '{"adapterProfiles":{},"recommendations":{},"patterns":[]}'
}

function Get-SafetyState {
    $safetyFile = Join-Path $configDir "safety-state.json"
    if (Test-Path $safetyFile) {
        try { return Get-Content $safetyFile -Raw } catch {}
    }
    return '{"safeMode":false,"circuitBreakerOpen":false,"proxyHealthy":true,"version":"5.0"}'
}

function Get-SystemResources {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalMb = [math]::Round(([double]$os.TotalVisibleMemorySize / 1KB), 1)
        $freeMb = [math]::Round(([double]$os.FreePhysicalMemory / 1KB), 1)
        $usedMb = [math]::Round(($totalMb - $freeMb), 1)
        $memoryPct = if ($totalMb -gt 0) { [math]::Round(($usedMb / $totalMb) * 100, 1) } else { 0 }

        $procSamples = Get-Process -Name powershell,pwsh -ErrorAction SilentlyContinue
        $netFusionProcs = @(
            $procSamples | Where-Object {
                $_.Path -or $_.ProcessName -match 'powershell|pwsh'
            }
        )

        $procStats = foreach ($proc in $netFusionProcs) {
            @{
                id = $proc.Id
                name = $proc.ProcessName
                cpuSeconds = if ($null -ne $proc.CPU) { [math]::Round([double]$proc.CPU, 2) } else { 0 }
                workingSetMb = [math]::Round(($proc.WorkingSet64 / 1MB), 1)
                privateMemoryMb = [math]::Round(($proc.PrivateMemorySize64 / 1MB), 1)
                startTime = try { $proc.StartTime.ToString('o') } catch { $null }
            }
        }

        $result = @{
            timestamp = (Get-Date).ToString('o')
            cpu = @{
                logicalProcessors = [int]$env:NUMBER_OF_PROCESSORS
                processCpuSeconds = [math]::Round((($procStats | Measure-Object -Property cpuSeconds -Sum).Sum), 2)
            }
            memory = @{
                totalMb = $totalMb
                usedMb = $usedMb
                freeMb = $freeMb
                usedPercent = $memoryPct
            }
            powershellProcesses = $procStats
        }

        return ($result | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        return (@{
            timestamp = (Get-Date).ToString('o')
            error = 'resource_query_failed'
            message = $_.Exception.Message
        } | ConvertTo-Json -Depth 3 -Compress)
    }
}

function Get-Telemetry {
    $result = @{ timestamp = (Get-Date).ToString('o') }
    $healthPath = Join-Path $configDir "health.json"
    if (Test-Path $healthPath) {
        try {
            $hData = Get-Content $healthPath -Raw | ConvertFrom-Json
            $result.adapters = @()
            foreach ($a in $hData.adapters) {
                $result.adapters += @{
                    name = $a.Name; type = $a.Type; health = $a.HealthScore
                    latency = $a.InternetLatency
                    latencyEWMA = if ($a.InternetLatencyEWMA) { $a.InternetLatencyEWMA } else { $a.InternetLatency }
                    jitter = if ($a.Jitter) { $a.Jitter } else { 0 }
                    downloadMbps = $a.DownloadMbps; uploadMbps = $a.UploadMbps
                    successRate = if ($a.SuccessRate) { $a.SuccessRate } else { 100 }
                    stability = if ($a.StabilityScore) { $a.StabilityScore } else { 80 }
                    trend = if ($a.HealthTrend) { $a.HealthTrend } else { 0 }
                    isDegrading = if ($a.IsDegrading) { $a.IsDegrading } else { $false }
                }
            }
            $result.degradation = if ($hData.degradation) { $hData.degradation } else { @{} }
        } catch {}
    }
    return ($result | ConvertTo-Json -Depth 4 -Compress)
}

function Set-Mode {
    param([string]$Mode)
    $cfgFile = Join-Path $configDir "config.json"
    if (Test-Path $cfgFile) {
        $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
        $cfg.mode = $Mode
        # v6.0: Atomic write to prevent truncation on disk contention
        $tmp = [IO.Path]::GetTempFileName()
        $cfg | ConvertTo-Json -Depth 4 | Set-Content $tmp -Force -Encoding UTF8
        Move-Item $tmp $cfgFile -Force
    }
}

function Set-SafeMode {
    param([bool]$Enabled)
    $safetyFile = Join-Path $configDir "safety-state.json"
    $state = @{ safeMode = $Enabled; version = '5.0'; lastEvent = "Safe mode toggled via dashboard" }
    if (Test-Path $safetyFile) {
        try {
            $existing = Get-Content $safetyFile -Raw | ConvertFrom-Json
            $existing.PSObject.Properties | ForEach-Object {
                if ($_.Name -ne 'safeMode') { $state[$_.Name] = $_.Value }
            }
        } catch {}
    }
    $state.safeMode = $Enabled
    # v6.0: Atomic write to prevent truncation
    $tmp = [IO.Path]::GetTempFileName()
    $state | ConvertTo-Json -Depth 3 -Compress | Set-Content $tmp -Force -Encoding UTF8
    Move-Item $tmp $safetyFile -Force
}

function Reset-LearningData {
    $learningFile = Join-Path $configDir "learning-data.json"
    $empty = @{
        version = '5.0'
        lastUpdated = (Get-Date).ToString('o')
        totalSessions = 0
        adapterProfiles = @{}
        recommendations = @{}
        patterns = @()
    }
    # v6.0: Atomic write
    $tmp = [IO.Path]::GetTempFileName()
    $empty | ConvertTo-Json -Depth 3 -Compress | Set-Content $tmp -Force -Encoding UTF8
    Move-Item $tmp $learningFile -Force
}

function Send-TcpResponse {
    param(
        [System.IO.Stream]$Stream, [int]$StatusCode, [string]$StatusText,
        [string]$ContentType, [byte[]]$Body,
        [string[]]$ExtraHeaders = @()
    )
    $headers  = "HTTP/1.1 $StatusCode $StatusText`r`n"
    $headers += "Content-Type: $ContentType`r`n"
    $headers += "Content-Length: $($Body.Length)`r`n"
    $headers += "Access-Control-Allow-Origin: *`r`n"
    $headers += "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n"
    $headers += "Access-Control-Allow-Headers: Content-Type, Authorization, X-NetFusion-Token`r`n"
    $headers += "Cache-Control: no-cache`r`n"
    foreach ($header in $ExtraHeaders) {
        $headers += "$header`r`n"
    }
    $headers += "Connection: close`r`n`r`n"
    $hBytes = [System.Text.Encoding]::UTF8.GetBytes($headers)
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
Write-Host "    NETFUSION DASHBOARD SERVER v5.0                  " -ForegroundColor Cyan
Write-Host "    Production Observability + Safety Controls        " -ForegroundColor DarkGray
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

$listener = $null
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $listener.Start()
    
    $tokenPath = Join-Path $configDir "dashboard-token.txt"
    if (-not (Test-Path $tokenPath)) {
        $global:DashToken = -join ((65..90)+(97..122)+(48..57) | Get-Random -Count 14 | ForEach-Object {[char]$_})
        $global:DashToken | Set-Content $tokenPath -Force
    } else {
        $global:DashToken = (Get-Content $tokenPath -Raw).Trim()
    }
    
    Write-Host "  Dashboard: http://127.0.0.1:${Port}" -ForegroundColor Green
    Write-Host "  Access token: $global:DashToken" -ForegroundColor Green
    Write-Host "  APIs: /api/stream | /api/stats | /api/safety" -ForegroundColor DarkGray
    Write-Host ""
} catch {
    Write-Host "  [ERROR] Port ${Port} in use." -ForegroundColor Red
    exit 1
}

try {
    while ($true) {
        # Cleanup dead SSE runspaces to prevent memory leaks
        if (-not $global:ActiveSSE) { $global:ActiveSSE = @() }
        if ($global:ActiveSSE.Count -gt 0) {
            $global:ActiveSSE = @($global:ActiveSSE | Where-Object { $_.client.Connected })
        }

        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 50
            continue
        }

        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $suppressClose = $false

        try {
            $buffer = New-Object byte[] 16384
            $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) { $stream.Close(); $client.Close(); continue }
            $requestText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)

            $firstLine = ($requestText -split "`r`n")[0]
            $reqParts = $firstLine -split ' '
            $method = $reqParts[0]
            $path = if ($reqParts.Length -ge 2) { $reqParts[1] } else { '/' }

            if ($method -eq 'OPTIONS') {
                Send-TcpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -ContentType 'text/plain' -Body ([byte[]]@())
                continue
            }

            # Pre-parse query parameters and headers
            $parsedPath = $path.Split('?')[0]
            $queryString = if ($path.Contains('?')) { $path.Split('?')[1] } else { '' }
            
            $headerToken = ''
            $cookieToken = ''
            foreach ($line in ($requestText -split "`r`n")) {
                if ($line -match '^X-NetFusion-Token:\s*(.+)$') { $headerToken = $matches[1].Trim() }
                if ($line -match '^Authorization:\s*Bearer\s+(.+)$') { $headerToken = $matches[1].Trim() }
                if ($line -match '^Cookie:\s*(.+)$') {
                    foreach ($cookiePart in ($matches[1] -split ';')) {
                        $cookiePart = $cookiePart.Trim()
                        if ($cookiePart -match '^NetFusionToken=(.+)$') {
                            $cookieToken = $matches[1].Trim()
                        }
                    }
                }
            }
            
            $providedToken = if ($cookieToken) { $cookieToken } else { $headerToken }

            if ($parsedPath -eq '/api/login' -and $method -eq 'POST') {
                $bodyStart = $requestText.IndexOf("`r`n`r`n")
                $bodyText = if ($bodyStart -gt -1) { $requestText.Substring($bodyStart + 4) } else { '' }
                $loginToken = ''
                if ($bodyText) {
                    try {
                        $loginData = $bodyText | ConvertFrom-Json -ErrorAction Stop
                        if ($loginData.token) { $loginToken = [string]$loginData.token }
                    } catch {}
                }

                if ($loginToken -eq $global:DashToken) {
                    $resp = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json' -Body $resp -ExtraHeaders @('Set-Cookie: NetFusionToken=' + $global:DashToken + '; Path=/; HttpOnly; SameSite=Strict')
                } else {
                    $resp = [System.Text.Encoding]::UTF8.GetBytes('{"error":"unauthorized"}')
                    Send-TcpResponse -Stream $stream -StatusCode 403 -StatusText 'Forbidden' -ContentType 'application/json' -Body $resp
                }
                continue
            }

            # Auth Check for ALL requests
            if ($providedToken -ne $global:DashToken) {
                if ($parsedPath -eq '/' -or $parsedPath -eq '/index.html') {
                    $loginHtml = "<html><head><title>NetFusion Login</title><style>body{background:#0d1117;color:#c9d1d9;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;} .box{background:#161b22;padding:40px;border-radius:8px;border:1px solid #30363d;text-align:center;} input{padding:10px;margin-top:20px;width:300px;background:#0d1117;border:1px solid #30363d;color:white;border-radius:4px;} button{padding:10px 20px;background:#238636;color:white;border:none;border-radius:4px;cursor:pointer;margin-top:15px;} .err{color:#ff7b72;margin-top:12px;min-height:20px;}</style></head><body><div class='box'><h2>NetFusion Dashboard</h2><p>Please enter your access token (found in the console).</p><input type='password' id='tok' placeholder='Token...'><br><button onclick='login()'>Login</button><div id='err' class='err'></div></div><script>async function login(){ var t=document.getElementById('tok').value; var err=document.getElementById('err'); err.textContent=''; if(!t){ err.textContent='Enter a token.'; return; } var res=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:t})}); if(res.ok){ window.location.href='/'; } else { err.textContent='Invalid token.'; }}</script></body></html>"
                    $body = [System.Text.Encoding]::UTF8.GetBytes($loginHtml)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'text/html; charset=utf-8' -Body $body
                    continue
                } else {
                    $err = [System.Text.Encoding]::UTF8.GetBytes('{"error":"unauthorized"}')
                    Send-TcpResponse -Stream $stream -StatusCode 403 -StatusText 'Forbidden' -ContentType 'application/json' -Body $err
                    continue
                }
            }

            switch -Wildcard ($parsedPath) {
                '/api/stats' {
                    $json = Get-UnifiedStats
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/stream' {
                    # [V5-FIX-5] Server-Sent Events (SSE) Loop - ASYNCHRONOUS OFF-THREADING
                    $client.ReceiveTimeout = 5000
                    $client.SendTimeout = 5000
                    
                    $headers  = "HTTP/1.1 200 OK`r`n"
                    $headers += "Content-Type: text/event-stream`r`n"
                    $headers += "Cache-Control: no-cache`r`n"
                    $headers += "Connection: keep-alive`r`n`r`n"
                    $hBytes = [System.Text.Encoding]::UTF8.GetBytes($headers)
                    $stream.Write($hBytes, 0, $hBytes.Length)
                    $stream.Flush()
                    
                    $sseLogic = {
                        param($c, $s, $cDir, $lDir)
                        
                        function Get-StatsAsync {
                            $res = @{ timestamp = (Get-Date).ToString('o') }
                            $fs = @{ interfaces="interfaces.json"; health="health.json"; proxy="proxy-stats.json"; config="config.json"; safety="safety-state.json" }
                            foreach ($k in $fs.Keys) {
                                $p = Join-Path $cDir $fs[$k]
                                if (Test-Path $p) { 
                                    try { 
                                        $cnt = Get-Content $p -Raw -ErrorAction SilentlyContinue
                                        if ([string]::IsNullOrWhiteSpace($cnt)) { throw "Empty" }
                                        $res[$k] = $cnt | ConvertFrom-Json -ErrorAction Stop
                                    } catch {} 
                                }
                            }
                            return ($res | ConvertTo-Json -Depth 6 -Compress)
                        }
                        function Get-EvtAsync {
                            $p = Join-Path $lDir "events.json"
                            if (Test-Path $p) { try { $c = Get-Content $p -Raw -ErrorAction SilentlyContinue; if (-not [string]::IsNullOrWhiteSpace($c)) { return $c } } catch {} }
                            return '{"events":[]}'
                        }
                        
                        function Get-DecAsync {
                            $p = Join-Path $cDir "decisions.json"
                            if (Test-Path $p) { try { $c = Get-Content $p -Raw -ErrorAction SilentlyContinue; if (-not [string]::IsNullOrWhiteSpace($c)) { return $c } } catch {} }
                            return '{"decisions":[]}'
                        }
                        
                        function Get-LrnAsync {
                            $p = Join-Path $cDir "learning-data.json"
                            if (Test-Path $p) { try { $c = Get-Content $p -Raw -ErrorAction SilentlyContinue; if (-not [string]::IsNullOrWhiteSpace($c)) { return $c } } catch {} }
                            return '{"adapterProfiles":{},"recommendations":{},"patterns":[]}'
                        }

                        try {
                            while ($c.Connected) {
                                $ping = [System.Text.Encoding]::UTF8.GetBytes(": keepalive`n`n")
                                $s.Write($ping, 0, $ping.Length)
                                
                                try {
                                    $pl = @{
                                        stats     = (Get-StatsAsync) | ConvertFrom-Json
                                        events    = (Get-EvtAsync) | ConvertFrom-Json
                                        decisions = (Get-DecAsync) | ConvertFrom-Json
                                        learning  = (Get-LrnAsync) | ConvertFrom-Json
                                    } | ConvertTo-Json -Depth 6 -Compress
                                    
                                    $msg = [System.Text.Encoding]::UTF8.GetBytes("data: $($pl)`n`n")
                                    $s.Write($msg, 0, $msg.Length)
                                } catch {
                                    # Ignore partial parse failures caused by race conditions so the socket stays open
                                }
                                
                                $s.Flush()
                                Start-Sleep -Seconds 2
                            }
                        } catch {} finally {
                            try { $c.Close() } catch {}
                        }
                    }

                    $ps = [System.Management.Automation.PowerShell]::Create()
                    $ps.AddScript($sseLogic).AddArgument($client).AddArgument($stream).AddArgument($configDir).AddArgument($logsDir) | Out-Null
                    $handle = $ps.BeginInvoke()
                    
                    # [V5-FIX] Anchor the client, stream, and runspace to prevent .NET Garbage Collection disposal
                    $global:ActiveSSE += @{ ps = $ps; client = $client; stream = $stream; handle = $handle }
                    $suppressClose = $true
                    continue
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
                        $bodyStart = $requestText.IndexOf("`r`n`r`n")
                        if ($bodyStart -gt 0) {
                            $bodyText = $requestText.Substring($bodyStart + 4)
                            try {
                                $safeData = $bodyText | ConvertFrom-Json
                                Set-SafeMode -Enabled ([bool]$safeData.safeMode)
                                $resp = @{ ok = $true; safeMode = [bool]$safeData.safeMode } | ConvertTo-Json -Compress
                                $body = [System.Text.Encoding]::UTF8.GetBytes($resp)
                                Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json' -Body $body
                                $modeStr = if ($safeData.safeMode) { 'ENABLED' } else { 'DISABLED' }
                                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Safe Mode -> $modeStr" -ForegroundColor Yellow
                            } catch {
                                $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"invalid"}')
                                Send-TcpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -ContentType 'application/json' -Body $body
                            }
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
                        Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json' -Body $body
                        Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Learning data RESET" -ForegroundColor Magenta
                    }
                }
                '/api/mode' {
                    if ($method -eq 'POST') {
                        $bodyStart = $requestText.IndexOf("`r`n`r`n")
                        if ($bodyStart -gt 0) {
                            $bodyText = $requestText.Substring($bodyStart + 4)
                            try {
                                $modeData = $bodyText | ConvertFrom-Json
                                Set-Mode -Mode $modeData.mode
                                $resp = @{ ok = $true; mode = $modeData.mode } | ConvertTo-Json -Compress
                                $body = [System.Text.Encoding]::UTF8.GetBytes($resp)
                                Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json' -Body $body
                                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Mode -> $($modeData.mode)" -ForegroundColor Green
                            } catch {
                                $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"invalid"}')
                                Send-TcpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -ContentType 'application/json' -Body $body
                            }
                        }
                    }
                }
                '/api/resources' {
                    $json = Get-SystemResources
                    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                    Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json; charset=utf-8' -Body $body
                }
                '/api/config' {
                    $cfgFile = Join-Path $configDir "config.json"
                    if (Test-Path $cfgFile) {
                        $json = Get-Content $cfgFile -Raw
                        $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                        Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType 'application/json' -Body $body
                    }
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
                    Send-TcpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -ContentType 'text/plain' -Body ([byte[]]@())
                }
                default {
                    $safePath = $parsedPath.TrimStart('/').Replace('/', '\')
                    
                    # [V5-FIX-17] Path traversal protection
                    if ($safePath -match '\.\.') {
                        $msg = [System.Text.Encoding]::UTF8.GetBytes("Forbidden")
                        Send-TcpResponse -Stream $stream -StatusCode 403 -StatusText 'Forbidden' -ContentType 'text/plain' -Body $msg
                        continue
                    }
                    
                    $filePath = Join-Path $dashDir $safePath
                    if ((Test-Path $filePath) -and -not (Get-Item $filePath).PSIsContainer) {
                        $ext = [System.IO.Path]::GetExtension($filePath)
                        $content = [System.IO.File]::ReadAllBytes($filePath)
                        Send-TcpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -ContentType (Get-MimeType $ext) -Body $content
                    } else {
                        $msg = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                        Send-TcpResponse -Stream $stream -StatusCode 404 -StatusText 'Not Found' -ContentType 'text/plain' -Body $msg
                    }
                }
            }
        } catch {
            try {
                $err = [System.Text.Encoding]::UTF8.GetBytes("Error")
                Send-TcpResponse -Stream $stream -StatusCode 500 -StatusText 'Error' -ContentType 'text/plain' -Body $err
            } catch {}
        } finally {
            if (-not $suppressClose) {
                try { $stream.Close() } catch {}
                try { $client.Close() } catch {}
            }
        }
    }
} finally {
    if ($listener) { $listener.Stop() }
    Write-Host "`n  Dashboard stopped." -ForegroundColor Yellow
}
