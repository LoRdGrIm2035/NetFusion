<#
.SYNOPSIS
    SmartProxy v6.2 -- Production-grade intelligent connection orchestration engine.
.DESCRIPTION
    Local HTTP/HTTPS proxy with safety-first design:
      - Connection-level weighted round-robin with soft host hints
      - Adaptive thread pool: scales aggressively for burst traffic
      - Connection-type detection (bulk/interactive/streaming/gaming)
      - Per-connection adaptive scheduling with health-aware weights
      - Degradation-aware routing with predictive warnings
      - Decision logging for UI observability
      - Configurable buffer sizes per traffic type
      - Health endpoint for SafetyController watchdog
      - Self-monitoring (CPU/memory reporting)
      - Graceful failover with adapter exclusion
      - Safe mode awareness (stops routing when safe mode active)
#>

[CmdletBinding()]
param(
    [int]$Port = 8080
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$configFile = Join-Path $projectDir "config\config.json"
$healthFile = Join-Path $projectDir "config\health.json"
$interfacesFile = Join-Path $projectDir "config\interfaces.json"
$statsFile = Join-Path $projectDir "config\proxy-stats.json"
$eventsFile = Join-Path $projectDir "logs\events.json"
$decisionsFile = Join-Path $projectDir "config\decisions.json"
$safetyFile = Join-Path $projectDir "config\safety-state.json"

$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

if (-not ('NetFusion.StreamCopier' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace NetFusion
{
    public static class StreamCopier
    {
        private const int BufferSize = 262144;

        private static async Task CopyStreamCoreAsync(NetworkStream source, NetworkStream dest, long bytesToCopy, Action<int> onBytesTransferred, CancellationToken ct)
        {
            byte[] buffer = new byte[BufferSize];
            long remaining = bytesToCopy;
            while (!ct.IsCancellationRequested)
            {
                if (bytesToCopy >= 0 && remaining <= 0)
                {
                    break;
                }

                int toRead = bytesToCopy < 0 ? buffer.Length : (int)Math.Min(buffer.Length, remaining);
                int read = await source.ReadAsync(buffer, 0, toRead, ct).ConfigureAwait(false);
                if (read <= 0)
                {
                    break;
                }

                await dest.WriteAsync(buffer, 0, read, ct).ConfigureAwait(false);
                if (onBytesTransferred != null)
                {
                    onBytesTransferred(read);
                }

                if (bytesToCopy >= 0)
                {
                    remaining -= read;
                }
            }
        }

        public static void CopyStream(NetworkStream source, NetworkStream dest, ref long bytesTransferred)
        {
            using (var cts = new CancellationTokenSource())
            {
                long transferred = 0;
                try
                {
                    CopyStreamCoreAsync(source, dest, -1, n => Interlocked.Add(ref transferred, n), cts.Token).GetAwaiter().GetResult();
                }
                catch (OperationCanceledException)
                {
                }
                catch (IOException)
                {
                }
                catch (ObjectDisposedException)
                {
                }

                Interlocked.Add(ref bytesTransferred, transferred);
            }
        }

        public static void CopyStream(NetworkStream source, NetworkStream dest, long bytesToCopy, ref long bytesTransferred)
        {
            using (var cts = new CancellationTokenSource())
            {
                long transferred = 0;
                try
                {
                    CopyStreamCoreAsync(source, dest, bytesToCopy, n => Interlocked.Add(ref transferred, n), cts.Token).GetAwaiter().GetResult();
                }
                catch (OperationCanceledException)
                {
                }
                catch (IOException)
                {
                }
                catch (ObjectDisposedException)
                {
                }

                Interlocked.Add(ref bytesTransferred, transferred);
            }
        }

        public static void CopyStreamBidirectional(NetworkStream client, NetworkStream remote, ref long clientToRemoteBytes, ref long remoteToClientBytes)
        {
            using (var cts = new CancellationTokenSource())
            {
                long c2r = 0;
                long r2c = 0;
                var uploadTask = CopyStreamCoreAsync(client, remote, -1, n => Interlocked.Add(ref c2r, n), cts.Token);
                var downloadTask = CopyStreamCoreAsync(remote, client, -1, n => Interlocked.Add(ref r2c, n), cts.Token);

                try
                {
                    Task.WhenAny(uploadTask, downloadTask).GetAwaiter().GetResult();
                }
                catch
                {
                }

                try
                {
                    Task.WhenAll(uploadTask, downloadTask).Wait(5000);
                }
                catch
                {
                }

                if (!uploadTask.IsCompleted || !downloadTask.IsCompleted)
                {
                    try
                    {
                        cts.Cancel();
                    }
                    catch
                    {
                    }

                    try
                    {
                        client.Close();
                    }
                    catch
                    {
                    }

                    try
                    {
                        remote.Close();
                    }
                    catch
                    {
                    }

                    try
                    {
                        Task.WhenAll(uploadTask, downloadTask).Wait(1000);
                    }
                    catch
                    {
                    }
                }

                Interlocked.Add(ref clientToRemoteBytes, c2r);
                Interlocked.Add(ref remoteToClientBytes, r2c);
            }
        }
    }

    public static class SocketConnector
    {
        public static TcpClient CreateBoundConnection(string localSourceIp, string remoteHost, int remotePort, int timeoutMs, int interfaceIndex)
        {
            var client = new TcpClient();
            try
            {
                client.NoDelay = true;
                client.ReceiveBufferSize = 524288;
                client.SendBufferSize = 524288;
                client.Client.Bind(new IPEndPoint(IPAddress.Parse(localSourceIp), 0));

                if (interfaceIndex > 0)
                {
                    try
                    {
                        client.Client.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, interfaceIndex);
                    }
                    catch
                    {
                    }
                }

                var connectTask = client.ConnectAsync(remoteHost, remotePort);
                var timeoutTask = Task.Delay(timeoutMs);
                if (Task.WhenAny(connectTask, timeoutTask).GetAwaiter().GetResult() == timeoutTask)
                {
                    client.Close();
                    throw new TimeoutException("Connection via " + localSourceIp + " timed out");
                }

                connectTask.GetAwaiter().GetResult();
                return client;
            }
            catch
            {
                try
                {
                    client.Close();
                }
                catch
                {
                }

                throw;
            }
        }
    }

    public static class WeightedRoundRobin
    {
        private static long _counter = -1;

        public static int NextIndex(int[] schedule)
        {
            if (schedule == null || schedule.Length == 0)
            {
                return -1;
            }

            long next = Interlocked.Increment(ref _counter);
            long slot = next % schedule.Length;
            if (slot < 0)
            {
                slot += schedule.Length;
            }

            return schedule[(int)slot];
        }
    }
}
"@ -Language CSharp
}

# ===== Thread-safe state =====
$global:ProxyState = [hashtable]::Synchronized(@{
    adapters         = @()
    weights          = @()
    rrSchedule       = @()
    connectionCounts = [hashtable]::Synchronized(@{})
    successCounts    = [hashtable]::Synchronized(@{})
    failCounts       = [hashtable]::Synchronized(@{})
    totalConnections = 0
    totalFails       = 0
    activeConnections = 0        # v5.1: live active connection count
    activePerAdapter  = [hashtable]::Synchronized(@{})      # v5.1: per-adapter active counts
    activePerHost     = [hashtable]::Synchronized(@{})      # v5.1: per-host active counts for dynamic bulk detection
    currentMode      = 'maxspeed'
    rrIndex          = 0
    connectTimeout   = 5000
    configFile       = $configFile
    healthFile       = $healthFile
    interfacesFile   = $interfacesFile
    statsFile        = $statsFile
    eventsFile       = $eventsFile
    decisionsFile    = $decisionsFile
    safetyFile       = $safetyFile
    port             = $Port
    # v5.0 Intelligence State
    adapterHealth    = @{}
    degradationFlags = @{}
    connectionTypes  = [hashtable]::Synchronized(@{})
    decisions        = @()
    maxDecisions     = 100
    bandwidthEstimates = @{}
    uploadBandwidthEstimates = @{}
    uploadHostHints  = [hashtable]::Synchronized(@{})
    uploadHintTTL    = 300
    activeConns      = @{}
    weightRefreshInterval = 2.0
    bufferSizes      = @{
        'bulk'        = 524288   # 512KB for downloads (maximum throughput pipes)
        'interactive' = 32768    # 32KB for browsing
        'streaming'   = 262144   # 256KB for streaming (smooth 4K playback)
        'gaming'      = 8192     # 8KB for gaming (low latency)
        'default'     = 131072   # 128KB default
    }
    # v6.2 Soft host hint cache (used only when weights are effectively equal)
    sessionMap     = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()    # { "host:port" -> @{ adapter=Name; time=Ticks } }
    sessionTTL     = 120
    # v5.0 Safety
    safeMode       = $false
    portClasses    = @{
        gaming = @(3074, 3478, 3479, 3480, 3659, 25565, 27015, 27036, 19132)
        voice  = @(3478, 3479, 3480, 5004, 5005, 5060, 5061)
        bulk   = @(20, 21, 22, 8080, 8443, 9000, 9090)
    }
})
$script:ProxyLogMutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")

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
        try { Copy-Item $Path "$Path.bak" -Force -ErrorAction SilentlyContinue } catch {}
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Read-JsonFile {
    param(
        [string]$Path,
        [object]$DefaultValue = $null
    )

    if (-not (Test-Path $Path)) {
        return $DefaultValue
    }

    try {
        return (Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        $backupPath = "$Path.bak"
        if (Test-Path $backupPath) {
            try {
                $backup = Get-Content $backupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                Copy-Item $backupPath $Path -Force -ErrorAction SilentlyContinue
                return $backup
            } catch {}
        }

        return $DefaultValue
    }
}

function Repair-EventsFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-AtomicJson -Path $Path -Data @{ events = @() } -Depth 3
        return
    }

    $data = Read-JsonFile -Path $Path -DefaultValue $null
    if (-not $data -or -not $data.events) {
        Write-AtomicJson -Path $Path -Data @{ events = @() } -Depth 3
    }
}

