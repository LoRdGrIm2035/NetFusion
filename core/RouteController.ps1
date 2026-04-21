<#
.SYNOPSIS
    RouteController v5.0 -- Safe dynamic routing with metric management.
.DESCRIPTION
    v5.0 design: Proxy is primary distribution method. Routes are secondary.
      - Dynamic metric adjustment based on real-time health scores
      - Metric decisions derive from live health and capacity signals
      - Self-healing: DNS verification, gateway change detection
      - Route verification with retry (up to 3 attempts)
      - Safe mode awareness: skips all changes when safe mode active
      - Split routes are optional (only in MaxSpeed mode via explicit Enable)
.PARAMETER Action
    Enable, Disable, Status, or Watch (continuous monitoring).
#>

[CmdletBinding()]
param(
    [ValidateSet('Enable','Disable','Status','Watch')]
    [string]$Action = 'Status',
    [int]$TargetMetric = 25,
    [int]$WatchInterval = 15
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$InterfacesFile = Join-Path $projectDir "config\interfaces.json"
$HealthFile = Join-Path $projectDir "config\health.json"
$EventsFile = Join-Path $projectDir "logs\events.json"
$SafetyFile = Join-Path $projectDir "config\safety-state.json"
. (Join-Path $projectDir "core\RouteAdapter.ps1")

# Ensure logs dir
$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

# Load config
$configPath = Join-Path $projectDir "config\config.json"
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
$script:throughputMode = if ($config -and $config.mode -and ([string]$config.mode).ToLowerInvariant() -in @('maxspeed', 'download')) { $true } else { $false }

$script:prevAdapterSet = @()
$script:routesActive = $false
$script:adapterMetrics = @{}       # Dynamic per-adapter metrics
$script:dnsVerified = @{}          # DNS verification status
$script:routeRetryCount = @{}     # Route creation retry tracking
$script:prevGateways = @{}         # Previous gateways for DHCP change detection
$script:loopCount = 0              # Watch loop counter for periodic tasks
$script:metricSnapshots = @{}      # interfaceIndex -> original metric/auto state
$script:RouteControllerLogMutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")
$script:RouteControllerRequiresLock = $Action -in @('Enable','Disable','Watch')
$script:RouteControllerInstanceMutex = $null
$script:RouteControllerInstanceHeld = $false
if ($script:RouteControllerRequiresLock) {
    $script:RouteControllerInstanceMutex = New-Object System.Threading.Mutex($false, "Global\NetFusion-RouteController")
    try {
        $script:RouteControllerInstanceHeld = $script:RouteControllerInstanceMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $script:RouteControllerInstanceHeld = $true
    }
    if (-not $script:RouteControllerInstanceHeld) {
        Write-Host "  [RouteCtrl] Another RouteController instance is already running." -ForegroundColor Yellow
        exit 1
    }
}

function Write-AtomicJson {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 3
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

function Write-AtomicText {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tmp = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    try {
        Set-Content -Path $tmp -Value $Content -Encoding UTF8 -Force -ErrorAction Stop
        Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Repair-EventsFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-AtomicJson -Path $Path -Data @{ events = @() } -Depth 3
        return
    }

    try {
        $existing = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $existing -or -not $existing.events) {
            throw "Invalid event store"
        }
    } catch {
        Write-AtomicJson -Path $Path -Data @{ events = @() } -Depth 3
    }
}

function Test-SafeMode {
    <# v5.0: Check if safe mode is active -- skip all routing changes if true. #>
    if (Test-Path $SafetyFile) {
        try {
            $safety = Get-Content $SafetyFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($safety -and $safety.safeMode -eq $true) { return $true }
        } catch {}
    }
    return $false
}

function Write-RouteEvent {
    param([string]$Message)
    Write-Host "  [RouteCtrl] $Message" -ForegroundColor Cyan
    $mutexTaken = $false
    try {
        try {
            $mutexTaken = $script:RouteControllerLogMutex.WaitOne(3000)
        } catch [System.Threading.AbandonedMutexException] {
            try { Repair-EventsFile -Path $EventsFile } catch {}
            $mutexTaken = $true
        }

        if (-not $mutexTaken) { return }

        try {
            $events = @()
            if (Test-Path $EventsFile) {
                $data = Get-Content $EventsFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($data -and $data.events) { $events = @($data.events) }
            }
            $evt = @{ timestamp = (Get-Date).ToString('o'); type = 'route'; adapter = ''; message = $Message }
            $events = @($evt) + $events
            if ($events.Count -gt 200) { $events = $events[0..199] }

            Write-AtomicJson -Path $EventsFile -Data @{ events = $events }
        } finally {
            if ($mutexTaken) {
                try { $script:RouteControllerLogMutex.ReleaseMutex() } catch {}
            }
        }
    } catch {}
}

function Get-ActiveInterfaces {
    if (Test-Path $InterfacesFile) {
        try {
            $data = Get-Content $InterfacesFile -Raw | ConvertFrom-Json
            return @($data.interfaces | Where-Object { $_.IPAddress -and $_.Gateway })
        } catch {}
    }

    # Fallback: direct detection
    $adapters = Get-NetworkAdapters
    $results = @()
    foreach ($a in $adapters) {
        $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        $gw = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Sort-Object RouteMetric | Select-Object -First 1).NextHop
        if ($ip -and $gw) {
            $type = 'Unknown'
            $ipIf4 = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $ifType = if ($ipIf4 -and $null -ne $ipIf4.InterfaceType) { [int]$ipIf4.InterfaceType } else { 0 }
            $mediaType = if ($null -ne $a.MediaType) { [string]$a.MediaType } else { '' }
            $physicalMediaType = if ($null -ne $a.PhysicalMediaType) { [string]$a.PhysicalMediaType } else { '' }
            $desc = [string]$a.InterfaceDescription
            $isUsb = $desc -match '(?i)USB'
            $isWifi = $ifType -eq 71 -or $desc -match '(?i)Wi-Fi|Wireless|802\.11|WLAN' -or $mediaType -match '(?i)Native802_11|Wireless' -or $physicalMediaType -match '(?i)Native802_11|Wireless'
            $isEthernet = $ifType -eq 6 -or $desc -match '(?i)Ethernet|GbE|RJ45' -or $mediaType -match '(?i)802\.3|Ethernet'
            $isWwan = $ifType -in @(243, 244) -or $desc -match '(?i)WWAN|Cellular|Mobile'

            if ($isWifi -and $isUsb) { $type = 'USB-WiFi' }
            elseif ($isWifi) { $type = 'WiFi' }
            elseif ($isEthernet -and $isUsb) { $type = 'USB-Ethernet' }
            elseif ($isEthernet) { $type = 'Ethernet' }
            elseif ($isWwan) { $type = 'Cellular' }
            $results += @{ Name = $a.Name; InterfaceIndex = $a.ifIndex; IPAddress = $ip; Gateway = $gw; Type = $type }
        }
    }
    return $results
}

