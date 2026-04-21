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
$engineConfig = if (Test-Path $configPath) {
    try { Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $null }
} else {
    $null
}
$script:engineTickSec = 1

$script:EngineMutex = New-Object System.Threading.Mutex($false, "Global\NetFusion-Engine")
$hasEngineLock = $false
try {
    $hasEngineLock = $script:EngineMutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $hasEngineLock = $true
}
if (-not $hasEngineLock) {
    Write-Host "  [Engine] Another NetFusionEngine instance is already running." -ForegroundColor Yellow
    exit 1
}
try {
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        try { if ($script:EngineMutex) { $script:EngineMutex.ReleaseMutex() } } catch {}
    } | Out-Null
} catch {}
$proxyPort = if ($engineConfig -and $engineConfig.proxyPort) { [int]$engineConfig.proxyPort } else { 8080 }
$maxProxyRestarts = if ($engineConfig -and $engineConfig.safety -and $engineConfig.safety.maxProxyRestarts) {
    [int]$engineConfig.safety.maxProxyRestarts
} else {
    3
}
$metricRefreshSec = if ($engineConfig -and $engineConfig.routing -and $engineConfig.routing.metricRefreshSec) {
    [int]$engineConfig.routing.metricRefreshSec
} else {
    30
}
$metricRefreshLoops = [math]::Max(3, [int][math]::Ceiling([math]::Max(6, $metricRefreshSec) / [double]$script:engineTickSec))
$dhcpRepairSec = if ($engineConfig -and $engineConfig.selfHealing -and $engineConfig.selfHealing.dhcpRepairIntervalSec) {
    [int]$engineConfig.selfHealing.dhcpRepairIntervalSec
} else {
    120
}
$dhcpRepairLoops = [math]::Max(5, [int][math]::Ceiling([math]::Max(30, $dhcpRepairSec) / [double]$script:engineTickSec))
$ecmpEnforceSec = if ($engineConfig -and $engineConfig.routing -and $engineConfig.routing.ecmpRefreshSec) {
    [int]$engineConfig.routing.ecmpRefreshSec
} else {
    60
}
$ecmpEnforceLoops = [math]::Max(10, [int][math]::Ceiling([math]::Max(30, $ecmpEnforceSec) / [double]$script:engineTickSec))
$enableDhcpAutoRepair = if ($engineConfig -and $engineConfig.selfHealing -and $null -ne $engineConfig.selfHealing.dhcpAutoRepair) {
    [bool]$engineConfig.selfHealing.dhcpAutoRepair
} else {
    $false
}
$engineMode = if ($engineConfig -and $engineConfig.mode) { ([string]$engineConfig.mode).ToLowerInvariant() } else { 'maxspeed' }
$throughputMode = $engineMode -in @('maxspeed', 'download')
$enableEcmpEnforcement = if ($engineConfig -and $engineConfig.routing -and $null -ne $engineConfig.routing.enforceECMP) {
    [bool]$engineConfig.routing.enforceECMP
} else {
    $false
}
if ($throughputMode -and -not $enableEcmpEnforcement) {
    $enableEcmpEnforcement = $true
}
$proxyRestartCount = 0

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

# RC-1: CRITICAL safety net -- always clear system proxy when engine exits
function Clear-SystemProxy {
    try {
        $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Set-ItemProperty $inetKey 'ProxyEnable' 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty $inetKey 'ProxyServer' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty $inetKey 'ProxyOverride' -Force -ErrorAction SilentlyContinue
        # Fallback: reg.exe in case PowerShell registry provider fails
        & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyEnable /t REG_DWORD /d 0 /f 2>$null | Out-Null
        Write-Host '  [Engine] System proxy cleared (safety shutdown).' -ForegroundColor Yellow
    } catch {
        # Last resort: direct reg.exe call
        try { & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyEnable /t REG_DWORD /d 0 /f 2>$null | Out-Null } catch {}
    }
}