function Get-SafeBufferSize {
    param(
        [int]$RequestedSize,
        [int]$MaxSize = 1048576
    )

    $safe = [Math]::Max(8192, [Math]::Min($RequestedSize, $MaxSize))
    if ([IntPtr]::Size -le 4 -and $safe -gt 262144) {
        return 262144
    }
    return [int]$safe
}

foreach ($bufferKey in @($global:ProxyState.bufferSizes.Keys)) {
    $global:ProxyState.bufferSizes[$bufferKey] = Get-SafeBufferSize -RequestedSize ([int]$global:ProxyState.bufferSizes[$bufferKey])
}

function Write-ProxyEvent {
    param([string]$Message)
    $mutexTaken = $false
    try {
        try {
            $mutexTaken = $script:ProxyLogMutex.WaitOne(3000)
        } catch [System.Threading.AbandonedMutexException] {
            try { Repair-EventsFile -Path $global:ProxyState.eventsFile } catch {}
            $mutexTaken = $true
        }

        if (-not $mutexTaken) { return }

        try {
            $ef = $global:ProxyState.eventsFile
            $events = @()
            $data = Read-JsonFile -Path $ef -DefaultValue $null
            if ($data -and $data.events) { $events = @($data.events) }
            $evt = @{ timestamp = (Get-Date).ToString('o'); type = 'proxy'; adapter = ''; message = $Message }
            $events = @($evt) + $events
            if ($events.Count -gt 200) { $events = $events[0..199] }
            Write-AtomicJson -Path $ef -Data @{ events = $events } -Depth 3
        } finally {
            if ($mutexTaken) {
                try { $script:ProxyLogMutex.ReleaseMutex() } catch {}
            }
        }
    } catch {}
}

function Get-ProxyAdapters {
    $adapters = @()
    $ifFile = $global:ProxyState.interfacesFile
    $data = Read-JsonFile -Path $ifFile -DefaultValue $null
    if ($data -and $data.interfaces) {
        foreach ($iface in $data.interfaces) {
            if ($iface.IPAddress -and $iface.Status -eq 'Up') {
                $adapters += @{ Name = $iface.Name; IP = $iface.IPAddress; Type = $iface.Type; Speed = $iface.LinkSpeedMbps; InterfaceIndex = $iface.InterfaceIndex }
            }
        }
    }
    if ($adapters.Count -lt 1) {
        Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN' } | ForEach-Object {
            $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            if ($ip) {
                $type = if ($_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11' -or $_.Name -match 'Wi-Fi') { if ($_.InterfaceDescription -match 'USB') { 'USB-WiFi' } else { 'WiFi' } } elseif ($_.InterfaceDescription -match 'Ethernet') { 'Ethernet' } else { 'Unknown' }
                $adapters += @{ Name = $_.Name; IP = $ip; Type = $type; Speed = 100; InterfaceIndex = $_.ifIndex }
            }
        }
    }
    return $adapters
}

function New-WeightedRoundRobinSchedule {
    param(
        [double[]]$Weights,
        [int]$MinimumSlots = 16,
        [int]$MaximumSlots = 64
    )

    if (-not $Weights -or $Weights.Count -eq 0) {
        return @()
    }

    $slotCount = [math]::Max($MinimumSlots, $Weights.Count * 8)
    $slotCount = [math]::Min($MaximumSlots, $slotCount)
    $totalWeight = 0.0
    foreach ($weight in $Weights) {
        $totalWeight += [double]$weight
    }

    if ($totalWeight -le 0.0) {
        return @(0..([math]::Max(0, $Weights.Count - 1)))
    }

    $accumulators = @()
    for ($i = 0; $i -lt $Weights.Count; $i++) {
        $accumulators += 0.0
    }

    $schedule = [System.Collections.Generic.List[int]]::new()
    for ($slot = 0; $slot -lt $slotCount; $slot++) {
        $bestIndex = 0
        $bestScore = [double]::NegativeInfinity

        for ($i = 0; $i -lt $Weights.Count; $i++) {
            $accumulators[$i] = [double]$accumulators[$i] + [double]$Weights[$i]
            if ([double]$accumulators[$i] -gt $bestScore) {
                $bestIndex = $i
                $bestScore = [double]$accumulators[$i]
            }
        }

        $schedule.Add($bestIndex)
        $accumulators[$bestIndex] = [double]$accumulators[$bestIndex] - $totalWeight
    }

    return ,$schedule.ToArray()
}

