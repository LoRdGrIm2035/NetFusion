<#
.SYNOPSIS
    NetFusionControl -- reliable orchestration for START / STOP / SAFE flows.
#>

[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Safe')]
    [string]$Action,
    [switch]$SkipAdminCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:ProjectDir = Split-Path $script:ScriptDir -Parent
$script:ConfigDir = Join-Path $script:ProjectDir 'config'
$script:LogsDir = Join-Path $script:ProjectDir 'logs'
$script:RuntimeStateFile = Join-Path $script:ConfigDir 'runtime-state.json'
$script:SafetyStateFile = Join-Path $script:ConfigDir 'safety-state.json'
$script:ProxyStatsFile = Join-Path $script:ConfigDir 'proxy-stats.json'
$script:WatchdogHeartbeatFile = Join-Path $script:ConfigDir 'watchdog-heartbeat.json'
$script:ComponentRegex = '(?i)(NetFusionEngine|NetFusionWatchdog|DashboardServer|SmartProxy|InterfaceMonitor|NetworkManager|RouteController|LearningEngine|QuicBlocker)\.ps1'
$script:ProjectRegex = [regex]::Escape($script:ProjectDir)

if (-not (Test-Path $script:LogsDir)) {
    New-Item -ItemType Directory -Path $script:LogsDir -Force | Out-Null
}

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host "[$Text]" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "  - $Text" -ForegroundColor Gray
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Read-JsonFile {
    param(
        [string]$Path,
        [object]$DefaultValue = $null
    )
    if (-not (Test-Path $Path)) { return $DefaultValue }
    try {
        return (Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $DefaultValue
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 6
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ([System.IO.Path]::GetRandomFileName())
    try {
        $Data | ConvertTo-Json -Depth $Depth -Compress | Set-Content -Path $tmp -Encoding UTF8 -Force -ErrorAction Stop
        Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-IntOrDefault {
    param([object]$Value, [int]$Default)
    if ($null -eq $Value) { return $Default }
    try {
        return [int]$Value
    } catch {
        return $Default
    }
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )
    if ($null -eq $Object) { return $DefaultValue }
    try {
        $prop = $Object.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
    } catch {}
    return $DefaultValue
}

function Get-CurrentConfig {
    $cfg = Read-JsonFile -Path (Join-Path $script:ConfigDir 'config.json') -DefaultValue $null
    if (-not $cfg) {
        $cfg = Read-JsonFile -Path (Join-Path $script:ConfigDir 'config.default.json') -DefaultValue ([pscustomobject]@{})
    }
    return [pscustomobject]@{
        proxyPort = Get-IntOrDefault (Get-ObjectPropertyValue -Object $cfg -Name 'proxyPort' -DefaultValue 8080) 8080
        dashboardPort = Get-IntOrDefault (Get-ObjectPropertyValue -Object $cfg -Name 'dashboardPort' -DefaultValue 9090) 9090
        startupTimeoutSec = Get-IntOrDefault (Get-ObjectPropertyValue -Object $cfg -Name 'startupTimeoutSec' -DefaultValue 20) 20
    }
}

function Get-NetFusionCimProcesses {
    try {
        return @(
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.Name -match '^(powershell|pwsh)\.exe$') -and
                    $_.CommandLine -and
                    ($_.CommandLine -match $script:ProjectRegex) -and
                    ($_.CommandLine -match $script:ComponentRegex)
                }
        )
    } catch {
        return @()
    }
}

function Test-IsNetFusionPid {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
        if (-not $proc -or -not $proc.CommandLine) { return $false }
        return (($proc.CommandLine -match $script:ProjectRegex) -and ($proc.CommandLine -match $script:ComponentRegex))
    } catch {
        return $false
    }
}

function Get-ListeningPids {
    param([int]$Port)
    $pids = @()
    try {
        $pids += @(
            Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty OwningProcess -Unique
        )
    } catch {}
    if (@($pids).Count -eq 0) {
        try {
            $lines = netstat -ano -p tcp 2>$null | Select-String "LISTENING"
            foreach ($line in $lines) {
                if ($line.Line -match "^\s*TCP\s+\S+:$Port\s+\S+\s+LISTENING\s+(\d+)\s*$") {
                    $pids += [int]$Matches[1]
                }
            }
        } catch {}
    }
    return @($pids | Where-Object { $_ -and $_ -gt 0 } | Sort-Object -Unique)
}

function Test-PortListening {
    param(
        [int]$Port,
        [int]$ExpectedPid = 0
    )
    $owners = Get-ListeningPids -Port $Port
    if ($ExpectedPid -gt 0) {
        return ($owners -contains $ExpectedPid)
    }
    return (@($owners).Count -gt 0)
}

function Get-NetFusionPortOwners {
    param([int]$Port)
    $owners = @()
    foreach ($ownerPid in @(Get-ListeningPids -Port $Port)) {
        if (Test-IsNetFusionPid -ProcessId $ownerPid) {
            $owners += $ownerPid
        }
    }
    return @($owners | Sort-Object -Unique)
}

function Wait-PortState {
    param(
        [int]$Port,
        [bool]$ShouldListen,
        [int]$TimeoutSec = 20,
        [int]$ExpectedPid = 0
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $isListening = Test-PortListening -Port $Port -ExpectedPid $ExpectedPid
        if ($ShouldListen) {
            if ($isListening) { return $true }
        } else {
            if (-not (Test-PortListening -Port $Port)) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Wait-NetFusionPortClear {
    param(
        [int]$Port,
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-NetFusionPortOwners -Port $Port).Count -eq 0) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Test-ProxyHealth {
    param([int]$Port)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(3000, $false)) { $tcp.Dispose(); return $false }
        try { $tcp.EndConnect($ar) } catch { $tcp.Dispose(); return $false }
        if (-not $tcp.Connected) { $tcp.Dispose(); return $false }
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 3000
        $stream.WriteTimeout = 3000
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("GET /health HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $buffer = New-Object byte[] 256
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $tcp.Dispose()
        if ($read -le 0) { return $false }
        $resp = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        return ($resp -match 'HTTP/1\.[01] 200')
    } catch {
        return $false
    }
}

function Test-ProxyForward {
    param([int]$Port)
    $targets = @('www.gstatic.com:443', 'connectivity-check.ubuntu.com:443', 'www.cloudflare.com:443')
    foreach ($target in $targets) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne(3000, $false)) { $tcp.Dispose(); continue }
            try { $tcp.EndConnect($ar) } catch { $tcp.Dispose(); continue }
            if (-not $tcp.Connected) { $tcp.Dispose(); continue }
            $stream = $tcp.GetStream()
            $stream.ReadTimeout = 5000
            $stream.WriteTimeout = 5000
            $req = [System.Text.Encoding]::ASCII.GetBytes("CONNECT $target HTTP/1.1`r`nHost: $target`r`n`r`n")
            $stream.Write($req, 0, $req.Length)
            $stream.Flush()
            $buffer = New-Object byte[] 256
            $read = $stream.Read($buffer, 0, $buffer.Length)
            $tcp.Dispose()
            if ($read -gt 0) {
                $resp = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
                if ($resp -match 'HTTP/1\.[01] 200') { return $true }
            }
        } catch {}
    }
    return $false
}

