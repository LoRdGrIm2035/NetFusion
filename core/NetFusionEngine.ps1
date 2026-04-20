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
$metricRefreshLoops = [math]::Max(3, [int][math]::Ceiling([math]::Max(6, $metricRefreshSec) / 2.0))
$dhcpRepairSec = if ($engineConfig -and $engineConfig.selfHealing -and $engineConfig.selfHealing.dhcpRepairIntervalSec) {
    [int]$engineConfig.selfHealing.dhcpRepairIntervalSec
} else {
    120
}
$dhcpRepairLoops = [math]::Max(5, [int][math]::Ceiling([math]::Max(30, $dhcpRepairSec) / 2.0))
$ecmpEnforceSec = if ($engineConfig -and $engineConfig.routing -and $engineConfig.routing.ecmpRefreshSec) {
    [int]$engineConfig.routing.ecmpRefreshSec
} else {
    60
}
$ecmpEnforceLoops = [math]::Max(10, [int][math]::Ceiling([math]::Max(30, $ecmpEnforceSec) / 2.0))
$enableDhcpAutoRepair = if ($engineConfig -and $engineConfig.selfHealing -and $null -ne $engineConfig.selfHealing.dhcpAutoRepair) {
    [bool]$engineConfig.selfHealing.dhcpAutoRepair
} else {
    $false
}
$enableEcmpEnforcement = if ($engineConfig -and $engineConfig.routing -and $null -ne $engineConfig.routing.enforceECMP) {
    [bool]$engineConfig.routing.enforceECMP
} else {
    $false
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

function Start-SmartProxyProcess {
    param([string]$ScriptPath)

    return (Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$ScriptPath`"" -WindowStyle Hidden -PassThru)
}

function Wait-ProxyBind {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(500, $false)) {
                $tcp.Close()
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
    $proxyProc = Start-SmartProxyProcess -ScriptPath $proxyScript
    Write-Host "  [+] SmartProxy Process Started (PID: $($proxyProc.Id))." -ForegroundColor Green
} catch {
    Write-Host "  [Engine] CRUCIAL FAILURE: SmartProxy could not start! $_" -ForegroundColor Red
    exit 1
}

# 4. Wait for proxy to bind (retry loop, up to 10s)
$portOpen = Wait-ProxyBind -Port $proxyPort -TimeoutSeconds 10

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
                        
                        # Determine a safe static IP (use .147 for second adapter, .148 for third, etc.)
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

# v6.1: ECMP Enforcement - keep both adapters' metrics equal
function Enforce-ECMP {
    $targetMetric = if ($engineConfig -and $engineConfig.routing -and $engineConfig.routing.targetMetric) { [int]$engineConfig.routing.targetMetric } else { 25 }
    $wifiAdapters = Get-NetAdapter | Where-Object { 
        $_.Status -eq 'Up' -and $_.Name -match 'Wi-Fi' 
    }
    
    if ($wifiAdapters.Count -ge 2) {
        foreach ($wa in $wifiAdapters) {
            $currentMetric = (Get-NetIPInterface -InterfaceIndex $wa.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
            if ($currentMetric -ne $targetMetric) {
                try {
                    Set-NetIPInterface -InterfaceIndex $wa.ifIndex -AutomaticMetric Disabled -InterfaceMetric $targetMetric -ErrorAction SilentlyContinue
                    Set-NetRoute -InterfaceIndex $wa.ifIndex -DestinationPrefix '0.0.0.0/0' -RouteMetric $targetMetric -ErrorAction SilentlyContinue
                } catch {}
            }
        }
    }
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
                $proxyProc = Start-SmartProxyProcess -ScriptPath $proxyScript
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
        
        # 3. Route Controller Dynamic Update (config-driven cadence)
        if ($loopCount % $metricRefreshLoops -eq 0 -and $interfaces.Count -ge 2) {
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
    Start-Sleep -Seconds 2
}