function Update-AdaptersAndWeights {
    $s = $global:ProxyState
    $s.adapters = @(Get-ProxyAdapters)

    # v5.0: Check safe mode
    if (Test-Path $s.safetyFile) {
        $safety = Read-JsonFile -Path $s.safetyFile -DefaultValue $null
        if ($safety -and $safety.safeMode -eq $true) {
            $s.safeMode = $true
        } else {
            $s.safeMode = $false
        }
    }

    # Read health data from InterfaceMonitor
    $health = @{}
    if (Test-Path $s.healthFile) {
        try {
            $hData = Read-JsonFile -Path $s.healthFile -DefaultValue $null
            if (-not $hData) { throw "Health data unavailable." }
            $hData.adapters | ForEach-Object {
                $currentDown = if ($_.DownloadMbps) { [double]$_.DownloadMbps } else { 0.0 }
                $currentUp = if ($_.UploadMbps) { [double]$_.UploadMbps } else { 0.0 }
                $prevEstimate = if ($s.bandwidthEstimates.ContainsKey($_.Name)) { [double]$s.bandwidthEstimates[$_.Name] } else { 0.0 }
                $prevUpEstimate = if ($s.uploadBandwidthEstimates.ContainsKey($_.Name)) { [double]$s.uploadBandwidthEstimates[$_.Name] } else { 0.0 }
                if ($currentDown -gt 1.0) {
                    $estimate = if ($prevEstimate -gt 0) {
                        [math]::Round(($prevEstimate * 0.65) + ($currentDown * 0.35), 2)
                    } else {
                        [math]::Round($currentDown, 2)
                    }
                } elseif ($prevEstimate -gt 0) {
                    $estimate = [math]::Round($prevEstimate * 0.9, 2)
                } else {
                    $estimate = 0.0
                }
                if ($currentUp -gt 1.0) {
                    $upEstimate = if ($prevUpEstimate -gt 0) {
                        [math]::Round(($prevUpEstimate * 0.65) + ($currentUp * 0.35), 2)
                    } else {
                        [math]::Round($currentUp, 2)
                    }
                } elseif ($prevUpEstimate -gt 0) {
                    $upEstimate = [math]::Round($prevUpEstimate * 0.9, 2)
                } else {
                    $upEstimate = 0.0
                }
                $s.bandwidthEstimates[$_.Name] = $estimate
                $s.uploadBandwidthEstimates[$_.Name] = $upEstimate

                $health[$_.Name] = @{
                    Score       = $_.HealthScore
                    Latency     = $_.InternetLatency
                    LatencyEWMA = if ($_.InternetLatencyEWMA) { $_.InternetLatencyEWMA } else { $_.InternetLatency }
                    Jitter      = if ($_.Jitter) { $_.Jitter } else { 0 }
                    SuccessRate = if ($_.SuccessRate) { $_.SuccessRate } else { 100 }
                    Stability   = if ($_.StabilityScore) { $_.StabilityScore } else { 80 }
                    Trend       = if ($_.HealthTrend) { $_.HealthTrend } else { 0 }
                    IsDegrading = if ($_.IsDegrading) { $_.IsDegrading } else { $false }
                    DownloadMbps = if ($_.DownloadMbps) { $_.DownloadMbps } else { 0 }
                    UploadMbps = if ($_.UploadMbps) { $_.UploadMbps } else { 0 }
                    EstimatedDownMbps = $estimate
                    EstimatedUpMbps = $upEstimate
                    LinkSpeedMbps = if ($_.LinkSpeedMbps) { $_.LinkSpeedMbps } else { 0 }
                }
            }
            $s.adapterHealth = $health
            if ($hData.degradation) {
                $degradeHash = @{}
                $hData.degradation.PSObject.Properties | ForEach-Object { $degradeHash[$_.Name] = $_.Value }
                $s.degradationFlags = $degradeHash
            }
        } catch {}
    }
    if (Test-Path $s.configFile) {
        try {
            $cfg = Read-JsonFile -Path $s.configFile -DefaultValue $null
            if (-not $cfg) { throw "Config data unavailable." }
            if ($cfg.mode) { $s.currentMode = $cfg.mode }
            $refresh = $cfg.intelligence.weightRefreshInterval
            if ($null -ne $refresh -and [double]$refresh -gt 0) {
                $s.weightRefreshInterval = [double]$refresh
            }
        } catch {}
    }

    $weights = @()
    foreach ($a in $s.adapters) {
        $h = $health[$a.Name]
        $linkSpeedMbps = if ($null -ne $a.Speed -and [double]$a.Speed -gt 0) { [double]$a.Speed } else { 0.0 }
        if ($h) {
            if ($null -ne $h.LinkSpeedMbps -and [double]$h.LinkSpeedMbps -gt $linkSpeedMbps) {
                $linkSpeedMbps = [double]$h.LinkSpeedMbps
            }
        }
        if ($linkSpeedMbps -le 0.0) {
            $linkSpeedMbps = 100.0
        }

        $penalty = 0.0
        if ($h) {
            $latency = if ($null -ne $h.LatencyEWMA) { [double]$h.LatencyEWMA } elseif ($null -ne $h.Latency) { [double]$h.Latency } else { 999.0 }
            $jitter = if ($null -ne $h.Jitter) { [double]$h.Jitter } else { 0.0 }

            $latencyPenalty = 0.0
            if ($latency -gt 40.0) {
                $latencyPenalty = [math]::Min(0.20, (($latency - 40.0) / 200.0))
            }

            $jitterPenalty = 0.0
            if ($jitter -gt 5.0) {
                $jitterPenalty = [math]::Min(0.10, (($jitter - 5.0) / 100.0))
            }

            $penalty = [math]::Min(0.30, ($latencyPenalty + $jitterPenalty))
        }

        $w = [math]::Max(1.0, [math]::Round($linkSpeedMbps * (1.0 - $penalty), 2))

        $weights += $w
        if (-not $s.connectionCounts.ContainsKey($a.Name)) {
            $s.connectionCounts[$a.Name] = 0
            $s.successCounts[$a.Name] = 0
            $s.failCounts[$a.Name] = 0
        }
    }
    $s.weights = $weights
    $s.rrSchedule = New-WeightedRoundRobinSchedule -Weights ([double[]]$weights)
}

function Update-ProxyStats {
    $s = $global:ProxyState
    $aStats = @()
    foreach ($a in $s.adapters) {
        $h = $s.adapterHealth[$a.Name]
        $aStats += @{
            name = $a.Name; type = $a.Type; ip = $a.IP
            connections = $s.connectionCounts[$a.Name]
            successes = $s.successCounts[$a.Name]
            failures = $s.failCounts[$a.Name]
            health = if ($h) { $h.Score } else { 0 }
            latency = if ($h) { $h.LatencyEWMA } else { 999 }
            jitter = if ($h) { $h.Jitter } else { 0 }
            isDegrading = if ($h) { $h.IsDegrading } else { $false }
        }
    }
    # Build per-adapter active counts
    $activePerAdapterSnap = @{}
    foreach ($a in $s.adapters) {
        $activePerAdapterSnap[$a.Name] = if ($s.activePerAdapter.ContainsKey($a.Name)) { $s.activePerAdapter[$a.Name] } else { 0 }
    }
    $sessionStats = @{
        activeSessionCount = $s.sessionMap.Count
        oldestSessionAge = 0
        newestSessionAge = 0
        averageSessionAge = 0
    }
    $sessionAges = @()
    $sessionNowTicks = [System.DateTimeOffset]::UtcNow.Ticks
    foreach ($sessionKey in @($s.sessionMap.Keys)) {
        $entry = $s.sessionMap[$sessionKey]
        try {
            if ($entry -and $entry.time) {
                $entryTicks = if ($entry.time -is [long] -or $entry.time -is [int64]) {
                    [int64]$entry.time
                } else {
                    ([System.DateTimeOffset][datetime]$entry.time).Ticks
                }
                $sessionAges += ($sessionNowTicks - $entryTicks) / [double][System.TimeSpan]::TicksPerSecond
            }
        } catch {}
    }
    if ($sessionAges.Count -gt 0) {
        $sessionStats.oldestSessionAge = [Math]::Round(($sessionAges | Measure-Object -Maximum).Maximum, 2)
        $sessionStats.newestSessionAge = [Math]::Round(($sessionAges | Measure-Object -Minimum).Minimum, 2)
        $sessionStats.averageSessionAge = [Math]::Round(($sessionAges | Measure-Object -Average).Average, 2)
    }
    $statsSnapshot = @{
        running = $true; port = $s.port; mode = $s.currentMode
        totalConnections = $s.totalConnections; totalFailures = $s.totalFails
        activeConnections = $s.activeConnections
        activePerAdapter = $activePerAdapterSnap
        adapterCount = $s.adapters.Count; adapters = $aStats
        connectionTypes = $s.connectionTypes
        safeMode = $s.safeMode
        sessionMapSize = $s.sessionMap.Count
        uploadHintHostCount = $s.uploadHostHints.Count
        sessionStats = $sessionStats
        currentMaxThreads = $s.currentMaxThreads
        timestamp = [System.DateTimeOffset]::UtcNow.ToString('o')
    }
    try { Write-AtomicJson -Path $s.statsFile -Data $statsSnapshot -Depth 3 } catch {}

    try {
        Write-AtomicJson -Path $s.decisionsFile -Data @{ decisions = $s.decisions } -Depth 3
    } catch {}
}

