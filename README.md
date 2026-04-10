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
- [Directory & Architecture Structure](#directory--architecture-structure)
  - [Root Control Scripts](#1-root-control-scripts)
  - [Core Engine Modules (`/core`)](#2-core-engine-modules-core)
  - [Dashboard & UI (`/dashboard`)](#3-dashboard--ui-dashboard)
  - [State & Configuration (`/config`)](#4-state--configuration-config)
- [Core Performance Specifications](#core-performance-specifications)
- [How NetFusion Bypasses Windows Limitations](#how-netfusion-bypasses-windows-limitations)
  - [The E.C.M.P Route Override](#the-ecmp-route-override)
  - [APIPA DHCP Fallback](#apipa-dhcp-fallback)
- [Installation & Operation](#installation--operation)
- [Deep-Dive Subsystem Technicals](#deep-dive-subsystem-technicals)
- [Version 6.0 Change Log](#version-60-change-log)

---

## Executive Technical Summary

NetFusion does not use bonding VPNs or cloud servers. It operates exclusively as a **Layer 7 HTTP/HTTPS Transparent Pipeline** (`127.0.0.1:8080`). Modern Windows fundamentally restricts identical-subnet network adapters, causing active collisions and throttling when multiple Wi-Fis are connected. 

NetFusion acts directly upon the Windows TCP/IP Stack and native Routing Tables to physically force Equal-Cost Multi-Path (E.C.M.P) rules, and then pipelines connection sockets independently over your adapters based on a live health-matrix (Latency, Jitter, Loss).

---

## Directory & Architecture Structure

The project is segmented strictly into decoupled modules to ensure if one crashes, the engine survives.

### 1. Root Control Scripts
These are the user-facing entry points used to interact completely safely with the OS.
* `NetFusion-START.bat` - Requests Administrator privileges, cleans stale ports, and boots the Watchdog.
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
* `config.json` - Global engine behavior limits (Ports, File paths, Wait-Times).
* `health.json` - Updated every 2000ms by `InterfaceMonitor`. Read by `SmartProxy`.
* `proxy-stats.json` - Telemetry dumped by proxy threads. Read by `DashboardServer`.
* `decisions.json` - Connection logs (which URL went to which adapter and why).
* `interfaces.json` - Detected hardware MACs and physics capabilities.
* `dashboard-token.txt` - Local dashboard access token. Keep this file out of git and do not share it.

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
1. Ensure both Wi-Fi / Ethernet adapters are connected to the network.
2. Run **`NetFusion-START.bat`** *(as Administrator)*.
3. The firewall will sync, UDP will be blocked, and the Proxy (`127.0.0.1:8080`) will take over Windows web settings.
4. The premium UI will spawn at **`http://localhost:9090`**.
5. The dashboard will prompt for the access token shown in the server console and stores it in an HTTP-only cookie after login. Do not pass the token in the URL.

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

## Version 6.0 Change Log

* **Massive 256 Thread Sockets:** Rewrote the runspace boundary limit. It no longer waits to "scale up" during 10s tests; 64 connection handlers idle natively preventing timeout drops.
* **Asymmetric ECMP Patch:** Automated overlapping gateway handling for uniform `192` router matrices using static hard-overrides.
* **IPv6 Safety Engine:** Rebuilt the `HTTP CONNECT` parser. CDNs feeding `[2600::]` IPv6 literal hosts no longer cast index errors; they're smoothly funneled into IPv4 failovers, resurrecting broken Netflix / Fast.com compatibility.
* **Port Evacuation:** Completely migrated off Hyper-V reserved block `8888/8877` onto standard `8080/9090` ensuring WSL/Docker port collision zero-points.
* **Dashboard Overhaul:** Completely rewrote `/dashboard/index.html` from raw grid tables into pure CSS Glassmorphism logic, generating dynamic telemetry mapping natively without external Javascript libraries.

<br>
<div align="center">
<i>Built for Zero-Trace Redundant Networking.</i>
</div>
