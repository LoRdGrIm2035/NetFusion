# Repair Scripts

This folder contains non-entrypoint adapter repair helpers for known local recovery cases.

Repair scripts may change adapter IP settings, ARP entries, or routes. Keep startup, shutdown, safe-mode, setup, and service-install scripts at the repository root unless there is a compatibility wrapper in place.

- `repair-wifi4-basic.ps1` runs the basic Wi-Fi 4 repair workflow.
- `repair-wifi4-route.ps1` repairs Wi-Fi 4 route/static-IP behavior.
- `repair-wifi4-arp.ps1` repairs Wi-Fi 4 ARP/static route behavior.
- `force-reset-wifi4-static.ps1` is the older force static reset helper, preserved for compatibility by purpose rather than public path.
- `reset-wifi4-dhcp-static.ps1` is the older DHCP/static reset helper, preserved for compatibility by purpose rather than public path.