# v5.0: Clean expired session affinity entries
function Clear-ExpiredSessions {
    $s = $global:ProxyState
    $nowTicks = [System.DateTimeOffset]::UtcNow.Ticks
    $expired = [System.Collections.Generic.List[string]]::new()
    $snapshot = @{}

    foreach ($key in @($s.sessionMap.Keys)) {
        $snapshot[$key] = $s.sessionMap[$key]
    }

    foreach ($key in @($snapshot.Keys)) {
        $entry = $snapshot[$key]
        if (-not $entry -or -not $entry.time) {
            $expired.Add($key)
            continue
        }

        try {
            $entryTicks = if ($entry.time -is [long] -or $entry.time -is [int64]) {
                [int64]$entry.time
            } else {
                ([System.DateTimeOffset][datetime]$entry.time).Ticks
            }
            $ageSeconds = ($nowTicks - $entryTicks) / [double][System.TimeSpan]::TicksPerSecond
            if ($ageSeconds -gt $s.sessionTTL) {
                $expired.Add($key)
            }
        } catch {
            $expired.Add($key)
        }
    }

    foreach ($key in @($expired)) {
        try {
            $removedEntry = $null
            [void]$s.sessionMap.TryRemove($key, [ref]$removedEntry)
        } catch {}
    }

    $purgedCount = $expired.Count
    if ($s.sessionMap.Count -gt 10000) {
        $orderedSessions = foreach ($key in @($s.sessionMap.Keys)) {
            $entry = $s.sessionMap[$key]
            [pscustomobject]@{
                Key = $key
                Entry = $entry
                Time = try { if ($entry -and $entry.time) { [datetime]$entry.time } else { [datetime]::MinValue } } catch { [datetime]::MinValue }
            }
        }

        $keepers = @($orderedSessions | Sort-Object Time -Descending | Select-Object -First 5000)
        $removedForCap = [Math]::Max(0, $orderedSessions.Count - $keepers.Count)
        $s.sessionMap.Clear()
        foreach ($item in $keepers) {
            $s.sessionMap.TryAdd($item.Key, $item.Entry) | Out-Null
        }
        $purgedCount += $removedForCap
    }

    return $purgedCount
}

function Clear-ExpiredUploadHostHints {
    $s = $global:ProxyState
    $ttl = if ($s.uploadHintTTL -gt 0) { [int]$s.uploadHintTTL } else { 300 }
    $nowTicks = [System.DateTimeOffset]::UtcNow.Ticks
    $expired = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @($s.uploadHostHints.Keys)) {
        $entry = $s.uploadHostHints[$key]
        try {
            $ageSeconds = 0.0
            if (-not $entry -or -not $entry.time) {
                $expired.Add($key)
                continue
            }

            if ($entry.time -is [long] -or $entry.time -is [int64]) {
                $ageSeconds = ($nowTicks - [int64]$entry.time) / [double][System.TimeSpan]::TicksPerSecond
            } else {
                $entryTicks = ([System.DateTimeOffset][datetime]$entry.time).Ticks
                $ageSeconds = ($nowTicks - $entryTicks) / [double][System.TimeSpan]::TicksPerSecond
            }

            if ($ageSeconds -gt $ttl) {
                $expired.Add($key)
            }
        } catch {
            $expired.Add($key)
        }
    }

    foreach ($key in @($expired)) {
        try { [void]$s.uploadHostHints.Remove($key) } catch {}
    }

    return $expired.Count
}

