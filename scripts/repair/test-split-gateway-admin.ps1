[CmdletBinding()]
param(
    [string]$PrimaryAdapter = "Wi-Fi 3",
    [string]$SecondaryAdapter = "Wi-Fi 4",
    [string]$PrimaryGateway = "192.168.1.254",
    [string]$SecondaryGateway = "192.168.1.253",
    [string]$FallbackGateway = "192.168.1.254",
    [string]$DownloadUrl = "http://speedtest-srv.classic.com.np:8080/speedtest/random4000x4000.jpg"
)

$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path (Split-Path $scriptDir -Parent) -Parent
$resultPath = Join-Path $projectDir "config\gateway-split-result.json"

function Write-Result {
    param([hashtable]$Data)

    $Data.timestamp = (Get-Date).ToString("o")
    $Data | ConvertTo-Json -Depth 8 | Set-Content -Path $resultPath -Encoding UTF8 -Force
}

function Get-AdapterIPv4 {
    param([int]$InterfaceIndex)

    $addr = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -and $_.IPAddress -notmatch "^169\.254\." } |
        Sort-Object SkipAsSource |
        Select-Object -First 1
    if (-not $addr) {
        throw "No usable IPv4 address on interface index $InterfaceIndex."
    }
    return [string]$addr.IPAddress
}

function Set-DefaultRoutes {
    param(
        [int]$InterfaceIndex,
        [object[]]$Routes
    )

    Get-NetRoute -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    foreach ($route in $Routes) {
        New-NetRoute -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -NextHop $route.NextHop -RouteMetric $route.Metric -ErrorAction Stop | Out-Null
    }
}

function Invoke-BoundCurl {
    param(
        [string]$LocalIP,
        [string]$Url
    )

    $format = "CODE=%{http_code};SIZE=%{size_download};TIME=%{time_total};SPEED=%{speed_download};IP=%{local_ip}"
    $output = & curl.exe --interface $LocalIP --noproxy * --connect-timeout 5 --max-time 25 --speed-time 10 --speed-limit 1024 -L -o NUL -sS -w $format $Url 2>&1
    $text = ($output | Out-String).Trim()
    $matched = $text -match "CODE=(\d+);SIZE=(\d+);TIME=([0-9.]+);SPEED=([0-9.]+);IP=(.*)$"
    if (-not $matched) {
        return @{
            ok = $false
            exitCode = $LASTEXITCODE
            raw = $text
            mbps = 0.0
        }
    }

    $size = [double]$Matches[2]
    $seconds = [double]$Matches[3]
    return @{
        ok = ($LASTEXITCODE -eq 0 -and [int]$Matches[1] -ge 200 -and [int]$Matches[1] -lt 400)
        exitCode = $LASTEXITCODE
        httpCode = [int]$Matches[1]
        bytes = [int64]$size
        seconds = $seconds
        mbps = if ($seconds -gt 0) { [math]::Round(($size * 8 / 1MB) / $seconds, 2) } else { 0.0 }
        localIP = $Matches[5]
        raw = $text
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Result @{
        ok = $false
        stage = "admin-check"
        error = "This script must run as Administrator."
    }
    exit 1
}

$primary = Get-NetAdapter -Name $PrimaryAdapter -ErrorAction Stop
$secondary = Get-NetAdapter -Name $SecondaryAdapter -ErrorAction Stop
$primaryIndex = [int]$primary.ifIndex
$secondaryIndex = [int]$secondary.ifIndex
$primaryIP = Get-AdapterIPv4 -InterfaceIndex $primaryIndex
$secondaryIP = Get-AdapterIPv4 -InterfaceIndex $secondaryIndex

$beforeRoutes = @(
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceIndex -in @($primaryIndex, $secondaryIndex) } |
        Select-Object InterfaceAlias, InterfaceIndex, NextHop, RouteMetric
)

try {
    Set-NetIPInterface -InterfaceIndex $primaryIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction Stop
    Set-NetIPInterface -InterfaceIndex $secondaryIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 15 -ErrorAction Stop

    Set-DefaultRoutes -InterfaceIndex $primaryIndex -Routes @(
        @{ NextHop = $PrimaryGateway; Metric = 15 }
    )
    Set-DefaultRoutes -InterfaceIndex $secondaryIndex -Routes @(
        @{ NextHop = $SecondaryGateway; Metric = 15 }
    )

    Start-Sleep -Seconds 2

    $neighbor = Get-NetNeighbor -InterfaceIndex $secondaryIndex -AddressFamily IPv4 -IPAddress $SecondaryGateway -ErrorAction SilentlyContinue | Select-Object -First 1
    $gatewayPing = Test-Connection -TargetName $SecondaryGateway -Source $secondaryIP -Count 2 -Quiet -ErrorAction SilentlyContinue
    $secondaryCurl = Invoke-BoundCurl -LocalIP $secondaryIP -Url $DownloadUrl
    $primaryCurl = Invoke-BoundCurl -LocalIP $primaryIP -Url $DownloadUrl

    $splitViable = $secondaryCurl.ok -and $secondaryCurl.mbps -ge 100.0

    if (-not $splitViable) {
        Set-DefaultRoutes -InterfaceIndex $secondaryIndex -Routes @(
            @{ NextHop = $FallbackGateway; Metric = 75 },
            @{ NextHop = $SecondaryGateway; Metric = 575 }
        )
    }

    $afterRoutes = @(
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -in @($primaryIndex, $secondaryIndex) } |
            Select-Object InterfaceAlias, InterfaceIndex, NextHop, RouteMetric
    )

    Write-Result @{
        ok = $splitViable
        stage = "complete"
        primaryAdapter = $PrimaryAdapter
        secondaryAdapter = $SecondaryAdapter
        primaryIP = $primaryIP
        secondaryIP = $secondaryIP
        primaryGateway = $PrimaryGateway
        secondaryGateway = $SecondaryGateway
        fallbackGateway = $FallbackGateway
        gatewayPing = $gatewayPing
        secondaryNeighbor = if ($neighbor) { @{ ip = [string]$neighbor.IPAddress; mac = [string]$neighbor.LinkLayerAddress; state = [string]$neighbor.State } } else { $null }
        primaryCurl = $primaryCurl
        secondaryCurl = $secondaryCurl
        keptSplitGateway = $splitViable
        beforeRoutes = $beforeRoutes
        afterRoutes = $afterRoutes
    }

    if ($splitViable) { exit 0 } else { exit 2 }
} catch {
    try {
        Set-DefaultRoutes -InterfaceIndex $secondaryIndex -Routes @(
            @{ NextHop = $FallbackGateway; Metric = 75 },
            @{ NextHop = $SecondaryGateway; Metric = 575 }
        )
    } catch {}

    Write-Result @{
        ok = $false
        stage = "exception"
        error = $_.Exception.Message
        beforeRoutes = $beforeRoutes
    }
    exit 1
}
