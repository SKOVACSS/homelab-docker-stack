#Requires -Version 5.0

<#
.SYNOPSIS
Health Check Script for Docker Home Lab

.DESCRIPTION
Validates all Docker containers and services are running with proper health status.

.EXAMPLE
.\health-check.ps1

#>

param(
    [switch]$Detailed = $false,
    [switch]$JSON = $false,

    # Optional: notify Gotify when something is unhealthy/not running.
    # Create an Application in Gotify's web UI (gotify.DOMAIN -> Apps ->
    # Create) to get a token - opt-in, nothing is sent if left unset.
    [string]$GotifyUrl = "",
    [string]$GotifyToken = ""
)

# All human-readable output goes through this so -JSON gets clean,
# parseable stdout (just the JSON object) instead of JSON glued onto the
# decorated console output.
function Say {
    param([string]$Text = "", [string]$Color = "White")
    if ($JSON) { return }
    Write-Host $Text -ForegroundColor $Color
}

function Send-GotifyNotification {
    param([string]$Title, [string]$Message, [int]$Priority = 5)
    if ([string]::IsNullOrEmpty($GotifyUrl) -or [string]::IsNullOrEmpty($GotifyToken)) { return }
    try {
        $body = @{ title = $Title; message = $Message; priority = $Priority } | ConvertTo-Json
        Invoke-RestMethod -Uri "$GotifyUrl/message?token=$GotifyToken" -Method Post -Body $body -ContentType "application/json" | Out-Null
    } catch {
        Say "  (Gotify notification failed: $_)" "Yellow"
    }
}

# Configuration
$stacks = @("authentik", "caddy", "media-stack", "privacy-stack", "security-stack", "email-stack", "monitoring-stack", "notification-stack", "utilities", "immich-app")
$results = @{
    Healthy = @()
    Unhealthy = @()
    NotRunning = @()
    Total = 0
}

Say ""
Say "═══════════════════════════════════════════════════════════════" "Cyan"
Say "  Docker Home Lab - Health Check" "Cyan"
Say "═══════════════════════════════════════════════════════════════" "Cyan"
Say ""

# Quick "is anything running at all" check. Note: `docker ps` (even with
# zero containers) always prints a header row in table format, so a plain
# truthiness check on that output is always true - use -q (bare IDs, truly
# empty when nothing's running) instead.
$containers = docker ps -q

if (-not $containers) {
    if ($JSON) {
        @{ Error = "No containers running" } | ConvertTo-Json
    } else {
        Say "⚠️  No containers running" "Yellow"
        Say ""
        Say "To start services, run:" "Cyan"
        Say "  docker compose -f caddy/docker-compose.yml up -d" "White"
    }
    exit 1
}

foreach ($stack in $stacks) {
    Say "Checking $stack..." "White"

    try {
        $stackPath = Split-Path -Parent $PSScriptRoot
        $stackPath = Join-Path $stackPath $stack

        if (-not (Test-Path "$stackPath\docker-compose.yml")) {
            continue
        }

        # --format json gives one JSON object per line with real State/
        # Health fields. The previous version split the human-readable
        # table on whitespace, which breaks the moment STATUS contains a
        # space ("Up 5 hours (healthy)") or PORTS has a value - it was
        # matching "Up" (a substring of every running container's status,
        # healthy or not) before ever reaching the unhealthy check below,
        # so unhealthy containers were silently reported as fine.
        $stackContainers = docker compose -f "$stackPath\docker-compose.yml" ps --all --format json 2>$null

        if ($stackContainers) {
            foreach ($line in $stackContainers) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $c = $line | ConvertFrom-Json
                $status = "$($c.State)/$($c.Health)"

                if ($c.State -ne "running") {
                    Say "  ⏸️  $($c.Name) - Not Running ($($c.State))" "Yellow"
                    $results.NotRunning += @{Stack=$stack; Container=$c.Name; Status=$status}
                } elseif ($c.Health -eq "unhealthy") {
                    Say "  ❌ $($c.Name) - Unhealthy" "Red"
                    $results.Unhealthy += @{Stack=$stack; Container=$c.Name; Status=$status}
                } elseif ($c.Health -eq "" -or $null -eq $c.Health) {
                    Say "  ⚠️  $($c.Name) - Running (no healthcheck)" "Yellow"
                    $results.Healthy += @{Stack=$stack; Container=$c.Name; Status=$status}
                } else {
                    Say "  ✅ $($c.Name) - Healthy" "Green"
                    $results.Healthy += @{Stack=$stack; Container=$c.Name; Status=$status}
                }
                $results.Total++
            }
        }
    }
    catch {
        Say "  ⚠️  Error checking stack" "Yellow"
    }
}