# ===== Connection Handler ScriptBlock (runs in separate runspace) =====
$HandlerScript = {
    param($ClientSocket, $State)

    function Read-HttpLine {
        param([System.IO.Stream]$Stream)

        $lineBytes = [System.Collections.Generic.List[byte]]::new()
        $oneByte = New-Object byte[] 1
        $sawCR = $false
        while ($true) {
            $read = $Stream.Read($oneByte, 0, 1)
            if ($read -le 0) {
                if ($lineBytes.Count -eq 0 -and -not $sawCR) { return $null }
                break
            }

            $b = $oneByte[0]
            if ($sawCR) {
                if ($b -eq 10) { break }
                [void]$lineBytes.Add(13)
                $sawCR = $false
            }

            if ($b -eq 13) {
                $sawCR = $true
                continue
            }

            [void]$lineBytes.Add($b)
        }

        return [System.Text.Encoding]::ASCII.GetString($lineBytes.ToArray())
    }

    function Read-ExactBytes {
        param(
            [System.IO.Stream]$Stream,
            [byte[]]$Buffer,
            [int]$Count
        )

        $offset = 0
        while ($offset -lt $Count) {
            $read = $Stream.Read($Buffer, $offset, $Count - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }

        return $offset
    }

    function Read-ChunkedRequestBody {
        param([System.IO.Stream]$Stream)

        $body = [System.Collections.Generic.List[byte]]::new()
        while ($true) {
            $sizeLine = Read-HttpLine -Stream $Stream
            if ($null -eq $sizeLine) { throw "Unexpected end of stream while reading chunk size." }
            if ([string]::IsNullOrWhiteSpace($sizeLine)) { continue }

            $sizeToken = $sizeLine.Split(';')[0].Trim()
            $chunkSize = [Convert]::ToInt32($sizeToken, 16)
            if ($chunkSize -eq 0) {
                while ($true) {
                    $trailerLine = Read-HttpLine -Stream $Stream
                    if ($null -eq $trailerLine -or $trailerLine -eq '') { break }
                }
                break
            }

            $chunkBuffer = New-Object byte[] $chunkSize
            if ((Read-ExactBytes -Stream $Stream -Buffer $chunkBuffer -Count $chunkSize) -ne $chunkSize) {
                throw "Unexpected end of stream while reading chunk body."
            }
            $body.AddRange($chunkBuffer)

            $chunkTerminator = New-Object byte[] 2
            if ((Read-ExactBytes -Stream $Stream -Buffer $chunkTerminator -Count 2) -ne 2) {
                throw "Unexpected end of stream while reading chunk terminator."
            }
        }

        return $body.ToArray()
    }

    function Set-UploadHostHint {
        param(
            [hashtable]$ProxyState,
            [string]$Host,
            [string]$Reason,
            [long]$ClientToRemoteBytes = 0,
            [long]$RemoteToClientBytes = 0
        )

        if ([string]::IsNullOrWhiteSpace($Host)) { return }
        $ProxyState.uploadHostHints[$Host] = @{
            time = [System.DateTimeOffset]::UtcNow.Ticks
            reason = $Reason
            clientToRemoteBytes = $ClientToRemoteBytes
            remoteToClientBytes = $RemoteToClientBytes
        }
    }

    $connAdapter = $null  # track which adapter this connection uses
    $hostKey = $null
    $sessionKey = $null
    $remoteClient = $null
    $clientStream = $null
    $remoteStream = $null
    $clientToRemoteBytes = [long]0
    $remoteToClientBytes = [long]0
    $uri = $null
    try {
        # v5.0: Safe mode check -- if active, act as simple pass-through on default adapter
        $isSafeMode = $State.safeMode

        $clientStream = $ClientSocket.GetStream()
        $clientStream.ReadTimeout = 10000

        # Read request headers safely up to 64KB so large cookies or auth headers are not truncated.
        $headerLines = [System.Collections.Generic.List[string]]::new()
        $headerByteCount = 0
        while ($true) {
            $line = Read-HttpLine -Stream $clientStream
            if ($null -eq $line) { $ClientSocket.Close(); return }

            $headerByteCount += [System.Text.Encoding]::ASCII.GetByteCount($line) + 2
            if ($headerByteCount -gt 65536) { $ClientSocket.Close(); return }

            if ($line -eq '') { break }
            [void]$headerLines.Add($line)
        }

        if ($headerLines.Count -lt 1) { $ClientSocket.Close(); return }
        $lines = @($headerLines)
        $parts = $lines[0] -split ' '
        if ($parts.Count -lt 2) { $ClientSocket.Close(); return }
        $method = $parts[0].ToUpperInvariant()
        $text = ($lines -join "`r`n") + "`r`n`r`n"
        $requestContentLength = 0L
        if ($text -match '(?im)^Content-Length:\s*(\d+)') { $requestContentLength = [int64]$Matches[1] }
        $uploadContentLength = 0L
        if ($text -match '(?im)^X-Upload-Content-Length:\s*(\d+)') { $uploadContentLength = [int64]$Matches[1] }
        $isChunkedRequest = $text -match '(?im)^Transfer-Encoding:\s*.*\bchunked\b'
        $hasContentRange = $text -match '(?im)^Content-Range:\s*bytes\s+\d+-\d+/\d+'
        $hasExpectContinue = $text -match '(?im)^Expect:\s*100-continue'
        $hasTusResumable = $text -match '(?im)^Tus-Resumable:\s*'
        $contentType = ''
        if ($text -match '(?im)^Content-Type:\s*([^\r\n]+)') { $contentType = $Matches[1].Trim() }

        # ===== v5.0: Health check endpoint for SafetyController =====
        if ($method -eq 'GET' -and $parts.Count -ge 2 -and $parts[1] -eq '/health') {
            $remoteEndPoint = $ClientSocket.Client.RemoteEndPoint -as [System.Net.IPEndPoint]
            $isLocalRequester = $remoteEndPoint -and (
                $remoteEndPoint.Address.Equals([System.Net.IPAddress]::Loopback) -or
                $remoteEndPoint.Address.Equals([System.Net.IPAddress]::IPv6Loopback)
            )
            $resp = if ($isLocalRequester) {
                [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK")
            } else {
                [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 403 Forbidden`r`nContent-Type: text/plain`r`nContent-Length: 9`r`nConnection: close`r`n`r`nForbidden")
            }
            $clientStream.Write($resp, 0, $resp.Length)
            $ClientSocket.Close()
            return
        }

        # [V5-FIX-20] HTTP/2 Multiplexing Behavior:
        # Modern browsers use HTTP/2 which multiplexes many page requests over a single TCP connection. 
        # NetFusion routes per-TCP connection, meaning all resources from one host may go through the 
        # same adapter in one session. This is correct behavior -- splitting one HTTP/2 connection 
        # across adapters would instantly corrupt and sever the tunnel.

        # ===== Connection Type Detection =====
        $connType = 'interactive'
        $targetHost = ''

        if ($method -eq 'CONNECT') {
            $target = $parts[1]
            if ($target -match '^\[(.*)\]:(\d+)$') {
                $targetHost = $Matches[1]
                $rPort = [int]$Matches[2]
            } else {
                $idx = $target.LastIndexOf(':')
                if ($idx -gt 0) {
                    $targetHost = $target.Substring(0, $idx)
                    $rPort = [int]($target.Substring($idx + 1))
                } else {
                    $targetHost = $target
                    $rPort = 443
                }
            }
        } else {
            try { $uri = [System.Uri]$parts[1] } catch { $ClientSocket.Close(); return }
            $targetHost = $uri.Host
            $rPort = if ($uri.Port -gt 0 -and $uri.Port -ne -1) { $uri.Port } else { 80 }
        }

        $isGoogleDriveServiceHost = $targetHost -match '(?i)(^|\.)drivefrontend-pa\.clients\d+\.google\.com$|(^|\.)drive-thirdparty\.googleusercontent\.com$|(^|\.)workspaceui-pa\.clients\d+\.google\.com$'
        $isGoogleDriveHost = $isGoogleDriveServiceHost -or ($targetHost -match '(?i)^drive\.google\.com$')
        $isUploadMethod = $method -in @('POST', 'PUT', 'PATCH')
        $hasUploadContentType = $contentType -match '(?i)\bmultipart/form-data\b|\bapplication/octet-stream\b|\bapplication/x-www-form-urlencoded\b|\bimage\/|\bvideo\/|\baudio\/'
        $recentUploadHint = $false
        if ($targetHost -and $State.uploadHostHints.ContainsKey($targetHost)) {
            $hint = $State.uploadHostHints[$targetHost]
            try {
                $isRecentHint = $false
                if ($hint -and $hint.time) {
                    if ($hint.time -is [long] -or $hint.time -is [int64]) {
                        $hintAgeSec = ([System.DateTimeOffset]::UtcNow.Ticks - [int64]$hint.time) / [double][System.TimeSpan]::TicksPerSecond
                        $isRecentHint = $hintAgeSec -lt $State.uploadHintTTL
                    } else {
                        $hintTicks = ([System.DateTimeOffset][datetime]$hint.time).Ticks
                        $hintAgeSec = ([System.DateTimeOffset]::UtcNow.Ticks - $hintTicks) / [double][System.TimeSpan]::TicksPerSecond
                        $isRecentHint = ($hintAgeSec -lt $State.uploadHintTTL)
                    }
                }
                if ($isRecentHint) {
                    $recentUploadHint = $true
                } else {
                    [void]$State.uploadHostHints.Remove($targetHost)
                }
            } catch {
                [void]$State.uploadHostHints.Remove($targetHost)
            }
        }

        # Note: L7 connection type detection using regex heuristics was replaced by strict L4 Arbitration Table in v5.1
        $isBulkHint = $false
        if ($method -ne 'CONNECT') {
            $targetPath = if ($uri) { ($uri.AbsolutePath + $uri.Query) } else { '' }
            $hasGenericUploadPathHint = $targetPath -match '(?i)(^|/)(upload|uploads|uploading|attach|attachment|attachments|multipart|resumable|media|files|file|chunks?)(/|$)|[?&](upload|uploadType|resumable|chunk|partNumber|session)='
            $isGenericUploadHint = $hasContentRange -or
                $uploadContentLength -gt 0 -or
                $hasTusResumable -or
                (
                    $isUploadMethod -and (
                        $requestContentLength -ge 262144 -or
                        $isChunkedRequest -or
                        $hasExpectContinue -or
                        $hasUploadContentType -or
                        $hasGenericUploadPathHint
                    )
                )
            if (
                $text -match '(?im)^Range:\s*bytes=' -or
                $targetPath -match '(?i)(^|/)(__down|download|downloads?|payload|bigfile|speedtest)' -or
                $targetPath -match '(?i)\.(zip|iso|msi|exe|bin|7z|rar|tar|gz|pkg)(\?|$)' -or
                $targetHost -match '(?i)(^|\.)speed\.cloudflare\.com$|speedtest|download' -or
                $isGenericUploadHint -or
                (
                    $isGoogleDriveHost -and (
                        $isUploadMethod -or
                        $targetPath -match '(?i)(^|/)(upload|resumable|multipart)(/|$)|[?&]uploadType=' -or
                        $text -match '(?im)^X-Goog-Upload-(Command|Protocol):' -or
                        $hasContentRange
                    )
                )
            ) {
                $isBulkHint = $true
            }
        } elseif ($targetHost -match '(?i)(^|\.)speed\.cloudflare\.com$|speedtest') {
            $isBulkHint = $true
        } elseif ($recentUploadHint -and $State.currentMode -in @('maxspeed', 'download')) {
            # HTTPS uploads hide the inner request method. Reuse short-lived host hints so
            # repeated upload tunnels to the same service stop getting sticky treatment.
            $isBulkHint = $true
        } elseif ($isGoogleDriveServiceHost -and $State.currentMode -in @('maxspeed', 'download')) {
            # Drive uploads are often hidden behind HTTPS CONNECT tunnels to service hosts.
            # Treat those tunnels as bulk-capable so parallel upload channels are not kept sticky.
            $isBulkHint = $true
        }

        if ($method -ne 'CONNECT' -and $isBulkHint -and ($isUploadMethod -or $uploadContentLength -gt 0 -or $requestContentLength -ge 262144 -or $isChunkedRequest -or $hasTusResumable -or $hasContentRange)) {
            Set-UploadHostHint -ProxyState $State -Host $targetHost -Reason 'http-upload-signal' -ClientToRemoteBytes ([math]::Max($requestContentLength, $uploadContentLength)) -RemoteToClientBytes 0
        }

        # v5.1: Track host concurrency for dynamic download manager detection
        $hostKey = $targetHost
        if (-not $State.activePerHost.ContainsKey($hostKey)) { $State.activePerHost[$hostKey] = 0 }
        $State.activePerHost[$hostKey]++
        $activeHostCount = $State.activePerHost[$hostKey]

        $portClasses = $State.portClasses
        $gamingPorts = if ($portClasses -and $portClasses.gaming) { @($portClasses.gaming) } else { @() }
        $voicePorts = if ($portClasses -and $portClasses.voice) { @($portClasses.voice) } else { @() }
        $bulkPorts = if ($portClasses -and $portClasses.bulk) { @($portClasses.bulk) } else { @() }

        if ($rPort -in $gamingPorts) { 
            $connType = 'gaming' 
        } elseif ($rPort -in $voicePorts) { 
            $connType = 'voice' 
        } elseif ($isBulkHint) {
            $connType = 'bulk'
        } elseif ($rPort -in $bulkPorts) { 
            $connType = 'bulk' 
        } elseif ($rPort -eq 443 -or $rPort -eq 80) { 
            if ($activeHostCount -gt 2 -and $State.currentMode -in @('maxspeed', 'download')) {
                $connType = 'bulk'  # High concurrency detected -> Multi-part download aggregation!
            } else {
                $connType = 'streaming' 
            }
        } else { 
            $connType = 'bulk' 
        }

        if (-not $State.connectionTypes.ContainsKey($connType)) { $State.connectionTypes[$connType] = 0 }
        $State.connectionTypes[$connType]++

        # ===== Adapter Selection =====
        $avail = @(); $aw = @()
        for ($i = 0; $i -lt $State.adapters.Count; $i++) {
            $avail += $State.adapters[$i]
            $aw += $State.weights[$i]
        }
        if ($avail.Count -eq 0) { $ClientSocket.Close(); return }
        $State.totalConnections++
        $State.activeConnections++
        $sessionKey = if ($targetHost) { "{0}:{1}" -f $targetHost, $rPort } else { $null }

        $adapter = $avail[0]
        $selectionReason = 'default'
        $affinityMode = 'none'
        $weightsNearlyEqual = $false

        if ($isSafeMode) {
            # Safe mode: use first adapter only (most reliable, default Windows behavior)
            $selectionReason = 'safe-mode(single-adapter)'
        } elseif ($avail.Count -eq 1) {
            $selectionReason = 'only-adapter'
        } else {
            $preferredIndex = [NetFusion.WeightedRoundRobin]::NextIndex([int[]]$State.rrSchedule)
            if ($preferredIndex -lt 0 -or $preferredIndex -ge $avail.Count) {
                $preferredIndex = 0
            }

            $adapter = $avail[$preferredIndex]
            $selectionReason = 'weighted-round-robin(per-connection)'

            if ($aw.Count -gt 1) {
                $maxWeight = [double](($aw | Measure-Object -Maximum).Maximum)
                $minWeight = [double](($aw | Measure-Object -Minimum).Minimum)
                $weightsNearlyEqual = ([math]::Abs($maxWeight - $minWeight) -le [math]::Max(5.0, ($maxWeight * 0.05)))
            }

            if ($weightsNearlyEqual -and $sessionKey) {
                $hintEntry = $null
                if ($State.sessionMap.TryGetValue($sessionKey, [ref]$hintEntry) -and $hintEntry -and $hintEntry.adapter) {
                    $hintedAdapter = $avail | Where-Object { $_.Name -eq [string]$hintEntry.adapter } | Select-Object -First 1
                    if ($hintedAdapter) {
                        $adapter = $hintedAdapter
                        $selectionReason = 'soft-host-hint(equal-weights)'
                        $affinityMode = 'soft'
                    }
                }
            }
        }

        # Log decision
        $decision = @{
            time = [System.DateTimeOffset]::Now.ToString('HH:mm:ss')
            host = $targetHost
            type = $connType
            adapter = $adapter.Name
            reason = $selectionReason
            affinity_mode = $affinityMode
        }
        $State.decisions = @($decision) + @($State.decisions | Select-Object -First ($State.maxDecisions - 1))

        # ===== Connect to remote via chosen adapter (with failover) =====
        $remoteClient = $null
        $candidateAdapters = @($adapter)
        $fallbackAdapters = @(
            for ($fi = 0; $fi -lt $avail.Count; $fi++) {
                if ($avail[$fi].Name -eq $adapter.Name) { continue }
                [pscustomobject]@{
                    Adapter = $avail[$fi]
                    Weight = [double]$aw[$fi]
                }
            }
        )
        if ($fallbackAdapters.Count -gt 0) {
            $candidateAdapters += @($fallbackAdapters | Sort-Object Weight -Descending | Select-Object -ExpandProperty Adapter)
        }

        $maxRetries = [math]::Min($candidateAdapters.Count, 3)

        for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
            $adapter = $candidateAdapters[$attempt]

            $rHost = $targetHost

            try {
                if (-not $adapter.IP -or $adapter.IP -match '^169\.254\.') {
                    $State.failCounts[$adapter.Name]++
                    $State.totalFails++
                    continue
                }

                $ifIndex = if ($null -ne $adapter.InterfaceIndex) { [int]$adapter.InterfaceIndex } else { 0 }
                $remoteClient = [NetFusion.SocketConnector]::CreateBoundConnection($adapter.IP, $rHost, $rPort, 5000, $ifIndex)
                $remoteClient.SendTimeout = 15000
                $remoteClient.ReceiveTimeout = 15000

                if (-not $State.activePerAdapter.ContainsKey($adapter.Name)) { $State.activePerAdapter[$adapter.Name] = 0 }
                $State.activePerAdapter[$adapter.Name] = [int]$State.activePerAdapter[$adapter.Name] + 1
                $connAdapter = $adapter.Name

                if ($sessionKey) {
                    $sessionEntry = @{
                        adapter = $adapter.Name
                        time = [System.DateTimeOffset]::UtcNow.Ticks
                    }
                    try {
                        $State.sessionMap[$sessionKey] = $sessionEntry
                    } catch {
                        $State.sessionMap.TryAdd($sessionKey, $sessionEntry) | Out-Null
                    }
                }

                $State.connectionCounts[$adapter.Name]++
                $State.successCounts[$adapter.Name]++
                break
            } catch {
                try { $remoteClient.Close() } catch {}
                try { $remoteClient.Dispose() } catch {}
                $remoteClient = $null
            }
            $State.failCounts[$adapter.Name]++; $State.totalFails++
        }

        if (-not $remoteClient) {
            $err = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 502 Bad Gateway`r`nConnection: close`r`n`r`n")
            $clientStream.Write($err, 0, $err.Length); $ClientSocket.Close(); return
        }

        $remoteStream = $remoteClient.GetStream()

        if ($method -eq 'CONNECT') {
            # [V5-FIX-11] HTTPS TUNNELING: Forward tunnel without modification -- NO MITM.
            # Hostname classification already occurred. Tunnel remains entirely encrypted.
            # Event logging disabled here to avoid log spam, as millions of tunnels happen per day.
            
            $ok = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n")
            $clientStream.Write($ok, 0, $ok.Length)
            $clientStream.ReadTimeout = [System.Threading.Timeout]::Infinite
            $clientStream.WriteTimeout = [System.Threading.Timeout]::Infinite
            $remoteStream.ReadTimeout = [System.Threading.Timeout]::Infinite
            $remoteStream.WriteTimeout = [System.Threading.Timeout]::Infinite
            [NetFusion.StreamCopier]::CopyStreamBidirectional(
                $clientStream,
                $remoteStream,
                [ref]$clientToRemoteBytes,
                [ref]$remoteToClientBytes
            )
        } else {
            $remoteStream.ReadTimeout = 15000
            $reqPath = $uri.PathAndQuery; if (-not $reqPath) { $reqPath = '/' }
            $req = "$method $reqPath HTTP/1.1`r`n"
            $hasHost = $false; $contentLength = 0; $isChunked = $false
            $forwardHeaders = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ($l -match '^Proxy-') { continue }
                if ($l -match '^Connection:') { continue }
                if ($l -match '^Host:') { $hasHost = $true }
                if ($l -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1]; continue }
                if ($l -match '^Transfer-Encoding:\s*(.+)$') {
                    if ($Matches[1] -match '(?i)\bchunked\b') { $isChunked = $true }
                    continue
                }
                $forwardHeaders.Add($l)
            }
            foreach ($headerLine in $forwardHeaders) {
                $req += "$headerLine`r`n"
            }
            if (-not $hasHost) { $req += "Host: $($uri.Host)`r`n" }

            $chunkedBody = $null
            if ($isChunked) {
                $chunkedBody = Read-ChunkedRequestBody -Stream $clientStream
                $req += "Content-Length: $($chunkedBody.Length)`r`n"
            } elseif ($contentLength -gt 0) {
                $req += "Content-Length: $contentLength`r`n"
            }
            $req += "Connection: close`r`n`r`n"
            $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
            $remoteStream.Write($reqBytes, 0, $reqBytes.Length)

            if ($isChunked) {
                if ($chunkedBody.Length -gt 0) {
                    $remoteStream.Write($chunkedBody, 0, $chunkedBody.Length)
                    $clientToRemoteBytes += [long]$chunkedBody.Length
                }
            } elseif ($contentLength -gt 0) {
                [NetFusion.StreamCopier]::CopyStream($clientStream, $remoteStream, [int64]$contentLength, [ref]$clientToRemoteBytes)
            }

            [NetFusion.StreamCopier]::CopyStream($remoteStream, $clientStream, [ref]$remoteToClientBytes)
        }

    } catch {} finally {
        # v5.1: Decrement active connection counters
        if ($State.activeConnections -gt 0) { $State.activeConnections-- }
        if ($connAdapter -and $State.activePerAdapter.ContainsKey($connAdapter)) {
            $State.activePerAdapter[$connAdapter] = [math]::Max(0, $State.activePerAdapter[$connAdapter] - 1)
        }
        if ($hostKey -and $State.activePerHost.ContainsKey($hostKey)) {
            $State.activePerHost[$hostKey] = [math]::Max(0, $State.activePerHost[$hostKey] - 1)
        }
        try { if ($remoteStream) { $remoteStream.Dispose() } } catch {}
        try { if ($clientStream) { $clientStream.Dispose() } } catch {}
        try { if ($remoteClient) { $remoteClient.Close() } } catch {}
        try { if ($remoteClient) { $remoteClient.Dispose() } } catch {}
        try { if ($ClientSocket) { $ClientSocket.Close() } } catch {}
        try { if ($ClientSocket) { $ClientSocket.Dispose() } } catch {}
    }
}

