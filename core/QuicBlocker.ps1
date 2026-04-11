<#
.SYNOPSIS
<<<<<<< HEAD
    QuicBlocker v5.0 -- UDP 443 Firewall Manager
=======
    QuicBlocker v6.0 -- UDP 443 Firewall Manager
>>>>>>> origin/main
.DESCRIPTION
    Modern browsers attempt to use QUIC (UDP 443) for Google/YouTube/Cloudflare.
    NetFusion TCP proxies CANNOT route UDP. This script explicitly creates an
    outbound Windows Firewall rule to strictly block UDP 443 globally, 
    forcing all modern browsers to instantly fallback to TCP (HTTP/2), 
    which allows NetFusion to perfectly load balance them.
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectDir = Split-Path $scriptDir -Parent
$configPath = Join-Path $projectDir "config\config.json"
$eventsFile = Join-Path $projectDir "logs\events.json"

function Write-QuicEvent {
    param([string]$Message)
    Write-Host "  [QUIC] $Message" -ForegroundColor Cyan
    try {
        if (-not (Test-Path $eventsFile)) { return }
        $mutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")
        try {
            $mutex.WaitOne(3000) | Out-Null
            $data = Get-Content $eventsFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            $events = if ($data -and $data.events) { @($data.events) } else { @() }
            $evt = @{ timestamp = (Get-Date).ToString('o'); type = 'system'; adapter = ''; message = $Message; level = 'info' }
            $events = @($evt) + $events
            if ($events.Count -gt 200) { $events = $events[0..199] }
            
            $tmp = [System.IO.Path]::GetTempFileName()
            @{ events = $events } | ConvertTo-Json -Depth 3 -Compress | Set-Content $tmp -Force -Encoding UTF8 -ErrorAction SilentlyContinue
            Move-Item $tmp $eventsFile -Force -ErrorAction SilentlyContinue
        } finally {
            $mutex.ReleaseMutex()
        }
    } catch {}
}

$ruleName = "NetFusion_Block_QUIC"

try {
    $config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
    
<<<<<<< HEAD
    # If the config specifies blockQUICOnSecondaryAdapters, we block it globally to guarantee TCP fallback
    $shouldBlock = if ($config -and $config.routing -and $config.routing.blockQUICOnSecondaryAdapters) { $true } else { $false }
=======
    # v6.0 #12: Fix — key is at root level, not nested under routing
    $shouldBlock = if ($config -and $config.blockQUICOnSecondaryAdapters -eq $true) { $true } else { $false }
>>>>>>> origin/main
    
    $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    
    $sentinelFile = Join-Path $projectDir "config\active-fw-rules.json"

    if ($shouldBlock) {
        if (-not $existingRule) {
            Write-QuicEvent "Creating Windows Firewall Rule to strict-block UDP 443 (Forcing HTTP/2 Fallback)"
            New-NetFirewallRule -DisplayName $ruleName `
                -Description "NetFusion: Forces browsers to fallback to TCP for proxy load-balancing" `
                -Direction Outbound `
                -Protocol UDP `
                -RemotePort 443 `
                -Action Block `
                -Profile Any `
                -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [+] QUIC strictly blocked." -ForegroundColor Green
        } else {
            Write-Host "  [+] QUIC firewall rule already enforcing." -ForegroundColor DarkGray
        }
<<<<<<< HEAD
        # [FIX-B] Write active firewall rules to sentinel
        @{ rules = @($ruleName); created = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Set-Content $sentinelFile -Force
=======
        # Atomic sentinel write
        $tmp = [IO.Path]::GetTempFileName()
        @{ rules = @($ruleName); created = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Set-Content $tmp -Force -Encoding UTF8
        Move-Item $tmp $sentinelFile -Force
>>>>>>> origin/main
    } else {
        if ($existingRule) {
            Write-QuicEvent "Removing QUIC Firewall Rule (Disabled in config)"
            Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            Write-Host "  [-] QUIC block removed." -ForegroundColor DarkGray
        }
<<<<<<< HEAD
        @{ rules = @(); created = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Set-Content $sentinelFile -Force
=======
        $tmp = [IO.Path]::GetTempFileName()
        @{ rules = @(); created = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Set-Content $tmp -Force -Encoding UTF8
        Move-Item $tmp $sentinelFile -Force
>>>>>>> origin/main
    }
} catch {
    Write-Host "  [QUIC] Failed to manage firewall bounds: $_" -ForegroundColor Red
}
