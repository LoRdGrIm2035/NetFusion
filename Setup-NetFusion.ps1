[CmdletBinding()]
param(
    [switch]$ResetConfig
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = $scriptDir
$configDir = Join-Path $projectDir "config"
$logsDir = Join-Path $projectDir "logs"
$defaultConfigPath = Join-Path $configDir "config.default.json"
$configPath = Join-Path $configDir "config.json"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UsableAdapters {
    try {
        return @(
            Get-NetAdapter -ErrorAction Stop |
                Where-Object {
                    $_.Status -ne 'Disabled' -and
                    $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|VPN'
                }
        )
    } catch {
        return @()
    }
}

function Show-ProxyGuidance {
    param($Config)

    $proxyPort = if ($Config -and $Config.proxyPort) { [int]$Config.proxyPort } else { 8080 }

    Write-Step "Browser proxy guidance"
    Write-Host "NetFusion applies the Windows system proxy automatically when you start it with NetFusion-START.bat." -ForegroundColor White
    Write-Host "For browsers that use Windows proxy settings, you usually do not need to configure anything manually." -ForegroundColor White
    Write-Host ""
    Write-Host "If a browser or app needs manual proxy settings, use:" -ForegroundColor White
    Write-Host "  HTTP proxy : 127.0.0.1:$proxyPort" -ForegroundColor Green
    Write-Host "  HTTPS proxy: 127.0.0.1:$proxyPort" -ForegroundColor Green
    Write-Host ""
    Write-Host "Do not enable the proxy until NetFusion is actually running." -ForegroundColor Yellow
    Write-Host "Use NetFusion-STOP.bat or NetFusion-SAFE.bat if a browser is left pointing at a stopped proxy." -ForegroundColor Yellow
}

function Show-MetricGuidance {
    param([array]$Adapters)

    Write-Step "Adapter and routing guidance"
    if ($Adapters.Count -eq 0) {
        Write-Warn "No usable adapters were detected from Get-NetAdapter."
        return
    }

    try {
        $metrics = @(
            Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.ConnectionState -ne 'Disconnected' }
        )
    } catch {
        $metrics = @()
    }

    foreach ($adapter in $Adapters) {
        $metric = $metrics | Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex } | Select-Object -First 1
        if ($metric) {
            $metricMode = if ($metric.AutomaticMetric -eq 'Enabled') { 'Automatic' } else { 'Manual' }
            Write-Host ("  - {0} | Status={1} | Metric={2} ({3})" -f $adapter.Name, $adapter.Status, $metric.InterfaceMetric, $metricMode) -ForegroundColor White
        } else {
            Write-Host ("  - {0} | Status={1}" -f $adapter.Name, $adapter.Status) -ForegroundColor White
        }
    }

    Write-Host ""
    Write-Host "If you are using two adapters on the same router/subnet, Windows may still resist balancing traffic." -ForegroundColor White
    Write-Host "In that case, NetFusion's routing helpers may need to correct metrics before performance stabilizes." -ForegroundColor White
    Write-Host "Relevant tools: core\\RouteController.ps1, test-ecmp.ps1, and the built-in repair logic in the engine." -ForegroundColor Gray
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "    NETFUSION v6.0 -- FIRST-RUN SETUP                 " -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

Write-Step "Checking prerequisites"

if (-not (Test-IsAdmin)) {
    Write-Warn "This setup script is not running as Administrator."
    Write-Host "Some checks can still run, but NetFusion-START.bat and route/proxy operations should be run as Administrator." -ForegroundColor Yellow
} else {
    Write-Ok "Administrator rights detected."
}

if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Host "[FAIL] PowerShell 5.1 or newer is required. Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    exit 1
}
Write-Ok "PowerShell version $($PSVersionTable.PSVersion) is supported."

if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
Write-Ok "Project folders are present."

Write-Step "Preparing configuration"

if (-not (Test-Path $defaultConfigPath)) {
    Write-Host "[FAIL] Missing default config: $defaultConfigPath" -ForegroundColor Red
    exit 1
}

if ($ResetConfig -or -not (Test-Path $configPath)) {
    Copy-Item $defaultConfigPath $configPath -Force
    if ($ResetConfig) {
        Write-Ok "config.json was reset from config.default.json."
    } else {
        Write-Ok "config.json was created from config.default.json."
    }
} else {
    Write-Ok "config.json already exists."
}

try {
    $config = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Write-Ok "config.json loaded successfully."
} catch {
    Write-Host "[FAIL] config.json is invalid: $_" -ForegroundColor Red
    exit 1
}

Write-Host ("  Mode           : {0}" -f $config.mode) -ForegroundColor White
Write-Host ("  Proxy          : 127.0.0.1:{0}" -f $config.proxyPort) -ForegroundColor White
$dashProto = if ($config.dashboardTLS) { 'https' } else { 'http' }
Write-Host ("  Dashboard      : {0}://127.0.0.1:{1}" -f $dashProto, $config.dashboardPort) -ForegroundColor White
Write-Host ("  Thread pool    : {0}-{1}" -f $config.proxy.minThreads, $config.proxy.maxThreads) -ForegroundColor White
$capPerAdapter = if ($config.proxy.maxConcurrentPerAdapter) { $config.proxy.maxConcurrentPerAdapter } else { 48 }
Write-Host ("  Max conns/adapt: {0}" -f $capPerAdapter) -ForegroundColor White
Write-Host "  Main behavior file: config\\config.json" -ForegroundColor Gray

# v6.2: Generate dashboard token if missing or still using a weak legacy value
$tokenFile = Join-Path $configDir "dashboard-token.txt"
$legacyDashboardTokens = @(
    'mpKLZzFlE5tNi3Yw7gcID2QRu06BWjby'
)
$existingToken = if (Test-Path $tokenFile) { (Get-Content $tokenFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
if (-not (Test-Path $tokenFile) -or $existingToken.Length -lt 24 -or $existingToken -in $legacyDashboardTokens) {
    $newToken = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    Set-Content $tokenFile -Value $newToken -NoNewline -Force -Encoding UTF8
    Write-Ok "Dashboard token generated or rotated."
} else {
    Write-Ok "Dashboard token exists."
}

$adapters = Get-UsableAdapters

Write-Step "Checking adapters"
if ($adapters.Count -lt 1) {
    Write-Warn "No usable physical adapters were detected. NetFusion will not be able to route traffic correctly."
} elseif ($adapters.Count -eq 1) {
    Write-Warn "Only one usable adapter was detected. NetFusion can still run, but aggregation benefits will be limited."
} else {
    Write-Ok "$($adapters.Count) usable adapters detected."
}

foreach ($adapter in $adapters) {
    Write-Host ("  - {0} | Status={1} | LinkSpeed={2}" -f $adapter.Name, $adapter.Status, $adapter.LinkSpeed) -ForegroundColor White
}

Show-MetricGuidance -Adapters $adapters
Show-ProxyGuidance -Config $config

Write-Step "Next steps"
Write-Host "1. Review config\\config.json if you want to change ports, mode, or proxy thread settings." -ForegroundColor White
Write-Host "2. Start NetFusion with NetFusion-START.bat as Administrator." -ForegroundColor White
Write-Host "3. Open the dashboard at http://127.0.0.1:$($config.dashboardPort). It should open directly on the local machine." -ForegroundColor White
Write-Host "4. If you see same-subnet routing issues, review adapter metrics or run the routing helpers noted above." -ForegroundColor White

Write-Host ""
Write-Host "Setup completed." -ForegroundColor Green