# ===== Dynamic Adaptive Runspace Pool =====
$cfgProxy = $null
if (Test-Path $configFile) {
    try {
        $cfgData = Read-JsonFile -Path $configFile -DefaultValue $null
        if ($cfgData) { $cfgProxy = $cfgData.proxy }
    } catch {}
}
$minThreads = if ($cfgProxy -and $cfgProxy.minThreads -gt 0) { [int]$cfgProxy.minThreads } else { 64 }
$maxThreads = if ($cfgProxy -and $cfgProxy.maxThreads -gt 0) { [int]$cfgProxy.maxThreads } else { 256 }
$maxThreads = [math]::Max(50, [math]::Max($minThreads, $maxThreads))
$currentMaxThreads = [math]::Max(50, [math]::Min($maxThreads, [math]::Max($minThreads, 96)))
$global:ProxyState.currentMaxThreads = $currentMaxThreads

$rsPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($minThreads, $currentMaxThreads)
$rsPool.Open()
$jobs = [System.Collections.Generic.List[object]]::new()

# ===== Main =====
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "    NETFUSION SMART PROXY v6.2                       " -ForegroundColor Cyan
Write-Host "    Production Connection Orchestration Engine        " -ForegroundColor DarkGray
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

Update-AdaptersAndWeights

if ($global:ProxyState.adapters.Count -lt 1) {
    Write-Host "  [ERROR] No usable network adapters found." -ForegroundColor Red
    exit 1
}

