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
    # NetFusion-FIX-1: Raise relay socket buffers to 1 MB and harden bound outbound sockets for high-BDP links.
    # NetFusion-FIX-2: Keep relay copy buffers at 256 KB to cut syscall churn in the hot path.
    # NetFusion-FIX-3: Use CopyToAsync for HTTPS tunnels -- kernel I/O completion ports instead of sync blocking.
    # NetFusion-FIX-10: Pool 256 KB relay buffers via ConcurrentQueue to avoid LOH allocations and Gen2 GC pauses.
    # NetFusion-FIX-8: Batch byte accounting -- count only at connection end via CountingStream wrapper.
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace NetFusion
{
    public sealed class AtomicCounter
    {
        private long _value;

        public long Add(long delta)
        {
            return Interlocked.Add(ref _value, delta);
        }

        public long Increment()
        {
            return Interlocked.Increment(ref _value);
        }

        public long Decrement()
        {
            return Interlocked.Decrement(ref _value);
        }

        public long Read()
        {
            return Interlocked.Read(ref _value);
        }

        public long Set(long value)
        {
            return Interlocked.Exchange(ref _value, value);
        }
    }

    /// <summary>
    /// Lightweight stream wrapper that counts bytes flowing through without
    /// adding per-iteration delegate or Interlocked overhead.
    /// </summary>
    public sealed class CountingStream : Stream
    {
        private readonly Stream _inner;
        private long _bytesRead;
        private long _bytesWritten;

        public CountingStream(Stream inner) { _inner = inner; }

        public long BytesRead { get { return Interlocked.Read(ref _bytesRead); } }
        public long BytesWritten { get { return Interlocked.Read(ref _bytesWritten); } }

        public override bool CanRead { get { return _inner.CanRead; } }
        public override bool CanWrite { get { return _inner.CanWrite; } }
        public override bool CanSeek { get { return false; } }
        public override long Length { get { return _inner.Length; } }
        public override long Position { get { return _inner.Position; } set { _inner.Position = value; } }
        public override void Flush() { _inner.Flush(); }
        public override long Seek(long offset, SeekOrigin origin) { return _inner.Seek(offset, origin); }
        public override void SetLength(long value) { _inner.SetLength(value); }

        public override int Read(byte[] buffer, int offset, int count)
        {
            int n = _inner.Read(buffer, offset, count);
            if (n > 0) _bytesRead += n;
            return n;
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            _inner.Write(buffer, offset, count);
            _bytesWritten += count;
        }

        protected override void Dispose(bool disposing)
        {
            // Do not dispose the inner stream -- caller manages lifetime.
            base.Dispose(disposing);
        }
    }

    public sealed class RelayProgressState
    {
        private long _lastProgressTicks;

        public RelayProgressState()
        {
            Touch();
        }

        public void Touch()
        {
            Interlocked.Exchange(ref _lastProgressTicks, DateTime.UtcNow.Ticks);
        }

        public long LastProgressTicks
        {
            get { return Interlocked.Read(ref _lastProgressTicks); }
        }
    }

    public static class StreamCopier
    {
        private const int BufferSize = 1048576;
        private static readonly ConcurrentQueue<byte[]> BufferPool = new ConcurrentQueue<byte[]>();

        private static byte[] RentBuffer()
        {
            byte[] buf;
            if (BufferPool.TryDequeue(out buf) && buf != null && buf.Length >= BufferSize) return buf;
            return new byte[BufferSize];
        }

        private static void ReturnBuffer(byte[] buf)
        {
            if (buf != null && buf.Length == BufferSize) BufferPool.Enqueue(buf);
        }

        /// <summary>
        /// Synchronous relay for HTTP (non-CONNECT) fixed-length body copies.
        /// Uses pooled 256 KB buffers to avoid LOH allocations.
        /// </summary>
        private static void CopyStreamCore(Stream source, Stream dest, long bytesToCopy, AtomicCounter progressCounter)
        {
            byte[] buffer = RentBuffer();
            try
            {
                long remaining = bytesToCopy;
                while (true)
                {
                    if (bytesToCopy >= 0 && remaining <= 0) break;
                    int toRead = bytesToCopy < 0 ? BufferSize : (int)Math.Min(BufferSize, remaining);
                    int read = source.Read(buffer, 0, toRead);
                    if (read <= 0) break;
                    dest.Write(buffer, 0, read);
                    if (progressCounter != null) progressCounter.Add(read);
                    if (bytesToCopy >= 0) remaining -= read;
                }
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            catch (SocketException) { }
            finally
            {
                ReturnBuffer(buffer);
            }
        }

        /// <summary>Copy until EOF -- used for HTTP response relay.</summary>
        public static void CopyStream(NetworkStream source, NetworkStream dest, ref long bytesTransferred)
        {
            var cs = new CountingStream(source);
            CopyStreamCore(cs, dest, -1, null);
            Interlocked.Add(ref bytesTransferred, cs.BytesRead);
        }

        public static void CopyStream(NetworkStream source, NetworkStream dest, ref long bytesTransferred, AtomicCounter progressCounter)
        {
            var cs = new CountingStream(source);
            CopyStreamCore(cs, dest, -1, progressCounter);
            Interlocked.Add(ref bytesTransferred, cs.BytesRead);
        }

        /// <summary>Copy exactly N bytes -- used for HTTP request body relay.</summary>
        public static void CopyStream(NetworkStream source, NetworkStream dest, long bytesToCopy, ref long bytesTransferred)
        {
            var cs = new CountingStream(source);
            CopyStreamCore(cs, dest, bytesToCopy, null);
            Interlocked.Add(ref bytesTransferred, cs.BytesRead);
        }

        public static void CopyStream(NetworkStream source, NetworkStream dest, long bytesToCopy, ref long bytesTransferred, AtomicCounter progressCounter)
        {
            var cs = new CountingStream(source);
            CopyStreamCore(cs, dest, bytesToCopy, progressCounter);
            Interlocked.Add(ref bytesTransferred, cs.BytesRead);
        }

        public static long CopyFixedBytes(NetworkStream source, NetworkStream dest, long bytesToCopy, AtomicCounter progressCounter)
        {
            var cs = new CountingStream(source);
            CopyStreamCore(cs, dest, bytesToCopy, progressCounter);
            return cs.BytesRead;
        }

        private static async Task<long> CopyStreamCoreAsync(Stream source, Stream dest, AtomicCounter progressCounter)
        {
            return await CopyStreamCoreAsync(source, dest, progressCounter, null).ConfigureAwait(false);
        }

        private static async Task<long> CopyStreamCoreAsync(Stream source, Stream dest, AtomicCounter progressCounter, RelayProgressState relayProgress)
        {
            byte[] buffer = RentBuffer();
            long bytes = 0;
            try
            {
                while (true)
                {
                    int read = await source.ReadAsync(buffer, 0, BufferSize).ConfigureAwait(false);
                    if (read <= 0) break;
                    await dest.WriteAsync(buffer, 0, read).ConfigureAwait(false);
                    bytes += read;
                    if (progressCounter != null) progressCounter.Add(read);
                    if (relayProgress != null) relayProgress.Touch();
                }
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            catch (SocketException) { }
            finally
            {
                ReturnBuffer(buffer);
            }

            return bytes;
        }

        /// <summary>
        /// Bidirectional relay for HTTPS CONNECT tunnels.
        /// Uses true async NetworkStream I/O instead of two dedicated LongRunning
        /// threads per connection, reducing thread pressure during parallel downloads.
        /// </summary>
        public static void CopyStreamBidirectional(NetworkStream client, NetworkStream remote, ref long clientToRemoteBytes, ref long remoteToClientBytes)
        {
            CopyStreamBidirectional(client, remote, ref clientToRemoteBytes, ref remoteToClientBytes, null, null);
        }

        public static void CopyStreamBidirectional(NetworkStream client, NetworkStream remote, ref long clientToRemoteBytes, ref long remoteToClientBytes, AtomicCounter clientToRemoteCounter, AtomicCounter remoteToClientCounter)
        {
            CopyStreamBidirectional(client, remote, ref clientToRemoteBytes, ref remoteToClientBytes, clientToRemoteCounter, remoteToClientCounter, 45000);
        }

        public static void CopyStreamBidirectional(NetworkStream client, NetworkStream remote, ref long clientToRemoteBytes, ref long remoteToClientBytes, AtomicCounter clientToRemoteCounter, AtomicCounter remoteToClientCounter, int idleTimeoutMs)
        {
            int safeIdleTimeoutMs = Math.Max(15000, Math.Min(idleTimeoutMs, 300000));
            var relayProgress = new RelayProgressState();
            var uploadTask = CopyStreamCoreAsync(client, remote, clientToRemoteCounter, relayProgress);
            var downloadTask = CopyStreamCoreAsync(remote, client, remoteToClientCounter, relayProgress);
            var relayTasks = new Task[] { uploadTask, downloadTask };

            try
            {
                while (true)
                {
                    int completed = Task.WaitAny(relayTasks, 1000);
                    if (completed >= 0) break;

                    long idleMs = (DateTime.UtcNow.Ticks - relayProgress.LastProgressTicks) / TimeSpan.TicksPerMillisecond;
                    if (idleMs > safeIdleTimeoutMs) break;
                }
            }
            catch { }

            try { client.Close(); } catch { }
            try { remote.Close(); } catch { }

            try { Task.WaitAll(new Task[] { uploadTask, downloadTask }, 1000); } catch { }

            if (uploadTask.IsCompleted && !uploadTask.IsFaulted && !uploadTask.IsCanceled)
                Interlocked.Add(ref clientToRemoteBytes, uploadTask.Result);
            if (downloadTask.IsCompleted && !downloadTask.IsFaulted && !downloadTask.IsCanceled)
                Interlocked.Add(ref remoteToClientBytes, downloadTask.Result);
        }
    }

    public static class SocketConnector
    {
        private const int SocketBufferSize = 1048576;

        public static TcpClient CreateBoundConnection(string localSourceIp, string remoteHost, int remotePort, int timeoutMs, int interfaceIndex)
        {
            var client = new TcpClient(AddressFamily.InterNetwork);
            try
            {
                client.NoDelay = true;
                client.ReceiveBufferSize = SocketBufferSize;
                client.SendBufferSize = SocketBufferSize;
                client.Client.LingerState = new LingerOption(false, 0);

                IPAddress parsedRemote;
                bool isLoopbackTarget =
                    string.Equals(remoteHost, "localhost", StringComparison.OrdinalIgnoreCase) ||
                    (IPAddress.TryParse(remoteHost, out parsedRemote) && IPAddress.IsLoopback(parsedRemote));

                if (!isLoopbackTarget)
                {
                    client.Client.Bind(new IPEndPoint(IPAddress.Parse(localSourceIp), 0));

                    if (interfaceIndex > 0)
                    {
                        try
                        {
                            // Windows IP_UNICAST_IF expects the interface index in network byte order.
                            client.Client.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(interfaceIndex));
                        }
                        catch { }
                    }
                }

                var connectTask = client.ConnectAsync(remoteHost, remotePort);
                if (!connectTask.Wait(timeoutMs))
                {
                    client.Close();
                    throw new TimeoutException("Connection via " + localSourceIp + " timed out");
                }

                return client;
            }
            catch
            {
                try { client.Close(); } catch { }
                throw;
            }
        }
    }

    public static class WeightedRoundRobin
    {
        private static long _counter = -1;

        public static int NextIndex(int[] schedule)
        {
            if (schedule == null || schedule.Length == 0) return -1;
            long next = Interlocked.Increment(ref _counter);
            long slot = next % schedule.Length;
            if (slot < 0) slot += schedule.Length;
            return schedule[(int)slot];
        }
    }
}
"@ -Language CSharp
    # Ensure enough I/O completion threads for async relay operations
    $workerMin = 0; $ioMin = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$workerMin, [ref]$ioMin)
    if ($ioMin -lt 64) {
        [System.Threading.ThreadPool]::SetMinThreads([Math]::Max($workerMin, 64), 64)
    }
}

