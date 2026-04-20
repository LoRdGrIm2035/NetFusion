<#
.SYNOPSIS
    NetFusionWatchdog v6.2 -- Failsafe Guardian
.DESCRIPTION
    A micro-script that ensures if NetFusionEngine dies or port 8080 stops responding,
    the system instantly clears the Windows proxy, preventing the "No Internet" offline state.
#>

[CmdletBinding()]
param()

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$logsDir = Join-Path $projectDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$watchdogFailLog = Join-Path $logsDir "watchdog-fail.txt"

$proxyPort = 8080
$failCount = 0

Write-Host "  [Watchdog] Active. Guarding proxy on port $proxyPort..." -ForegroundColor Cyan

function Write-WatchdogFailureLog {
    param([string]$Message)
    $ts = (Get-Date).ToString('o')
    try {
        Add-Content -Path $watchdogFailLog -Value "[$ts] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Set-RegistryValueVerified {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string]$Type = 'String'
    )

    try {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        $actual = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        if ([string]$actual -ne [string]$Value) {
            Write-WatchdogFailureLog "Registry verify failed for $Path::$Name (expected '$Value', got '$actual')."
        }
    } catch {
        Write-WatchdogFailureLog "Registry write failed for $Path::$Name -> $($_.Exception.Message)"
    }
}

function Clear-Proxy {
    Write-Host "  [Watchdog] Critical Failure Detected! Clearing proxy..." -ForegroundColor Red
    try {
        $inetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Set-RegistryValueVerified -Path $inetKey -Name 'ProxyEnable' -Value 0 -Type DWord
        Remove-ItemProperty -Path $inetKey -Name 'ProxyServer' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $inetKey -Name 'ProxyOverride' -Force -ErrorAction SilentlyContinue
        
        $idmKey = 'HKCU:\Software\DownloadManager'
        if (Test-Path $idmKey) {
            Set-RegistryValueVerified -Path $idmKey -Name 'nProxyMode' -Value 1 -Type DWord
            Set-RegistryValueVerified -Path $idmKey -Name 'UseHttpProxy' -Value 0 -Type DWord
            Set-RegistryValueVerified -Path $idmKey -Name 'UseHttpsProxy' -Value 0 -Type DWord
        }
        Write-Host "  [Watchdog] Direct internet restored successfully." -ForegroundColor Green
    } catch {
        Write-Host "  [Watchdog] Failed to clear proxy! $_" -ForegroundColor Red
    }
}

while ($true) {
    Start-Sleep -Seconds 3

    # Check whether proxy port is listening.
    $isListening = $false
    try {
        $isListening = @(
            Get-NetTCPConnection -LocalPort $proxyPort -State Listen -ErrorAction Stop
        ).Count -gt 0
    } catch {
        try {
            $isListening = [bool](netstat -ano | Select-String ":$proxyPort\s+.*LISTENING")
        } catch {}
    }

    # CommandLine matching can be brittle. Use a broad liveness signal:
    # at least one powershell.exe process older than 5 seconds.
    $engineProcs = @(
        Get-Process -Name powershell -ErrorAction SilentlyContinue |
            Where-Object {
                try { ((Get-Date) - $_.StartTime).TotalSeconds -gt 5 } catch { $false }
            }
    )

    if (-not $isListening -or $engineProcs.Count -eq 0) {
        $failCount++
        if ($failCount -ge 2) {
            Clear-Proxy

            # Attempt to kill lingering NetFusion engine process only.
            $netFusionEngineProcs = @(
                Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine -match 'NetFusionEngine' }
            )
            foreach ($p in $netFusionEngineProcs) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            }
            exit 1
        }
    } else {
        $failCount = 0
    }
}