function Get-AdapterHealthScore {
    <# Read adapter health from health.json for dynamic metric calculation. #>
    param([string]$Name)
    if (Test-Path $HealthFile) {
        try {
            $hData = Get-Content $HealthFile -Raw | ConvertFrom-Json
            $adapter = $hData.adapters | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
            if ($adapter) {
                return @{
                    Score = $adapter.HealthScore
                    Score01 = if ($adapter.HealthScore01) { [double]$adapter.HealthScore01 } else { [math]::Min(1.0, [math]::Max(0.0, [double]$adapter.HealthScore / 100.0)) }
                    IsDegrading = if ($adapter.IsDegrading) { $adapter.IsDegrading } else { $false }
                    Latency = if ($adapter.InternetLatencyEWMA) { $adapter.InternetLatencyEWMA } else { $adapter.InternetLatency }
                    IsQuarantined = if ($adapter.IsQuarantined) { $true } else { $false }
                    IsDisabled = if ($adapter.IsDisabled) { $true } else { $false }
                    ShouldAvoidNewFlows = if ($adapter.ShouldAvoidNewFlows) { $true } else { $false }
                }
            }
        } catch {}
    }
    return @{ Score = 80; Score01 = 0.8; IsDegrading = $false; Latency = 50; IsQuarantined = $false; IsDisabled = $false; ShouldAvoidNewFlows = $false }
}

function Save-InterfaceMetricSnapshot {
    param([int]$InterfaceIndex)

    if ($script:metricSnapshots.ContainsKey($InterfaceIndex)) { return }
    try {
        $ipif = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ipif) {
            $script:metricSnapshots[$InterfaceIndex] = @{
                AutomaticMetric = [string]$ipif.AutomaticMetric
                InterfaceMetric = if ($null -ne $ipif.InterfaceMetric) { [int]$ipif.InterfaceMetric } else { 0 }
            }
        }
    } catch {}
}