Say ""
Say "═══════════════════════════════════════════════════════════════" "Cyan"
Say "  Summary" "Cyan"
Say "═══════════════════════════════════════════════════════════════" "Cyan"
Say ""
Say "✅ Healthy:     $($results.Healthy.Count)" "Green"
Say "⚠️  Unhealthy:   $($results.Unhealthy.Count)" "Yellow"
Say "❌ Not Running:  $($results.NotRunning.Count)" "Red"
Say "📊 Total:       $($results.Total)" "Cyan"
Say ""

# Overall status
$healthPercentage = if ($results.Total -gt 0) {
    [math]::Round(($results.Healthy.Count / $results.Total) * 100)
} else {
    0
}

$status = "HEALTHY"
if ($results.Unhealthy.Count -eq 0 -and $results.NotRunning.Count -eq 0) {
    Say "✅ System Status: HEALTHY ($healthPercentage%)" "Green"
} elseif ($results.Unhealthy.Count -gt 0) {
    $status = "ISSUES_DETECTED"
    Say "❌ System Status: ISSUES DETECTED" "Red"
    $bad = ($results.Unhealthy + $results.NotRunning) | ForEach-Object { "$($_.Container) ($($_.Stack))" }
    Send-GotifyNotification -Title "Homelab: issues detected" -Message "Unhealthy/down: $($bad -join ', ')" -Priority 8
} else {
    $status = "DEGRADED"
    Say "⚠️  System Status: DEGRADED" "Yellow"
    $bad = $results.NotRunning | ForEach-Object { "$($_.Container) ($($_.Stack))" }
    Send-GotifyNotification -Title "Homelab: services down" -Message "Not running: $($bad -join ', ')" -Priority 6
}

Say ""

# Detailed diagnostics (console mode only - use the JSON object's own
# fields for machine-readable consumption instead)
if ($Detailed -and -not $JSON) {
    Say "═══════════════════════════════════════════════════════════════" "Cyan"
    Say "  Detailed Diagnostics" "Cyan"
    Say "═══════════════════════════════════════════════════════════════" "Cyan"
    Say ""

    Say "Networks:" "White"
    docker network ls --filter "name=caddy" --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}" | ForEach-Object { Say "  $_" }

    Say ""
    Say "Volumes:" "White"
    docker volume ls --format "table {{.Name}}\t{{.Driver}}" | Select-Object -First 15 | ForEach-Object { Say "  $_" }

    Say ""
    Say "Disk Usage:" "White"
    docker system df | ForEach-Object { Say "  $_" }
}

Say ""
Say "═══════════════════════════════════════════════════════════════" "Cyan"
Say ""

if ($JSON) {
    [PSCustomObject]@{
        Status          = $status
        HealthPercent   = $healthPercentage
        Healthy         = $results.Healthy
        Unhealthy       = $results.Unhealthy
        NotRunning      = $results.NotRunning
        Total           = $results.Total
    } | ConvertTo-Json -Depth 5
}

# Exit code
if ($results.Unhealthy.Count -eq 0 -and $results.NotRunning.Count -eq 0) {
    exit 0
} else {
    exit 1
}
