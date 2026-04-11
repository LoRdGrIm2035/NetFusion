Write-Host "=== FORCE RESET WI-FI 4 ===" -ForegroundColor Cyan

# Disable and re-enable the adapter to clear stale state
Disable-NetAdapter -Name "Wi-Fi 4" -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep 3
Enable-NetAdapter -Name "Wi-Fi 4" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Adapter recycled. Waiting for reconnect..."
Start-Sleep 8

# Remove ALL IPv4 addresses on Wi-Fi 4
Get-NetIPAddress -InterfaceAlias "Wi-Fi 4" -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceAlias "Wi-Fi 4" -ErrorAction SilentlyContinue | 
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep 1

# Apply fresh static IP
New-NetIPAddress -InterfaceAlias "Wi-Fi 4" -IPAddress "192.168.1.147" -PrefixLength 24 -DefaultGateway "192.168.1.254" -ErrorAction Stop
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi 4" -ServerAddresses @("8.8.8.8","1.1.1.1")
Write-Host "Static IP applied: 192.168.1.147" -ForegroundColor Green

# Wait and force ARP resolution
Start-Sleep 2
$result = ping.exe -S 192.168.1.147 -n 5 -w 1000 192.168.1.254
Write-Host ($result -join "`n")

$result2 = ping.exe -S 192.168.1.147 -n 3 -w 2000 8.8.8.8
$ok = ($result2 -join " ") -match "Reply from"
Write-Host "Wi-Fi 4 -> 8.8.8.8: $(if($ok){'SUCCESS'}else{'FAIL'})" -ForegroundColor $(if($ok){'Green'}else{'Red'})

# Set ECMP metrics
Set-NetIPInterface -InterfaceAlias "Wi-Fi 3" -AutomaticMetric Disabled -InterfaceMetric 15
Set-NetIPInterface -InterfaceAlias "Wi-Fi 4" -AutomaticMetric Disabled -InterfaceMetric 15
Set-NetRoute -InterfaceAlias "Wi-Fi 3" -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
Set-NetRoute -InterfaceAlias "Wi-Fi 4" -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue

# Final check
$wifi4Idx = (Get-NetAdapter -Name "Wi-Fi 4").ifIndex
$arp = Get-NetNeighbor -InterfaceIndex $wifi4Idx -IPAddress "192.168.1.254" -ErrorAction SilentlyContinue
Write-Host "Wi-Fi 4 gateway MAC: $($arp.LinkLayerAddress) ($($arp.State))"

Get-NetIPAddress -InterfaceAlias "Wi-Fi 4" -AddressFamily IPv4 | Format-Table IPAddress, PrefixOrigin -AutoSize
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Format-Table InterfaceAlias, NextHop, RouteMetric -AutoSize
Start-Sleep 5
