# NetFusion Network Repair Utility -- auto-discovers adapters
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ifFile = Join-Path $scriptDir "config\interfaces.json"

# Auto-discover adapters
$adapters = @()
if (Test-Path $ifFile) {
    try {
        $ifData = Get-Content $ifFile -Raw | ConvertFrom-Json
        $adapters = @($ifData.interfaces | Where-Object { $_.Status -eq 'Up' -and $_.Type -match 'WiFi|USB-WiFi' })
    } catch {}
}
if ($adapters.Count -lt 1) {
    $adapters = @(Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel' -and
        ($_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11|WLAN|WiFi' -or $_.Name -match 'Wi-Fi|WLAN|Wireless')
    })
}
if ($adapters.Count -lt 1) {
    Write-Host "[FAIL] No WiFi adapters found to repair." -ForegroundColor Red
    Start-Sleep -Seconds 5; exit 1
}

# The "sick" adapter is the last one (most likely the secondary); the "healthy" one is the first
$sickAdapter  = if ($adapters.Count -ge 2) { $adapters[1] } else { $adapters[0] }
$healthyAdapter = $adapters[0]
$sickName = $sickAdapter.Name
$healthyName = $healthyAdapter.Name

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "     NetFusion Network Repair Utility     " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Target adapter : $sickName" -ForegroundColor Yellow
Write-Host "Healthy adapter: $healthyName" -ForegroundColor Green
Write-Host ""

Write-Host "Restarting $sickName..." -ForegroundColor Yellow
Disable-NetAdapter -Name $sickName -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Enable-NetAdapter -Name $sickName -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "Waiting 5 seconds for DHCP..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

$ipConf = Get-NetIPConfiguration -InterfaceAlias $sickName -ErrorAction SilentlyContinue
if ($null -ne $ipConf -and ($null -eq $ipConf.IPv4Address -or $ipConf.IPv4Address.IPAddress -match "^169\.254\.")) {
    # Dynamically get gateway from healthy adapter (same as Repair-AdapterDHCP in the engine)
    $workingGW = (Get-NetIPConfiguration -InterfaceAlias $healthyName -ErrorAction SilentlyContinue).IPv4DefaultGateway.NextHop
    if (-not $workingGW) {
        Write-Host "Cannot determine gateway from $healthyName. Aborting static IP." -ForegroundColor Red
        Start-Sleep -Seconds 5; exit 1
    }
    $gwParts = $workingGW -split '\.'
    $subnet = "$($gwParts[0]).$($gwParts[1]).$($gwParts[2])"
    $staticIP = "$subnet.147"

    Write-Host "DHCP is dead on $sickName. Applying Emergency Static IP ($staticIP, gw $workingGW)..." -ForegroundColor Red

    Remove-NetIPAddress -InterfaceAlias $sickName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $sickName -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceAlias $sickName -IPAddress $staticIP -PrefixLength 24 -DefaultGateway $workingGW -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $sickName -ServerAddresses ("8.8.8.8","1.1.1.1") -ErrorAction SilentlyContinue
    Write-Host "Static IP successfully applied!" -ForegroundColor Green
} else {
    Write-Host "DHCP recovered successfully!" -ForegroundColor Green
}

Write-Host ""
Write-Host "Enforcing Perfect 50/50 E.C.M.P Routing..." -ForegroundColor Yellow
foreach ($a in $adapters) {
    Set-NetIPInterface -InterfaceAlias $a.Name -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction SilentlyContinue
    Set-NetRoute -InterfaceAlias $a.Name -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Network Repaired!" -ForegroundColor Green
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Format-Table InterfaceAlias, RouteMetric -AutoSize
Start-Sleep -Seconds 10
