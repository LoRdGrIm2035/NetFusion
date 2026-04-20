<#
.SYNOPSIS
    RouteController v5.0 -- Safe dynamic routing with metric management.
.DESCRIPTION
    v5.0 design: Proxy is primary distribution method. Routes are secondary.
      - Dynamic metric adjustment based on real-time health scores
      - Ethernet gets lower metric for latency-sensitive traffic
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
$ethernetPriority = if ($config -and $config.routing -and $config.routing.ethernetPriority) { $config.routing.ethernetPriority } else { $true }
$script:throughputMode = if ($config -and $config.mode -and ([string]$config.mode).ToLowerInvariant() -in @('maxspeed', 'download')) { $true } else { $false }

$script:prevAdapterSet = @()
$script:routesActive = $false
$script:adapterMetrics = @{}       # Dynamic per-adapter metrics
$script:dnsVerified = @{}          # DNS verification status
$script:routeRetryCount = @{}     # Route creation retry tracking
$script:prevGateways = @{}         # Previous gateways for DHCP change detection
$script:loopCount = 0              # Watch loop counter for periodic tasks
$script:RouteControllerLogMutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")

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
            if ($a.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11' -or $a.Name -match 'Wi-Fi') {
                $type = if ($a.InterfaceDescription -match 'USB') { 'USB-WiFi' } else { 'WiFi' }
            } elseif ($a.InterfaceDescription -match 'Ethernet' -or $a.Name -match 'Ethernet') {
                $type = 'Ethernet'
            }
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
                    IsDegrading = if ($adapter.IsDegrading) { $adapter.IsDegrading } else { $false }
                    Latency = if ($adapter.InternetLatencyEWMA) { $adapter.InternetLatencyEWMA } else { $adapter.InternetLatency }
                }
            }
        } catch {}
    }
    return @{ Score = 80; IsDegrading = $false; Latency = 50 }
}

function Set-DynamicMetrics {
    <# v4.0: Set metrics based on adapter type and real-time health. Lower metric = higher priority. #>
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

        # Throughput-first mode keeps adapters close in metric so multi-flow
        # workloads can exploit both links. Outside throughput mode, preserve
        # legacy type-based preference.
        if (-not $script:throughputMode) {
            if ($ethernetPriority -and $type -eq 'Ethernet') {
                $metric = [math]::Max(5, $BaseMetric - 15)
            } elseif ($type -eq 'USB-WiFi') {
                $metric = $BaseMetric + 5  # Slight penalty for USB overhead
            }
        }

        # Health-based adjustment: degrading adapters get higher metric
        if ($health.IsDegrading) {
            $metric += 20
            Write-Host "    [!] $name is degrading -- metric increased to $metric" -ForegroundColor Yellow
        } elseif ($health.Score -lt 50) {
            $metric += 10
        }

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

            Set-InterfaceMetric -InterfaceIndex $liveIdx -Metric $metric
            Write-Host "    * $name (index $liveIdx) -> metric $metric [$type HP:$($health.Score)]" -ForegroundColor Green
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
    switch ($Count) {
        2 { return @('0.0.0.0/1', '128.0.0.0/1') }
        3 { return @('0.0.0.0/2', '64.0.0.0/2', '128.0.0.0/1') }
        default { return @() }
    }
}

function Add-SplitRoutes {
    <# v4.0: Add split routes with retry logic and verification. #>
    param([array]$Interfaces)
    $count = $Interfaces.Count
    if ($count -lt 2) {
        Write-Host "  Need 2+ interfaces for split routes. Found: $count" -ForegroundColor Yellow
        return $false
    }

    Remove-SplitRoutes -Silent
    $prefixes = Get-SplitPrefixes -Count $count

    if ($prefixes.Count -gt 0) {
        Write-RouteEvent "Creating $count-way split routes"
        for ($i = 0; $i -lt [math]::Min($count, $prefixes.Count); $i++) {
            $success = $false
            for ($retry = 0; $retry -lt 3; $retry++) {
                try {
                    Add-Route -DestinationPrefix $prefixes[$i] -InterfaceIndex $Interfaces[$i].InterfaceIndex -NextHop $Interfaces[$i].Gateway -RouteMetric 10

                    # Verify route was actually created
                    $verify = Get-NetRoute -DestinationPrefix $prefixes[$i] -InterfaceIndex $Interfaces[$i].InterfaceIndex -ErrorAction SilentlyContinue
                    if ($verify) {
                        Write-Host "    * $($prefixes[$i]) -> $($Interfaces[$i].Name) via $($Interfaces[$i].Gateway)" -ForegroundColor Green
                        $success = $true
                        break
                    }
                } catch {
                    if ($_.Exception.Message -match 'already exists') {
                        $success = $true
                        break
                    }
                    if ($retry -lt 2) {
                        Start-Sleep -Milliseconds 500
                    }
                }
            }
            if (-not $success) {
                Write-Host "    x $($prefixes[$i]) -> FAILED after 3 retries" -ForegroundColor Red
            }
        }
    } else {
        Write-RouteEvent "$count interfaces: using ECMP (equal metric routing)"
    }
    $script:routesActive = $true
    return $true
}

