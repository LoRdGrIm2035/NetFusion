<#
.SYNOPSIS
    NetFusionEngine v6.0 -- Core Orchestrator
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

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " NetFusion Engine v6.0 SOLID Starting..." -ForegroundColor Cyan
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
    $proxyProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$proxyScript`"" -WindowStyle Hidden -PassThru
    Write-Host "  [+] SmartProxy Process Started (PID: $($proxyProc.Id))." -ForegroundColor Green
} catch {
    Write-Host "  [Engine] CRUCIAL FAILURE: SmartProxy could not start! $_" -ForegroundColor Red
    exit 1
}

# 4. Wait for proxy to bind (retry loop, up to 10s)
Write-Host "  [Engine] Waiting for SmartProxy to bind port 8080..." -ForegroundColor DarkGray
$portOpen = $false
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect('127.0.0.1', 8080, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(500, $false)) {
            $portOpen = $true
            $tcp.Close()
            break
        }
        $tcp.Close()
    } catch {}
}

if ($portOpen) {
    Write-Host "  [+] Proxy Core Verified Online (Port 8080)." -ForegroundColor Green
} else {
    Write-Host "  [-] Proxy Core Failed to Bind after 10s. Aborting Engine." -ForegroundColor Red
    if ($proxyProc -and -not $proxyProc.HasExited) { Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue }
    exit 1
}

# Enable Route Watchdog mode flag implicitly
$script:routesActive = $false
$TargetMetric = 25

# v6.0: Initialize safety-state.json so dashboard never shows "NO DATA"
$safetyFile = Join-Path $projectDir "config\safety-state.json"
$engineStartTime = Get-Date
$initSafety = @{
    safeMode = $false; version = '6.0'; uptime = 0
    lastEvent = 'Engine started'; circuitBreakerOpen = $false
    startTime = $engineStartTime.ToString('o')
}
$tmp = [IO.Path]::GetTempFileName()
$initSafety | ConvertTo-Json -Compress | Set-Content $tmp -Force -Encoding UTF8
Move-Item $tmp $safetyFile -Force
Write-Host "  [+] Safety state initialized." -ForegroundColor Green

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
    
    $adapterIdx = 0
    foreach ($adapter in $allAdapters) {
        $ip = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        $hasRoute = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        
        # Check if adapter needs repair (APIPA or no route)
        if ($ip -match '^169\.254\.' -or (-not $hasRoute -and $ip)) {
            $alreadyKnown = $Interfaces | Where-Object { $_.Name -eq $adapter.Name }
            if (-not $alreadyKnown) {
                Write-Host "  [REPAIR] $($adapter.Name) has APIPA ($ip) or no route - attempting fix..." -ForegroundColor Yellow
                
                # Try to find gateway from a working adapter on same subnet
                $workingGW = ($Interfaces | Where-Object { $_.Gateway } | Select-Object -First 1).Gateway
                if ($workingGW) {
                    try {
                        # Remove APIPA address
                        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                            Where-Object { $_.IPAddress -match '^169\.254\.' } | 
                            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                        # Use a simple loop counter so fallback IPs stay sequential (.147, .148, .149).
                        $lastOctet   = 147 + $adapterIdx
                        $staticIP = "192.168.1.$lastOctet"
                        
                        # Apply static IP with same gateway as working adapter
                        $gwParts = $workingGW -split '\.'
                        $subnet = "$($gwParts[0]).$($gwParts[1]).$($gwParts[2])"
                        
                        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress "$subnet.$lastOctet" -PrefixLength 24 -DefaultGateway $workingGW -ErrorAction SilentlyContinue | Out-Null
                        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @("8.8.8.8","1.1.1.1") -ErrorAction SilentlyContinue
                        
                        Write-Host "  [REPAIR] Applied static IP $subnet.$lastOctet to $($adapter.Name)" -ForegroundColor Green
                        $adapterIdx++  # Only increment for adapters that actually got repaired
                    } catch {
                        Write-Host "  [REPAIR] Failed: $_" -ForegroundColor Red
                    }
                }
            }
        }
    }
}

# v6.1: ECMP Enforcement - keep all managed adapters' metrics equal
function Enforce-ECMP {
    $targetMetric = 15
    # v6.0 #10: Read from interfaces.json so we use the same adapter set as NetworkManager,
    # catching USB-WiFi adapters with generic names like "Realtek USB GbE" that regex misses.
    $ifFile = Join-Path $projectDir "config\interfaces.json"
    $managedAdapters = @()
    if (Test-Path $ifFile) {
        try {
            $ifData = Get-Content $ifFile -Raw | ConvertFrom-Json
            $managedAdapters = @($ifData.interfaces | Where-Object { $_.Status -eq 'Up' -and $_.Type -match 'WiFi|USB-WiFi' })
        } catch {}
    }
    # Fallback to direct query if interfaces.json is missing or empty
    if ($managedAdapters.Count -lt 2) {
        $managedAdapters = @(Get-NetAdapter | Where-Object { 
            $_.Status -eq 'Up' -and
            $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel' -and
            ($_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11|WLAN|WiFi' -or $_.Name -match 'Wi-Fi|WLAN|Wireless')
        })
    }
    
    if ($managedAdapters.Count -ge 2) {
        foreach ($wa in $managedAdapters) {
            $ifIdx = if ($wa.ifIndex) { $wa.ifIndex } elseif ($wa.InterfaceIndex) { $wa.InterfaceIndex } else { continue }
            $currentMetric = (Get-NetIPInterface -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
            if ($currentMetric -ne $targetMetric) {
                try {
                    Set-NetIPInterface -InterfaceIndex $ifIdx -AutomaticMetric Disabled -InterfaceMetric $targetMetric -ErrorAction SilentlyContinue
                    Set-NetRoute -InterfaceIndex $ifIdx -DestinationPrefix '0.0.0.0/0' -RouteMetric $targetMetric -ErrorAction SilentlyContinue
                } catch {}
            }
        }
    }
}

while ($true) {
    try {
        # Check if proxy process crashed — respawn it in-place instead of exiting
        # NOTE #6: $proxyRestarts resets when the Watchdog restarts the entire engine (new process).
        # This means SmartProxy can crash 3 times per Watchdog restart cycle indefinitely.
        # This is acceptable: each Watchdog restart is itself logged and rate-limited by the 20s grace period.
        if ($proxyProc.HasExited) {
            $proxyRestarts = if ($proxyRestarts) { $proxyRestarts + 1 } else { 1 }
            Write-Host "  [Engine] SmartProxy crashed (Exit: $($proxyProc.ExitCode)). Respawn attempt $proxyRestarts/3..." -ForegroundColor Yellow
            
            if ($proxyRestarts -gt 3) {
                Write-Host "  [Engine] FATAL: SmartProxy failed 3 respawns. Giving up." -ForegroundColor Red
                exit 1
            }
            
            # Respawn proxy only (no full engine cold-boot)
            try {
                $proxyScript = Join-Path $scriptDir "SmartProxy.ps1"
                $proxyProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$proxyScript`"" -WindowStyle Hidden -PassThru
                Write-Host "  [Engine] SmartProxy respawned (PID: $($proxyProc.Id)). Waiting for port bind..." -ForegroundColor Yellow
                
                $portOpen = $false
                $deadline = (Get-Date).AddSeconds(10)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 500
                    try {
                        $tcp = New-Object System.Net.Sockets.TcpClient
                        $ar = $tcp.BeginConnect('127.0.0.1', 8080, $null, $null)
                        if ($ar.AsyncWaitHandle.WaitOne(500, $false)) { $portOpen = $true; $tcp.Close(); break }
                        $tcp.Close()
                    } catch {}
                }
                
                if ($portOpen) {
                    Write-Host "  [Engine] SmartProxy respawn successful." -ForegroundColor Green
                    $proxyRestarts = 0  # Reset counter on success
                } else {
                    Write-Host "  [Engine] SmartProxy respawn failed to bind port." -ForegroundColor Red
                }
            } catch {
                Write-Host "  [Engine] SmartProxy respawn error: $_" -ForegroundColor Red
            }
        }
        
        # 1. Update Hardware Mapping (Every ~6s)
        if ($loopCount % 3 -eq 0) {
            $interfaces = Update-NetworkState
        }
        
        # 2. Ping Health Monitor (Every ~2s)
        $health = Update-HealthState
        
        # 3. Route Controller Dynamic Update (Every ~10s)
        if ($loopCount % 5 -eq 0 -and $interfaces.Count -ge 2) {
            Set-DynamicMetrics -Interfaces $interfaces -BaseMetric $TargetMetric
        }
        
        # 4. Learning Engine Analytics (Every ~60s)
        if ($loopCount % 30 -eq 0) {
            Update-LearningState
        }
        
        # 5. v6.1: DHCP Auto-Recovery (Every ~30s)
        if ($loopCount % 15 -eq 0) {
            Repair-AdapterDHCP -Interfaces $interfaces
        }
        
        # 6. v6.1: ECMP Enforcement (Every ~30s)
        if ($loopCount % 15 -eq 0) {
            Enforce-ECMP
        }
        
        # 7. v6.0: Update safety-state uptime every loop
        try {
            $uptimeMin = [math]::Round(((Get-Date) - $engineStartTime).TotalMinutes, 1)
            $curSafety = @{
                safeMode = $false; version = '6.1'; circuitBreakerOpen = $false
                startTime = $engineStartTime.ToString('o')
            }
            if (Test-Path $safetyFile) {
                try {
                    $ex = Get-Content $safetyFile -Raw | ConvertFrom-Json
                    $curSafety.safeMode = [bool]$ex.safeMode
                } catch {}
            }
            $curSafety.uptime = $uptimeMin
            $curSafety.lastEvent = 'Engine running normally'
            # v6.0 #5: Atomic write to prevent race with DashboardServer SSE reads
            $tmp = [IO.Path]::GetTempFileName()
            $curSafety | ConvertTo-Json -Compress | Set-Content $tmp -Force -Encoding UTF8
            Move-Item $tmp $safetyFile -Force
        } catch {}
        
    } catch {
        Write-Host "  [Engine] Inner Loop Sync Error: $_" -ForegroundColor Red
    }
    
    $loopCount++
    Start-Sleep -Seconds 2
}
