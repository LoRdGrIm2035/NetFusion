Write-Host "=== FIXING WI-FI 4 NETWORK STACK ===" -ForegroundColor Cyan

# Step 1: Remove the lingering APIPA address 
Write-Host "Removing APIPA address..."
Get-NetIPAddress -InterfaceAlias "Wi-Fi 4" -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
    Where-Object { $_.IPAddress -match '^169\.254\.' } | 
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

# Step 2: Flush ARP cache for Wi-Fi 4 to force fresh MAC resolution
Write-Host "Flushing ARP for Wi-Fi 4..."
$wifi4Idx = (Get-NetAdapter -Name "Wi-Fi 4").ifIndex
netsh interface ip delete arpcache interface=$wifi4Idx 2>$null
Remove-NetNeighbor -InterfaceIndex $wifi4Idx -Confirm:$false -ErrorAction SilentlyContinue

# Step 3: Verify static IP is set correctly
$wifi4IP = (Get-NetIPAddress -InterfaceAlias "Wi-Fi 4" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^169\.254\.' }).IPAddress
if (-not $wifi4IP) {
    Write-Host "Re-applying static IP 192.168.1.147..."
    New-NetIPAddress -InterfaceAlias "Wi-Fi 4" -IPAddress "192.168.1.147" -PrefixLength 24 -DefaultGateway "192.168.1.254" -ErrorAction SilentlyContinue
    $wifi4IP = "192.168.1.147"
}
Write-Host "Wi-Fi 4 IP: $wifi4IP"

# Step 4: Force DNS
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi 4" -ServerAddresses @("8.8.8.8","1.1.1.1") -ErrorAction SilentlyContinue

# Step 5: Ping gateway to resolve ARP
Write-Host "Resolving gateway ARP..."
ping.exe -S 192.168.1.147 -n 3 -w 1000 192.168.1.254 | Out-Null

# Step 6: Verify ARP resolved
Start-Sleep 1
$arp4 = Get-NetNeighbor -InterfaceIndex $wifi4Idx -IPAddress "192.168.1.254" -ErrorAction SilentlyContinue
Write-Host "Wi-Fi 4 gateway MAC after fix: $($arp4.LinkLayerAddress)"

# Step 7: ECMP
Set-NetIPInterface -InterfaceAlias "Wi-Fi 3" -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceAlias "Wi-Fi 4" -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction SilentlyContinue
Set-NetRoute -InterfaceAlias "Wi-Fi 3" -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
Set-NetRoute -InterfaceAlias "Wi-Fi 4" -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue

# Step 8: Test both can reach internet
Write-Host "`nTesting internet..."
$p3 = ping.exe -S 192.168.1.67 -n 1 -w 2000 8.8.8.8
$p4 = ping.exe -S 192.168.1.147 -n 1 -w 2000 8.8.8.8
Write-Host "Wi-Fi 3 internet: $(if(($p3 -join ' ') -match 'Reply from'){'OK'}else{'FAIL'})"
Write-Host "Wi-Fi 4 internet: $(if(($p4 -join ' ') -match 'Reply from'){'OK'}else{'FAIL'})"

# Step 9: Check if MACs are different (different routers)
$arp3 = Get-NetNeighbor -InterfaceIndex (Get-NetAdapter -Name "Wi-Fi 3").ifIndex -IPAddress "192.168.1.254" -ErrorAction SilentlyContinue
$arp4new = Get-NetNeighbor -InterfaceIndex $wifi4Idx -IPAddress "192.168.1.254" -ErrorAction SilentlyContinue
Write-Host "`nWi-Fi 3 gateway MAC: $($arp3.LinkLayerAddress)"
Write-Host "Wi-Fi 4 gateway MAC: $($arp4new.LinkLayerAddress)"
if ($arp3.LinkLayerAddress -eq $arp4new.LinkLayerAddress) {
    Write-Host "SAME ROUTER - same internet pipe" -ForegroundColor Yellow
} else {
    Write-Host "DIFFERENT ROUTERS - separate pipes possible!" -ForegroundColor Green
}
Start-Sleep 3