function Remove-SplitRoutes {
    param([switch]$Silent)
    $prefixes = @('0.0.0.0/1', '128.0.0.0/1', '0.0.0.0/2', '64.0.0.0/2')
    $removed = 0
    foreach ($prefix in $prefixes) {
        $routes = Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue
        foreach ($r in $routes) {
            Remove-Route -DestinationPrefix $prefix -InterfaceIndex $r.InterfaceIndex -NextHop $r.NextHop
            $removed++
        }
    }
    if (-not $Silent -and $removed -gt 0) {
        Write-RouteEvent "Removed $removed split routes"
    }
    $script:routesActive = $false
}

function Test-RoutesIntact {
    <# Check if our split routes still exist. #>
    $interfaces = Get-ActiveInterfaces
    if ($interfaces.Count -lt 2) { return $false }

    $prefixes = Get-SplitPrefixes -Count $interfaces.Count
    if ($prefixes.Count -eq 0) { return $true }  # ECMP mode, no explicit routes

    foreach ($prefix in $prefixes) {
        $exists = Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue
        if (-not $exists) { return $false }
    }
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

    $splitRoutes = Get-NetRoute -ErrorAction SilentlyContinue | Where-Object {
        $_.DestinationPrefix -match '^(0\.0\.0\.0/[12]|64\.0\.0\.0/2|128\.0\.0\.0/[12])$'
    }
    if ($splitRoutes) {
        Write-Host "`n  Split Routes:" -ForegroundColor Green
        foreach ($r in $splitRoutes) {
            $adapterName = (Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue).Name
            Write-Host "    $($r.DestinationPrefix) -> $($r.NextHop) [$adapterName]" -ForegroundColor Green
        }
    } else {
        Write-Host "`n  No split routes active." -ForegroundColor Yellow
    }
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
                if ($Event.SourceEventArgs.NewEvent.EventType -eq 4) {
                    Out-File -InputObject "SLEEP" -FilePath "$using:projectDir\logs\power.state"
                } elseif ($Event.SourceEventArgs.NewEvent.EventType -eq 7) {
                    Out-File -InputObject "RESUME" -FilePath "$using:projectDir\logs\power.state"
                }
            } -ErrorAction SilentlyContinue
        } catch {}
    }
    Register-PowerHandler

    # Initial setup -- set metrics only (no split routes by default in v5.0)
    $interfaces = Get-ActiveInterfaces
    if ($interfaces.Count -ge 2 -and -not (Test-SafeMode)) {
        Set-DynamicMetrics -Interfaces $interfaces -BaseMetric $TargetMetric
        Out-File -InputObject "routes_applied" -FilePath "$projectDir\config\routes-applied.flag"
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
                    Write-RouteEvent "VPN Detected! ($($vpnAdapters[0].Name)) - Entering VPN passthrough mode"
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
                if ($currentInterfaces.Count -ge 2) {
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
            if ($gatewayChanged -and $currentInterfaces.Count -ge 2) {
                Write-RouteEvent "Gateway change detected -- refreshing metrics"
                Set-DynamicMetrics -Interfaces $currentInterfaces -BaseMetric $TargetMetric
            }

            # Self-heal: if split routes exist (user enabled MaxSpeed), verify them
            if ($currentInterfaces.Count -ge 2 -and $script:routesActive) {
                if (-not (Test-RoutesIntact)) {
                    Write-RouteEvent "Split routes corrupted -- auto-repairing"
                    Write-Host "  [!] Routes corrupted -- repairing..." -ForegroundColor Yellow
                    Set-DynamicMetrics -Interfaces $currentInterfaces -BaseMetric $TargetMetric
                    Add-SplitRoutes -Interfaces $currentInterfaces
                }
            }

            # Periodically refresh dynamic metrics based on current health
            if (-not $added -and -not $removed -and -not $gatewayChanged -and $currentInterfaces.Count -ge 2) {
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
$interfaces = Get-ActiveInterfaces

switch ($Action) {
    'Enable' {
        Write-RouteEvent "Enabling load balancing on $($interfaces.Count) interfaces (v4.0 dynamic)"
        Set-DynamicMetrics -Interfaces $interfaces -BaseMetric $TargetMetric
        Add-SplitRoutes -Interfaces $interfaces
        Show-Status
    }
    'Disable' {
        Write-RouteEvent "Disabling load balancing"
        Remove-SplitRoutes
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

