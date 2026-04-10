<#
.SYNOPSIS
    LogRotation v5.0 -- Atomic Ring-Buffer for events.json
.DESCRIPTION
    Ensures logs/events.json does not exceed 500 entries to prevent memory
    bloat in the Dashboard SSE streamer. Runs iteratively, safely parsing and clipping arrays.
#>

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectDir = Split-Path $scriptDir -Parent
$eventsFile = Join-Path $projectDir "logs\events.json"

try {
    $mutex = New-Object System.Threading.Mutex($false, "NetFusion-LogWrite")
    try {
        $mutex.WaitOne(3000) | Out-Null
        if (Test-Path $eventsFile) {
            $data = Get-Content $eventsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($data -and $data.events -and $data.events.Count -gt 500) {
                $events = @($data.events)[0..499]
                $tmp = [System.IO.Path]::GetTempFileName()
                @{ events = $events } | ConvertTo-Json -Depth 3 -Compress | Set-Content $tmp -Force -ErrorAction Stop
                Move-Item $tmp $eventsFile -Force -ErrorAction Stop
                Write-Host "  [LogRotation] Clipped events.json to 500 entries." -ForegroundColor DarkGray
            }
        }
    } finally {
        $mutex.ReleaseMutex()
    }
} catch {
    # Fail silently to not interrupt active processes
}
