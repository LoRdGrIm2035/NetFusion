<<<<<<< HEAD
$wifi3Idx = (Get-NetAdapter -Name 'Wi-Fi 3' -ErrorAction SilentlyContinue).InterfaceIndex
$wifi4Idx = (Get-NetAdapter -Name 'Wi-Fi 4' -ErrorAction SilentlyContinue).InterfaceIndex

if ($wifi3Idx -and $wifi4Idx) {
    Write-Host 'Enforcing ECMP via Metrics on overlapping Wi-Fi networks...'
    try {
        Set-NetIPInterface -InterfaceIndex $wifi3Idx -AutomaticMetric Disabled -InterfaceMetric 15
        Set-NetIPInterface -InterfaceIndex $wifi4Idx -AutomaticMetric Disabled -InterfaceMetric 15
        Set-NetRoute -InterfaceIndex $wifi3Idx -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
        Set-NetRoute -InterfaceIndex $wifi4Idx -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
        Write-Host 'Networks successfully bound for 50/50 Dual Routing!'
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Format-Table InterfaceAlias, InterfaceIndex, NextHop, RouteMetric, ifMetric -AutoSize
    } catch {
        Write-Host 'Failed: ' $_
    }
} else {
    Write-Host 'Could not find Wi-Fi 3 and Wi-Fi 4 adapters.'
=======
# ECMP enforcement test -- auto-discovers adapters from interfaces.json
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ifFile = Join-Path $scriptDir "config\interfaces.json"

# Auto-discover adapters
$adapters = @()
if (Test-Path $ifFile) {
    try {
        $ifData = Get-Content $ifFile -Raw | ConvertFrom-Json
        $adapters = @($ifData.interfaces | Where-Object { $_.Status -eq 'Up' -and $_.Type -match 'WiFi|USB-WiFi' })
    } catch {
        Write-Host "[!] Failed to parse interfaces.json: $_" -ForegroundColor Red
    }
}

if ($adapters.Count -lt 2) {
    # Fallback: detect from OS directly
    Write-Host "[!] interfaces.json missing or has <2 WiFi adapters -- falling back to OS detection" -ForegroundColor Yellow
    $adapters = @(Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel' -and
        ($_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11|WLAN|WiFi' -or $_.Name -match 'Wi-Fi|WLAN|Wireless')
    } | Select-Object -First 2)
}

if ($adapters.Count -lt 2) {
    Write-Host "[FAIL] Need 2+ WiFi adapters for ECMP test. Found: $($adapters.Count)" -ForegroundColor Red
    Write-Host "       Detected adapters:" -ForegroundColor Yellow
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        Write-Host "         - $($_.Name) [$($_.InterfaceDescription)]" -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 5
    exit 1
}

$a1Name = $adapters[0].Name
$a2Name = $adapters[1].Name
$a1Idx = if ($adapters[0].ifIndex) { $adapters[0].ifIndex } else { (Get-NetAdapter -Name $a1Name).InterfaceIndex }
$a2Idx = if ($adapters[1].ifIndex) { $adapters[1].ifIndex } else { (Get-NetAdapter -Name $a2Name).InterfaceIndex }

Write-Host "Enforcing ECMP via Metrics on overlapping Wi-Fi networks..."
Write-Host "  Adapter 1: $a1Name (idx $a1Idx)"
Write-Host "  Adapter 2: $a2Name (idx $a2Idx)"
try {
    Set-NetIPInterface -InterfaceIndex $a1Idx -AutomaticMetric Disabled -InterfaceMetric 15
    Set-NetIPInterface -InterfaceIndex $a2Idx -AutomaticMetric Disabled -InterfaceMetric 15
    Set-NetRoute -InterfaceIndex $a1Idx -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
    Set-NetRoute -InterfaceIndex $a2Idx -DestinationPrefix '0.0.0.0/0' -RouteMetric 15 -ErrorAction SilentlyContinue
    Write-Host 'Networks successfully bound for 50/50 Dual Routing!' -ForegroundColor Green
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Format-Table InterfaceAlias, InterfaceIndex, NextHop, RouteMetric, ifMetric -AutoSize
} catch {
    Write-Host "Failed: $_" -ForegroundColor Red
>>>>>>> origin/main
}
Start-Sleep -Seconds 5