# NetFusion-FIX-6: Use Interlocked-backed counters instead of plain integers for shared relay statistics.
function Get-OrCreate-AtomicCounter {
    param(
        [hashtable]$Map,
        [string]$Key
    )

    $counter = $Map[$Key]
    if ($null -eq $counter) {
        $counter = [NetFusion.AtomicCounter]::new()
        $Map[$Key] = $counter
    }

    return $counter
}

function Get-AtomicCounterValue {
    param([object]$Counter)

    if ($null -eq $Counter) {
        return [int64]0
    }

    return [int64]$Counter.Read()
}

# ===== Thread-safe state =====
$global:ProxyState = [hashtable]::Synchronized(@{
    adapters         = @()
    weights          = @()
    rrSchedule       = @()
    rrCounter        = [NetFusion.AtomicCounter]::new()
    connectionCounts = [hashtable]::Synchronized(@{})
    successCounts    = [hashtable]::Synchronized(@{})
    failCounts       = [hashtable]::Synchronized(@{})
    totalConnections = [NetFusion.AtomicCounter]::new()
    totalFails       = [NetFusion.AtomicCounter]::new()
    activeConnections = [NetFusion.AtomicCounter]::new()        # v5.1: live active connection count
    activePerAdapter  = [hashtable]::Synchronized(@{})      # v5.1: per-adapter active counts
    activePerHost     = [hashtable]::Synchronized(@{})      # v5.1: per-host active counts for dynamic bulk detection
    currentMode      = 'maxspeed'
    rrIndex          = 0
    connectTimeout   = 5000
    connectIdleTimeoutMs = 45000
    maxRetries       = 3
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
    decisions        = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    maxDecisions     = 100
    bandwidthEstimates = @{}
    uploadBandwidthEstimates = @{}
    proxyDownloadBytes = [hashtable]::Synchronized(@{})
    proxyUploadBytes   = [hashtable]::Synchronized(@{})
    proxyRateMbps      = [hashtable]::Synchronized(@{})
    proxyCapacityMbps  = [hashtable]::Synchronized(@{})
    proxyLastRateSample = [hashtable]::Synchronized(@{})
    adapterFailureStreak = [hashtable]::Synchronized(@{})
    adapterCooldownUntil = [hashtable]::Synchronized(@{})
    adapterEndpoints = [hashtable]::Synchronized(@{})
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
    sessionTTL     = 60
    # v5.0 Safety
    safeMode       = $false
    portClasses    = @{
        gaming = @(3074, 3478, 3479, 3480, 3659, 25565, 27015, 27036, 19132)
        voice  = @(3478, 3479, 3480, 5004, 5005, 5060, 5061)
        bulk   = @(20, 21, 22, 8080, 8443, 9000, 9090)
    }
})
$script:ProxyLogMutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")
$script:ActivePowershells = [System.Collections.Concurrent.ConcurrentQueue[System.Management.Automation.PowerShell]]::new()
$script:IsRunning = $true

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
        if ($Path -notmatch '(?i)(proxy-stats|decisions)\.json$') {
            try { Copy-Item $Path "$Path.bak" -Force -ErrorAction SilentlyContinue } catch {}
        }
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

