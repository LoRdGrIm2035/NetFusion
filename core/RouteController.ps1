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
. (Join-Path $projectDir "core\NetworkState.ps1")

# Ensure logs dir
$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

# Load config
$configPath = Join-Path $projectDir "config\config.json"
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
$ethernetPriority = if ($config -and $config.routing -and $config.routing.ethernetPriority) { $config.routing.ethernetPriority } else { $true }

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
    <# v6.2 safety: keep the primary adapter untouched and only maintain secondary metrics/routes. #>
    param([array]$Interfaces, [int]$BaseMetric)

    if (-not $Interfaces -or $Interfaces.Count -lt 2) {
        return
    }

    $state = Read-NetworkState
    if ($state) {
        try {
            [void](Ensure-NetFusionRoutes)
            foreach ($iface in $Interfaces) {
                $metricInfo = Get-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                if ($metricInfo) {
                    $script:adapterMetrics[$iface.Name] = [int]$metricInfo.InterfaceMetric
                }
            }
            Write-Host "    * Route safety refresh complete (primary metric preserved)" -ForegroundColor Green
            return
        } catch {
            Write-Host "    x Route safety refresh failed -> $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $liveMetrics = @()
    foreach ($iface in $Interfaces) {
        $ipif = Get-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ipif) {
            $liveMetrics += [pscustomobject]@{
                Name = $iface.Name
                InterfaceIndex = [int]$iface.InterfaceIndex
                InterfaceMetric = [int]$ipif.InterfaceMetric
            }
        }
    }

    if ($liveMetrics.Count -lt 2) {
        return
    }

    $primary = $liveMetrics | Sort-Object InterfaceMetric, InterfaceIndex | Select-Object -First 1
    $primaryMetric = [int]$primary.InterfaceMetric
    $secondaryRank = 0

    foreach ($iface in ($liveMetrics | Sort-Object @{ Expression = { if ($_.InterfaceIndex -eq $primary.InterfaceIndex) { 0 } else { 1 } } }, InterfaceMetric, InterfaceIndex)) {
        if ($iface.InterfaceIndex -eq $primary.InterfaceIndex) {
            $script:adapterMetrics[$iface.Name] = $primaryMetric
            Write-Host "    * $($iface.Name) (index $($iface.InterfaceIndex)) -> primary metric preserved at $primaryMetric" -ForegroundColor Green
            continue
        }

        $secondaryRank++
        $desiredMetric = [Math]::Max([int]$iface.InterfaceMetric, $primaryMetric + ($secondaryRank * 50))
        $script:adapterMetrics[$iface.Name] = $desiredMetric

        try {
            Set-InterfaceMetric -InterfaceIndex $iface.InterfaceIndex -Metric $desiredMetric
            Write-Host "    * $($iface.Name) (index $($iface.InterfaceIndex)) -> secondary metric $desiredMetric" -ForegroundColor Green
        } catch {
            Write-Host "    x $($iface.Name) (index $($iface.InterfaceIndex)) -> $($_.Exception.Message)" -ForegroundColor Red
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
        $dnsConfig = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $dnsConfig -or -not $dnsConfig.ServerAddresses -or @($dnsConfig.ServerAddresses).Count -eq 0) {
            # NetFusion-FIX-16: Fall back to neutral public resolvers when an adapter lacks usable DNS so WAN-specific lookups stay consistent.
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @('1.1.1.1', '8.8.8.8') -ErrorAction SilentlyContinue
        }

        # Test DNS resolution
        Resolve-DnsName -Name 'www.google.com' -DnsOnly -ErrorAction Stop -QuickTimeout 2>$null | Out-Null
        $script:dnsVerified[$name] = @{ verified = $true; time = Get-Date }
    } catch {
        Write-Host "  [DNS] $name DNS resolution failed -- adding fallback DNS" -ForegroundColor Yellow
        Write-RouteEvent "DNS failsafe: adding 8.8.8.8 + 1.1.1.1 to $name"
        try {
            # NetFusion-FIX-16: Fall back to neutral public resolvers when an adapter has broken DNS so CDN lookups stop depending on the wrong WAN.
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @('1.1.1.1', '8.8.8.8') -ErrorAction SilentlyContinue
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
$script:IsRouteControllerDotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $script:IsRouteControllerDotSourced) {
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
}