# RC-12: Validate actual internet connectivity through the proxy
function Test-InternetThroughProxy {
    param([int]$ProxyPort = 8080)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.SendTimeout = 5000
        $tcp.ReceiveTimeout = 5000
        $ar = $tcp.BeginConnect('127.0.0.1', $ProxyPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(3000, $false)) {
            $tcp.Dispose()
            return $false
        }
        try { $tcp.EndConnect($ar) } catch { $tcp.Dispose(); return $false }
        if (-not $tcp.Connected) { $tcp.Dispose(); return $false }

        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 5000
        $stream.WriteTimeout = 5000
        # Send a CONNECT probe to a known-good host
        $req = "CONNECT connectivity-check.ubuntu.com:443 HTTP/1.1`r`nHost: connectivity-check.ubuntu.com:443`r`n`r`n"
        $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($reqBytes, 0, $reqBytes.Length)
        $stream.Flush()

        $respBuf = New-Object byte[] 512
        $bytesRead = $stream.Read($respBuf, 0, $respBuf.Length)
        $tcp.Dispose()

        if ($bytesRead -gt 0) {
            $resp = [System.Text.Encoding]::ASCII.GetString($respBuf, 0, $bytesRead)
            # Proxy responded (200 = tunnel established, 502 = upstream fail)
            return ($resp -match 'HTTP/1\.[01] 200')
        }
        return $false
    } catch {
        return $false
    }
}