function Clear-SessionAffinityForAdapters {
    param(
        [object]$State,
        [string[]]$AdapterNames
    )

    if (-not $State -or -not $AdapterNames -or $AdapterNames.Count -eq 0) {
        return 0
    }

    $targetAdapters = @($AdapterNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($targetAdapters.Count -eq 0) {
        return 0
    }

    $removedCount = 0
    foreach ($key in @($State.sessionMap.Keys)) {
        $entry = $State.sessionMap[$key]
        if (-not $entry -or -not $entry.adapter) {
            continue
        }

        if ([string]$entry.adapter -in $targetAdapters) {
            try {
                $removedEntry = $null
                if ($State.sessionMap.TryRemove($key, [ref]$removedEntry)) {
                    $removedCount++
                }
            } catch {}
        }
    }

    return $removedCount
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

function Reset-AdapterRuntimeStateForEndpointChanges {
    param(
        [object]$State,
        [object[]]$Adapters
    )

    if (-not $State -or -not $Adapters) {
        return
    }

    $currentNames = @{}
    $changedNames = [System.Collections.Generic.List[string]]::new()

    foreach ($adapter in @($Adapters)) {
        if (-not $adapter -or [string]::IsNullOrWhiteSpace([string]$adapter.Name)) {
            continue
        }

        $name = [string]$adapter.Name
        $currentNames[$name] = $true
        $endpoint = "{0}|{1}|{2}" -f ([string]$adapter.IP), ([string]$adapter.InterfaceIndex), ([string]$adapter.Gateway)

        $previousEndpoint = $null
        if ($State.adapterEndpoints.ContainsKey($name)) {
            $previousEndpoint = [string]$State.adapterEndpoints[$name]
        }

        if ($previousEndpoint -and $previousEndpoint -ne $endpoint) {
            $changedNames.Add($name)
            try { [void]$State.adapterFailureStreak.Remove($name) } catch {}
            try { [void]$State.adapterCooldownUntil.Remove($name) } catch {}
            try { [void]$State.bandwidthEstimates.Remove($name) } catch {}
            try { [void]$State.uploadBandwidthEstimates.Remove($name) } catch {}
            try { [void]$State.proxyCapacityMbps.Remove($name) } catch {}
            try { [void]$State.proxyRateMbps.Remove($name) } catch {}
            try { [void]$State.proxyLastRateSample.Remove($name) } catch {}
        }

        $State.adapterEndpoints[$name] = $endpoint
    }

    foreach ($knownName in @($State.adapterEndpoints.Keys)) {
        if (-not $currentNames.ContainsKey([string]$knownName)) {
            $changedNames.Add([string]$knownName)
            try { [void]$State.adapterEndpoints.Remove([string]$knownName) } catch {}
            try { [void]$State.adapterFailureStreak.Remove([string]$knownName) } catch {}
            try { [void]$State.adapterCooldownUntil.Remove([string]$knownName) } catch {}
        }
    }

    if ($changedNames.Count -gt 0) {
        $uniqueNames = @($changedNames | Select-Object -Unique)
        [void](Clear-SessionAffinityForAdapters -State $State -AdapterNames $uniqueNames)
        Write-ProxyEvent ("Adapter endpoint changed; cleared stale runtime state for {0}" -f ($uniqueNames -join ', '))
    }
}

function Get-ProxyAdapters {
    $adapters = @()
    $ifFile = $global:ProxyState.interfacesFile
    $data = Read-JsonFile -Path $ifFile -DefaultValue $null
    if ($data -and $data.interfaces) {
        foreach ($iface in $data.interfaces) {
            # NetFusion-FIX-12: Carry adapter IP, gateway, DNS, and link-speed metadata into the proxy so source-bound connects use the selected WAN.
            $adapterIp = if ($iface.PSObject.Properties['IpAddress'] -and $iface.IpAddress) { $iface.IpAddress } else { $iface.IPAddress }
            $adapterDns = if ($iface.PSObject.Properties['DnsServers'] -and $iface.DnsServers) {
                [string]$iface.DnsServers
            } elseif ($iface.PSObject.Properties['DNSServers'] -and $iface.DNSServers) {
                (@($iface.DNSServers) -join ',')
            } else {
                ''
            }
            if ($adapterIp -and $iface.Status -eq 'Up' -and $adapterIp -notmatch '^169\.254\.' -and $iface.Gateway) {
                $adapters += @{
                    Name = $iface.Name
                    IP = $adapterIp
                    IpAddress = $adapterIp
                    Type = $iface.Type
                    Speed = $iface.LinkSpeedMbps
                    InterfaceIndex = $iface.InterfaceIndex
                    Gateway = $iface.Gateway
                    DnsServers = $adapterDns
                }
            }
        }
    }
    if ($adapters.Count -lt 1) {
        Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN' } | ForEach-Object {
            $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^169\.254\.' } |
                Sort-Object @{ Expression = { if ($_.PrefixOrigin -eq 'Dhcp') { 0 } elseif ($_.PrefixOrigin -eq 'Manual') { 1 } else { 2 } } }, SkipAsSource |
                Select-Object -First 1).IPAddress
            if ($ip -and $ip -notmatch '^169\.254\.') {
                $type = if ($_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11' -or $_.Name -match 'Wi-Fi') { if ($_.InterfaceDescription -match 'USB|TP-Link|Ralink|MediaTek.*USB|Realtek.*USB') { 'USB-WiFi' } else { 'WiFi' } } elseif ($_.InterfaceDescription -match 'Ethernet') { 'Ethernet' } else { 'Unknown' }
                $linkSpeedMbps = 100.0
                if ($_.LinkSpeed -match '([\d.]+)\s*(Gbps|Mbps|Kbps)') {
                    $value = [double]$Matches[1]
                    switch ($Matches[2]) {
                        'Gbps' { $linkSpeedMbps = $value * 1000.0 }
                        'Mbps' { $linkSpeedMbps = $value }
                        'Kbps' { $linkSpeedMbps = $value / 1000.0 }
                    }
                }
                $dnsServers = ''
                try {
                    $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    if ($dnsInfo -and $dnsInfo.ServerAddresses) {
                        $dnsServers = (@($dnsInfo.ServerAddresses) -join ',')
                    }
                } catch {}
                $gateway = ''
                try {
                    $routeInfo = Get-NetRoute -InterfaceIndex $_.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
                    if ($routeInfo) {
                        $gateway = [string]$routeInfo.NextHop
                    }
                } catch {}
                if ($gateway) {
                    $adapters += @{
                        Name = $_.Name
                        IP = $ip
                        IpAddress = $ip
                        Type = $type
                        Speed = $linkSpeedMbps
                        InterfaceIndex = $_.ifIndex
                        Gateway = $gateway
                        DnsServers = $dnsServers
                    }
                }
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

function Update-ProxyRateSnapshot {
    param(
        [object]$State,
        [object[]]$Adapters
    )

    if (-not $State -or -not $Adapters) {
        return
    }

    $rateNowTicks = [System.DateTimeOffset]::UtcNow.Ticks
    foreach ($adapter in $Adapters) {
        try {
            $downloadCounter = Get-OrCreate-AtomicCounter -Map $State.proxyDownloadBytes -Key $adapter.Name
            $uploadCounter = Get-OrCreate-AtomicCounter -Map $State.proxyUploadBytes -Key $adapter.Name
            $downloadBytes = [int64](Get-AtomicCounterValue -Counter $downloadCounter)
            $uploadBytes = [int64](Get-AtomicCounterValue -Counter $uploadCounter)
            $lastSample = if ($State.proxyLastRateSample.ContainsKey($adapter.Name)) { $State.proxyLastRateSample[$adapter.Name] } else { $null }

            if ($lastSample -and $lastSample.Ticks) {
                $seconds = ($rateNowTicks - [int64]$lastSample.Ticks) / [double][System.TimeSpan]::TicksPerSecond
                if ($seconds -lt 0.25) {
                    continue
                }

                $downloadDelta = [math]::Max(0L, $downloadBytes - [int64]$lastSample.DownloadBytes)
                $uploadDelta = [math]::Max(0L, $uploadBytes - [int64]$lastSample.UploadBytes)
                $State.proxyRateMbps[$adapter.Name] = @{
                    DownloadMbps = [math]::Round(($downloadDelta * 8.0) / $seconds / 1000000.0, 2)
                    UploadMbps = [math]::Round(($uploadDelta * 8.0) / $seconds / 1000000.0, 2)
                }
            } elseif (-not $State.proxyRateMbps.ContainsKey($adapter.Name)) {
                $State.proxyRateMbps[$adapter.Name] = @{ DownloadMbps = 0.0; UploadMbps = 0.0 }
            }

            $State.proxyLastRateSample[$adapter.Name] = @{
                Ticks = $rateNowTicks
                DownloadBytes = $downloadBytes
                UploadBytes = $uploadBytes
            }
        } catch {}
    }
}

function Update-AdaptersAndWeights {
    $s = $global:ProxyState
    $freshAdapters = @(Get-ProxyAdapters)
    Reset-AdapterRuntimeStateForEndpointChanges -State $s -Adapters $freshAdapters
    $s.adapters = $freshAdapters
    Update-ProxyRateSnapshot -State $s -Adapters $s.adapters

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
                    Status      = if ($_.Status) { [string]$_.Status } else { 'offline' }
                    Latency     = $_.InternetLatency
                    LatencyEWMA = if ($_.InternetLatencyEWMA) { $_.InternetLatencyEWMA } else { $_.InternetLatency }
                    Jitter      = if ($_.Jitter) { $_.Jitter } else { 0 }
                    PacketLoss  = if ($null -ne $_.PacketLoss) { $_.PacketLoss } else { 0 }
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
            if ($cfg.proxy -and $null -ne $cfg.proxy.connectTimeout -and [int]$cfg.proxy.connectTimeout -gt 0) {
                $s.connectTimeout = [int]$cfg.proxy.connectTimeout
            }
            if ($cfg.proxy -and $null -ne $cfg.proxy.connectIdleTimeoutSec -and [int]$cfg.proxy.connectIdleTimeoutSec -gt 0) {
                $s.connectIdleTimeoutMs = [Math]::Min(300000, [Math]::Max(15000, ([int]$cfg.proxy.connectIdleTimeoutSec * 1000)))
            }
            if ($cfg.proxy -and $null -ne $cfg.proxy.maxRetries -and [int]$cfg.proxy.maxRetries -gt 0) {
                $s.maxRetries = [int]$cfg.proxy.maxRetries
            }
            # NetFusion-FIX-7: Keep soft affinity short-lived so new bulk flows rebalance quickly across both WAN adapters.
            if ($cfg.proxy -and $null -ne $cfg.proxy.sessionAffinityTTL) {
                $ttl = [int]$cfg.proxy.sessionAffinityTTL
                if ($ttl -gt 0) {
                    $s.sessionTTL = [Math]::Min(30, [Math]::Max(15, $ttl))
                }
            } else {
                $s.sessionTTL = 30
            }
            $refresh = $cfg.intelligence.weightRefreshInterval
            if ($null -ne $refresh -and [double]$refresh -gt 0) {
                $s.weightRefreshInterval = [double]$refresh
            }
        } catch {}
    }

    # NetFusion-FIX-7: Immediately expire sticky affinity entries for adapters that just went offline so new flows re-spread.
    $unhealthyAdapters = @(
        foreach ($entry in $health.GetEnumerator()) {
            $status = if ($entry.Value.ContainsKey('Status')) { [string]$entry.Value.Status } else { '' }
            $score = if ($entry.Value.ContainsKey('Score') -and $null -ne $entry.Value.Score) { [double]$entry.Value.Score } else { 0.0 }
            if ($status -eq 'offline' -or $score -le 0.0) {
                $entry.Key
            }
        }
    )
    if ($unhealthyAdapters.Count -gt 0) {
        [void](Clear-SessionAffinityForAdapters -State $s -AdapterNames $unhealthyAdapters)
    }

    # NetFusion-FIX-5: Weight adapters by measured throughput first, then apply only a minor latency nudge.
    $weights = @()
    foreach ($a in $s.adapters) {
        $h = $health[$a.Name]
        $observedMbps = Get-AdapterObservedMbps -State $s -Adapter $a
        $liveCapacityMbps = 0.0
        try {
            if ($s.proxyCapacityMbps.ContainsKey($a.Name)) {
                $liveCapacityMbps = [double]$s.proxyCapacityMbps[$a.Name]
            }
        } catch {}
        $linkSpeedMbps = if ($null -ne $a.Speed -and [double]$a.Speed -gt 0) {
            [double]$a.Speed
        } elseif ($h -and $h.ContainsKey('LinkSpeedMbps') -and [double]$h.LinkSpeedMbps -gt 0) {
            [double]$h.LinkSpeedMbps
        } else {
            0.0
        }

        $capacityFloor = 100.0
        if ($linkSpeedMbps -gt 0.0) {
            if ($a.Type -match 'Ethernet') {
                $capacityFloor = [math]::Max(100.0, [math]::Min($linkSpeedMbps, $linkSpeedMbps * 0.80))
            } elseif ($a.Type -match 'WiFi') {
                # Wi-Fi LinkSpeed is PHY rate, not usable WAN throughput. Seed
                # mixed Wi-Fi systems toward practical WAN targets so the USB
                # adapter receives enough discovery and bulk flows to prove or
                # disprove its real capacity instead of being starved by PHY math.
                $wifiSeed = [math]::Sqrt($linkSpeedMbps) * 12.0
                $practicalSeed = if ($a.Type -match 'USB') {
                    if ($linkSpeedMbps -ge 150.0) { 300.0 } elseif ($linkSpeedMbps -ge 72.0) { 150.0 } else { 80.0 }
                } else {
                    if ($linkSpeedMbps -ge 866.0) { 500.0 } elseif ($linkSpeedMbps -ge 300.0) { 300.0 } else { 150.0 }
                }
                $capacityFloor = [math]::Max(80.0, [math]::Max($wifiSeed, $practicalSeed))
            } else {
                $capacityFloor = [math]::Max(50.0, [math]::Min($linkSpeedMbps, $linkSpeedMbps * 0.35))
            }
        } elseif ($a.Type -match 'WiFi|Ethernet') {
            $capacityFloor = 300.0
        }

        # Weight by the best current evidence of capacity. Initial discovery uses
        # practical floors, but once sustained proxy traffic proves a different
        # real path capacity, let that live estimate override stale 500/300 Wi-Fi
        # assumptions. Keep a small exploration floor so an idle adapter can recover.
        if ($liveCapacityMbps -ge 25.0) {
            # Do not let a short, low-quality sample permanently erase the
            # practical 500/300 Wi-Fi target. Maxspeed should preserve the
            # strong internal Wi-Fi baseline while still probing the USB link.
            $observedMbps = [math]::Max($liveCapacityMbps, ($capacityFloor * 0.60))
        } else {
            # Pure observed-throughput weighting causes positive feedback: an idle
            # but healthy second adapter decays toward zero and stops receiving
            # discovery flows.
            $observedMbps = [math]::Max($observedMbps, $capacityFloor)
        }

        $latencyAdjustment = 1.0
        if ($h) {
            $latency = if ($null -ne $h.LatencyEWMA) { [double]$h.LatencyEWMA } elseif ($null -ne $h.Latency) { [double]$h.Latency } else { 0.0 }
            $latencyPenalty = [math]::Min(0.10, [math]::Max(0.0, ($latency / 1000.0)))
            $latencyAdjustment = 1.0 - $latencyPenalty
        }

        $w = [math]::Max(1.0, [math]::Round(($observedMbps * $latencyAdjustment), 2))

        $weights += $w
        [void](Get-OrCreate-AtomicCounter -Map $s.connectionCounts -Key $a.Name)
        [void](Get-OrCreate-AtomicCounter -Map $s.successCounts -Key $a.Name)
        [void](Get-OrCreate-AtomicCounter -Map $s.failCounts -Key $a.Name)
        [void](Get-OrCreate-AtomicCounter -Map $s.activePerAdapter -Key $a.Name)
    }
    $s.weights = $weights
    $s.rrSchedule = New-WeightedRoundRobinSchedule -Weights ([double[]]$weights)
}

function Get-AdapterObservedMbps {
    param(
        [object]$State,
        [object]$Adapter
    )

    $h = $State.adapterHealth[$Adapter.Name]
    if (-not $h) {
        try {
            if ($State.proxyCapacityMbps.ContainsKey($Adapter.Name)) {
                return [double]$State.proxyCapacityMbps[$Adapter.Name]
            }
        } catch {}
        return 0.0
    }

    $bestDown = 0.0
    foreach ($propertyName in @('EstimatedDownMbps', 'DownloadMbps')) {
        if ($h.ContainsKey($propertyName) -and $null -ne $h[$propertyName]) {
            $value = [double]$h[$propertyName]
            if ($value -gt $bestDown) {
                $bestDown = $value
            }
        }
    }

    $bestUp = 0.0
    foreach ($propertyName in @('EstimatedUpMbps', 'UploadMbps')) {
        if ($h.ContainsKey($propertyName) -and $null -ne $h[$propertyName]) {
            $value = [double]$h[$propertyName]
            if ($value -gt $bestUp) {
                $bestUp = $value
            }
        }
    }

    $healthObserved = [double]($bestDown + $bestUp)
    $proxyObserved = 0.0
    if ($State.PSObject.Properties['proxyRateMbps'] -or $State.ContainsKey('proxyRateMbps')) {
        try {
            if ($State.proxyCapacityMbps.ContainsKey($Adapter.Name)) {
                $proxyObserved = [math]::Max($proxyObserved, [double]$State.proxyCapacityMbps[$Adapter.Name])
            }
            if ($State.proxyRateMbps.ContainsKey($Adapter.Name)) {
                $rateEntry = $State.proxyRateMbps[$Adapter.Name]
                if ($rateEntry) {
                    $proxyObserved = [double]$rateEntry.DownloadMbps + [double]$rateEntry.UploadMbps
                }
            }
        } catch {}
    }

    return [math]::Max($healthObserved, $proxyObserved)
}

function Get-AdapterSelectionOrder {
    param(
        [object]$State,
        [object[]]$Adapters,
        [double[]]$Weights,
        [int]$PreferredIndex = 0
    )

    if (-not $Adapters -or $Adapters.Count -eq 0) {
        return @()
    }

    $weightValues = @()
    $totalWeight = 0.0
    for ($i = 0; $i -lt $Adapters.Count; $i++) {
        $weight = if ($i -lt $Weights.Count) { [double]$Weights[$i] } else { 1.0 }
        $weight = [math]::Max(1.0, $weight)
        $weightValues += $weight
        $totalWeight += $weight
    }

    $totalActive = 0
    foreach ($adapter in $Adapters) {
        if ($State.activePerAdapter.ContainsKey($adapter.Name)) {
            $totalActive += [int](Get-AtomicCounterValue -Counter $State.activePerAdapter[$adapter.Name])
        }
    }

    $proxyMbpsByAdapter = @{}
    $totalProxyMbps = 0.0
    foreach ($adapter in $Adapters) {
        $adapterProxyMbps = 0.0
        try {
            if ($State.proxyRateMbps.ContainsKey($adapter.Name)) {
                $rateEntry = $State.proxyRateMbps[$adapter.Name]
                if ($rateEntry) {
                    $adapterProxyMbps = [math]::Max(0.0, [double]$rateEntry.DownloadMbps + [double]$rateEntry.UploadMbps)
                }
            }
        } catch {}
        $proxyMbpsByAdapter[$adapter.Name] = $adapterProxyMbps
        $totalProxyMbps += $adapterProxyMbps
    }

    if ($PreferredIndex -lt 0 -or $PreferredIndex -ge $Adapters.Count) {
        $PreferredIndex = 0
    }

    $ranked = @()
    for ($i = 0; $i -lt $Adapters.Count; $i++) {
        $adapter = $Adapters[$i]
        $weight = [double]$weightValues[$i]
        $targetShare = if ($totalWeight -gt 0.0) { $weight / $totalWeight } else { 1.0 / [double]$Adapters.Count }
        $activeCount = if ($State.activePerAdapter.ContainsKey($adapter.Name)) { [int](Get-AtomicCounterValue -Counter $State.activePerAdapter[$adapter.Name]) } else { 0 }
        $currentShare = if ($totalActive -gt 0) { [double]$activeCount / [double]$totalActive } else { 0.0 }
        $currentRateShare = if ($totalProxyMbps -gt 10.0 -and $proxyMbpsByAdapter.ContainsKey($adapter.Name)) { [double]$proxyMbpsByAdapter[$adapter.Name] / [double]$totalProxyMbps } else { $currentShare }

        $h = $State.adapterHealth[$adapter.Name]
        $linkSpeedMbps = if ($null -ne $adapter.Speed -and [double]$adapter.Speed -gt 0) {
            [double]$adapter.Speed
        } elseif ($h -and $h.ContainsKey('LinkSpeedMbps') -and [double]$h.LinkSpeedMbps -gt 0) {
            [double]$h.LinkSpeedMbps
        } else {
            100.0
        }
        $observedMbps = Get-AdapterObservedMbps -State $State -Adapter $adapter
        $utilization = [math]::Min(1.50, ($observedMbps / [math]::Max(50.0, $linkSpeedMbps)))

        # Lifetime failure totals are telemetry, not a routing penalty. A single
        # bad speed-test burst or temporary server refusal should not suppress a
        # healthy USB Wi-Fi adapter for the rest of the process lifetime.
        $failureStreak = if ($State.adapterFailureStreak.ContainsKey($adapter.Name)) { [int]$State.adapterFailureStreak[$adapter.Name] } else { 0 }
        $failRate = [math]::Min(0.50, ([double]$failureStreak / 8.0))

        # Keep weighted round-robin as the base policy, but prefer adapters that are below their target live share.
        $rrBoost = if ($i -eq $PreferredIndex) { 0.02 } else { 0.0 }
        $deficit = $targetShare - $currentShare
        $rateDeficit = if ($totalProxyMbps -gt 10.0) { $targetShare - $currentRateShare } else { 0.0 }
        # Keep scheduling capacity-stable. Live rate is a useful correction, but
        # over-weighting short samples can oscillate traffic toward the slower
        # adapter and reduce total throughput below the fast-link baseline.
        $score = ($deficit * 1.25) + ($rateDeficit * 1.0) + ((1.0 - $utilization) * 0.05) - ($failRate * 0.75) + $rrBoost

        $ranked += [pscustomobject]@{
            Adapter = $adapter
            Score = [math]::Round($score, 6)
            Weight = $weight
            Preferred = ($i -eq $PreferredIndex)
        }
    }

    @($ranked | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Weight }; Descending = $true }, @{ Expression = { $_.Preferred }; Descending = $true })
}

function Update-ProxyStats {
    $s = $global:ProxyState
    $aStats = @()
    $rateNowTicks = [System.DateTimeOffset]::UtcNow.Ticks
    $activeTotalNow = [int](Get-AtomicCounterValue -Counter $s.activeConnections)
    foreach ($a in $s.adapters) {
        $h = $s.adapterHealth[$a.Name]
        $downloadCounter = Get-OrCreate-AtomicCounter -Map $s.proxyDownloadBytes -Key $a.Name
        $uploadCounter = Get-OrCreate-AtomicCounter -Map $s.proxyUploadBytes -Key $a.Name
        $downloadBytes = [int64](Get-AtomicCounterValue -Counter $downloadCounter)
        $uploadBytes = [int64](Get-AtomicCounterValue -Counter $uploadCounter)
        $downloadMbps = 0.0
        $uploadMbps = 0.0
        try {
            $lastSample = if ($s.proxyLastRateSample.ContainsKey($a.Name)) { $s.proxyLastRateSample[$a.Name] } else { $null }
            if ($lastSample -and $lastSample.Ticks) {
                $seconds = ($rateNowTicks - [int64]$lastSample.Ticks) / [double][System.TimeSpan]::TicksPerSecond
                if ($seconds -gt 0.25) {
                    $downloadDelta = [math]::Max(0L, $downloadBytes - [int64]$lastSample.DownloadBytes)
                    $uploadDelta = [math]::Max(0L, $uploadBytes - [int64]$lastSample.UploadBytes)
                    $downloadMbps = [math]::Round(($downloadDelta * 8.0) / $seconds / 1000000.0, 2)
                    $uploadMbps = [math]::Round(($uploadDelta * 8.0) / $seconds / 1000000.0, 2)
                    $currentCapacityMbps = [math]::Max(0.0, $downloadMbps + $uploadMbps)
                    if ($currentCapacityMbps -ge 5.0) {
                        $previousCapacity = if ($s.proxyCapacityMbps.ContainsKey($a.Name)) { [double]$s.proxyCapacityMbps[$a.Name] } else { 0.0 }
                        $alpha = if ($currentCapacityMbps -gt $previousCapacity) { 0.45 } else { 0.20 }
                        $s.proxyCapacityMbps[$a.Name] = [math]::Round((($previousCapacity * (1.0 - $alpha)) + ($currentCapacityMbps * $alpha)), 2)
                    }
                    $s.proxyLastRateSample[$a.Name] = @{
                        Ticks = $rateNowTicks
                        DownloadBytes = $downloadBytes
                        UploadBytes = $uploadBytes
                    }
                    $s.proxyRateMbps[$a.Name] = @{
                        DownloadMbps = $downloadMbps
                        UploadMbps = $uploadMbps
                    }
                }
            } else {
                $s.proxyLastRateSample[$a.Name] = @{
                    Ticks = $rateNowTicks
                    DownloadBytes = $downloadBytes
                    UploadBytes = $uploadBytes
                }
                if (-not $s.proxyRateMbps.ContainsKey($a.Name)) {
                    $s.proxyRateMbps[$a.Name] = @{
                        DownloadMbps = 0.0
                        UploadMbps = 0.0
                    }
                }
            }
        } catch {}
        try {
            if ($s.proxyRateMbps.ContainsKey($a.Name)) {
                $rateEntry = $s.proxyRateMbps[$a.Name]
                if ($rateEntry) {
                    $downloadMbps = [double]$rateEntry.DownloadMbps
                    $uploadMbps = [double]$rateEntry.UploadMbps
                }
            }
        } catch {}
        try {
            $instantCapacityMbps = [math]::Max(0.0, $downloadMbps + $uploadMbps)
            if ($instantCapacityMbps -ge 5.0) {
                $previousCapacity = if ($s.proxyCapacityMbps.ContainsKey($a.Name)) { [double]$s.proxyCapacityMbps[$a.Name] } else { 0.0 }
                $alpha = if ($instantCapacityMbps -gt $previousCapacity) { 0.45 } else { 0.20 }
                $s.proxyCapacityMbps[$a.Name] = [math]::Round((($previousCapacity * (1.0 - $alpha)) + ($instantCapacityMbps * $alpha)), 2)
            }
        } catch {}

        $aStats += @{
            name = $a.Name; type = $a.Type; ip = $a.IP
            connections = [int](Get-AtomicCounterValue -Counter $s.connectionCounts[$a.Name])
            successes = [int](Get-AtomicCounterValue -Counter $s.successCounts[$a.Name])
            failures = [int](Get-AtomicCounterValue -Counter $s.failCounts[$a.Name])
            failureStreak = if ($s.adapterFailureStreak.ContainsKey($a.Name)) { [int]$s.adapterFailureStreak[$a.Name] } else { 0 }
            cooldownRemainingSec = if ($s.adapterCooldownUntil.ContainsKey($a.Name)) { [math]::Max(0.0, [math]::Round((([int64]$s.adapterCooldownUntil[$a.Name] - [System.DateTimeOffset]::UtcNow.Ticks) / [double][System.TimeSpan]::TicksPerSecond), 1)) } else { 0.0 }
            health = if ($h) { $h.Score } else { 0 }
            latency = if ($h) { $h.LatencyEWMA } else { 999 }
            jitter = if ($h) { $h.Jitter } else { 0 }
            isDegrading = if ($h) { $h.IsDegrading } else { $false }
            proxyDownloadBytes = $downloadBytes
            proxyUploadBytes = $uploadBytes
            proxyDownloadMbps = $downloadMbps
            proxyUploadMbps = $uploadMbps
            proxyCapacityMbps = if ($s.proxyCapacityMbps.ContainsKey($a.Name)) { [double]$s.proxyCapacityMbps[$a.Name] } else { 0.0 }
        }
    }
    # Build per-adapter active counts
    $activePerAdapterSnap = @{}
    foreach ($a in $s.adapters) {
        if ($activeTotalNow -le 0 -and $s.activePerAdapter.ContainsKey($a.Name)) {
            try { [void]$s.activePerAdapter[$a.Name].Set(0) } catch {}
        }
        $activePerAdapterSnap[$a.Name] = if ($s.activePerAdapter.ContainsKey($a.Name)) { [int](Get-AtomicCounterValue -Counter $s.activePerAdapter[$a.Name]) } else { 0 }
    }
    if ($activeTotalNow -le 0) {
        try { [void]$s.activeConnections.Set(0) } catch {}
        try {
            foreach ($hostKeyName in @($s.activePerHost.Keys)) {
                $hostCounter = $s.activePerHost[$hostKeyName]
                if ($hostCounter) { [void]$hostCounter.Set(0) }
            }
        } catch {}
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
    $gatewayGroups = @{}
    foreach ($a in $s.adapters) {
        $gatewayKey = if ($a.Gateway) { [string]$a.Gateway } else { '' }
        if ([string]::IsNullOrWhiteSpace($gatewayKey)) { continue }
        if (-not $gatewayGroups.ContainsKey($gatewayKey)) {
            $gatewayGroups[$gatewayKey] = @()
        }
        $gatewayGroups[$gatewayKey] = @($gatewayGroups[$gatewayKey]) + @([string]$a.Name)
    }
    $sharedGatewayGroups = @()
    foreach ($gatewayKey in @($gatewayGroups.Keys)) {
        $names = @($gatewayGroups[$gatewayKey])
        if ($names.Count -gt 1) {
            $sharedGatewayGroups += @{
                gateway = $gatewayKey
                adapters = $names
            }
        }
    }
    $networkLimits = @{
        possibleWanConvergence = ($sharedGatewayGroups.Count -gt 0)
        sharedGateways = $sharedGatewayGroups
    }
    $statsSnapshot = @{
        running = $true; port = $s.port; mode = $s.currentMode
        totalConnections = [int](Get-AtomicCounterValue -Counter $s.totalConnections); totalFailures = [int](Get-AtomicCounterValue -Counter $s.totalFails)
        activeConnections = $activeTotalNow
        activePerAdapter = $activePerAdapterSnap
        adapterCount = $s.adapters.Count; adapters = $aStats
        connectionTypes = $s.connectionTypes
        safeMode = $s.safeMode
        sessionMapSize = $s.sessionMap.Count
        uploadHintHostCount = $s.uploadHostHints.Count
        sessionStats = $sessionStats
        currentMaxThreads = $s.currentMaxThreads
        networkLimits = $networkLimits
        timestamp = [System.DateTimeOffset]::UtcNow.ToString('o')
    }
    try { Write-AtomicJson -Path $s.statsFile -Data $statsSnapshot -Depth 3 } catch {}

    try {
        if ($s.decisions -and $s.decisions -is [System.Collections.Concurrent.ConcurrentQueue[object]]) {
            while ($s.decisions.Count -gt ($s.maxDecisions * 2)) {
                $discardedDecision = $null
                [void]$s.decisions.TryDequeue([ref]$discardedDecision)
            }

            $decisionSnapshot = @($s.decisions.ToArray())
            [array]::Reverse($decisionSnapshot)
            if ($decisionSnapshot.Count -gt $s.maxDecisions) {
                $decisionSnapshot = @($decisionSnapshot | Select-Object -First $s.maxDecisions)
            }
        } else {
            $decisionSnapshot = @($s.decisions | Select-Object -First $s.maxDecisions)
        }

        Write-AtomicJson -Path $s.decisionsFile -Data @{ decisions = $decisionSnapshot } -Depth 3
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

    function Get-OrCreate-LocalAtomicCounter {
        param(
            [hashtable]$Map,
            [string]$Key
        )

        $counter = $Map[$Key]
        if ($null -eq $counter) {
            $counter = [NetFusion.AtomicCounter]::new()
            $Map[$Key] = $counter
        }

        return $counter
    }

    function Get-LocalAtomicCounterValue {
        param([object]$Counter)

        if ($null -eq $Counter) {
            return [int64]0
        }

        return [int64]$Counter.Read()
    }

    function Get-AdapterCooldownRemainingSeconds {
        param(
            [object]$ProxyState,
            [string]$AdapterName
        )

        try {
            if (-not $ProxyState.adapterCooldownUntil.ContainsKey($AdapterName)) {
                return 0.0
            }

            $untilTicks = [int64]$ProxyState.adapterCooldownUntil[$AdapterName]
            $remaining = ($untilTicks - [System.DateTimeOffset]::UtcNow.Ticks) / [double][System.TimeSpan]::TicksPerSecond
            if ($remaining -gt 0.0) {
                return $remaining
            }

            [void]$ProxyState.adapterCooldownUntil.Remove($AdapterName)
            return 0.0
        } catch {
            return 0.0
        }
    }

    function Clear-AdapterConnectFailure {
        param(
            [object]$ProxyState,
            [string]$AdapterName
        )

        try { $ProxyState.adapterFailureStreak[$AdapterName] = 0 } catch {}
        try { [void]$ProxyState.adapterCooldownUntil.Remove($AdapterName) } catch {}
    }

    function Register-AdapterConnectFailure {
        param(
            [object]$ProxyState,
            [string]$AdapterName
        )

        $streak = 1
        try {
            if ($ProxyState.adapterFailureStreak.ContainsKey($AdapterName)) {
                $streak = [int]$ProxyState.adapterFailureStreak[$AdapterName] + 1
            }
            $ProxyState.adapterFailureStreak[$AdapterName] = $streak

            if ($streak -ge 4) {
                # Do not suppress a high-capacity adapter for a long time because
                # one remote host or DNS path had transient failures during a
                # burst. Short cooldowns avoid repeated dead probes while keeping
                # both links available for the next batch of flows.
                $cooldownSeconds = [math]::Min(15, 2 * $streak)
                $ProxyState.adapterCooldownUntil[$AdapterName] = [System.DateTimeOffset]::UtcNow.AddSeconds($cooldownSeconds).Ticks
            }
        } catch {}

        return $streak
    }

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

    function Write-AsciiText {
        param(
            [System.IO.Stream]$Stream,
            [string]$Text
        )

        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Text)
        $Stream.Write($bytes, 0, $bytes.Length)
    }

    function Copy-ChunkedRequestBody {
        param(
            [System.Net.Sockets.NetworkStream]$Source,
            [System.Net.Sockets.NetworkStream]$Destination,
            [object]$UploadCounter
        )

        $bytesCopied = [long]0
        while ($true) {
            $sizeLine = Read-HttpLine -Stream $Source
            if ($null -eq $sizeLine) { throw "Unexpected end of stream while reading chunk size." }
            Write-AsciiText -Stream $Destination -Text "$sizeLine`r`n"

            if ([string]::IsNullOrWhiteSpace($sizeLine)) {
                continue
            }

            $sizeToken = $sizeLine.Split(';')[0].Trim()
            $chunkSize = [Convert]::ToInt64($sizeToken, 16)
            if ($chunkSize -gt 0) {
                $bytesCopied += [NetFusion.StreamCopier]::CopyFixedBytes($Source, $Destination, $chunkSize, $UploadCounter)

                $chunkTerminator = New-Object byte[] 2
                if ((Read-ExactBytes -Stream $Source -Buffer $chunkTerminator -Count 2) -ne 2) {
                    throw "Unexpected end of stream while reading chunk terminator."
                }
                $Destination.Write($chunkTerminator, 0, 2)
                continue
            }

            while ($true) {
                $trailerLine = Read-HttpLine -Stream $Source
                if ($null -eq $trailerLine) {
                    Write-AsciiText -Stream $Destination -Text "`r`n"
                    break
                }
                Write-AsciiText -Stream $Destination -Text "$trailerLine`r`n"
                if ($trailerLine -eq '') { break }
            }
            break
        }

        return $bytesCopied
    }

    function Set-UploadHostHint {
        param(
            [hashtable]$ProxyState,
            [string]$HostName,
            [string]$Reason,
            [long]$ClientToRemoteBytes = 0,
            [long]$RemoteToClientBytes = 0
        )

        if ([string]::IsNullOrWhiteSpace($HostName)) { return }
        $ProxyState.uploadHostHints[$HostName] = @{
            time = [System.DateTimeOffset]::UtcNow.Ticks
            reason = $Reason
            clientToRemoteBytes = $ClientToRemoteBytes
            remoteToClientBytes = $RemoteToClientBytes
        }
    }

    function Get-LocalAdapterObservedMbps {
        param(
            [object]$ProxyState,
            [object]$Adapter
        )

        $h = $ProxyState.adapterHealth[$Adapter.Name]
        if (-not $h) {
            try {
                if ($ProxyState.proxyCapacityMbps.ContainsKey($Adapter.Name)) {
                    return [double]$ProxyState.proxyCapacityMbps[$Adapter.Name]
                }
            } catch {}
            return 0.0
        }

        $bestDown = 0.0
        foreach ($propertyName in @('EstimatedDownMbps', 'DownloadMbps')) {
            if ($h.ContainsKey($propertyName) -and $null -ne $h[$propertyName]) {
                $value = [double]$h[$propertyName]
                if ($value -gt $bestDown) {
                    $bestDown = $value
                }
            }
        }

        $bestUp = 0.0
        foreach ($propertyName in @('EstimatedUpMbps', 'UploadMbps')) {
            if ($h.ContainsKey($propertyName) -and $null -ne $h[$propertyName]) {
                $value = [double]$h[$propertyName]
                if ($value -gt $bestUp) {
                    $bestUp = $value
                }
            }
        }

        $healthObserved = [double]($bestDown + $bestUp)
        $proxyObserved = 0.0
        try {
            if ($ProxyState.proxyCapacityMbps.ContainsKey($Adapter.Name)) {
                $proxyObserved = [math]::Max($proxyObserved, [double]$ProxyState.proxyCapacityMbps[$Adapter.Name])
            }
            if ($ProxyState.proxyRateMbps.ContainsKey($Adapter.Name)) {
                $rateEntry = $ProxyState.proxyRateMbps[$Adapter.Name]
                if ($rateEntry) {
                    $proxyObserved = [double]$rateEntry.DownloadMbps + [double]$rateEntry.UploadMbps
                }
            }
        } catch {}

        return [math]::Max($healthObserved, $proxyObserved)
    }

    function Get-LocalAdapterSelectionOrder {
        param(
            [object]$ProxyState,
            [object[]]$Adapters,
            [double[]]$Weights,
            [int]$PreferredIndex = 0
        )

        if (-not $Adapters -or $Adapters.Count -eq 0) {
            return @()
        }

        $weightValues = @()
        $totalWeight = 0.0
        for ($i = 0; $i -lt $Adapters.Count; $i++) {
            $weight = if ($i -lt $Weights.Count) { [double]$Weights[$i] } else { 1.0 }
            $weight = [math]::Max(1.0, $weight)
            $weightValues += $weight
            $totalWeight += $weight
        }

        $totalActive = 0
        foreach ($adapter in $Adapters) {
            if ($ProxyState.activePerAdapter.ContainsKey($adapter.Name)) {
                $totalActive += [int](Get-LocalAtomicCounterValue -Counter $ProxyState.activePerAdapter[$adapter.Name])
            }
        }

        $proxyMbpsByAdapter = @{}
        $totalProxyMbps = 0.0
        foreach ($adapter in $Adapters) {
            $adapterProxyMbps = 0.0
            try {
                if ($ProxyState.proxyRateMbps.ContainsKey($adapter.Name)) {
                    $rateEntry = $ProxyState.proxyRateMbps[$adapter.Name]
                    if ($rateEntry) {
                        $adapterProxyMbps = [math]::Max(0.0, [double]$rateEntry.DownloadMbps + [double]$rateEntry.UploadMbps)
                    }
                }
            } catch {}
            $proxyMbpsByAdapter[$adapter.Name] = $adapterProxyMbps
            $totalProxyMbps += $adapterProxyMbps
        }

        if ($PreferredIndex -lt 0 -or $PreferredIndex -ge $Adapters.Count) {
            $PreferredIndex = 0
        }

        $ranked = @()
        for ($i = 0; $i -lt $Adapters.Count; $i++) {
            $adapter = $Adapters[$i]
            $weight = [double]$weightValues[$i]
            $targetShare = if ($totalWeight -gt 0.0) { $weight / $totalWeight } else { 1.0 / [double]$Adapters.Count }
            $activeCount = if ($ProxyState.activePerAdapter.ContainsKey($adapter.Name)) { [int](Get-LocalAtomicCounterValue -Counter $ProxyState.activePerAdapter[$adapter.Name]) } else { 0 }
            $currentShare = if ($totalActive -gt 0) { [double]$activeCount / [double]$totalActive } else { 0.0 }
            $currentRateShare = if ($totalProxyMbps -gt 10.0 -and $proxyMbpsByAdapter.ContainsKey($adapter.Name)) { [double]$proxyMbpsByAdapter[$adapter.Name] / [double]$totalProxyMbps } else { $currentShare }

            $h = $ProxyState.adapterHealth[$adapter.Name]
            $linkSpeedMbps = if ($null -ne $adapter.Speed -and [double]$adapter.Speed -gt 0) {
                [double]$adapter.Speed
            } elseif ($h -and $h.ContainsKey('LinkSpeedMbps') -and [double]$h.LinkSpeedMbps -gt 0) {
                [double]$h.LinkSpeedMbps
            } else {
                100.0
            }
            $observedMbps = Get-LocalAdapterObservedMbps -ProxyState $ProxyState -Adapter $adapter
            $utilization = [math]::Min(1.50, ($observedMbps / [math]::Max(50.0, $linkSpeedMbps)))

            # Use only the current failure streak for routing penalty. Lifetime
            # fail counters remain visible in stats, but should not permanently
            # bias scheduling after an adapter has recovered.
            $failureStreak = if ($ProxyState.adapterFailureStreak.ContainsKey($adapter.Name)) { [int]$ProxyState.adapterFailureStreak[$adapter.Name] } else { 0 }
            $failRate = [math]::Min(0.50, ([double]$failureStreak / 8.0))

            $rrBoost = if ($i -eq $PreferredIndex) { 0.02 } else { 0.0 }
            $deficit = $targetShare - $currentShare
            $rateDeficit = if ($totalProxyMbps -gt 10.0) { $targetShare - $currentRateShare } else { 0.0 }
            # NetFusion-FIX-21: Keep maxspeed scheduling capacity-stable. The old
            # rate-deficit multiplier was aggressive enough to swing bursts toward
            # a slower USB Wi-Fi adapter during short samples, which can reduce
            # total throughput below the strong single-link baseline. Prefer the
            # smooth capacity schedule and use live rate only as a damped nudge.
            $score = ($deficit * 1.25) + ($rateDeficit * 1.0) + ((1.0 - $utilization) * 0.05) - ($failRate * 0.75) + $rrBoost

            $ranked += [pscustomobject]@{
                Adapter = $adapter
                Score = [math]::Round($score, 6)
                Weight = $weight
                Preferred = ($i -eq $PreferredIndex)
            }
        }

        @($ranked | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Weight }; Descending = $true }, @{ Expression = { $_.Preferred }; Descending = $true })
    }

    function Get-LocalWeightedPreferredIndex {
        param(
            [object]$ProxyState,
            [object[]]$Adapters,
            [double[]]$Weights
        )

        if (-not $Adapters -or $Adapters.Count -eq 0) {
            return 0
        }

        $tick = [int64]$ProxyState.rrCounter.Increment()

        # Fast path: when all adapters are eligible, use the precomputed smooth
        # WRR schedule refreshed with the current capacity weights. This avoids
        # the old 500/300 score-walk behavior where the first hundreds of burst
        # connections could prefer the first adapter before the second adapter's
        # share was reached.
        try {
            $stateAdapters = @($ProxyState.adapters)
            $schedule = @($ProxyState.rrSchedule)
            if ($schedule.Count -gt 0 -and $stateAdapters.Count -eq $Adapters.Count) {
                $sameOrder = $true
                for ($i = 0; $i -lt $Adapters.Count; $i++) {
                    if ([string]$stateAdapters[$i].Name -ne [string]$Adapters[$i].Name) {
                        $sameOrder = $false
                        break
                    }
                }

                if ($sameOrder) {
                    $slot = [int]($tick % [int64]$schedule.Count)
                    if ($slot -lt 0) { $slot += $schedule.Count }
                    $scheduledIndex = [int]$schedule[$slot]
                    if ($scheduledIndex -ge 0 -and $scheduledIndex -lt $Adapters.Count) {
                        return $scheduledIndex
                    }
                }
            }
        } catch {}

        # Fallback for filtered adapter sets. Build a small smooth schedule on
        # demand instead of walking a huge cumulative score range.
        $slotCount = [math]::Min(64, [math]::Max(16, $Adapters.Count * 8))
        $targetSlot = [int]($tick % [int64]$slotCount)
        if ($targetSlot -lt 0) { $targetSlot += $slotCount }

        $accumulators = New-Object double[] $Adapters.Count
        $bestIndex = 0
        for ($slotIndex = 0; $slotIndex -le $targetSlot; $slotIndex++) {
            $bestScore = [double]::NegativeInfinity
            for ($i = 0; $i -lt $Adapters.Count; $i++) {
                $weight = if ($i -lt $Weights.Count) { [double]$Weights[$i] } else { 1.0 }
                $accumulators[$i] += [math]::Max(1.0, $weight)
                if ($accumulators[$i] -gt $bestScore) {
                    $bestScore = $accumulators[$i]
                    $bestIndex = $i
                }
            }

            $totalWeight = 0.0
            for ($i = 0; $i -lt $Adapters.Count; $i++) {
                $weight = if ($i -lt $Weights.Count) { [double]$Weights[$i] } else { 1.0 }
                $totalWeight += [math]::Max(1.0, $weight)
            }
            $accumulators[$bestIndex] -= $totalWeight
        }

        return $bestIndex
    }

    $connAdapter = $null  # track which adapter this connection uses
    $hostKey = $null
    $sessionKey = $null
    $remoteClient = $null
    $clientSocketRef = $null
    $remoteSocketRef = $null
    $clientStream = $null
    $remoteStream = $null
    $clientToRemoteBytes = [long]0
    $remoteToClientBytes = [long]0
    $proxyUploadCounter = $null
    $proxyDownloadCounter = $null
    $uri = $null
    $selectionPlan = @()
    try {
        # v5.0: Safe mode check -- if active, act as simple pass-through on default adapter
        $isSafeMode = $State.safeMode

        # NetFusion-FIX-1: Cache the accepted client socket wrapper once so socket property changes reliably apply to the underlying socket.
        $clientSocketRef = $ClientSocket.Client
        $clientSocketRef.ReceiveBufferSize = 1048576
        $clientSocketRef.SendBufferSize = 1048576
        $clientSocketRef.NoDelay = $true
        $clientSocketRef.ReceiveTimeout = 60000
        $clientSocketRef.SendTimeout = 60000
        $clientSocketRef.LingerState = New-Object System.Net.Sockets.LingerOption($false, 0)

        # NetFusion-FIX-18: Use NetworkStream with socket ownership disabled and close the TcpClient exactly once during cleanup.
        $clientStream = [System.Net.Sockets.NetworkStream]::new($clientSocketRef, $false)
        # NetFusion-FIX-8: Apply finite read/write timeouts so half-open relay connections do not consume runspaces forever.
        $clientStream.ReadTimeout = 60000
        $clientStream.WriteTimeout = 60000

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
            $remoteEndPoint = $clientSocketRef.RemoteEndPoint -as [System.Net.IPEndPoint]
            $isLocalRequester = $remoteEndPoint -and (
                $remoteEndPoint.Address.Equals([System.Net.IPAddress]::Loopback) -or
                $remoteEndPoint.Address.Equals([System.Net.IPAddress]::IPv6Loopback)
            )
            $resp = if ($isLocalRequester) {
                [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK")
            } else {
                [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 403 Forbidden`r`nContent-Type: text/plain`r`nContent-Length: 9`r`nConnection: close`r`n`r`nForbidden")
            }
            # NetFusion-FIX-7: Flush tiny proxy control responses immediately so clients do not stall waiting on buffered handshake bytes.
            $clientStream.Write($resp, 0, $resp.Length)
            $clientStream.Flush()
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
            Set-UploadHostHint -ProxyState $State -HostName $targetHost -Reason 'http-upload-signal' -ClientToRemoteBytes ([math]::Max($requestContentLength, $uploadContentLength)) -RemoteToClientBytes 0
        }

        # v5.1: Track host concurrency for dynamic download manager detection
        $hostKey = $targetHost
        $hostCounter = Get-OrCreate-LocalAtomicCounter -Map $State.activePerHost -Key $hostKey
        $activeHostCount = [int]$hostCounter.Increment()

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
            $candidateAdapter = $State.adapters[$i]
            $healthEntry = if ($State.adapterHealth.ContainsKey($candidateAdapter.Name)) { $State.adapterHealth[$candidateAdapter.Name] } else { $null }
            $candidateStatus = if ($healthEntry -and $healthEntry.ContainsKey('Status')) { [string]$healthEntry.Status } else { '' }
            $candidateScore = if ($healthEntry -and $healthEntry.ContainsKey('Score') -and $null -ne $healthEntry.Score) { [double]$healthEntry.Score } else { 1.0 }
            if ($candidateStatus -eq 'offline' -or $candidateScore -le 0.0) {
                continue
            }
            if ((Get-AdapterCooldownRemainingSeconds -ProxyState $State -AdapterName $candidateAdapter.Name) -gt 0.0) {
                continue
            }

            $avail += $candidateAdapter
            $aw += $State.weights[$i]
        }
        if ($avail.Count -eq 0 -and $State.adapters.Count -gt 0) {
            # If every adapter is in cooldown, fall back to the healthiest known
            # adapter instead of dropping traffic. This preserves internet access
            # while still avoiding repeated dead-secondary probes under load.
            for ($i = 0; $i -lt $State.adapters.Count; $i++) {
                $candidateAdapter = $State.adapters[$i]
                $healthEntry = if ($State.adapterHealth.ContainsKey($candidateAdapter.Name)) { $State.adapterHealth[$candidateAdapter.Name] } else { $null }
                $candidateStatus = if ($healthEntry -and $healthEntry.ContainsKey('Status')) { [string]$healthEntry.Status } else { '' }
                $candidateScore = if ($healthEntry -and $healthEntry.ContainsKey('Score') -and $null -ne $healthEntry.Score) { [double]$healthEntry.Score } else { 1.0 }
                if ($candidateStatus -eq 'offline' -or $candidateScore -le 0.0) {
                    continue
                }
                $avail += $candidateAdapter
                $aw += $State.weights[$i]
            }
        }
        if ($avail.Count -eq 0) { $ClientSocket.Close(); return }
        $null = $State.totalConnections.Increment()
        $null = $State.activeConnections.Increment()
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
            # NetFusion-FIX-5: Prefer adapters for new connections using measured-throughput weights, not latency-heavy health scores.
            $preferredIndex = Get-LocalWeightedPreferredIndex -ProxyState $State -Adapters $avail -Weights ([double[]]$aw)

            $selectionPlan = Get-LocalAdapterSelectionOrder -ProxyState $State -Adapters $avail -Weights ([double[]]$aw) -PreferredIndex $preferredIndex
            if ($selectionPlan.Count -gt 0) {
                $adapter = $selectionPlan[0].Adapter
                $selectionReason = if ($selectionPlan[0].Preferred) {
                    'weighted-round-robin(per-connection)'
                } else {
                    'weighted-round-robin(load-corrected)'
                }
            } else {
                $adapter = $avail[$preferredIndex]
                $selectionReason = 'weighted-round-robin(per-connection)'
            }

            if ($aw.Count -gt 1) {
                $maxWeight = [double](($aw | Measure-Object -Maximum).Maximum)
                $minWeight = [double](($aw | Measure-Object -Minimum).Minimum)
                $weightsNearlyEqual = ([math]::Abs($maxWeight - $minWeight) -le [math]::Max(5.0, ($maxWeight * 0.05)))
            }

            # NetFusion-FIX-7: Restrict soft host hints to non-bulk traffic so speed tests and parallel downloads spread per connection.
            if ($weightsNearlyEqual -and $sessionKey -and $connType -ne 'bulk') {
                $hintEntry = $null
                if ($State.sessionMap.TryGetValue($sessionKey, [ref]$hintEntry) -and $hintEntry -and $hintEntry.adapter) {
                    $hintedAdapter = $avail | Where-Object { $_.Name -eq [string]$hintEntry.adapter } | Select-Object -First 1
                    if ($hintedAdapter) {
                        $hintEntry.time = [System.DateTimeOffset]::UtcNow.Ticks
                        try { $State.sessionMap[$sessionKey] = $hintEntry } catch {}
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
        try {
            $State.decisions.Enqueue($decision)
        } catch {
            $State.decisions = @($decision) + @($State.decisions | Select-Object -First ($State.maxDecisions - 1))
        }

        # ===== Connect to remote via chosen adapter (with failover) =====
        $remoteClient = $null
        $candidateAdapters = @()
        if ($selectionPlan -and $selectionPlan.Count -gt 0) {
            $candidateAdapters = @($selectionPlan | Select-Object -ExpandProperty Adapter)
        } else {
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
        }

        $configuredRetries = if ($State.maxRetries -and [int]$State.maxRetries -gt 0) { [int]$State.maxRetries } else { 3 }
        $maxRetries = [math]::Min($candidateAdapters.Count, $configuredRetries)

        for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
            $adapter = $candidateAdapters[$attempt]

            $rHost = $targetHost

            try {
                if (-not $adapter.IP -or $adapter.IP -match '^169\.254\.') {
                    $null = (Get-OrCreate-LocalAtomicCounter -Map $State.failCounts -Key $adapter.Name).Increment()
                    $null = $State.totalFails.Increment()
                    continue
                }

                # NetFusion-FIX-5: Bind outbound sockets to the chosen adapter's local IPv4 before connect so Windows uses that WAN path.
                $ifIndex = if ($null -ne $adapter.InterfaceIndex) { [int]$adapter.InterfaceIndex } else { 0 }
                $connectTimeoutMs = if ($State.connectTimeout -and [int]$State.connectTimeout -gt 0) { [int]$State.connectTimeout } else { 5000 }
                $remoteClient = [NetFusion.SocketConnector]::CreateBoundConnection($adapter.IP, $rHost, $rPort, $connectTimeoutMs, $ifIndex)
                # NetFusion-FIX-1: Cache the outbound socket wrapper once so socket property changes reliably apply after source-IP binding.
                $remoteSocketRef = $remoteClient.Client
                $remoteSocketRef.ReceiveBufferSize = 1048576
                $remoteSocketRef.SendBufferSize = 1048576
                $remoteSocketRef.NoDelay = $true
                $remoteSocketRef.ReceiveTimeout = 60000
                $remoteSocketRef.SendTimeout = 60000
                $remoteSocketRef.LingerState = New-Object System.Net.Sockets.LingerOption($false, 0)
                $remoteClient.SendTimeout = 60000
                $remoteClient.ReceiveTimeout = 60000

                $null = (Get-OrCreate-LocalAtomicCounter -Map $State.activePerAdapter -Key $adapter.Name).Increment()
                $proxyUploadCounter = Get-OrCreate-LocalAtomicCounter -Map $State.proxyUploadBytes -Key $adapter.Name
                $proxyDownloadCounter = Get-OrCreate-LocalAtomicCounter -Map $State.proxyDownloadBytes -Key $adapter.Name
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

                $null = (Get-OrCreate-LocalAtomicCounter -Map $State.connectionCounts -Key $adapter.Name).Increment()
                $null = (Get-OrCreate-LocalAtomicCounter -Map $State.successCounts -Key $adapter.Name).Increment()
                Clear-AdapterConnectFailure -ProxyState $State -AdapterName $adapter.Name
                break
            } catch {
                try { $remoteClient.Close() } catch {}
                try { $remoteClient.Dispose() } catch {}
                $remoteClient = $null
            }
            $null = (Get-OrCreate-LocalAtomicCounter -Map $State.failCounts -Key $adapter.Name).Increment()
            $null = $State.totalFails.Increment()
            [void](Register-AdapterConnectFailure -ProxyState $State -AdapterName $adapter.Name)
        }

        if (-not $remoteClient) {
            $err = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 502 Bad Gateway`r`nConnection: close`r`n`r`n")
            $clientStream.Write($err, 0, $err.Length)
            $clientStream.Flush()
            $ClientSocket.Close()
            return
        }

        # NetFusion-FIX-18: Use NetworkStream with socket ownership disabled and close the TcpClient exactly once during cleanup.
        $remoteStream = [System.Net.Sockets.NetworkStream]::new($remoteSocketRef, $false)
        # NetFusion-FIX-8: Apply finite read/write timeouts so half-open relay connections do not consume runspaces forever.
        $remoteStream.ReadTimeout = 60000
        $remoteStream.WriteTimeout = 60000

        if ($method -eq 'CONNECT') {
            # [V5-FIX-11] HTTPS TUNNELING: Forward tunnel without modification -- NO MITM.
            # Hostname classification already occurred. Tunnel remains entirely encrypted.
            # Event logging disabled here to avoid log spam, as millions of tunnels happen per day.
            
            $ok = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n")
            $clientStream.Write($ok, 0, $ok.Length)
            $clientStream.Flush()
            # NetFusion-FIX-3: Set Infinite timeouts for CONNECT tunnels -- CopyToAsync manages
            # lifecycle via stream close propagation. Finite timeouts cause spurious SocketException
            # during normal idle periods in long-lived HTTPS tunnels.
            $clientStream.ReadTimeout = [System.Threading.Timeout]::Infinite
            $clientStream.WriteTimeout = [System.Threading.Timeout]::Infinite
            $remoteStream.ReadTimeout = [System.Threading.Timeout]::Infinite
            $remoteStream.WriteTimeout = [System.Threading.Timeout]::Infinite
            # NetFusion-FIX-4: Keep HTTPS tunnels fully bidirectional so ACK and payload paths are not serialized.
            [NetFusion.StreamCopier]::CopyStreamBidirectional(
                $clientStream,
                $remoteStream,
                [ref]$clientToRemoteBytes,
                [ref]$remoteToClientBytes,
                $proxyUploadCounter,
                $proxyDownloadCounter,
                [int]$State.connectIdleTimeoutMs
            )
        } else {
            $reqPath = $uri.PathAndQuery; if (-not $reqPath) { $reqPath = '/' }
            $req = "$method $reqPath HTTP/1.1`r`n"
            $hasHost = $false; $contentLength = 0L; $isChunked = $false; $expectsContinue = $false
            $forwardHeaders = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ($l -match '^Proxy-') { continue }
                if ($l -match '^Connection:') { continue }
                if ($l -match '^Expect:\s*100-continue\s*$') {
                    $expectsContinue = $true
                    continue
                }
                if ($l -match '^Host:') { $hasHost = $true }
                if ($l -match '^Content-Length:\s*(\d+)') { $contentLength = [int64]$Matches[1]; continue }
                if ($l -match '^Transfer-Encoding:\s*(.+)$') {
                    if ($Matches[1] -match '(?i)\bchunked\b') {
                        $isChunked = $true
                        $forwardHeaders.Add($l)
                    }
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
            } elseif ($contentLength -gt 0) {
                $req += "Content-Length: $contentLength`r`n"
            }
            $req += "Connection: close`r`n`r`n"
            $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
            $remoteStream.Write($reqBytes, 0, $reqBytes.Length)

            if ($expectsContinue -and ($isChunked -or $contentLength -gt 0)) {
                $continueBytes = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                $clientStream.Write($continueBytes, 0, $continueBytes.Length)
                $clientStream.Flush()
            }

            if ($isChunked) {
                $clientToRemoteBytes += [long](Copy-ChunkedRequestBody -Source $clientStream -Destination $remoteStream -UploadCounter $proxyUploadCounter)
            } elseif ($contentLength -gt 0) {
                [NetFusion.StreamCopier]::CopyStream($clientStream, $remoteStream, [int64]$contentLength, [ref]$clientToRemoteBytes, $proxyUploadCounter)
            }

            [NetFusion.StreamCopier]::CopyStream($remoteStream, $clientStream, [ref]$remoteToClientBytes, $proxyDownloadCounter)
        }

    } catch {
        try {
            $logDir = Split-Path -Parent $State.eventsFile
            if ($logDir) {
                $errLine = "{0} method={1} host={2} error={3}`r`n" -f (Get-Date -Format 'o'), $method, $targetHost, $_.Exception.Message
                [System.IO.File]::AppendAllText((Join-Path $logDir 'proxy-errors.log'), $errLine)
            }
        } catch {}
    } finally {
        # NetFusion-FIX-6: Use atomic decrement paths for shared connection counters during cleanup.
        if ($State.activeConnections.Read() -gt 0) { $null = $State.activeConnections.Decrement() }
        if ($connAdapter -and $State.activePerAdapter.ContainsKey($connAdapter)) {
            $adapterCounter = $State.activePerAdapter[$connAdapter]
            if ($adapterCounter -and $adapterCounter.Read() -gt 0) { $null = $adapterCounter.Decrement() }
        }
        if ($hostKey -and $State.activePerHost.ContainsKey($hostKey)) {
            $hostCounter = $State.activePerHost[$hostKey]
            if ($hostCounter -and $hostCounter.Read() -gt 0) { $null = $hostCounter.Decrement() }
        }
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
$currentMaxThreads = $maxThreads
$global:ProxyState.currentMaxThreads = $currentMaxThreads
$lockPoolAtMax = ([string]$global:ProxyState.currentMode -eq 'maxspeed')

# NetFusion-FIX-19: In maxspeed mode, throughput bursts should not wait for
# reactive pool growth. Raise .NET worker and I/O completion thread minima to
# the configured proxy ceiling so parallel download/upload relays are scheduled
# immediately instead of queuing behind conservative CLR defaults.
try {
    $workerMinNow = 0; $ioMinNow = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$workerMinNow, [ref]$ioMinNow)
    $threadFloor = [math]::Min(512, [math]::Max($minThreads, $maxThreads))
    if ($workerMinNow -lt $threadFloor -or $ioMinNow -lt $threadFloor) {
        [void][System.Threading.ThreadPool]::SetMinThreads(
            [math]::Max($workerMinNow, $threadFloor),
            [math]::Max($ioMinNow, $threadFloor)
        )
    }
} catch {}

# NetFusion-FIX-17: Keep the accept loop backed by a large adaptive runspace pool so burst traffic does not queue behind a small worker cap.
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
Write-Host "  Thread pool:     $minThreads-$maxThreads $(if($lockPoolAtMax){'(maxspeed locked)'}else{'(adaptive)'})" -ForegroundColor Green
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
# NetFusion-FIX-1: Cache the listener socket wrapper once so buffer settings reliably apply before the accept loop starts.
$listenerSocket = $listener.Server
$listenerSocket.ReceiveBufferSize = 1048576
$listenerSocket.SendBufferSize = 1048576
# NetFusion-FIX-20: Give the local listener enough pending accept backlog for
# browser, launcher, torrent, and download-manager bursts. A shallow backlog
# can look like low WAN throughput because clients stall before the proxy ever
# dispatches the connection to an adapter.
try { $listener.Start(1024) } catch { Write-Host "  [ERROR] Port ${Port} in use. $_" -ForegroundColor Red; exit 1 }

Update-ProxyStats
$lastRefreshTicks = [System.DateTimeOffset]::UtcNow.Ticks
$lastLogTicks = $lastRefreshTicks
$lastCleanupTicks = $lastRefreshTicks
$lastSessionCleanTicks = $lastRefreshTicks
$cleanupIntervalTicks = [System.TimeSpan]::FromMilliseconds(500).Ticks
# NetFusion-FIX-7: Sweep session affinity more frequently than the 30s inactivity TTL so stale pinning does not linger.
$sessionCleanIntervalTicks = [System.TimeSpan]::FromSeconds(15).Ticks
$logIntervalTicks = [System.TimeSpan]::FromSeconds(5).Ticks
$jobTimeoutSec = if ($cfgProxy -and $cfgProxy.jobTimeoutSec -gt 0) { [int]$cfgProxy.jobTimeoutSec } else { 0 }
$staleJobTicks = if ($jobTimeoutSec -gt 0) { [System.TimeSpan]::FromSeconds($jobTimeoutSec).Ticks } else { 0 }
$lowThreadHoldTicks = [System.TimeSpan]::FromSeconds(120).Ticks
$lowThreadTicks = $null

try {
    while ($script:IsRunning) {
        try {
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
                    if ($staleJobTicks -gt 0 -and $j.StartTicks -and (($nowTicks - [int64]$j.StartTicks) -gt $staleJobTicks)) {
                        # Optional stale-job breaker. Disabled by default because long
                        # browser/download-manager/torrent flows are legitimate and may
                        # run for many minutes while still transferring data.
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
            $queueDepth = if ($listenerSocket.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) { 1 } else { 0 } # Conservative estimate to avoid oversensitive scale-ups
            
            if ($queueDepth -gt 0 -and $activeThreads -ge ($currentMaxThreads - 8) -and $currentMaxThreads -lt $maxThreads) {
                $targetThreads = [math]::Max($currentMaxThreads + 16, $activeThreads + 16)
                $currentMaxThreads = [math]::Min($maxThreads, $targetThreads)
                $rsPool.SetMaxRunspaces($currentMaxThreads)
                $global:ProxyState.currentMaxThreads = $currentMaxThreads
                Write-ProxyEvent "Pool scaled UP: $currentMaxThreads (queue pending, active=$activeThreads)"
                Write-Host "  [Scale UP] Thread pool expanded to $currentMaxThreads" -ForegroundColor Cyan
                $lowThreadTicks = $null
            } elseif ((-not $lockPoolAtMax) -and $activeThreads -lt [math]::Floor($currentMaxThreads * 0.4) -and $currentMaxThreads -gt $minThreads) {
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

        # NetFusion-FIX-9: Use an interruptible poll-based accept loop so shutdown can break out of accept waits without hanging the process.
        $acceptReady = $false
        try {
            $acceptReady = $listenerSocket.Poll(1000000, [System.Net.Sockets.SelectMode]::SelectRead)
        } catch {
            if (-not $script:IsRunning) { break }
        }

        if (-not $acceptReady) {
            continue
        }

        try {
            $client = $listener.AcceptTcpClient()
        } catch {
            if (-not $script:IsRunning) { break }
            continue
        }

        # NetFusion-FIX-1: Cache the accepted socket wrapper once so socket property changes reliably apply before dispatch.
        $clientSocket = $client.Client
        $clientSocket.ReceiveBufferSize = 1048576
        $clientSocket.SendBufferSize = 1048576
        # NetFusion-FIX-7: Disable Nagle on proxy sockets so ACK/control packets are not delayed in the relay.
        $clientSocket.NoDelay = $true
        $clientSocket.ReceiveTimeout = 30000
        $clientSocket.SendTimeout = 30000
        $clientSocket.LingerState = New-Object System.Net.Sockets.LingerOption($false, 0)

        # NetFusion-FIX-17: Dispatch each accepted connection asynchronously into the existing runspace pool; never block the accept loop on relay work.
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $rsPool
        $ps.AddScript($HandlerScript).AddArgument($client).AddArgument($global:ProxyState) | Out-Null
        $handle = $ps.BeginInvoke()
        $jobs.Add(@{ PS = $ps; Handle = $handle; StartTicks = $nowTicks })

        # Log connection activity
        if (($nowTicks - $lastLogTicks) -gt $logIntervalTicks) {
            $s = $global:ProxyState
            $connParts = @()
            foreach ($a in $s.adapters) { $connParts += "$($a.Name):$(Get-AtomicCounterValue -Counter $s.connectionCounts[$a.Name])" }
            $typeStr = @()
            foreach ($k in @('bulk','interactive','streaming','gaming')) {
                if ($s.connectionTypes.ContainsKey($k)) { $typeStr += "$k=$($s.connectionTypes[$k])" }
            }
            $safeFlag = if ($s.safeMode) { ' [SAFE]' } else { '' }
            $ts = [System.DateTimeOffset]::Now.ToString('HH:mm:ss')
            Write-Host "  [$ts] conns=$(Get-AtomicCounterValue -Counter $s.totalConnections) | $($connParts -join ' | ') | threads=$($jobs.Count) | sessions=$($s.sessionMap.Count)$safeFlag | $($typeStr -join ' ')" -ForegroundColor DarkGray
            $lastLogTicks = $nowTicks
        }
        } catch {
            try {
                $errLine = "{0} proxy-loop error={1}`r`n" -f (Get-Date -Format 'o'), $_.Exception.Message
                [System.IO.File]::AppendAllText((Join-Path $logsDir 'proxy-errors.log'), $errLine)
            } catch {}
            Start-Sleep -Milliseconds 100
        }
    }
} finally {
    $script:IsRunning = $false
    try { $listener.Stop() } catch {}
    try { $listenerSocket.Close() } catch {}
    foreach ($job in @($jobs)) {
        try { $job.PS.Dispose() } catch {}
    }
    $psInstance = $null
    while ($script:ActivePowershells.TryDequeue([ref]$psInstance)) {
        try { if ($psInstance) { $psInstance.Dispose() } } catch {}
        $psInstance = $null
    }
    $rsPool.Close()
    try { $rsPool.Dispose() } catch {}
    try { Write-AtomicJson -Path $global:ProxyState.statsFile -Data @{ running = $false } -Depth 3 } catch {}
    Write-ProxyEvent "Proxy stopped"
    Write-Host "`n  Proxy stopped." -ForegroundColor Yellow
}

