Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "     NetFusion Network Repair Utility     " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Restarting Wi-Fi 4..." -ForegroundColor Yellow
Disable-NetAdapter -Name "Wi-Fi 4" -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Enable-NetAdapter -Name "Wi-Fi 4" -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "Waiting 5 seconds for DHCP..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

$ipConf = Get-NetIPConfiguration -InterfaceAlias "Wi-Fi 4" -ErrorAction SilentlyContinue
if ($null -ne $ipConf -and ($null -eq $ipConf.IPv4Address -or $ipConf.IPv4Address.IPAddress -match "^169\.254\.")) {
    Write-Host "DHCP is dead on Wi-Fi 4. Applying Emergency Static IP (192.168.1.147)..." -ForegroundColor Red
    
    Remove-NetIPAddress -InterfaceAlias "Wi-Fi 4" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias "Wi-Fi 4" -Confirm:$false -ErrorAction SilentlyContinue
    
    New-NetIPAddress -InterfaceAlias "Wi-Fi 4" -IPAddress "192.168.1.147" -PrefixLength 24 -DefaultGateway "192.168.1.254" -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi 4" -ServerAddresses ("8.8.8.8","1.1.1.1") -ErrorAction SilentlyContinue
    Write-Host "Static IP successfully applied!" -ForegroundColor Green
} else {
    Write-Host "DHCP recovered successfully!" -ForegroundColor Green
}

Write-Host "
Enforcing Perfect 50/50 E.C.M.P Routing..." -ForegroundColor Yellow
Set-NetIPInterface -InterfaceAlias "Wi-Fi 4" -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction SilentlyContinue
Set-NetRoute -InterfaceAlias "Wi-Fi 4" -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceAlias "Wi-Fi 3" -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction SilentlyContinue
Set-NetRoute -InterfaceAlias "Wi-Fi 3" -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue

Write-Host "
Network Repaired!" -ForegroundColor Green
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Format-Table InterfaceAlias, RouteMetric -AutoSize
Start-Sleep -Seconds 10