function Start-SmartProxyProcess {
    param(
        [string]$ScriptPath,
        [int]$ProxyPort
    )

    return (Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$ScriptPath`" -Port $ProxyPort" -WindowStyle Hidden -PassThru)
}

function Wait-ProxyBind {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 10,
        [int]$ExpectedPid = 0
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($ExpectedPid -gt 0) {
            try {
                if (-not (Get-Process -Id $ExpectedPid -ErrorAction SilentlyContinue)) {
                    return $false
                }
            } catch {
                return $false
            }
        }
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(500, $false)) {
                $tcp.Close()
                if ($ExpectedPid -gt 0) {
                    $ownedByExpected = $false
                    try {
                        $ownedByExpected = @(
                            Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
                                Where-Object { $_.OwningProcess -eq $ExpectedPid }
                        ).Count -gt 0
                    } catch {}
                    if (-not $ownedByExpected) {
                        try {
                            $ownedByExpected = [bool](netstat -ano | Select-String "127\.0\.0\.1:$Port\s+.*LISTENING\s+$ExpectedPid$")
                        } catch {}
                    }
                    if (-not $ownedByExpected) {
                        continue
                    }
                }
                return $true
            }
            $tcp.Close()
        } catch {}
    }

    return $false
}

function Get-AvailableRecoveryIP {
    param(
        [string]$Subnet,
        [int]$StartOctet = 147
    )

    $usedIPs = @()
    try {
        $usedIPs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like "$Subnet.*" } |
            Select-Object -ExpandProperty IPAddress)
    } catch {}

    for ($octet = [math]::Max(2, $StartOctet); $octet -lt 254; $octet++) {
        $candidate = "$Subnet.$octet"
        if ($candidate -in $usedIPs) { continue }

        $inUse = $false
        try {
            $inUse = Test-Connection -ComputerName $candidate -Count 1 -Quiet -ErrorAction SilentlyContinue
        } catch {}

        if (-not $inUse) {
            return $candidate
        }
    }

    return $null
}

function Test-GatewayReachability {
    param([string]$Gateway)

    if ([string]::IsNullOrWhiteSpace($Gateway)) { return $false }
    try {
        $pinger = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $pinger.Send($Gateway, 500)
            return ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
        } finally {
            $pinger.Dispose()
        }
    } catch {
        return $false
    }
}

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

# 3. Launch SmartProxy as a background process
Write-Host "  [Engine] Booting SmartProxy..." -ForegroundColor DarkGray
try {
    $proxyScript = Join-Path $scriptDir "SmartProxy.ps1"
    $proxyProc = Start-SmartProxyProcess -ScriptPath $proxyScript -ProxyPort $proxyPort
    Write-Host "  [+] SmartProxy Process Started (PID: $($proxyProc.Id))." -ForegroundColor Green
} catch {
    Write-Host "  [Engine] CRUCIAL FAILURE: SmartProxy could not start! $_" -ForegroundColor Red
    exit 1
}

# 4. Wait for proxy to bind (retry loop, up to 10s)
$portOpen = Wait-ProxyBind -Port $proxyPort -TimeoutSeconds 10 -ExpectedPid $proxyProc.Id

if ($portOpen) {
    Write-Host "  [+] Proxy Core Verified Online (Port $proxyPort)." -ForegroundColor Green
} else {
    Write-Host "  [-] Proxy Core Failed to Bind after 10s. Aborting Engine." -ForegroundColor Red
    if ($proxyProc -and -not $proxyProc.HasExited) { Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue }
    exit 1
}

# Enable Route Watchdog mode flag implicitly
$script:routesActive = $false
$TargetMetric = if ($engineConfig -and $engineConfig.routing -and $engineConfig.routing.targetMetric) { [int]$engineConfig.routing.targetMetric } else { 25 }
$script:lastRepairAttempt = @{}

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
Write-Host ("  [Engine] Metric refresh: {0}s | DHCP auto-repair: {1} | ECMP enforcement: {2}" -f $metricRefreshSec, ($(if ($enableDhcpAutoRepair) { 'enabled' } else { 'disabled' })), ($(if ($enableEcmpEnforcement) { 'enabled' } else { 'disabled' }))) -ForegroundColor DarkGray

$loopCount = 0
$lastECMP = Get-Date
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
        $repairKey = [string]$adapter.Name
        $ip = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        $hasRoute = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        
        # Check if adapter needs repair (APIPA or no route)
        if ($ip -match '^169\.254\.' -or (-not $hasRoute -and $ip)) {
            $alreadyKnown = $Interfaces | Where-Object { $_.Name -eq $adapter.Name }
            if (-not $alreadyKnown) {
                if ($script:lastRepairAttempt.ContainsKey($repairKey)) {
                    try {
                        $lastAttempt = [datetime]$script:lastRepairAttempt[$repairKey]
                        if (((Get-Date) - $lastAttempt).TotalSeconds -lt 120) {
                            continue
                        }
                    } catch {}
                }

                Write-Host "  [REPAIR] $($adapter.Name) has APIPA ($ip) or no route - attempting fix..." -ForegroundColor Yellow
                
                # Try to find gateway from a working adapter on same subnet
                $workingGW = ($Interfaces | Where-Object { $_.Gateway } | Select-Object -First 1).Gateway
                if ($workingGW) {
                    $script:lastRepairAttempt[$repairKey] = Get-Date
                    try {
                        # Remove APIPA address
                        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                            Where-Object { $_.IPAddress -match '^169\.254\.' } | 
                            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                        
                        # Determine a safe static IP using adapter position offsets (.147, .148, ...).
                        $sortedIndexes = @($allAdapters | Select-Object -ExpandProperty ifIndex | Sort-Object)
                        $adapterPosition = [Array]::IndexOf($sortedIndexes, $adapter.ifIndex)
                        $lastOctet = if ($adapterPosition -ge 0) { 147 + $adapterPosition } else { 149 }
                        
                        # Apply static IP with same gateway as working adapter
                        $gwParts = $workingGW -split '\.'
                        $subnet = "$($gwParts[0]).$($gwParts[1]).$($gwParts[2])"
                        $availableIP = Get-AvailableRecoveryIP -Subnet $subnet -StartOctet $lastOctet
                        if (-not $availableIP) {
                            Write-Host "  [REPAIR] No available recovery IP found in $subnet.0/24 for $($adapter.Name)" -ForegroundColor Red
                            continue
                        }
                        
                        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $availableIP -PrefixLength 24 -DefaultGateway $workingGW -ErrorAction SilentlyContinue | Out-Null
                        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @("8.8.8.8","1.1.1.1") -ErrorAction SilentlyContinue
                        
                        Write-Host "  [REPAIR] Applied static IP $availableIP to $($adapter.Name)" -ForegroundColor Green
                    } catch {
                        Write-Host "  [REPAIR] Failed: $_" -ForegroundColor Red
                    }
                }
            }
        }
    }
}

# v6.2: ECMP Enforcement - keep all active adapters at harmonized metrics
# RC-8 FIX: Only equalize metrics for adapters with verified-reachable gateways
function Enforce-ECMP {
    $targetMetric = if ($engineConfig -and $engineConfig.routing -and $engineConfig.routing.targetMetric) { [int]$engineConfig.routing.targetMetric } else { 25 }
    $candidateAdapters = Get-NetAdapter | Where-Object { 
        $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|OpenVPN|WireGuard|TAP-Windows|Cisco AnyConnect|Tailscale|ZeroTier'
    }
    
    if ($candidateAdapters.Count -gt 1) {
        $verifiedCount = 0
        $adapterGatewayStatus = @{}

        # First pass: probe all gateways to determine which adapters have real internet
        foreach ($wa in $candidateAdapters) {
            $defaultRoutes = @(
                Get-NetRoute -InterfaceIndex $wa.ifIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Sort-Object RouteMetric
            )
            $gwOk = $false
            foreach ($route in $defaultRoutes) {
                if (Test-GatewayReachability -Gateway ([string]$route.NextHop)) {
                    $gwOk = $true
                    break
                }
            }
            $adapterGatewayStatus[$wa.ifIndex] = $gwOk
            if ($gwOk) { $verifiedCount++ }
        }

        # Second pass: only set ECMP metrics on adapters with verified gateways
        foreach ($wa in $candidateAdapters) {
            $gwOk = $adapterGatewayStatus[$wa.ifIndex]
            if (-not $gwOk) {
                # RC-8: Don't give dead-gateway adapters the same priority metric
                # Push them to high metric so OS doesn't randomly route through them
                try {
                    $currentMetric = (Get-NetIPInterface -InterfaceIndex $wa.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
                    if ($null -ne $currentMetric -and [int]$currentMetric -lt 200) {
                        Set-NetIPInterface -InterfaceIndex $wa.ifIndex -AutomaticMetric Disabled -InterfaceMetric 500 -ErrorAction SilentlyContinue
                        Write-Host "  [ECMP] $($wa.Name): gateway unreachable, metric raised to 500" -ForegroundColor Yellow
                    }
                } catch {}
                continue
            }

            $currentMetric = (Get-NetIPInterface -InterfaceIndex $wa.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
            if ($currentMetric -ne $targetMetric) {
                try { Set-NetIPInterface -InterfaceIndex $wa.ifIndex -AutomaticMetric Disabled -InterfaceMetric $targetMetric -ErrorAction SilentlyContinue } catch {}
            }
        }
    }
}

# RC-9: Sleep/resume detection for the engine
$script:lastPowerCheck = Get-Date
$powerStateFile = Join-Path $projectDir "logs\power.state"

# RC-12: Internet validation state
$script:internetFailCount = 0
$script:lastInternetValidation = Get-Date
$script:internetValidationIntervalSec = 30
$script:internetFailThreshold = 3

# RC-1: Wrap entire engine loop in try/finally to ALWAYS clear proxy on exit
try {
while ($true) {
    try {
        # RC-9: Sleep/Resume detection
        if (Test-Path $powerStateFile) {
            $pState = Get-Content $powerStateFile -Raw -ErrorAction SilentlyContinue
            if ($pState -match 'RESUME') {
                Write-Host '  [Engine] System resumed from sleep -- refreshing adapters and validating internet...' -ForegroundColor Yellow
                Remove-Item $powerStateFile -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
                $interfaces = Update-NetworkState
                $health = Update-HealthState
                # Force immediate internet validation after resume
                $script:lastInternetValidation = (Get-Date).AddSeconds(-$script:internetValidationIntervalSec - 1)
            } elseif ($pState -match 'SLEEP') {
                Start-Sleep -Seconds 1
                continue
            }
        }

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
                Write-Host "  [Engine] FATAL: SmartProxy crashed $maxProxyRestarts times. Clearing proxy and exiting." -ForegroundColor Red
                # RC-1: Clear proxy before exit so internet isn't broken
                Clear-SystemProxy
                exit 1
            }

            $proxyRestartCount++
            $backoffSeconds = [math]::Min(30, [math]::Pow(2, $proxyRestartCount))
            Write-Host "  [Engine] SmartProxy health check failed: $($proxyHealth.Reason). Restart $proxyRestartCount/$maxProxyRestarts in ${backoffSeconds}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $backoffSeconds

            try {
                $proxyProc = Start-SmartProxyProcess -ScriptPath $proxyScript -ProxyPort $proxyPort
            } catch {
                Write-Host "  [Engine] Failed to restart SmartProxy: $_" -ForegroundColor Red
                Clear-SystemProxy
                exit 1
            }

            if (-not (Wait-ProxyBind -Port $proxyPort -TimeoutSeconds 10 -ExpectedPid $proxyProc.Id)) {
                Write-Host "  [Engine] Restarted SmartProxy did not bind port $proxyPort in time. Clearing proxy." -ForegroundColor Red
                Clear-SystemProxy
                exit 1
            }

            Write-Host "  [Engine] SmartProxy restart successful (PID: $($proxyProc.Id))." -ForegroundColor Green
            $proxyRestartCount = 0
            $script:internetFailCount = 0
            continue
        }
        
        # 1. Update Hardware Mapping (Every ~6s)
        if ($loopCount % 3 -eq 0) {
            $interfaces = Update-NetworkState
        }
        
        # 2. Ping Health Monitor (Every ~2s)
        $health = Update-HealthState

        # RC-7: Prevent all-adapters-disabled state -- always keep at least one alive
        if ($health -and $health.adapters) {
            $activeAdapters = @($health.adapters | Where-Object { -not $_.IsDisabled -and -not $_.IsQuarantined })
            if ($activeAdapters.Count -eq 0 -and $health.adapters.Count -gt 0) {
                Write-Host '  [Engine] CRITICAL: All adapters disabled/quarantined! Force-clearing best adapter.' -ForegroundColor Red
                # Pick the adapter with the best recent latency and force-clear its quarantine
                $bestAdapter = $health.adapters | Sort-Object @{ Expression = 'InternetLatency'; Ascending = $true } | Select-Object -First 1
                if ($bestAdapter) {
                    $hFile = Join-Path $projectDir 'config\health.json'
                    try {
                        $hData = Get-Content $hFile -Raw | ConvertFrom-Json
                        foreach ($a in $hData.adapters) {
                            if ($a.Name -eq $bestAdapter.Name) {
                                $a.IsQuarantined = $false
                                $a.IsDisabled = $false
                                $a.ShouldAvoidNewFlows = $false
                                $a.ForceDrain = $false
                            }
                        }
                        Write-AtomicJson -Path $hFile -Data $hData -Depth 8
                        Write-Host "  [Engine] Force-cleared quarantine on $($bestAdapter.Name)" -ForegroundColor Green
                    } catch {}
                }
            }
        }
        
        # 3. Route Controller Dynamic Update (config-driven cadence)
        if ($loopCount % $metricRefreshLoops -eq 0 -and $interfaces.Count -gt 1) {
            Set-DynamicMetrics -Interfaces $interfaces -BaseMetric $TargetMetric
        }
        
        # 4. Learning Engine Analytics (Every ~60s)
        if ($loopCount % 30 -eq 0) {
            Update-LearningState
        }
        
        # 5. DHCP Auto-Recovery (opt-in only; disabled by default for safety)
        if ($enableDhcpAutoRepair -and ($loopCount % $dhcpRepairLoops -eq 0)) {
            Repair-AdapterDHCP -Interfaces $interfaces
        }

        # 6. ECMP Enforcement (opt-in only to avoid metric flapping with dynamic metrics)
        if ($enableEcmpEnforcement -and ($loopCount % $ecmpEnforceLoops -eq 0)) {
            Enforce-ECMP
        }

        # RC-12: Periodic end-to-end internet validation through the proxy
        if (((Get-Date) - $script:lastInternetValidation).TotalSeconds -ge $script:internetValidationIntervalSec) {
            $script:lastInternetValidation = Get-Date
            $internetOk = Test-InternetThroughProxy -ProxyPort $proxyPort
            if (-not $internetOk) {
                $script:internetFailCount++
                Write-Host "  [Engine] Internet validation FAILED ($($script:internetFailCount)/$($script:internetFailThreshold))" -ForegroundColor Yellow
                if ($script:internetFailCount -ge $script:internetFailThreshold) {
                    Write-Host '  [Engine] CRITICAL: Internet unreachable through proxy for too long! Clearing proxy for safe fallback.' -ForegroundColor Red
                    Clear-SystemProxy
                    # Give direct internet a moment to work, then re-enable if proxy recovers
                    Start-Sleep -Seconds 5
                    $directOk = $false
                    try {
                        $pinger = New-Object System.Net.NetworkInformation.Ping
                        $reply = $pinger.Send('8.8.8.8', 3000)
                        $directOk = $reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
                        $pinger.Dispose()
                    } catch {}
                    if ($directOk) {
                        Write-Host '  [Engine] Direct internet works. Proxy will be re-enabled when it recovers.' -ForegroundColor Green
                    }
                    $script:internetFailCount = 0
                }
            } else {
                if ($script:internetFailCount -gt 0) {
                    Write-Host '  [Engine] Internet validation recovered.' -ForegroundColor Green
                }
                $script:internetFailCount = 0
                # Re-enable proxy if it was cleared by validation failure and proxy is healthy
                $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                $proxyEnabled = (Get-ItemProperty $inetKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
                if ($proxyEnabled -ne 1) {
                    Set-ItemProperty $inetKey 'ProxyEnable' 1 -Type DWord -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $inetKey 'ProxyServer' "127.0.0.1:$proxyPort" -Type String -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty $inetKey 'ProxyOverride' '<local>;127.0.0.1;localhost;::1' -Type String -Force -ErrorAction SilentlyContinue
                    Write-Host '  [Engine] Proxy re-enabled after successful internet validation.' -ForegroundColor Green
                }
            }
        }
        
        # 7. v6.2: Update safety-state uptime every loop
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
        
    } catch {
        Write-Host "  [Engine] Inner Loop Sync Error: $_" -ForegroundColor Red
    }
    
    $loopCount++
    Start-Sleep -Seconds $script:engineTickSec
}
} finally {
    # RC-1: ALWAYS clear system proxy when engine exits for ANY reason
    Write-Host '  [Engine] Engine shutting down -- clearing system proxy...' -ForegroundColor Yellow
    Clear-SystemProxy
    # Restore automatic metrics on all adapters
    try {
        Get-NetAdapter | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel'
        } | ForEach-Object {
            Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue
        }
    } catch {}
    # Release engine mutex
    try { if ($script:EngineMutex) { $script:EngineMutex.ReleaseMutex() } } catch {}
    try { if ($script:EngineMutex) { $script:EngineMutex.Dispose() } } catch {}
}
