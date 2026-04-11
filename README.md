<<<<<<< HEAD
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
=======
<div align="center">

# 🌐 NetFusion Engine v6.0 SOLID
**Enterprise-Grade Multi-Interface Network Orchestration for Windows**

*NetFusion is a highly intelligent, completely local, asynchronous PowerShell network proxy designed to perfectly aggregate multiple Wi-Fi/Ethernet adapters, bypassing Windows OS choke-points to deliver combined gigabit speeds, zero-jitter failover, and strict traffic routing.*

[![Version](https://img.shields.io/badge/Version-6.0_SOLID-blue.svg)]()
[![Platform](https://img.shields.io/badge/Platform-Windows_10%20%7C%2011-lightgrey.svg)]()
[![Language](https://img.shields.io/badge/Language-PowerShell_5.1%2B-blue.svg)]()
[![License](https://img.shields.io/badge/License-Private-red.svg)]()

</div>

---

## 📋 Table of Contents
- [Executive Technical Summary](#executive-technical-summary)
- [Quick Start](#quick-start)
- [Directory & Architecture Structure](#directory--architecture-structure)
  - [Root Control Scripts](#1-root-control-scripts)
  - [Core Engine Modules (`/core`)](#2-core-engine-modules-core)
  - [Dashboard & UI (`/dashboard`)](#3-dashboard--ui-dashboard)
  - [State & Configuration (`/config`)](#4-state--configuration-config)
- [Git Hygiene](#git-hygiene)
- [Core Performance Specifications](#core-performance-specifications)
- [How NetFusion Bypasses Windows Limitations](#how-netfusion-bypasses-windows-limitations)
  - [The E.C.M.P Route Override](#the-ecmp-route-override)
  - [APIPA DHCP Fallback](#apipa-dhcp-fallback)
- [Installation & Operation](#installation--operation)
- [Troubleshooting](#troubleshooting)
- [Deep-Dive Subsystem Technicals](#deep-dive-subsystem-technicals)
- [Version 6.0 Change Log](#version-60-change-log)

---

## Executive Technical Summary

NetFusion does not use bonding VPNs or cloud servers. It operates exclusively as a **Layer 7 HTTP/HTTPS Transparent Pipeline** (`127.0.0.1:8080`). Modern Windows fundamentally restricts identical-subnet network adapters, causing active collisions and throttling when multiple Wi-Fis are connected. 

NetFusion acts directly upon the Windows TCP/IP Stack and native Routing Tables to physically force Equal-Cost Multi-Path (E.C.M.P) rules, and then pipelines connection sockets independently over your adapters based on a live health-matrix (Latency, Jitter, Loss).

---

## Quick Start

1. Open **PowerShell as Administrator** in the project folder.
2. Run **`.\Setup-NetFusion.ps1`** on first use.
3. Review **`config\config.json`** only if you want local changes for your machine.
4. Run **`NetFusion-START.bat`** as Administrator.
5. Open the dashboard at **`http://127.0.0.1:9090/`**.
6. When finished, stop it with **`NetFusion-STOP.bat`**.

NetFusion applies the Windows system proxy automatically during startup. In most cases, browsers that follow Windows proxy settings do not need manual proxy setup.

---

## Directory & Architecture Structure

The project is segmented strictly into decoupled modules to ensure if one crashes, the engine survives.

### 1. Root Control Scripts
These are the user-facing entry points used to interact completely safely with the OS.
* `NetFusion-START.bat` - Requests Administrator privileges, cleans stale ports, and boots the Watchdog.
* `Setup-NetFusion.ps1` - First-run setup helper. Checks prerequisites, creates `config.json` from `config.default.json`, and explains proxy/config basics.
* `NetFusion-STOP.bat` - Safely un-registers the proxy from the OS registry, drops all subsystem jobs, and flushes IP metrics back to Windows Defaults.
* `NetFusion-SAFE.bat` - The scorched-earth Panic Button. Erases registry keys, resets firewall state, and drops frozen locked memory paths.
* `test-speed.ps1` - Diagnostic loopback module calculating exact adapter physical limits.
* `test-ecmp.ps1` - Direct OS-level patch for overlapping router topologies (Syncs RouteMetrics).
* `test-proxylimit.ps1` - Stress-testing harness creating isolated dummy local servers to test Proxy Thread Pool limits.
* `test-wifi4-fix.ps1` - DHCP APIPA recovery. Assigns hard Static IPs if bad routers fail to handshake.

### 2. Core Engine Modules (`/core`)
This array of scripts runs simultaneously as background `Runspace` threads, exchanging data via pure JSON.
* `NetFusionEngine.ps1` - The grand orchestration script. Establishes the thread factory, configures working directories, and spawns the subsystems below.
* `NetFusionWatchdog.ps1` - Scans Process IDs every second. If `SmartProxy` crashes, Watchdog resurrects it in < 0.5s.
* `SmartProxy.ps1` - **The Heart**. A 256-thread scalable TCP/TLS socket interceptor. Binds to port `8080`. Routes byte streams utilizing 256KB bulk pipelines without MITM decryption.
* `InterfaceMonitor.ps1` - Pings Cloudflare/Google DNS per-adapter. Calculates EWMA (Exponential Weighted Moving Average) latency and flags degrading hardware.
* `NetworkManager.ps1` - Reads Baseband physics. Detects if cards are Wi-Fi 4/5/6/7 and assigns capability scoring.
* `RouteController.ps1` - OS Manipulator. Edits Windows `IPv4 Route metrics` natively.
* `QuicBlocker.ps1` - Modifies `netsh advfirewall`. Blocks UDP 443 strictly, forcing browsers to use TCP so the proxy can load balance them.
* `Cleanup-OnCrash.ps1` / `LogRotation.ps1` / `ConfigValidator.ps1` - Silent background janitors freeing memory and sanitizing JSON limits.

### 3. Dashboard & UI (`/dashboard`)
* `DashboardServer.ps1` - A miniature asynchronous HTTP Server running natively in PowerShell on port `9090`. Broadcasts live telemetry using `Server-Sent Events (SSE)`.
* `index.html` - A completely standalone premium Web Application. Features state-of-the-art **Glassmorphism**, dark-ui aesthetics, live connection count pills, latency line charts (rendered dynamically via JS), and active decision logs.

### 4. State & Configuration (`/config`)
No databases are used. The engine breathes via asynchronous JSON file locks.
* `config.default.json` - The shared default configuration that should stay in Git.
* `config.json` - Local runtime configuration created from `config.default.json` by `Setup-NetFusion.ps1`.
* `health.json` - Generated health telemetry updated by `InterfaceMonitor`.
* `proxy-stats.json` - Generated proxy telemetry for the dashboard.
* `decisions.json` - Generated recent routing decisions.
* `interfaces.json` - Generated detected adapter metadata for the current machine.
* `learning-data.json` - Generated learning and recommendation state.
* `throughput.csv` - Generated historical throughput log.

These generated files are runtime state and should generally **not** be committed to GitHub.

---

## Git Hygiene

### Commit These
* PowerShell scripts, batch files, dashboard source, and documentation.
* `config/config.default.json` when you intentionally change the shared defaults.
* `.vscode/settings.json` if you want the repo to carry workspace-level editor behavior such as Git auto-fetch.

### Do Not Commit These
* `config/config.json`
* `config/health.json`
* `config/proxy-stats.json`
* `config/decisions.json`
* `config/interfaces.json`
* `config/learning-data.json`
* `config/throughput.csv`
* `logs/events.json`
* PID files, flags, and other generated runtime state

The repository `.gitignore` is set up so those generated files stay local and stop showing up in normal pushes once they are removed from Git tracking.

---

## Core Performance Specifications

Under **v6.0 SOLID**, the engine was heavily profiled directly against local loopback testing arrays removing internet limits. 

| Metric | Capacity |
|-------------|----------|
| **Initial Threads** | `64` threads immediately spawned on hit. |
| **Max Cap Threads** | `256` fully isolated runspaces. |
| **Tested Max Speed** | **`968 Mbps` sustained payload extraction.** |
| **Memory Blueprint** | Extends to `400 MB` under extreme load; dumps immediately post-socket closure. |

Because `SmartProxy` has zero delay scalability, violent modern networking bursts (like 4K video queues or `Speedtest.net / Fast.com` chunk tests) hit the 64-thread pool successfully with zero timeouts.

---

## How NetFusion Bypasses Windows Limitations

### The E.C.M.P Route Override
If you have multiple Wi-Fi adapters connected to the **same router** (e.g. `192.168.1.0/24`), Windows native stack absolutely refuses to balance traffic. It funnels 100% of data out the adapter with the lowest physical cost index.
* **The Solution:** NetFusion invokes Equal-Cost Multi-Path (`test-ecmp.ps1`). It strips native Automatic Metrics, assigning a hardcoded `15` to both adapters simultaneously. This completely removes the Windows preference tier, allowing NetFusion Proxy `Bind()` commands to physically dictate packet egress cleanly across both identically routed cards.

### APIPA DHCP Fallback
If an identical-subnet mesh node refuses to assign a secondary Wi-Fi adapter an IP address (stranding it with `169.254.x.x`), that adapter loses its `0.0.0.0/0` outbound gateway, breaking the entire multi-network loop. 
* **The Solution:** `test-wifi4-fix.ps1` physically destroys the Windows dynamic address and forces a stable Static IPv4 (`192.168.1.147`) mapped to the core gateway, skipping routing authentication and restoring the load-balance instantly.

> **Note:** To manually change the default gateway for a connected Wi-Fi adapter, open **PowerShell as Administrator** and replace the active default route for the target interface. Example for `Wi-Fi 2`, changing the gateway from `192.168.1.254` to `192.168.1.253`:
>
> ```powershell
> Remove-NetRoute -InterfaceAlias 'Wi-Fi 2' -DestinationPrefix '0.0.0.0/0' -NextHop '192.168.1.254' -Confirm:$false
> New-NetRoute -InterfaceAlias 'Wi-Fi 2' -DestinationPrefix '0.0.0.0/0' -NextHop '192.168.1.253' -RouteMetric 15
> ```
>
> Verify the applied gateway with:
>
> ```powershell
> Get-NetRoute -InterfaceAlias 'Wi-Fi 2' -DestinationPrefix '0.0.0.0/0'
> ```

---

## Installation & Operation

### Standard Startup
1. Run **`Setup-NetFusion.ps1`** *(preferably as Administrator)* on first use.
2. Ensure both Wi-Fi / Ethernet adapters are connected to the network.
3. Review **`config\config.json`** if you want to change ports, startup behavior, or optimization defaults.
4. Run **`NetFusion-START.bat`** *(as Administrator)*.
5. The firewall will sync, UDP will be blocked, and the Proxy (`127.0.0.1:8080` by default) will take over Windows web settings.
6. The premium UI will spawn at **`http://localhost:9090`**.
7. The dashboard opens directly on the local machine with no manual login step because the server binds to `127.0.0.1` only.

### What Setup-NetFusion.ps1 Does
* Checks PowerShell version compatibility.
* Warns if you are not running as Administrator.
* Detects usable adapters and warns if fewer than two are available.
* Creates `config\config.json` from `config\config.default.json` when needed.
* Shows which file controls behavior: `config\config.json`.
* Explains how proxy configuration works for browsers and apps.
* Prints adapter metric guidance for difficult same-subnet dual-adapter setups.

### For Segmented Maximum File Downloads
Because standard Chrome/Edge utilizes multiplexed HTTP/2, a massive single file download will only stream on a single adapter. 
**To utilize 100% hardware capability, you must use a segmented downloader:**
1. Open **Internet Download Manager (IDM)** or **qBittorrent**.
2. IDM will natively inherit the Proxy `127.0.0.1:8080`.
3. Set connections to `16` or `32` maximum streams.
4. The engine will accurately alternate the 32 streams dynamically based on adapter Latency/Speed ratings, generating true aggregate speed.

### Emergency Restores
Run **`NetFusion-SAFE.bat`** *(as Administrator)* if the OS freezes, BSODs, or if you ever see "No Internet" in your browser post-shutdown. This sweeps the registry cleanly.

---

## Troubleshooting

### NetFusion-START.bat opens and closes quickly
This usually means one of the startup steps failed before the proxy finished binding to port `8080`.

To keep the failure visible, run the engine directly:

```powershell
Set-Location .\core
powershell -ExecutionPolicy Bypass -File .\NetFusionEngine.ps1
```

Also check:
* Run the launcher as **Administrator**.
* Make sure no other app is already using ports `8080` or `9090`.
* If startup was interrupted earlier, run **`NetFusion-SAFE.bat`** before trying again.

### Dashboard opens but looks empty
* Make sure `DashboardServer.ps1` is running.
* Make sure `SmartProxy.ps1` successfully bound to `127.0.0.1:8080`.
* Refresh the page after the engine has had a few seconds to generate runtime JSON files.

### Browser loses internet after a crash
Run **`NetFusion-STOP.bat`** first. If Windows proxy settings still look stuck, run **`NetFusion-SAFE.bat`**.

---

## Adapter Compatibility

NetFusion is designed to work with many Windows Wi-Fi and Ethernet adapters, but it is **not guaranteed to work with every adapter model or driver stack**.

### Works Best With
* Adapters that appear cleanly in `Get-NetAdapter`, `Get-NetIPAddress`, and Windows route tables.
* Modern adapters with stable vendor drivers on Windows 10/11.
* Mixed topologies such as **Ethernet + Wi-Fi**, which are usually more predictable than dual identical Wi-Fi links.
* Adapters that support reliable outbound socket binding and normal DHCP/gateway behavior.

### May Be Unreliable With
* Very old USB Wi-Fi dongles.
* Adapters using weak, generic, or badly maintained drivers.
* Vendor utility suites that override or interfere with native Windows networking behavior.
* Virtual adapters, VPN adapters, mobile hotspot adapters, or tethering-only devices.
* Enterprise-auth, captive-portal, or policy-heavy networks that block or rewrite expected routing behavior.

### Practical Limits
* **Driver quality matters more than Wi-Fi generation.** Wi-Fi 4/5/6/7 can all work if the Windows driver behaves correctly.
* **Dual Wi-Fi on the same subnet is the hardest scenario.** Windows naturally resists balancing multiple adapters on one router/subnet, so this setup is more fragile.
* **Ethernet + Wi-Fi is usually easier than Wi-Fi + Wi-Fi.**
* DHCP/APIPA issues, gateway instability, or chipset-specific quirks can reduce reliability even when the adapter itself is detected correctly.

### Bottom Line
NetFusion should be thought of as **compatible with many well-behaved Windows adapters**, not as a universal solution for every Wi-Fi adapter ever made. If an adapter exposes stable routing, IP, and driver behavior in Windows, it is much more likely to work well.

---

## Version 6.0 Change Log

* **Massive 256 Thread Sockets:** Rewrote the runspace boundary limit. It no longer waits to "scale up" during 10s tests; 64 connection handlers idle natively preventing timeout drops.
* **Asymmetric ECMP Patch:** Automated overlapping gateway handling for uniform `192` router matrices using static hard-overrides.
* **IPv6 Safety Engine:** Rebuilt the `HTTP CONNECT` parser. CDNs feeding `[2600::]` IPv6 literal hosts no longer cast index errors; they're smoothly funneled into IPv4 failovers, resurrecting broken Netflix / Fast.com compatibility.
* **Port Evacuation:** Completely migrated off Hyper-V reserved block `8888/8877` onto standard `8080/9090` ensuring WSL/Docker port collision zero-points.
* **Dashboard Overhaul:** Completely rewrote `/dashboard/index.html` from raw grid tables into pure CSS Glassmorphism logic, generating dynamic telemetry mapping natively without external Javascript libraries.

---

## Contributors

* [LoRdGrIm2035](https://github.com/LoRdGrIm2035)
* [Arman-techiee](https://github.com/Arman-techiee)

<br>
<div align="center">
<i>Built for Zero-Trace Redundant Networking.</i>
</div>
>>>>>>> origin/main