Write-Host "  HTTP Proxy:      127.0.0.1:${Port}" -ForegroundColor Green
Write-Host "  Mode:            $($global:ProxyState.currentMode)" -ForegroundColor Green
Write-Host "  Thread pool:     $minThreads-$maxThreads (adaptive)" -ForegroundColor Green
Write-Host "  Soft host hints: $($global:ProxyState.sessionTTL)s TTL" -ForegroundColor Green
Write-Host "  Health endpoint: /health (loopback only)" -ForegroundColor Green
Write-Host "  Safety aware:    yes" -ForegroundColor Green
Write-Host ""
foreach ($a in $global:ProxyState.adapters) {
    $i = [array]::IndexOf($global:ProxyState.adapters, $a)
    $w = if ($i -ge 0 -and $i -lt $global:ProxyState.weights.Count) { [math]::Round($global:ProxyState.weights[$i], 2) } else { '?' }
    $h = $global:ProxyState.adapterHealth[$a.Name]
    $flags = ''
    if ($h -and $h.IsDegrading) { $flags = ' [DEGRADING]' }
    Write-Host "  $($a.Name) ($($a.IP)) [$($a.Type)] weight=$w$flags" -ForegroundColor White
}
Write-Host ""
Write-Host "  Configure apps: proxy 127.0.0.1 port ${Port}" -ForegroundColor Yellow
Write-Host ""

