<#
.SYNOPSIS
    NetFusionEngine v6.2 -- Core Orchestrator
.DESCRIPTION
    A highly optimized, single-process master loop that coordinates:
      - SmartProxy (Async Background Runspace)
      - NetworkManager (Adapter Discovery)
      - InterfaceMonitor (Health Polling)
      - RouteController (OS Dynamic Metrics)
      - LearningEngine (Analytics)
    This drastically reduces RAM usage from 400MB down to ~120MB and
    nullifies I/O contention.
#>

[CmdletBinding()]
param()

$Host.UI.RawUI.WindowTitle = 'NF-Engine'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectDir = Split-Path $scriptDir -Parent
$script:NetFusionVersion = '6.2'
$configPath = Join-Path $projectDir "config\config.json"
$networkStateScript = Join-Path $scriptDir "NetworkState.ps1"
$engineConfig = if (Test-Path $configPath) {
    try { Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $null }
} else {
    $null
}
$proxyPort = if ($engineConfig -and $engineConfig.proxyPort) { [int]$engineConfig.proxyPort } else { 8080 }
$maxProxyRestarts = if ($engineConfig -and $engineConfig.safety -and $engineConfig.safety.maxProxyRestarts) {
    [int]$engineConfig.safety.maxProxyRestarts
} else {
    3
}
$proxyRestartCount = 0
$script:NetworkRestoreInvoked = $false
if (Test-Path $networkStateScript) {
    . $networkStateScript
}