function Restore-InterfaceMetricSnapshot {
    param([int]$InterfaceIndex)

    if (-not $script:metricSnapshots.ContainsKey($InterfaceIndex)) { return }
    $snapshot = $script:metricSnapshots[$InterfaceIndex]
    try {
        if ($snapshot.AutomaticMetric -match 'Enabled|True|1') {
            Enable-AutomaticMetric -InterfaceIndex $InterfaceIndex
        } else {
            Set-InterfaceMetric -InterfaceIndex $InterfaceIndex -Metric ([int]$snapshot.InterfaceMetric)
        }
    } catch {
        Write-RouteEvent "Failed to restore metric snapshot for ifIndex=${InterfaceIndex}: $($_.Exception.Message)"
    }
}

function Set-DynamicMetrics {
    <# v4.0+: Set metrics from real-time health telemetry. Lower metric = higher priority. #>
    param([array]$Interfaces, [int]$BaseMetric)

    $liveAdapterCache = @{}
    try {
        foreach ($adapter in @(Get-NetworkAdapters)) {
            if ($adapter -and $adapter.Name -and -not $liveAdapterCache.ContainsKey($adapter.Name)) {
                $liveAdapterCache[$adapter.Name] = $adapter
            }
        }
    } catch {}

    foreach ($iface in $Interfaces) {
        $idx = $iface.InterfaceIndex
        $name = $iface.Name
        $type = if ($iface.Type) { $iface.Type } else { 'Unknown' }

        $health = Get-AdapterHealthScore -Name $name
        $metric = $BaseMetric

        # Keep base metrics uniform and let health/capacity telemetry decide.
        # This avoids hardcoding adapter-type preference (e.g., Ethernet > Wi-Fi).

        # Health-based adjustment using 0.0-1.0 thresholds.
        $health01 = if ($null -ne $health.Score01) { [double]$health.Score01 } else { [math]::Min(1.0, [math]::Max(0.0, [double]$health.Score / 100.0)) }
        if ($health.IsDisabled -or $health.IsQuarantined -or $health01 -lt 0.3) {
            $metric += 80
        } elseif ($health01 -lt 0.5 -or $health.ShouldAvoidNewFlows) {
            $metric += 30
        } elseif ($health01 -lt 0.8 -or $health.IsDegrading) {
            $metric += 10
        }

        $metric = [math]::Max(5, [math]::Min(900, [int]$metric))

        $script:adapterMetrics[$name] = $metric

        $liveIdx = $null
        try {
            # Resolve from a single per-pass adapter cache to avoid repeated OS queries.
            $liveAdapter = if ($liveAdapterCache.ContainsKey($name)) { $liveAdapterCache[$name] } else { $null }
            if (-not $liveAdapter) {
                Write-Host "    - $name -> waiting for adapter to initialize..." -ForegroundColor DarkGray
                continue
            }
            $liveIdx = $liveAdapter.ifIndex

            # Verify IPv4 is bound to the interface before touching metrics
            $ipif = Get-NetIPInterface -InterfaceIndex $liveIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if (-not $ipif) {
                Write-Host "    - $name (index $liveIdx) -> waiting for IPv4 to bind..." -ForegroundColor DarkGray
                continue
            }

            $currentMetric = if ($null -ne $ipif.InterfaceMetric) { [int]$ipif.InterfaceMetric } else { -1 }
            $autoMetricState = [string]$ipif.AutomaticMetric
            $autoDisabled = $autoMetricState -match 'Disabled|False|0'
            if ($autoDisabled -and $currentMetric -eq $metric) {
                Write-Host "    - $name (index $liveIdx) -> metric unchanged ($metric)" -ForegroundColor DarkGray
                continue
            }

            Save-InterfaceMetricSnapshot -InterfaceIndex $liveIdx
            try {
                Set-InterfaceMetric -InterfaceIndex $liveIdx -Metric $metric
                Write-Host "    * $name (index $liveIdx) -> metric $metric [$type HP:$($health.Score)]" -ForegroundColor Green
            } catch {
                Restore-InterfaceMetricSnapshot -InterfaceIndex $liveIdx
                throw
            }
        } catch {
            $idxLabel = if ($null -ne $liveIdx) { $liveIdx } else { '(unknown)' }
            Write-Host "    x $name (index $idxLabel) -> $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Restore-AutoMetrics {
    param([array]$Interfaces)
    foreach ($iface in $Interfaces) {
        try {
            Enable-AutomaticMetric -InterfaceIndex $iface.InterfaceIndex
            Write-Host "    * $($iface.Name) -> auto metric" -ForegroundColor Green
        } catch {
            Write-Host "    x $($iface.Name) -> $_" -ForegroundColor Red
        }
    }
}

function Get-SplitPrefixes {
    param([int]$Count)
    return @()
}

function Add-SplitRoutes {
    <# Safety policy: do not modify default-route split prefixes. #>
    param([array]$Interfaces)
    Write-RouteEvent "Split-route mutation skipped by safety policy (default route remains untouched)."
    $script:routesActive = $false
    return $false
}

function Remove-SplitRoutes {
    param([switch]$Silent)
    if (-not $Silent) {
        Write-RouteEvent "Split-route removal skipped by safety policy."
    }
    $script:routesActive = $false
}

function Test-RoutesIntact {
    <# No split-route enforcement in safety mode. #>
    return $true
}

function Test-DNSResolution {
    <# v4.0: Verify DNS works on each adapter, fix if broken. #>
    param([object]$Interface)
    $name = $Interface.Name
    $idx = $Interface.InterfaceIndex

    if ($script:dnsVerified[$name] -and ((Get-Date) - $script:dnsVerified[$name].time).TotalMinutes -lt 5) {
        return  # Verified recently
    }

    try {
        # Test DNS resolution
        Resolve-DnsName -Name 'www.google.com' -DnsOnly -ErrorAction Stop -QuickTimeout 2>$null | Out-Null
        $script:dnsVerified[$name] = @{ verified = $true; time = Get-Date }
    } catch {
        Write-Host "  [DNS] $name DNS resolution failed -- adding fallback DNS" -ForegroundColor Yellow
        Write-RouteEvent "DNS failsafe: adding 8.8.8.8 + 1.1.1.1 to $name"
        try {
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @('8.8.8.8', '1.1.1.1') -ErrorAction SilentlyContinue
        } catch {}
        $script:dnsVerified[$name] = @{ verified = $false; time = Get-Date }
    }
}

function Test-GatewayChanged {
    <# v4.0: Detect gateway changes from DHCP renewals. #>
    param([object]$Interface)
    $name = $Interface.Name
    $currentGw = $Interface.Gateway

    if ($script:prevGateways.ContainsKey($name) -and $script:prevGateways[$name] -ne $currentGw) {
        Write-RouteEvent "Gateway changed for $name : $($script:prevGateways[$name]) -> $currentGw"
        Write-Host "  [!] Gateway changed: $name ($($script:prevGateways[$name]) -> $currentGw)" -ForegroundColor Yellow
        $script:prevGateways[$name] = $currentGw
        return $true
    }
    $script:prevGateways[$name] = $currentGw
    return $false
}

function Show-Status {
    Write-Host ""
    Write-Host "  === Route Status (v4.0) ===" -ForegroundColor Cyan
    $interfaces = Get-ActiveInterfaces
    Write-Host "  Active interfaces: $($interfaces.Count)" -ForegroundColor White

    foreach ($iface in $interfaces) {
        $metricInfo = Get-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $metric = if ($metricInfo) { $metricInfo.InterfaceMetric } else { '?' }
        $auto = if ($metricInfo) { $metricInfo.AutomaticMetric } else { '?' }
        $health = Get-AdapterHealthScore -Name $iface.Name
        $type = if ($iface.Type) { $iface.Type } else { 'Unknown' }
        Write-Host "    $($iface.Name) | IP: $($iface.IPAddress) | GW: $($iface.Gateway) | Metric: $metric (Auto: $auto) | HP:$($health.Score) [$type]" -ForegroundColor DarkGray
    }

    Write-Host "`n  Split routes: disabled by safety policy (metric-only routing)." -ForegroundColor Yellow
    Write-Host ""
}

function Invoke-WatchMode {
    Write-Host ""
    Write-Host "  [RouteController v5.0] Watch mode -- monitoring every ${WatchInterval}s" -ForegroundColor Cyan
    Write-Host "  v5.0: Proxy is primary distribution. Routes provide metric management only." -ForegroundColor DarkGray
    Write-Host "  Self-healing: DNS failsafe, gateway detection, metric refresh, VPN passthrough, sleep/resume" -ForegroundColor DarkGray
    Write-Host ""
    
    $script:vpnMode = $false

    # Register power event hook dynamically
    function Register-PowerHandler {
        try {
            Unregister-Event -SourceIdentifier "PowerEventHook" -ErrorAction SilentlyContinue
            $script:powerJob = Register-WmiEvent -Class Win32_PowerManagementEvent -SourceIdentifier "PowerEventHook" -Action {
                $powerFile = "$using:projectDir\logs\power.state"
                $tmp = [System.IO.Path]::GetTempFileName()
                if ($Event.SourceEventArgs.NewEvent.EventType -eq 4) {
                    Set-Content -Path $tmp -Value "SLEEP" -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                    Move-Item -Path $tmp -Destination $powerFile -Force -ErrorAction SilentlyContinue
                } elseif ($Event.SourceEventArgs.NewEvent.EventType -eq 7) {
                    Set-Content -Path $tmp -Value "RESUME" -Encoding UTF8 -Force -ErrorAction SilentlyContinue
                    Move-Item -Path $tmp -Destination $powerFile -Force -ErrorAction SilentlyContinue
                } else {
                    Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
                }
            } -ErrorAction SilentlyContinue
        } catch {}
    }
    Register-PowerHandler

    # Initial setup -- set metrics only (no split routes by default in v5.0)
    $interfaces = Get-ActiveInterfaces
    if ($interfaces.Count -gt 1 -and -not (Test-SafeMode)) {
        Set-DynamicMetrics -Interfaces $interfaces -BaseMetric $TargetMetric
        Write-AtomicText -Path "$projectDir\config\routes-applied.flag" -Content "routes_applied"
        # v5.0: Do NOT add split routes by default -- proxy handles distribution
    } elseif (Test-SafeMode) {
        Write-Host "  [!] Safe mode active -- skipping all route changes" -ForegroundColor Yellow
    }
    $script:prevAdapterSet = $interfaces | ForEach-Object { $_.Name }

    while ($true) {
        try {
            # Sleep/Resume Check
            $powerStateFile = Join-Path $projectDir "logs\power.state"
            if (Test-Path $powerStateFile) {
                $pState = Get-Content $powerStateFile -Raw -ErrorAction SilentlyContinue
                if ($pState -match "SLEEP") {
                    Write-Host "  [Sleep] System is suspending... Pausing orchestration" -ForegroundColor DarkGray
                    Start-Sleep -Seconds $WatchInterval
                    continue
                } elseif ($pState -match "RESUME") {
                    Write-Host "  [Resume] System resuming. Waiting 5s to stabilize..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 5
                    Remove-Item $powerStateFile -ErrorAction SilentlyContinue
                    $script:prevAdapterSet = @()
                    $script:prevGateways = @{}
                }
            }
            
            # Watchdog: Verify power handler is active
            if (-not $script:powerJob -or $script:powerJob.State -eq 'Failed') {
                Write-Host "  [!] WMI resume handler dropped -- re-registering" -ForegroundColor Yellow
                Register-PowerHandler
            }

            # VPN Detection Check
            $vpnAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'OpenVPN|WireGuard|TAP-Windows|Cisco AnyConnect|Tailscale|ZeroTier|Virtual' }
            if ($vpnAdapters) {
                if (-not $script:vpnMode) {
                    $vpnNames = @($vpnAdapters | ForEach-Object { $_.Name }) -join ', '
                    Write-RouteEvent "VPN Detected! ($vpnNames) - Entering VPN passthrough mode"
                    Write-Host "  [!] VPN Detected - Disabling orchestration" -ForegroundColor Yellow
                    Remove-SplitRoutes -Silent
                    Restore-AutoMetrics -Interfaces (Get-ActiveInterfaces)
                    $script:vpnMode = $true
                }
                Start-Sleep -Seconds $WatchInterval
                continue
            } elseif ($script:vpnMode) {
                Write-RouteEvent "VPN Disconnected. Resuming orchestration."
                Write-Host "  [+] VPN Disconnected - Resuming orchestration" -ForegroundColor Green
                $script:vpnMode = $false
                $script:prevAdapterSet = @()
            }

            # v5.0: Safe mode check -- skip all changes
            if (Test-SafeMode) {
                Write-Host "  [Safe Mode] Active -- skipping route management" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $WatchInterval
                continue
            }

            $currentInterfaces = Get-ActiveInterfaces
            $currentNames = @($currentInterfaces | ForEach-Object { $_.Name })

            # Detect adapter changes
            $added = $currentNames | Where-Object { $_ -notin $script:prevAdapterSet }
            $removed = $script:prevAdapterSet | Where-Object { $_ -notin $currentNames }

            if ($added) {
                foreach ($name in $added) {
                    Write-RouteEvent "Adapter connected: $name"
                    Write-Host "  [+] Adapter connected: $name" -ForegroundColor Green
                }
                # v5.0: Only update metrics, no split routes (proxy handles distribution)
                Set-DynamicMetrics -Interfaces $currentInterfaces -BaseMetric $TargetMetric
            }

            if ($removed) {
                foreach ($name in $removed) {
                    Write-RouteEvent "Adapter disconnected: $name"
                    Write-Host "  [-] Adapter disconnected: $name" -ForegroundColor Red
                }
                # Clean any existing split routes on adapter change
                Remove-SplitRoutes -Silent
                if ($currentInterfaces.Count -gt 1) {
                    Set-DynamicMetrics -Interfaces $currentInterfaces -BaseMetric $TargetMetric
                } elseif ($currentInterfaces.Count -eq 1) {
                    Write-Host "  [!] Only 1 adapter -- restoring auto metrics" -ForegroundColor Yellow
                    Restore-AutoMetrics -Interfaces $currentInterfaces
                }
            }

            # Check for gateway changes (DHCP renewals)
            $gatewayChanged = $false
            foreach ($iface in $currentInterfaces) {
                if (Test-GatewayChanged -Interface $iface) {
                    $gatewayChanged = $true
                }
            }
            if ($gatewayChanged -and $currentInterfaces.Count -gt 1) {
                Write-RouteEvent "Gateway change detected -- refreshing metrics"
                Set-DynamicMetrics -Interfaces $currentInterfaces -BaseMetric $TargetMetric
            }

            # Self-heal: if split routes exist (user enabled MaxSpeed), verify them
            if ($currentInterfaces.Count -gt 1 -and $script:routesActive) {
                if (-not (Test-RoutesIntact)) {
                    Write-RouteEvent "Split routes corrupted -- auto-repairing"
                    Write-Host "  [!] Routes corrupted -- repairing..." -ForegroundColor Yellow
                    Set-DynamicMetrics -Interfaces $currentInterfaces -BaseMetric $TargetMetric
                    Add-SplitRoutes -Interfaces $currentInterfaces
                }
            }

            # Periodically refresh dynamic metrics based on current health
            if (-not $added -and -not $removed -and -not $gatewayChanged -and $currentInterfaces.Count -gt 1) {
                $needsRefresh = $false
                foreach ($iface in $currentInterfaces) {
                    $health = Get-AdapterHealthScore -Name $iface.Name
                    $currentMetric = $script:adapterMetrics[$iface.Name]
                    if ($health.IsDegrading -and $currentMetric -and $currentMetric -lt ($TargetMetric + 10)) {
                        $needsRefresh = $true
                        break
                    }
                }
                if ($needsRefresh) {
                    Write-Host "  [RouteCtrl] Refreshing metrics due to health changes" -ForegroundColor DarkGray
                    Set-DynamicMetrics -Interfaces $currentInterfaces -BaseMetric $TargetMetric
                }
            }

            # DNS verification (every 5 cycles)
            $script:loopCount++
            if ($script:loopCount % 5 -eq 0) {
                foreach ($iface in $currentInterfaces) {
                    Test-DNSResolution -Interface $iface
                }
            }

            $script:prevAdapterSet = $currentNames

        } catch {
            Write-Host "  [RouteController] Watch error: $_" -ForegroundColor Red
        }

        Start-Sleep -Seconds $WatchInterval
    }
}

# --- Main ---
try {
    $interfaces = Get-ActiveInterfaces

    switch ($Action) {
        'Enable' {
            Write-RouteEvent "Enabling metric-aware routing on $($interfaces.Count) interfaces (default route untouched)"
            Set-DynamicMetrics -Interfaces $interfaces -BaseMetric $TargetMetric
            Show-Status
        }
        'Disable' {
            Write-RouteEvent "Disabling metric-aware routing and restoring automatic metrics"
            foreach ($iface in $interfaces) {
                Restore-InterfaceMetricSnapshot -InterfaceIndex $iface.InterfaceIndex
            }
            Restore-AutoMetrics -Interfaces $interfaces
            Show-Status
        }
        'Status' {
            Show-Status
        }
        'Watch' {
            Invoke-WatchMode
        }
    }
} finally {
    if ($script:RouteControllerInstanceHeld -and $script:RouteControllerInstanceMutex) {
        try { $script:RouteControllerInstanceMutex.ReleaseMutex() } catch {}
    }
    if ($script:RouteControllerInstanceMutex) {
        try { $script:RouteControllerInstanceMutex.Dispose() } catch {}
    }
}

