Write-Host "=== COMPLETE WI-FI 4 RESET ===" -ForegroundColor Cyan

# 1. Fully disable the adapter
Write-Host "Step 1: Disabling Wi-Fi 4..."
Disable-NetAdapter -Name "Wi-Fi 4" -Confirm:$false
Start-Sleep 3

# 2. Enable it again fresh
Write-Host "Step 2: Re-enabling Wi-Fi 4..."
Enable-NetAdapter -Name "Wi-Fi 4" -Confirm:$false
Start-Sleep 5

# 3. Wait for it to reconnect to SSID
Write-Host "Step 3: Waiting for Wi-Fi reconnection..."
$deadline = (Get-Date).AddSeconds(20)
$connected = $false
while ((Get-Date) -lt $deadline) {
    $state = netsh wlan show interfaces | Select-String "Wi-Fi 4" -Context 0,15
    if (($state -join " ") -match "connected") { $connected = $true; break }
    Start-Sleep 2
}
if ($connected) { Write-Host "  Connected!" -ForegroundColor Green }
else { Write-Host "  Not connected!" -ForegroundColor Red; Start-Sleep 10; exit }

# 4. Try DHCP by removing all manual config  
Write-Host "Step 4: Clearing manual IP config, requesting DHCP..."
Get-NetIPAddress -InterfaceAlias "Wi-Fi 4" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceAlias "Wi-Fi 4" -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceAlias "Wi-Fi 4" -Dhcp Enabled -ErrorAction SilentlyContinue
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi 4" -ResetServerAddresses -ErrorAction SilentlyContinue

# 5. Force DHCP renewal
Write-Host "Step 5: Forcing DHCP renewal..."
ipconfig /release "Wi-Fi 4" 2>$null
Start-Sleep 2
ipconfig /renew "Wi-Fi 4" 2>$null
Start-Sleep 8

# 6. Check what DHCP gave us
$ip4 = (Get-NetIPAddress -InterfaceAlias "Wi-Fi 4" -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
$gw4 = (Get-NetRoute -InterfaceAlias "Wi-Fi 4" -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop
Write-Host "DHCP result: IP=$ip4, Gateway=$gw4"

if ($ip4 -match '^169\.254\.' -or -not $gw4) {
    Write-Host "DHCP FAILED! Router is refusing DHCP." -ForegroundColor Red
    Write-Host "Applying static IP..." -ForegroundColor Yellow
    
    Get-NetIPAddress -InterfaceAlias "Wi-Fi 4" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceAlias "Wi-Fi 4" -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 1
    
    New-NetIPAddress -InterfaceAlias "Wi-Fi 4" -IPAddress "192.168.1.147" -PrefixLength 24 -DefaultGateway "192.168.1.254"
    Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi 4" -ServerAddresses @("8.8.8.8","1.1.1.1")
    Start-Sleep 2
    $ip4 = "192.168.1.147"
}

# 7. Test connectivity
Write-Host "`nTesting connectivity..."
$gw = ping.exe -S $ip4 -n 3 -w 1000 192.168.1.254
$gwOK = ($gw -join " ") -match "Reply from"
Write-Host "Gateway ping: $(if($gwOK){'OK'}else{'FAIL'})"

$inet = ping.exe -S $ip4 -n 3 -w 2000 8.8.8.8  
$inetOK = ($inet -join " ") -match "Reply from"
Write-Host "Internet ping: $(if($inetOK){'OK'}else{'FAIL'})"

$wifi4Idx = (Get-NetAdapter -Name "Wi-Fi 4").ifIndex
$arp = Get-NetNeighbor -InterfaceIndex $wifi4Idx -IPAddress "192.168.1.254" -ErrorAction SilentlyContinue
Write-Host "Gateway ARP: MAC=$($arp.LinkLayerAddress) State=$($arp.State)"

# 8. ECMP
Set-NetIPInterface -InterfaceAlias "Wi-Fi 3" -AutomaticMetric Disabled -InterfaceMetric 15
Set-NetIPInterface -InterfaceAlias "Wi-Fi 4" -AutomaticMetric Disabled -InterfaceMetric 15

Write-Host "`n=== DONE ===" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Wi-Fi*" | Format-Table InterfaceAlias, IPAddress, PrefixOrigin -AutoSize
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Where-Object { $_.InterfaceAlias -match 'Wi-Fi' } | Format-Table InterfaceAlias, NextHop, RouteMetric -AutoSize
Start-Sleep 8
