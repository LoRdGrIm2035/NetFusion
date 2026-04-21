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
}
Start-Sleep -Seconds 5
