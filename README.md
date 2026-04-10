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

<br>
<div align="center">
<i>Built for Zero-Trace Redundant Networking.</i>
</div>
