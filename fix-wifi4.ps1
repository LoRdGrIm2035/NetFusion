<#
.SYNOPSIS
    Legacy emergency Wi-Fi 4 repair helper.
.DESCRIPTION
    Superseded by the NetFusion engine's built-in Repair-AdapterDHCP loop.
    Keep this script for manual emergency recovery only. It applies a hardcoded
    static IP and can conflict with the engine's normal repair logic.
#>

﻿Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  NetFusion v6.1 Network Repair Utility     " -ForegroundColor Cyan  
Write-Host "============================================" -ForegroundColor Cyan

# Step 1: Get Wi-Fi 4 interface index
$wifi4 = Get-NetAdapter -Name "Wi-Fi 4" -ErrorAction SilentlyContinue
$wifi3 = Get-NetAdapter -Name "Wi-Fi 3" -ErrorAction SilentlyContinue
if (-not $wifi4 -or -not $wifi3) {
    Write-Host "[FAIL] Cannot find Wi-Fi 3 or Wi-Fi 4" -ForegroundColor Red
    Start-Sleep 5; exit 1
}

$wifi4Idx = $wifi4.ifIndex
$wifi3Idx = $wifi3.ifIndex
Write-Host "Wi-Fi 3 index: $wifi3Idx | Wi-Fi 4 index: $wifi4Idx"

# Step 2: Check current Wi-Fi 4 IP
$wifi4IP = (Get-NetIPAddress -InterfaceIndex $wifi4Idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
Write-Host "Wi-Fi 4 current IP: $wifi4IP"

if ($wifi4IP -match "^169\.254\." -or -not $wifi4IP) {
    Write-Host "[!] Wi-Fi 4 has APIPA/no IP. Attempting DHCP renewal..." -ForegroundColor Yellow
    
    # Try DHCP first
    Disable-NetAdapter -Name "Wi-Fi 4" -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 2
    Enable-NetAdapter -Name "Wi-Fi 4" -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 8
    
    $wifi4IP = (Get-NetIPAddress -InterfaceIndex $wifi4Idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    Write-Host "After DHCP retry, Wi-Fi 4 IP: $wifi4IP"
    
    if ($wifi4IP -match "^169\.254\." -or -not $wifi4IP) {
        Write-Host "[!] DHCP failed again. Applying static IP 192.168.1.147..." -ForegroundColor Red
        
        # Remove any existing IP config
        Get-NetIPAddress -InterfaceIndex $wifi4Idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $wifi4Idx -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        
        # Apply static IP
        New-NetIPAddress -InterfaceAlias "Wi-Fi 4" -IPAddress "192.168.1.147" -PrefixLength 24 -DefaultGateway "192.168.1.254" -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi 4" -ServerAddresses @("8.8.8.8","1.1.1.1") -ErrorAction SilentlyContinue
        
        $wifi4IP = "192.168.1.147"
        Write-Host "[OK] Static IP applied: $wifi4IP" -ForegroundColor Green
    } else {
        Write-Host "[OK] DHCP succeeded: $wifi4IP" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] Wi-Fi 4 already has valid IP: $wifi4IP" -ForegroundColor Green
}

# Step 3: Verify Wi-Fi 4 has a default route
$wifi4Route = Get-NetRoute -InterfaceIndex $wifi4Idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
if (-not $wifi4Route) {
    Write-Host "[!] Wi-Fi 4 has no default route. Adding one..." -ForegroundColor Yellow
    New-NetRoute -InterfaceIndex $wifi4Idx -DestinationPrefix "0.0.0.0/0" -NextHop "192.168.1.254" -RouteMetric 15 -ErrorAction SilentlyContinue
    Write-Host "[OK] Default route added" -ForegroundColor Green
}

# Step 4: Set ECMP equal metrics on both adapters
Write-Host "`nEnforcing ECMP equal metrics..." -ForegroundColor Yellow
Set-NetIPInterface -InterfaceIndex $wifi3Idx -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceIndex $wifi4Idx -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction SilentlyContinue

# Also set route metrics equal
Set-NetRoute -InterfaceIndex $wifi3Idx -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
Set-NetRoute -InterfaceIndex $wifi4Idx -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue

# Step 5: Verify internet works on Wi-Fi 4
Write-Host "`nTesting internet connectivity on Wi-Fi 4..." -ForegroundColor Yellow
$pingResult = ping.exe -S $wifi4IP -n 2 -w 2000 8.8.8.8
$pingOK = ($pingResult -join "`n") -match "Reply from"
if ($pingOK) {
    Write-Host "[OK] Wi-Fi 4 has internet!" -ForegroundColor Green
} else {
    Write-Host "[WARN] Wi-Fi 4 ping to 8.8.8.8 failed. Router may be blocking." -ForegroundColor Red
}

# Step 6: Final status
Write-Host "`n============ FINAL STATUS ============" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Wi-Fi*" | Format-Table InterfaceAlias, IPAddress, PrefixOrigin -AutoSize
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Format-Table InterfaceAlias, NextHop, RouteMetric, ifMetric -AutoSize
Write-Host "======================================" -ForegroundColor Cyan
Start-Sleep 10
