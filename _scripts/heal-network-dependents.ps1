#Requires -Version 5.0

<#
.SYNOPSIS
Self-heals containers that share another container's network namespace
(network_mode: service:X) after that container gets recreated under them.

.DESCRIPTION
qBittorrent and slskd both use `network_mode: service:gluetun` to route
their traffic through the VPN - Docker binds that to gluetun's specific
container ID at creation time, not its name. Whenever gluetun gets
recreated for any reason (a Docker Desktop/WSL2 restart, a host reboot,
a manual `docker compose up --force-recreate gluetun`, etc.) without
qBittorrent/slskd being recreated at the same time, their stale
reference breaks: they exit and a plain `docker start` or the normal
`restart: unless-stopped` policy can't fix it, since the container ID
they're bound to no longer exists. Confirmed live - this is exactly
what happened here, and it wasn't Watchtower's fault (its own logs
showed it correctly left gluetun alone, pinned to an exact version tag;
something else recreated it). The only real fix is recreating the
dependent via `docker compose up -d`, which re-resolves the reference
to gluetun's current container - this script automates exactly that,
on a schedule, so it self-heals instead of sitting broken for hours.

.EXAMPLE
.\heal-network-dependents.ps1
.\heal-network-dependents.ps1 -GotifyUrl "https://gotify.example.com" -GotifyToken "..."
#>

param(
    [switch]$Quiet = $false,
    [string]$GotifyUrl = "",
    [string]$GotifyToken = ""
)

function Say {
    param([string]$Text = "", [string]$Color = "White")
    if ($Quiet) { return }
    Write-Host $Text -ForegroundColor $Color
}

function Send-GotifyNotification {
    param([string]$Title, [string]$Message, [int]$Priority = 6)
    if ([string]::IsNullOrEmpty($GotifyUrl) -or [string]::IsNullOrEmpty($GotifyToken)) { return }
    try {
        $body = @{ title = $Title; message = $Message; priority = $Priority } | ConvertTo-Json
        Invoke-RestMethod -Uri "$GotifyUrl/message?token=$GotifyToken" -Method Post -Body $body -ContentType "application/json" | Out-Null
    } catch {
        Say "  (Gotify notification failed: $_)" "Yellow"
    }
}

# Add an entry here for any future service that uses
# network_mode: service:<Target> - qbittorrent, slskd and flaresolverr
# today (all in media-stack, all riding gluetun's VPN tunnel).
$dependents = @(
    @{ Stack = "media-stack"; Service = "qbittorrent";  Container = "qbittorrent";  Target = "gluetun" }
    @{ Stack = "media-stack"; Service = "slskd";        Container = "slskd";        Target = "gluetun" }
    @{ Stack = "media-stack"; Service = "flaresolverr"; Container = "flaresolverr"; Target = "gluetun" }
)

$appRoot = Split-Path -Parent $PSScriptRoot

# Scheduled tasks often run with a leaner PATH than an interactive
# session - confirmed live, "docker" alone silently resolved to nothing
# here even though Docker Desktop was running, which would otherwise
# make every check below look like "nothing to heal" instead of
# reporting the real failure. Fall back to the well-known install path
# rather than assume PATH has it.
$docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
if (-not $docker) {
    $fallback = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path $fallback) { $docker = $fallback }
}
if (-not $docker) {
    Say "docker executable not found (not on PATH, not at the default Docker Desktop install path) - cannot check anything" "Red"
    Send-GotifyNotification -Title "Homelab: heal-network-dependents failed" -Message "docker executable not found - script cannot run" -Priority 8
    exit 1
}

$healed = @()
$stillBroken = @()

foreach ($dep in $dependents) {
    $targetState = & $docker inspect $dep.Target --format '{{.State.Running}}' 2>$null
    if ($targetState -ne "true") {
        # Target itself isn't up - not this script's problem, health-check.ps1 covers that.
        continue
    }

    $depState = & $docker inspect $dep.Container --format '{{.State.Running}}' 2>$null
    if ($depState -eq "true") {
        continue
    }

    Say "$($dep.Container) is down while $($dep.Target) is running - likely a stale network-namespace reference, recreating..." "Yellow"
    $stackPath = Join-Path $appRoot $dep.Stack
    Push-Location $stackPath
    try {
        $result = & $docker compose up -d $dep.Service 2>&1
        Start-Sleep -Seconds 5
        $newState = & $docker inspect $dep.Container --format '{{.State.Running}}' 2>$null
        if ($newState -eq "true") {
            Say "  $($dep.Container) recovered" "Green"
            $healed += $dep.Container
        } else {
            Say "  $($dep.Container) still not running after recreation attempt - needs manual investigation" "Red"
            Say "  $result" "Red"
            $stillBroken += $dep.Container
        }
    } finally {
        Pop-Location
    }
}

if ($healed.Count -eq 0 -and $stillBroken.Count -eq 0) {
    Say "Nothing to heal - all network-namespace dependents are running." "Green"
    exit 0
}

if ($healed.Count -gt 0) {
    Send-GotifyNotification -Title "Homelab: auto-healed network dependents" -Message "Recreated: $($healed -join ', ')" -Priority 5
}
if ($stillBroken.Count -gt 0) {
    Send-GotifyNotification -Title "Homelab: could not auto-heal" -Message "Still down after recreation attempt: $($stillBroken -join ', ') - needs manual investigation" -Priority 8
    exit 1
}

exit 0
