<#
.SYNOPSIS
    NetFusionWatchdog v6.3 -- Failsafe Guardian with active health probing
.DESCRIPTION
    Ensures that if NetFusionEngine dies, proxy hangs, or internet breaks,
    the system instantly clears the Windows proxy, preventing "No Internet" state.

    v6.3 improvements (reliability):
      - RC-2: Does NOT exit after clearing proxy -- keeps running to re-guard
      - RC-3: Active /health endpoint probe (not just port check)
      - HTTP connectivity test validates traffic actually flows
      - Heartbeat file for liveness monitoring
      - Reduced check interval (2s) for faster detection
      - Auto-restores proxy when engine recovers
#>

[CmdletBinding()]
param()

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$watchdogFailLog = Join-Path $logsDir "watchdog-fail.txt"
$heartbeatFile = Join-Path $projectDir "config\watchdog-heartbeat.json"
$configPath = Join-Path $projectDir "config\config.json"

$proxyPort = 8080
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($cfg -and $cfg.proxyPort) { $proxyPort = [int]$cfg.proxyPort }
    } catch {}
}
$failCount = 0
$proxyCleared = $false
$script:WatchdogMutex = New-Object System.Threading.Mutex($false, "Global\NetFusion-Watchdog")
$script:WatchdogMutexHeld = $false
try {
    $script:WatchdogMutexHeld = $script:WatchdogMutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $script:WatchdogMutexHeld = $true
}
if (-not $script:WatchdogMutexHeld) {
    Write-Host "  [Watchdog] Another watchdog instance is already running." -ForegroundColor Yellow
    exit 1
}

Write-Host "  [Watchdog v6.3] Active. Guarding proxy on port $proxyPort..." -ForegroundColor Cyan

function Write-WatchdogFailureLog {
    param([string]$Message)
    $ts = (Get-Date).ToString('o')
    try {
        Add-Content -Path $watchdogFailLog -Value "[$ts] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Set-RegistryValueVerified {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string]$Type = 'String'
    )

    try {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        $actual = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        if ([string]$actual -ne [string]$Value) {
            Write-WatchdogFailureLog "Registry verify failed for $Path::$Name (expected '$Value', got '$actual')."
        }
    } catch {
        Write-WatchdogFailureLog "Registry write failed for $Path::$Name -> $($_.Exception.Message)"
    }
}

function Clear-Proxy {
    Write-Host "  [Watchdog] Critical Failure Detected! Clearing proxy..." -ForegroundColor Red
    try {
        $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Set-RegistryValueVerified -Path $inetKey -Name 'ProxyEnable' -Value 0 -Type DWord
        Remove-ItemProperty -Path $inetKey -Name 'ProxyServer' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $inetKey -Name 'ProxyOverride' -Force -ErrorAction SilentlyContinue
        # Fallback: direct reg.exe in case PowerShell provider fails
        & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyEnable /t REG_DWORD /d 0 /f 2>$null | Out-Null

        $idmKey = 'HKCU:\Software\DownloadManager'
        if (Test-Path $idmKey) {
            Set-RegistryValueVerified -Path $idmKey -Name 'nProxyMode' -Value 1 -Type DWord
            Set-RegistryValueVerified -Path $idmKey -Name 'UseHttpProxy' -Value 0 -Type DWord
            Set-RegistryValueVerified -Path $idmKey -Name 'UseHttpsProxy' -Value 0 -Type DWord
        }

        # Verify proxy is actually cleared
        $verify = (Get-ItemProperty $inetKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
        if ($verify -eq 0) {
            Write-Host "  [Watchdog] Direct internet restored successfully (verified)." -ForegroundColor Green
        } else {
            Write-WatchdogFailureLog "ProxyEnable still $verify after clear attempt!"
            # Force via reg.exe
            & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyEnable /t REG_DWORD /d 0 /f 2>$null | Out-Null
        }
    } catch {
        Write-Host "  [Watchdog] Failed to clear proxy! $_" -ForegroundColor Red
        try { & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyEnable /t REG_DWORD /d 0 /f 2>$null | Out-Null } catch {}
    }
}

function Restore-Proxy {
    param([int]$Port)
    try {
        $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Set-ItemProperty $inetKey 'ProxyEnable' 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty $inetKey 'ProxyServer' "127.0.0.1:$Port" -Type String -Force -ErrorAction SilentlyContinue
        Set-ItemProperty $inetKey 'ProxyOverride' '<local>;127.0.0.1;localhost;::1' -Type String -Force -ErrorAction SilentlyContinue
        Write-Host "  [Watchdog] Proxy re-enabled after engine recovery." -ForegroundColor Green
    } catch {}
}

function Test-EngineMutexAlive {
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting("Global\NetFusion-Engine")
        try {
            $acquired = $mutex.WaitOne(0, $false)
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch {}
                return $false
            }
            return $true
        } finally {
            $mutex.Dispose()
        }
    } catch {
        return $false
    }
}

