# NetFusion Engine

NetFusion is a local Windows multi-interface traffic orchestrator built in PowerShell. It combines three main ideas:

1. A local HTTP/HTTPS proxy on `127.0.0.1:8080`.
2. Adapter health monitoring and interface scoring.
3. Route and metric management to keep multiple adapters usable at the same time.

The project is designed to spread multiple independent TCP connections across multiple adapters. It is not true packet-level bonding. That distinction matters:

- A single browser download usually stays on one adapter.
- Multiple parallel connections can be distributed across adapters.
- Aggregate throughput depends on the application opening enough concurrent connections.

If you expect one `300 Mbps` connection plus another `300 Mbps` connection to always appear as one `600 Mbps` download, this project will not do that by itself. You need an app that opens multiple parallel streams, such as IDM, aria2, or a torrent client.

## Table of Contents

- [What NetFusion Actually Does](#what-netfusion-actually-does)
- [What NetFusion Does Not Do](#what-netfusion-does-not-do)
- [Architecture](#architecture)
- [Repository Layout](#repository-layout)
- [How Traffic Is Distributed](#how-traffic-is-distributed)
- [Requirements](#requirements)
- [Startup and Shutdown](#startup-and-shutdown)
- [Configuration Files](#configuration-files)
- [Testing and Verification](#testing-and-verification)
- [Troubleshooting](#troubleshooting)
- [Known Limits](#known-limits)
- [Recent Documentation Notes](#recent-documentation-notes)

## What NetFusion Actually Does

NetFusion runs a local proxy and decides which adapter should carry each outbound connection. It uses:

- Adapter discovery from Windows networking APIs.
- Live health data such as latency, jitter, packet-loss proxies, and activity.
- Source-IP socket binding in the proxy so outbound connections can leave on a chosen interface.
- Metric management so Windows does not immediately collapse all traffic onto a single preferred adapter.

In normal operation, the project tries to improve total usable throughput for workloads that already use many connections:

- segmented download managers
- torrent clients
- applications that open many parallel HTTP requests
- mixed browsing and downloading at the same time

## What NetFusion Does Not Do

This project does not currently implement:

- true link bonding at Layer 2
- MLPPP
- MPTCP
- a remote aggregation server or VPN concentrator
- packet striping for a single TCP flow

That means these expectations are incorrect:

- One large Chrome or Edge download should become the sum of both links.
- One HTTPS tunnel can be split live across two adapters without side effects.
- Two adapters on the same router automatically double WAN bandwidth.

If both adapters ultimately reach the internet through the same router and the same WAN uplink, the router itself may be the bottleneck. In that case, even perfect distribution inside Windows will not produce double internet speed.

## Architecture

NetFusion is composed of a controller loop plus supporting modules:

- `core/NetFusionEngine.ps1`
  Main orchestrator. Starts the proxy, runs periodic maintenance, and coordinates the monitoring and routing subsystems.
- `core/SmartProxy.ps1`
  Local HTTP/HTTPS proxy bound to `127.0.0.1:8080`. For each new connection, it chooses an adapter, binds the outgoing socket to that adapter's local IP, and relays traffic without TLS interception.
- `core/NetworkManager.ps1`
  Discovers active adapters, identifies likely adapter type, reads IP/gateway state, estimates capability, and writes `config/interfaces.json`.
- `core/InterfaceMonitor.ps1`
  Produces adapter health metrics using gateway checks, internet latency checks, jitter estimation, trend analysis, and live bandwidth observation. Writes `config/health.json`.
- `core/RouteController.ps1`
  Adjusts interface metrics and optionally applies split-route logic. In the current design, route management is secondary to proxy-based distribution.
- `core/QuicBlocker.ps1`
  Blocks UDP 443 so browsers fall back to TCP, which the proxy can then handle.
- `dashboard/DashboardServer.ps1`
  Exposes dashboard data on `http://localhost:9090`.

### Runtime model

NetFusion is connection-oriented, not packet-oriented.

For each new outbound connection:

1. The proxy accepts a local client connection.
2. It classifies traffic based on port and connection behavior.
3. It picks an adapter using health and load data.
4. It binds the outbound socket to that adapter's local IPv4 address.
5. It relays bytes until the connection closes.

Because of that design:

- a single TCP flow remains on one adapter
- session affinity can keep related requests on the same adapter
- only multi-connection workloads show true aggregate behavior

## Repository Layout

### Root scripts

- `NetFusion-START.bat`
  Starts the engine and related services.
- `NetFusion-STOP.bat`
  Stops the engine and attempts to restore normal Windows proxy and route state.
- `NetFusion-SAFE.bat`
  Emergency reset path for firewall, proxy, and route cleanup.
- `Install-Service.ps1`
  Helper for service-style installation or startup integration.

### Diagnostics

- `test-combined-speed.ps1`
  Main combined-throughput validator. Includes direct adapter-bound checks and proxy-based multi-connection checks.
- `test-speed.ps1`
  Baseline per-adapter speed experiments and proxy throughput comparison.
- `test-ecmp.ps1`
  Route and ECMP-related checks.
- `test-proxylimit.ps1`
  Proxy stress testing.
- `test-wifi4-fix.ps1`
  Recovery helper for missing DHCP/gateway state.
- `fix-wifi4.ps1`, `fix-wifi4-arp.ps1`, `_fix.ps1`, `_fix2.ps1`
  Targeted repair scripts used during debugging and field recovery.

### Core modules

- `core/NetFusionEngine.ps1`
- `core/SmartProxy.ps1`
- `core/NetworkManager.ps1`
- `core/InterfaceMonitor.ps1`
- `core/RouteController.ps1`
- `core/RouteAdapter.ps1`
- `core/NetFusionWatchdog.ps1`
- `core/LearningEngine.ps1`
- `core/QuicBlocker.ps1`
- `core/ConfigValidator.ps1`
- `core/LogRotation.ps1`
- `core/Cleanup-OnCrash.ps1`

### Dashboard

- `dashboard/index.html`
- `dashboard/DashboardServer.ps1`

### State and generated files

- `config/config.json`
  Main runtime configuration.
- `config/interfaces.json`
  Adapter inventory and capability snapshot.
- `config/health.json`
  Health metrics per adapter.
- `config/proxy-stats.json`
  Proxy counters and adapter distribution stats.
- `config/decisions.json`
  Recent adapter selection decisions.
- `config/throughput.csv`
  Rolling telemetry from the health monitor.
- `logs/events.json`
  Event log for route changes, prediction warnings, and proxy scaling.

## How Traffic Is Distributed

The important behavior is in the proxy.

### Adapter selection

The proxy considers:

- active adapters
- current health score
- degradation flags
- latency and jitter
- active connection count per adapter
- session affinity for non-bulk traffic

### Traffic classes

The proxy separates traffic into categories such as:

- `bulk`
- `interactive`
- `streaming`
- `gaming`
- `voice`

Bulk traffic is the most important for throughput testing because it is the category most likely to spread across adapters. Non-bulk traffic is more likely to remain sticky to one adapter to preserve stability.

### Session affinity

For many hosts, the proxy keeps related requests on the same adapter for a short TTL. This is intentional. It avoids breaking sessions and reduces instability for normal web traffic.

### Why one browser download often stays on one adapter

Modern browsers commonly use:

- HTTPS
- HTTP/2
- connection reuse
- multiplexing

That means one visible download may be carried by a single TCP connection or a very small number of long-lived connections. Since NetFusion distributes per connection, not per packet, there may be nothing to split.

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or newer
- Administrator privileges for route, firewall, and metric changes
- At least two active network adapters with valid IPv4 addresses
- A working gateway on each adapter if you expect both to carry traffic

Recommended:

- separate upstream networks or at least separate non-broken adapter paths
- a downloader that supports many parallel connections
- `curl.exe` available in Windows for adapter-bound diagnostics

## Startup and Shutdown

### Standard startup

1. Connect both adapters and verify each has an IPv4 address.
2. Run `NetFusion-START.bat` as Administrator.
3. Wait for the proxy to bind `127.0.0.1:8080`.
4. Open `http://localhost:9090` for dashboard telemetry.

### Standard shutdown

1. Run `NetFusion-STOP.bat`.
2. Confirm Windows proxy settings are restored.
3. Confirm routes and interface metrics have returned to expected values.

### Emergency cleanup

If Windows proxy state, routes, or firewall settings are left behind:

1. Run `NetFusion-SAFE.bat` as Administrator.
2. Re-check:
   - Windows proxy settings
   - `Get-NetRoute`
   - `Get-NetIPInterface`
   - firewall rules related to QUIC blocking

## Configuration Files

The main runtime configuration is `config/config.json`.

Important keys:

- `mode`
  Controls high-level routing preference such as `maxspeed`, `download`, `streaming`, or `gaming`.
- `proxyPort`
  Default `8080`.
- `dashboardPort`
  Default `9090`.
- `blockQUICOnSecondaryAdapters`
  Forces browsers toward TCP-based flows that the proxy can handle.
- `routing.targetMetric`
  Base metric used by route management.
- `routing.splitRoutesEnabled`
  Split routes are optional and not the primary distribution mechanism.
- `proxy.maxRetries`
  Retry count during outbound connection establishment.
- `intelligence.ewmaAlphas`
  Smoothing controls for latency scoring.

## Testing and Verification

### 1. Check that both adapters are really up

Use Windows and the generated files together:

```powershell
Get-NetAdapter | Where-Object Status -eq 'Up'
Get-NetIPAddress -AddressFamily IPv4
Get-NetRoute -DestinationPrefix '0.0.0.0/0'
```

Then compare with:

- `config/interfaces.json`
- `config/health.json`
- `config/proxy-stats.json`

### 2. Use the dashboard

Open:

```text
http://localhost:9090
```

Watch:

- adapter health
- total connections
- active per-adapter counts
- recent decisions
- failure counters

### 3. Run the combined-speed verifier

```powershell
powershell -ExecutionPolicy Bypass -File .\test-combined-speed.ps1
```

The script now does two different things:

- Step 3 runs direct adapter-bound tests using `curl.exe --interface <local-ip>`.
- Step 4 runs a proxy-based multi-connection test.

Interpretation:

- If Step 3 is poor on one adapter, the adapter or network path itself is weak.
- If Step 3 is good on both adapters but Step 4 is poor, the proxy distribution path needs investigation.
- If one large browser download is slow but the multi-connection proxy test is strong, that is expected behavior for this architecture.

### 4. Test with a segmented downloader

This is the most realistic throughput test for this project.

Recommended settings:

- IDM or aria2
- `16` to `32` parallel connections
- proxy set to `127.0.0.1:8080`

### 5. Validate actual adapter use

Do not rely on application-reported throughput alone. Check:

```powershell
Get-NetAdapterStatistics -Name 'Wi-Fi 3'
Get-NetAdapterStatistics -Name 'Wi-Fi 4'
```

If only one adapter's receive counters move during a test, the workload is not being split in practice.

## Troubleshooting

### Problem: only one adapter carries traffic

Check:

- the second adapter has a valid IPv4 address
- the second adapter has a default route
- the second adapter is not stuck on `169.254.x.x`
- the application is actually using the local proxy
- the workload opens multiple connections

Helpful files:

- `config/interfaces.json`
- `config/health.json`
- `config/proxy-stats.json`
- `logs/events.json`

### Problem: expected 600 Mbps but only see around one-link speed

Possible reasons:

- the test uses one TCP connection
- the browser is reusing a single HTTP/2 tunnel
- both adapters reach the same WAN bottleneck
- one adapter's real link is much slower than expected
- one adapter has repeated connection failures and is being used less

### Problem: second adapter has APIPA or no gateway

Try:

- `test-wifi4-fix.ps1`
- `fix-wifi4.ps1`
- `fix-wifi4-arp.ps1`

Then re-check:

```powershell
Get-NetIPAddress -InterfaceAlias 'Wi-Fi 4' -AddressFamily IPv4
Get-NetRoute -InterfaceAlias 'Wi-Fi 4' -DestinationPrefix '0.0.0.0/0'
```

### Problem: browser traffic is not load balanced

Remember:

- QUIC must be blocked if you want the TCP proxy to see browser traffic.
- HTTPS tunnels are still per connection.
- Browser downloads are not the best proof of aggregation.

### Problem: telemetry looks inconsistent

Check whether:

- the engine was restarted after edits
- stale state files remain in `config/`
- there are rapid retries or failovers during the test

## Known Limits

- NetFusion is not a replacement for true bonding hardware or a remote aggregation tunnel.
- Session affinity intentionally reduces spreading for some traffic classes.
- A single transfer can remain limited by one interface.
- Two adapters on one router do not guarantee doubled internet speed.
- Link speed shown by Windows is radio link speed, not guaranteed internet throughput.
- USB Wi-Fi adapters may have worse stability or higher failure rates than internal adapters.

## Recent Documentation Notes

This README was updated to match the current code and diagnostics more closely:

- clarified that NetFusion is connection-based, not packet-bonded
- clarified that single browser downloads usually do not sum both links
- documented the direct adapter-bound behavior of `test-combined-speed.ps1`
- documented the role of generated JSON state files in troubleshooting
- aligned the README with the actual proxy and route-management model in the repository