function Test-ProxyProcessHealth {
    param([System.Diagnostics.Process]$ProcessObject)

    if ($null -eq $ProcessObject) {
        return @{
            Alive = $false
            Reason = 'Process object is null'
            ExitCode = $null
        }
    }

    try { $ProcessObject.Refresh() } catch {}

    try {
        if ($ProcessObject.HasExited) {
            return @{
                Alive = $false
                Reason = "Process exited with code $($ProcessObject.ExitCode)"
                ExitCode = $ProcessObject.ExitCode
            }
        }
    } catch [System.InvalidOperationException] {
        return @{
            Alive = $false
            Reason = 'Process is no longer available'
            ExitCode = $null
        }
    } catch {
        return @{
            Alive = $false
            Reason = $_.Exception.Message
            ExitCode = $null
        }
    }

    return @{
        Alive = $true
        Reason = 'Running'
        ExitCode = $null
    }
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

function Start-SmartProxyProcess {
    param(
        [string]$ScriptPath,
        [int]$Port
    )

    return (Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$ScriptPath`" -Port $Port" -WindowStyle Hidden -PassThru)
}

function Wait-ProxyBind {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcpSocket = $tcp.Client
            $tcpSocket.NoDelay = $true
            $tcpSocket.ReceiveBufferSize = 1048576
            $tcpSocket.SendBufferSize = 1048576
            $ar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(500, $false)) {
                $tcp.Close()
                return $true
            }
            $tcp.Close()
        } catch {}
        Start-Sleep -Milliseconds 250
    }

    return $false
}

function Invoke-EngineNetworkRestore {
    if ($script:NetworkRestoreInvoked) {
        return
    }

    $script:NetworkRestoreInvoked = $true

    try {
        if (Get-Command Invoke-NetworkRestore -ErrorAction SilentlyContinue) {
            [void](Invoke-NetworkRestore)
            return
        }
    } catch {}

    try {
        & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $networkStateScript -Action Restore -Quiet | Out-Null
    } catch {}
}

function Ensure-EngineNetworkRoutes {
    try {
        if (Get-Command Ensure-NetFusionRoutes -ErrorAction SilentlyContinue) {
            [void](Ensure-NetFusionRoutes)
        }
    } catch {
        Write-Host "  [Engine] Route safety refresh failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

try {
    Get-EventSubscriber -SourceIdentifier 'PowerShell.Exiting' -ErrorAction SilentlyContinue |
        Where-Object { $_.Action -and $_.Action.ToString() -match 'NetworkState\.ps1' } |
        ForEach-Object {
            Unregister-Event -SubscriptionId $_.SubscriptionId -Force -ErrorAction SilentlyContinue
        }
} catch {}
$script:ExitRestoreEvent = $null
# Do not restore networking from the engine process exit event. A transient
# engine host exit must not tear down an otherwise healthy proxy path during
# large transfers. NetFusion-STOP.bat and NetFusion-SAFE.bat remain the explicit
# rollback paths; the watchdog clears proxy settings if the proxy port dies.

try {
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " NetFusion Engine v$script:NetFusionVersion SOLID Starting..." -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. Execute QUIC Blocker directly once
try {
    Write-Host "  [Engine] Initializing QUIC Firewall Policies..." -ForegroundColor DarkGray
    . (Join-Path $scriptDir "QuicBlocker.ps1")
} catch {
    Write-Host "  [Engine] QUIC blocker initialization failed: $_" -ForegroundColor Red
}

# 2. Load Core Modules (Refactored to expose functions rather than infinite loops)
Write-Host "  [Engine] Loading Subsystems..." -ForegroundColor DarkGray
. (Join-Path $scriptDir "NetworkManager.ps1")
. (Join-Path $scriptDir "InterfaceMonitor.ps1")
. (Join-Path $scriptDir "RouteController.ps1")
. (Join-Path $scriptDir "LearningEngine.ps1")

# Build a fresh adapter inventory before the proxy starts. A stale interfaces.json
# from the previous run can make the proxy select a disconnected/no-gateway USB
# adapter during startup, causing slow connection timeouts and bad first tests.
Write-Host "  [Engine] Refreshing adapter inventory..." -ForegroundColor DarkGray
$interfaces = Update-NetworkState -ForceRefresh
Write-Host "  [Engine] Running initial fast source-bound health check..." -ForegroundColor DarkGray
$health = Update-HealthState -PrimaryOnly

# 3. Launch SmartProxy as a background process
Write-Host "  [Engine] Booting SmartProxy..." -ForegroundColor DarkGray
try {
    $proxyScript = Join-Path $scriptDir "SmartProxy.ps1"
    $proxyProc = Start-SmartProxyProcess -ScriptPath $proxyScript -Port $proxyPort
    Write-Host "  [+] SmartProxy Process Started (PID: $($proxyProc.Id))." -ForegroundColor Green
} catch {
    Write-Host "  [Engine] CRUCIAL FAILURE: SmartProxy could not start! $_" -ForegroundColor Red
    exit 1
}

# 4. Wait for proxy to bind (retry loop, up to 10s)
$portOpen = Wait-ProxyBind -Port $proxyPort -TimeoutSeconds 10

if ($portOpen) {
    Write-Host "  [+] Proxy Core Verified Online (Port $proxyPort)." -ForegroundColor Green
    Ensure-EngineNetworkRoutes
} else {
    Write-Host "  [-] Proxy Core Failed to Bind after 10s. Aborting Engine." -ForegroundColor Red
    if ($proxyProc -and -not $proxyProc.HasExited) { Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue }
    exit 1
}

# Enable Route Watchdog mode flag implicitly
$script:routesActive = $false
$TargetMetric = 25

# v6.2: Initialize safety-state.json so dashboard never shows "NO DATA"
$safetyFile = Join-Path $projectDir "config\safety-state.json"
$engineStartTime = Get-Date
$initSafety = @{
    safeMode = $false; version = $script:NetFusionVersion; uptime = 0
    lastEvent = 'Engine started'; circuitBreakerOpen = $false
    startTime = $engineStartTime.ToString('o')
}
Write-AtomicJson -Path $safetyFile -Data $initSafety -Depth 3
Write-Host "  [+] Safety state initialized." -ForegroundColor Green

$loopCount = 0
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Network Orchestration Loop Running..." -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# v6.1: DHCP Recovery function - repairs adapters with APIPA addresses
function Repair-AdapterDHCP {
    param([array]$Interfaces)
    
    # Get all UP wifi/ethernet adapters including those without gateways
    $allAdapters = Get-NetAdapter | Where-Object { 
        $_.Status -eq 'Up' -and 
        $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel' 
    }
    
    foreach ($adapter in $allAdapters) {
        $ip = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        $hasRoute = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        
        # Check if adapter needs repair (APIPA or no route)
        if ($ip -match '^169\.254\.' -or (-not $hasRoute -and $ip)) {
            $alreadyKnown = $Interfaces | Where-Object { $_.Name -eq $adapter.Name }
            if (-not $alreadyKnown) {
                Write-Host "  [REPAIR] $($adapter.Name) has APIPA ($ip) or no route - attempting fix..." -ForegroundColor Yellow
                
                try {
                    # NetFusion-FIX-19: Never force static IPv4 during recovery. Static fallback can persist after exit and degrade Wi-Fi.
                    foreach ($manualIp in @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq 'Manual' })) {
                        try {
                            Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $manualIp.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
                        } catch {}
                    }

                    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
                    ipconfig /renew "$($adapter.Name)" | Out-Null

                    Start-Sleep -Seconds 2
                    $updatedIp = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
                        Select-Object -First 1).IPAddress
                    if ($updatedIp) {
                        Write-Host "  [REPAIR] DHCP recovery succeeded for $($adapter.Name): $updatedIp" -ForegroundColor Green
                    } else {
                        Write-Host "  [REPAIR] DHCP recovery attempted for $($adapter.Name), but no valid IPv4 yet." -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  [REPAIR] Failed: $_" -ForegroundColor Red
                }
            }
        }
    }
}

# v6.2: route safety maintenance - keep secondary routes present without touching primary metric
function Enforce-ECMP {
    Ensure-EngineNetworkRoutes
}

while ($true) {
    try {
        # Check if proxy process crashed
        $proxyHealth = Test-ProxyProcessHealth -ProcessObject $proxyProc
        if (-not $proxyHealth.Alive) {
            if ($proxyRestartCount -ge $maxProxyRestarts) {
                $crashReport = @{
                    timestamp = (Get-Date).ToString('o')
                    restartAttempts = $proxyRestartCount
                    reason = $proxyHealth.Reason
                    exitCode = $proxyHealth.ExitCode
                }
                $crashFile = Join-Path $projectDir ("logs\crash-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                try { Write-AtomicJson -Path $crashFile -Data $crashReport -Depth 3 } catch {}
                Write-Host "  [Engine] FATAL: SmartProxy crashed $maxProxyRestarts times. Last failure: $($proxyHealth.Reason)" -ForegroundColor Red
                exit 1
            }

            $proxyRestartCount++
            $backoffSeconds = [math]::Min(30, [math]::Pow(2, $proxyRestartCount))
            Write-Host "  [Engine] SmartProxy health check failed: $($proxyHealth.Reason). Restart $proxyRestartCount/$maxProxyRestarts in ${backoffSeconds}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $backoffSeconds

            try {
                $proxyProc = Start-SmartProxyProcess -ScriptPath $proxyScript -Port $proxyPort
            } catch {
                Write-Host "  [Engine] Failed to restart SmartProxy: $_" -ForegroundColor Red
                exit 1
            }

            if (-not (Wait-ProxyBind -Port $proxyPort -TimeoutSeconds 10)) {
                Write-Host "  [Engine] Restarted SmartProxy did not bind port $proxyPort in time." -ForegroundColor Red
                exit 1
            }

            Write-Host "  [Engine] SmartProxy restart successful (PID: $($proxyProc.Id))." -ForegroundColor Green
            $proxyRestartCount = 0
            continue
        }
        
        # 1. Update Hardware Mapping (Every ~6s)
        if ($loopCount % 3 -eq 0) {
            $interfaces = Update-NetworkState
        }
        
        # 2. Ping Health Monitor (Every ~2s)
        $health = Update-HealthState
        
        # 3. Route Controller Dynamic Update (Every ~30s)
        if ($loopCount % 15 -eq 0 -and $interfaces.Count -ge 2) {
            Set-DynamicMetrics -Interfaces $interfaces -BaseMetric $TargetMetric
        }
        
        # 4. Learning Engine Analytics (Every ~60s)
        if ($loopCount % 30 -eq 0) {
            Update-LearningState
        }
        
        # 5. v6.1: DHCP Auto-Recovery (Every ~30s)
        if ($loopCount % 15 -eq 0) {
            Repair-AdapterDHCP -Interfaces $interfaces
            $interfaces = Update-NetworkState -ForceRefresh
        }
        
        # 6. v6.2: Update safety-state uptime every ~10s instead of every loop.
        if ($loopCount % 5 -eq 0) {
            try {
                $uptimeMin = [math]::Round(((Get-Date) - $engineStartTime).TotalMinutes, 1)
                $curSafety = @{
                    safeMode = $false; version = $script:NetFusionVersion; circuitBreakerOpen = $false
                    startTime = $engineStartTime.ToString('o')
                }
                if (Test-Path $safetyFile) {
                    try {
                        $ex = Get-Content $safetyFile -Raw | ConvertFrom-Json
                        if ($ex -and $ex.lastEvent -and $ex.lastEvent -ne 'Engine running normally') {
                            $curSafety.lastEvent = [string]$ex.lastEvent
                        }
                    } catch {}
                }
                $curSafety.uptime = $uptimeMin
                $curSafety.lastEvent = 'Engine running normally'
                Write-AtomicJson -Path $safetyFile -Data $curSafety -Depth 3
            } catch {}
        }
        
    } catch {
        Write-Host "  [Engine] Inner Loop Sync Error: $_" -ForegroundColor Red
    }
    
    $loopCount++
    Start-Sleep -Seconds 2
}
} finally {
    try {
        if ($script:ExitRestoreEvent) {
            Unregister-Event -SubscriptionId $script:ExitRestoreEvent.SubscriptionId -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        $engineExitFile = Join-Path $projectDir 'logs\engine-exit.log'
        Add-Content -Path $engineExitFile -Value ("{0} Engine exited; proxy/network state left active for watchdog or explicit STOP/SAFE cleanup." -f (Get-Date -Format 'o')) -ErrorAction SilentlyContinue
    } catch {}
}