Write-ProxyEvent "Proxy v6.2 started on port $Port with $($global:ProxyState.adapters.Count) adapters (connection-level WRR + safety)"

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } catch { Write-Host "  [ERROR] Port ${Port} in use. $_" -ForegroundColor Red; exit 1 }

Update-ProxyStats
$lastRefreshTicks = [System.DateTimeOffset]::UtcNow.Ticks
$lastLogTicks = $lastRefreshTicks
$lastCleanupTicks = $lastRefreshTicks
$lastSessionCleanTicks = $lastRefreshTicks
$cleanupIntervalTicks = [System.TimeSpan]::FromMilliseconds(500).Ticks
$sessionCleanIntervalTicks = [System.TimeSpan]::FromSeconds(60).Ticks
$logIntervalTicks = [System.TimeSpan]::FromSeconds(1).Ticks
$staleJobTicks = [System.TimeSpan]::FromSeconds(180).Ticks
$lowThreadHoldTicks = [System.TimeSpan]::FromSeconds(120).Ticks
$lowThreadTicks = $null

try {
    while ($true) {
        $nowTicks = [System.DateTimeOffset]::UtcNow.Ticks

        # Refresh adapter data and weights every 5 seconds
        $refreshInterval = if ($global:ProxyState.weightRefreshInterval -gt 0) { [double]$global:ProxyState.weightRefreshInterval } else { 2.0 }
        $refreshIntervalTicks = [int64]($refreshInterval * [System.TimeSpan]::TicksPerSecond)
        if (($nowTicks - $lastRefreshTicks) -gt $refreshIntervalTicks) {
            Update-AdaptersAndWeights
            Update-ProxyStats
            $lastRefreshTicks = $nowTicks
        }

        # Clean completed jobs and evaluate scaling twice per second so short speed bursts can expand quickly.
        if (($nowTicks - $lastCleanupTicks) -gt $cleanupIntervalTicks) {
            $toRemove = @()
            $activeCount = 0
            foreach ($j in $jobs) {
                if ($j.Handle.IsCompleted) {
                    $toRemove += $j
                } else {
                    $activeCount++
                    if ($j.StartTicks -and (($nowTicks - [int64]$j.StartTicks) -gt $staleJobTicks)) {
                        # Stale job -- force dispose (180s timeout, reduced from 600s)
                        try { $j.PS.Stop() } catch {}
                        $toRemove += $j
                    }
                }
            }
            foreach ($j in $toRemove) {
                try { $j.PS.Dispose() } catch {}
                [void]$jobs.Remove($j)
            }
            
            # [V5-FIX-8] Dynamic Thread Pool Scaling Policy
            $activeThreads = $activeCount
            $queueDepth = if ($listener.Pending()) { 1 } else { 0 } # Conservative estimate to avoid oversensitive scale-ups
            
            if ($queueDepth -gt 0 -and $activeThreads -ge ($currentMaxThreads - 8) -and $currentMaxThreads -lt $maxThreads) {
                $targetThreads = [math]::Max($currentMaxThreads + 16, $activeThreads + 16)
                $currentMaxThreads = [math]::Min($maxThreads, $targetThreads)
                $rsPool.SetMaxRunspaces($currentMaxThreads)
                $global:ProxyState.currentMaxThreads = $currentMaxThreads
                Write-ProxyEvent "Pool scaled UP: $currentMaxThreads (queue pending, active=$activeThreads)"
                Write-Host "  [Scale UP] Thread pool expanded to $currentMaxThreads" -ForegroundColor Cyan
                $lowThreadTicks = $null
            } elseif ($activeThreads -lt [math]::Floor($currentMaxThreads * 0.4) -and $currentMaxThreads -gt $minThreads) {
                if ($null -eq $lowThreadTicks) {
                    $lowThreadTicks = $nowTicks
                } elseif (($nowTicks - [int64]$lowThreadTicks) -gt $lowThreadHoldTicks) {
                    $currentMaxThreads = [math]::Max($minThreads, $currentMaxThreads - 8)
                    $rsPool.SetMaxRunspaces($currentMaxThreads)
                    $global:ProxyState.currentMaxThreads = $currentMaxThreads
                    Write-ProxyEvent "Pool scaled DOWN: $currentMaxThreads (low usage for 120s, active=$activeThreads)"
                    Write-Host "  [Scale DOWN] Thread pool reduced to $currentMaxThreads" -ForegroundColor Cyan
                    $lowThreadTicks = $null
                }
            } else {
                $lowThreadTicks = $null
            }

            $lastCleanupTicks = $nowTicks
        }

        # v5.0: Clean expired session affinity entries every 60s
        if (($nowTicks - $lastSessionCleanTicks) -gt $sessionCleanIntervalTicks) {
            $removedSessions = Clear-ExpiredSessions
            if ($removedSessions -gt 0) {
                Write-ProxyEvent "Cleared $removedSessions expired or invalid session affinity entr$(if($removedSessions -eq 1){'y'}else{'ies'})"
            }
            $removedUploadHints = Clear-ExpiredUploadHostHints
            if ($removedUploadHints -gt 0) {
                Write-ProxyEvent "Cleared $removedUploadHints expired upload-host hint$(if($removedUploadHints -eq 1){''}else{'s'})"
            }
            $lastSessionCleanTicks = $nowTicks
        }

        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 5  # 5ms poll (was 15ms) -- 3x faster new connection acceptance
            continue
        }

        $client = $listener.AcceptTcpClient()
        $client.NoDelay = $true
        $client.ReceiveBufferSize = 524288
        $client.SendBufferSize = 524288

        # Spawn handler in runspace
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $rsPool
        $ps.AddScript($HandlerScript).AddArgument($client).AddArgument($global:ProxyState) | Out-Null
        $handle = $ps.BeginInvoke()
        $jobs.Add(@{ PS = $ps; Handle = $handle; StartTicks = $nowTicks })

        # Log connection activity
        if (($nowTicks - $lastLogTicks) -gt $logIntervalTicks) {
            $s = $global:ProxyState
            $connParts = @()
            foreach ($a in $s.adapters) { $connParts += "$($a.Name):$($s.connectionCounts[$a.Name])" }
            $typeStr = @()
            foreach ($k in @('bulk','interactive','streaming','gaming')) {
                if ($s.connectionTypes.ContainsKey($k)) { $typeStr += "$k=$($s.connectionTypes[$k])" }
            }
            $safeFlag = if ($s.safeMode) { ' [SAFE]' } else { '' }
            $ts = [System.DateTimeOffset]::Now.ToString('HH:mm:ss')
            Write-Host "  [$ts] conns=$($s.totalConnections) | $($connParts -join ' | ') | threads=$($jobs.Count) | sessions=$($s.sessionMap.Count)$safeFlag | $($typeStr -join ' ')" -ForegroundColor DarkGray
            $lastLogTicks = $nowTicks
        }
    }
} finally {
    $listener.Stop()
    $rsPool.Close()
    try { Write-AtomicJson -Path $global:ProxyState.statsFile -Data @{ running = $false } -Depth 3 } catch {}
    Write-ProxyEvent "Proxy stopped"
    Write-Host "`n  Proxy stopped." -ForegroundColor Yellow
}