# RC-3: Active health probe — actually test if proxy responds, not just port check
function Test-ProxyHealthEndpoint {
    param([int]$Port, [int]$TimeoutMs = 3000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.SendTimeout = $TimeoutMs
        $tcp.ReceiveTimeout = $TimeoutMs
        $ar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            $tcp.Dispose()
            return $false
        }
        try { $tcp.EndConnect($ar) } catch { $tcp.Dispose(); return $false }
        if (-not $tcp.Connected) { $tcp.Dispose(); return $false }

        $stream = $tcp.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        $req = "GET /health HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"
        $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($reqBytes, 0, $reqBytes.Length)
        $stream.Flush()

        $respBuf = New-Object byte[] 256
        $bytesRead = $stream.Read($respBuf, 0, $respBuf.Length)
        $tcp.Dispose()

        if ($bytesRead -gt 0) {
            $resp = [System.Text.Encoding]::ASCII.GetString($respBuf, 0, $bytesRead)
            return ($resp -match 'HTTP/1\.[01] 200')
        }
        return $false
    } catch {
        return $false
    }
}

function Write-Heartbeat {
    try {
        $data = @{
            timestamp = (Get-Date).ToString('o')
            proxyPort = $proxyPort
            failCount = $failCount
            proxyCleared = $proxyCleared
        }
        $tmp = Join-Path (Split-Path $heartbeatFile -Parent) ([System.IO.Path]::GetRandomFileName())
        $data | ConvertTo-Json -Compress | Set-Content $tmp -Force -Encoding UTF8 -ErrorAction Stop
        Move-Item $tmp $heartbeatFile -Force -ErrorAction Stop
    } catch {}
}

try {
while ($true) {
    Start-Sleep -Seconds 2

    # Write heartbeat every cycle so other components know watchdog is alive
    Write-Heartbeat

    # Check whether proxy port is listening
    $isListening = $false
    try {
        $isListening = @(
            Get-NetTCPConnection -LocalPort $proxyPort -State Listen -ErrorAction Stop
        ).Count -gt 0
    } catch {
        try {
            $isListening = [bool](netstat -ano | Select-String ":$proxyPort\s+.*LISTENING")
        } catch {}
    }

    $engineAlive = Test-EngineMutexAlive

    # RC-3: Active health probe -- verify proxy actually responds, not just socket alive
    $proxyHealthy = $false
    if ($isListening) {
        $proxyHealthy = Test-ProxyHealthEndpoint -Port $proxyPort -TimeoutMs 3000
    }

    if (-not $isListening -or -not $engineAlive -or -not $proxyHealthy) {
        $failCount++
        $reason = @()
        if (-not $isListening) { $reason += "port-not-listening" }
        if (-not $engineAlive) { $reason += "engine-mutex-dead" }
        if ($isListening -and -not $proxyHealthy) { $reason += "health-probe-failed(hung-proxy)" }

        if ($failCount -ge 2 -and -not $proxyCleared) {
            Write-WatchdogFailureLog "Failure detected: $($reason -join ', '). Clearing proxy."
            Clear-Proxy
            $proxyCleared = $true

            # Kill lingering NetFusion engine process if engine mutex is dead
            if (-not $engineAlive) {
                try {
                    $netFusionEngineProcs = @(
                        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                            Where-Object { $_.CommandLine -and $_.CommandLine -match 'NetFusionEngine' }
                    )
                    foreach ($p in $netFusionEngineProcs) {
                        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
            }

            # RC-2: DO NOT EXIT -- keep running to re-guard
            # If the engine restarts, we'll detect it and re-enable the proxy
            Write-Host "  [Watchdog] Continuing to guard. Will re-enable proxy when engine recovers." -ForegroundColor Yellow
        }
    } else {
        # Everything healthy
        if ($proxyCleared) {
            # Engine recovered! Re-enable the proxy
            Write-Host "  [Watchdog] Engine recovered! Re-enabling proxy." -ForegroundColor Green
            Restore-Proxy -Port $proxyPort
            $proxyCleared = $false
            Write-WatchdogFailureLog "Engine recovered. Proxy re-enabled."
        }
        $failCount = 0
    }
}
} finally {
    if ($script:WatchdogMutexHeld -and $script:WatchdogMutex) {
        try { $script:WatchdogMutex.ReleaseMutex() } catch {}
    }
    if ($script:WatchdogMutex) {
        try { $script:WatchdogMutex.Dispose() } catch {}
    }
}