function Test-DirectInternet {
    $pingOk = $false
    $httpOk = $false
    try {
        $p = New-Object Net.NetworkInformation.Ping
        $r1 = $p.Send('8.8.8.8', 3000)
        $r2 = $p.Send('1.1.1.1', 3000)
        $pingOk = (($r1 -and $r1.Status -eq 'Success') -or ($r2 -and $r2.Status -eq 'Success'))
        $p.Dispose()
    } catch {}
    try {
        $resp = Invoke-WebRequest -Uri 'http://connectivity-check.ubuntu.com' -UseBasicParsing -TimeoutSec 8
        $httpOk = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500)
    } catch {}
    return ($pingOk -or $httpOk)
}

function Test-InternetViaProxy {
    param([int]$Port)
    try {
        $resp = Invoke-WebRequest -Uri 'http://connectivity-check.ubuntu.com' -Proxy ("http://127.0.0.1:{0}" -f $Port) -UseBasicParsing -TimeoutSec 8
        return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500)
    } catch {
        return $false
    }
}

function Set-SystemProxyDisabled {
    $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        Set-ItemProperty -Path $inetKey -Name 'ProxyEnable' -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $inetKey -Name 'ProxyServer' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $inetKey -Name 'ProxyOverride' -Force -ErrorAction SilentlyContinue
    } catch {}
    try { & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyEnable /t REG_DWORD /d 0 /f 2>$null | Out-Null } catch {}
    try { & reg.exe delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyServer /f 2>$null | Out-Null } catch {}
    try { & reg.exe delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /v ProxyOverride /f 2>$null | Out-Null } catch {}
}

function Set-SystemProxyEnabled {
    param([int]$Port)
    $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -Path $inetKey -Name 'ProxyEnable' -Type DWord -Value 1 -Force
    Set-ItemProperty -Path $inetKey -Name 'ProxyServer' -Type String -Value ("127.0.0.1:{0}" -f $Port) -Force
    Set-ItemProperty -Path $inetKey -Name 'ProxyOverride' -Type String -Value '<local>;127.0.0.1;localhost;::1' -Force
}

function Set-IdmDirect {
    $idmKey = 'HKCU:\Software\DownloadManager'
    if (-not (Test-Path $idmKey)) { return }
    try {
        Set-ItemProperty -Path $idmKey -Name 'nProxyMode' -Type DWord -Value 1 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'UseHttpProxy' -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'nHttpPrChbSt' -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'UseHttpsProxy' -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'nHttpsPrChbSt' -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Set-IdmProxy {
    param([int]$Port)
    $idmKey = 'HKCU:\Software\DownloadManager'
    if (-not (Test-Path $idmKey)) { return }
    try {
        Set-ItemProperty -Path $idmKey -Name 'nProxyMode' -Type DWord -Value 2 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'UseHttpProxy' -Type DWord -Value 1 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'HttpProxyAddr' -Type String -Value '127.0.0.1' -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'HttpProxyPort' -Type DWord -Value $Port -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'nHttpPrChbSt' -Type DWord -Value 1 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'UseHttpsProxy' -Type DWord -Value 1 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'HttpsProxyAddr' -Type String -Value '127.0.0.1' -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'HttpsProxyPort' -Type DWord -Value $Port -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $idmKey -Name 'nHttpsPrChbSt' -Type DWord -Value 1 -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Stop-NetFusionProcesses {
    Write-Step "Stopping NetFusion PowerShell processes"
    foreach ($proc in @(Get-NetFusionCimProcesses)) {
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }

    foreach ($title in @('NF-Engine*', 'NF-Watchdog*', 'NF-Dashboard*', 'NF-SmartProxy*', 'NF-RouteController*', 'NF-InterfaceMonitor*', 'NF-NetworkManager*')) {
        try { & taskkill /FI "WINDOWTITLE eq $title" /F >$null 2>&1 } catch {}
    }
}

function Get-NetFusionWindowProcesses {
    $results = @()
    try {
        $rows = tasklist /v /fo csv /nh 2>$null
        foreach ($row in @($rows)) {
            if ([string]::IsNullOrWhiteSpace($row)) { continue }
            if ($row -notmatch '^"([^"]*)","(\d+)","[^"]*","[^"]*","[^"]*","[^"]*","[^"]*","[^"]*","([^"]*)"$') { continue }
            $imageName = [string]$Matches[1]
            $procId = 0
            try { [void][int]::TryParse([string]$Matches[2], [ref]$procId) } catch {}
            $windowTitle = [string]$Matches[3]
            if ($windowTitle -match '^(?i)NF-(Engine|Watchdog|Dashboard|SmartProxy|RouteController|InterfaceMonitor|NetworkManager)') {
                $results += [pscustomobject]@{
                    ProcessId = $procId
                    ImageName = $imageName
                    WindowTitle = $windowTitle
                }
            }
        }
    } catch {}
    return @($results)
}

function Ensure-PortNotOwnedByNetFusion {
    param([int]$Port)
    foreach ($ownerPid in @(Get-ListeningPids -Port $Port)) {
        if (Test-IsNetFusionPid -ProcessId $ownerPid) {
            try { Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Restore-NetworkBaseline {
    Write-Step "Clearing proxy and restoring direct networking"
    Set-SystemProxyDisabled
    Set-IdmDirect

    try {
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback|Bluetooth|WAN Miniport|Tunnel|OpenVPN|WireGuard|TAP-Windows|Cisco AnyConnect|Tailscale|ZeroTier' } |
            ForEach-Object {
                Set-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue
            }
    } catch {}

    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptDir 'Cleanup-OnCrash.ps1') | Out-Null } catch {}
    try { Remove-Item (Join-Path $script:ConfigDir 'routes-applied.flag') -Force -ErrorAction SilentlyContinue } catch {}
    try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { try { ipconfig /flushdns 2>$null | Out-Null } catch {} }
}

function Set-SafetyState {
    param([bool]$SafeMode, [string]$EventText)
    $data = @{
        safeMode = $SafeMode
        circuitBreakerOpen = $SafeMode
        proxyHealthy = $false
        version = '6.2'
        lastEvent = $EventText
        timestamp = (Get-Date).ToString('o')
    }
    Write-JsonFile -Path $script:SafetyStateFile -Data $data -Depth 4
}

function Save-RuntimeState {
    param([int]$ProxyPort, [int]$DashboardPort, [int[]]$Pids)
    $data = @{
        timestamp = (Get-Date).ToString('o')
        proxyPort = $ProxyPort
        dashboardPort = $DashboardPort
        pids = @($Pids | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    }
    Write-JsonFile -Path $script:RuntimeStateFile -Data $data -Depth 4
}

function Register-CrashRecoveryTask {
    try {
        $action = New-ScheduledTaskAction -Execute 'reg.exe' -Argument 'add HKCU\Software\Microsoft\Windows\CurrentVersion\Internet` Settings /v ProxyEnable /t REG_DWORD /d 0 /f'
        $trigger1 = New-ScheduledTaskTrigger -AtLogOn
        $trigger2 = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName 'NetFusion-CrashRecovery' -Action $action -Trigger @($trigger1, $trigger2) -Settings $settings -Description 'Clears proxy if NetFusion crashed.' -Force | Out-Null
    } catch {}
}

function Unregister-CrashRecoveryTask {
    try { Unregister-ScheduledTask -TaskName 'NetFusion-CrashRecovery' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

function Wait-WatchdogHeartbeat {
    param([int]$TimeoutSec = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $script:WatchdogHeartbeatFile) {
            $obj = Read-JsonFile -Path $script:WatchdogHeartbeatFile -DefaultValue $null
            if ($obj -and $obj.timestamp) {
                try {
                    $ts = [datetime]$obj.timestamp
                    if (((Get-Date) - $ts).TotalSeconds -lt 8) { return $true }
                } catch {}
            }
            if (((Get-Date) - (Get-Item $script:WatchdogHeartbeatFile).LastWriteTime).TotalSeconds -lt 8) {
                return $true
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Invoke-NetFusionStopCore {
    param(
        [bool]$SetSafeMode,
        [bool]$ValidateInternet,
        [string]$ModeLabel = 'Stop'
    )
    $cfg = Get-CurrentConfig
    $proxyPort = [int]$cfg.proxyPort
    $dashboardPort = [int]$cfg.dashboardPort

    Write-Section "NetFusion $ModeLabel"
    Set-SystemProxyDisabled
    Set-IdmDirect
    Stop-NetFusionProcesses
    Ensure-PortNotOwnedByNetFusion -Port $proxyPort
    Ensure-PortNotOwnedByNetFusion -Port $dashboardPort
    [void](Wait-NetFusionPortClear -Port $proxyPort -TimeoutSec 15)
    [void](Wait-NetFusionPortClear -Port $dashboardPort -TimeoutSec 15)
    Restore-NetworkBaseline
    Unregister-CrashRecoveryTask

    try { Write-JsonFile -Path $script:ProxyStatsFile -Data @{ running = $false; timestamp = (Get-Date).ToString('o') } -Depth 3 } catch {}
    try { Remove-Item $script:RuntimeStateFile -Force -ErrorAction SilentlyContinue } catch {}

    if ($SetSafeMode) {
        Set-SafetyState -SafeMode $true -EventText 'Emergency safe mode activated'
    } else {
        try { Remove-Item $script:SafetyStateFile -Force -ErrorAction SilentlyContinue } catch {}
    }

    if ($ValidateInternet) {
        $ok = Test-DirectInternet
        if (-not $ok) {
            Write-Host '  [FAIL] Direct internet validation failed after stop/safe cleanup.' -ForegroundColor Red
            return $false
        }
    }

    $proxyOwners = @(Get-ListeningPids -Port $proxyPort)
    $netFusionProxyOwners = @(Get-NetFusionPortOwners -Port $proxyPort)
    if ($netFusionProxyOwners.Count -gt 0) {
        Write-Host ("  [FAIL] Proxy port {0} is still owned by NetFusion PID(s): {1}" -f $proxyPort, ($netFusionProxyOwners -join ', ')) -ForegroundColor Red
        return $false
    }
    if ($proxyOwners.Count -gt 0) {
        Write-Host ("  [WARN] Port {0} remains in use by external process(es): {1}" -f $proxyPort, ($proxyOwners -join ', ')) -ForegroundColor Yellow
    }

    $windowProcesses = @(Get-NetFusionWindowProcesses)
    if ($windowProcesses.Count -gt 0) {
        $labels = @($windowProcesses | ForEach-Object { "$($_.WindowTitle) [PID $($_.ProcessId)]" })
        Write-Host ("  [FAIL] NetFusion window process(es) still active: {0}" -f ($labels -join '; ')) -ForegroundColor Red
        return $false
    }

    Write-Host '  [OK] Cleanup complete. System returned to direct networking.' -ForegroundColor Green
    return $true
}

function Invoke-NetFusionStart {
    $cfg = Get-CurrentConfig
    $proxyPort = [int]$cfg.proxyPort
    $dashboardPort = [int]$cfg.dashboardPort
    $startupTimeoutSec = [math]::Max(10, [int]$cfg.startupTimeoutSec)

    Write-Section 'NetFusion Start'
    Write-Step "Config: proxy port $proxyPort, dashboard port $dashboardPort, timeout ${startupTimeoutSec}s"

    Write-Step 'Running config validator'
    $validator = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script:ScriptDir\ConfigValidator.ps1`"" -PassThru -Wait -WindowStyle Hidden
    if ($validator.ExitCode -ne 0) {
        throw "ConfigValidator failed with exit code $($validator.ExitCode)."
    }

    $cfg = Get-CurrentConfig
    $proxyPort = [int]$cfg.proxyPort
    $dashboardPort = [int]$cfg.dashboardPort
    $startupTimeoutSec = [math]::Max(10, [int]$cfg.startupTimeoutSec)

    Write-Step 'Pre-cleaning stale state/processes'
    Set-SystemProxyDisabled
    Set-IdmDirect
    Stop-NetFusionProcesses
    Ensure-PortNotOwnedByNetFusion -Port $proxyPort
    Ensure-PortNotOwnedByNetFusion -Port $dashboardPort
    [void](Wait-NetFusionPortClear -Port $proxyPort -TimeoutSec 10)
    [void](Wait-NetFusionPortClear -Port $dashboardPort -TimeoutSec 10)

    $proxyOwners = @(Get-ListeningPids -Port $proxyPort)
    if ($proxyOwners.Count -gt 0) {
        throw "Proxy port $proxyPort is already used by process(es): $($proxyOwners -join ', ')."
    }
    $dashboardOwners = @(Get-ListeningPids -Port $dashboardPort)
    if ($dashboardOwners.Count -gt 0) {
        throw "Dashboard port $dashboardPort is already used by process(es): $($dashboardOwners -join ', ')."
    }
    $windowProcesses = @(Get-NetFusionWindowProcesses)
    if ($windowProcesses.Count -gt 0) {
        $labels = @($windowProcesses | ForEach-Object { "$($_.WindowTitle) [PID $($_.ProcessId)]" })
        throw "NetFusion process window(s) still active: $($labels -join '; ')."
    }

    Write-Step 'Starting NetFusion engine'
    $engineProc = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script:ScriptDir\NetFusionEngine.ps1`"" -PassThru -WindowStyle Hidden
    if (-not (Wait-PortState -Port $proxyPort -ShouldListen:$true -TimeoutSec $startupTimeoutSec)) {
        throw "Proxy port $proxyPort did not become ready."
    }
    if (-not (Test-ProxyHealth -Port $proxyPort)) {
        throw "Proxy /health endpoint check failed."
    }
    if (-not (Test-ProxyForward -Port $proxyPort)) {
        throw "Proxy forward CONNECT test failed."
    }

    Write-Step 'Starting watchdog'
    $watchdogProc = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script:ScriptDir\NetFusionWatchdog.ps1`"" -PassThru -WindowStyle Hidden
    if (-not (Wait-WatchdogHeartbeat -TimeoutSec 15)) {
        throw 'Watchdog heartbeat did not appear.'
    }

    Write-Step 'Applying system proxy and IDM proxy settings'
    Set-SystemProxyEnabled -Port $proxyPort
    Set-IdmProxy -Port $proxyPort

    Write-Step 'Starting dashboard'
    $dashboardProc = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script:ProjectDir\dashboard\DashboardServer.ps1`" -Port $dashboardPort" -PassThru -WindowStyle Hidden
    if (-not (Wait-PortState -Port $dashboardPort -ShouldListen:$true -TimeoutSec 20 -ExpectedPid $dashboardProc.Id)) {
        throw "Dashboard failed to bind to port $dashboardPort."
    }

    Register-CrashRecoveryTask
    Set-SafetyState -SafeMode $false -EventText 'Normal startup requested'

    if (-not (Test-InternetViaProxy -Port $proxyPort)) {
        throw 'Internet validation through proxy failed after startup.'
    }

    Save-RuntimeState -ProxyPort $proxyPort -DashboardPort $dashboardPort -Pids @($engineProc.Id, $watchdogProc.Id, $dashboardProc.Id)
    Write-Host '  [OK] NetFusion started successfully and proxy path validated.' -ForegroundColor Green
    return $true
}

try {
    if (-not $SkipAdminCheck -and -not (Test-IsAdministrator)) {
        throw 'Administrator privileges are required.'
    }

    $ok = $false
    switch ($Action) {
        'Start' {
            try {
                $ok = Invoke-NetFusionStart
            } catch {
                Write-Host ("  [FAIL] Start failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-Step 'Rolling back to safe direct internet state'
                $null = Invoke-NetFusionStopCore -SetSafeMode:$false -ValidateInternet:$true -ModeLabel 'Rollback'
                $ok = $false
            }
        }
        'Stop' {
            $ok = Invoke-NetFusionStopCore -SetSafeMode:$false -ValidateInternet:$true -ModeLabel 'Stop'
        }
        'Safe' {
            $ok = Invoke-NetFusionStopCore -SetSafeMode:$true -ValidateInternet:$true -ModeLabel 'Safe'
        }
    }

    if ($ok) { exit 0 }
    exit 1
} catch {
    Write-Host ("[FATAL] {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
