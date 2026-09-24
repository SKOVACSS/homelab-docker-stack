#Requires -Version 5.0

<#
.SYNOPSIS
Turns on CrowdSec (engine + the bouncer compiled into Caddy) after initial setup, without re-running gui-installer.ps1.

.DESCRIPTION
gui-installer.ps1 can't fully configure this stack up front the way it
does for most others: the bouncer's own CrowdSec API key can only be
minted after the crowdsec engine is already running. That's inherently
sequential, so it gets its own script - same reasoning as
enable-email.ps1 for Mailu.

Enforcement happens inside Caddy (caddy-crowdsec-bouncer, compiled in by
caddy/Dockerfile), not at Cloudflare's edge. Earlier versions of this
script deployed CrowdSec's Cloudflare Worker bouncer instead - retired
because the free Workers KV quota (1000 writes/day) ran out within
seconds of a normal decision sync, and its Daemon Mode redeploy-on-
restart then crash-looped until the UTC reset. Step 3 below cleans up
that old bouncer automatically if it's still around.

What this does, in order:
  1. Writes crowdsec-stack\.env and deploys the crowdsec engine (joins
     caddy-network so Caddy can reach its LAPI).
  2. Waits for it to become healthy.
  3. Retires the old Cloudflare Worker bouncer, if present - a clean
     `docker stop` makes it delete its own Worker, KV namespace, and
     route from your Cloudflare account on the way out.
  4. Mints a bouncer API key via the engine and writes
     caddy\crowdsec.d\global.caddy + handler.caddy from the committed
     .example templates (both gitignored - the key is a secret).
  5. Rebuilds and recreates Caddy so it loads the bouncer.

Safe to re-run: an existing Caddy bouncer config is left alone unless
you choose to regenerate it.

.EXAMPLE
.\enable-crowdsec.ps1
#>

$appRoot = Split-Path -Parent $PSScriptRoot
$caddyPath = "$appRoot\caddy"
$caddyEnvPath = "$caddyPath\.env"
$crowdsecConfDir = "$caddyPath\crowdsec.d"
$stackPath = "$appRoot\crowdsec-stack"
$envPath = "$stackPath\.env"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Enable CrowdSec (engine + Caddy bouncer)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $caddyEnvPath)) {
    Write-Host "❌ caddy\.env not found - run gui-installer.ps1 first (this script only" -ForegroundColor Red
    Write-Host "   adds crowdsec-stack on top of an already-configured deployment)." -ForegroundColor Red
    exit 1
}

$docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
if (-not $docker) {
    $fallback = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path $fallback) { $docker = $fallback }
}
if (-not $docker) {
    Write-Host "❌ docker executable not found - is Docker Desktop running?" -ForegroundColor Red
    exit 1
}

# ---------- Step 1-2: engine ----------

if (-not (Test-Path $envPath)) {
    "TZ=UTC" | Out-File $envPath -Encoding UTF8
    Write-Host "✅ crowdsec-stack\.env written" -ForegroundColor Green
} else {
    Write-Host "⚠️  crowdsec-stack\.env already exists - engine looks already set up." -ForegroundColor Yellow
}

# ---------- Step 3 (runs first): retire the old Cloudflare Worker bouncer ----------
# Before `compose up --remove-orphans` below, deliberately: that would
# remove the old container (no longer in docker-compose.yml) without
# guaranteeing the clean stop that makes Daemon Mode tear down its
# Worker/KV/route. A stop with a generous timeout gives it that time.
$oldBouncer = & $docker ps -a --filter "name=^crowdsec-cloudflare-bouncer$" --format '{{.Names}}' 2>$null
if ($oldBouncer) {
    Write-Host "Retiring the old Cloudflare Worker bouncer (removes its Worker/KV/route)..." -ForegroundColor White
    & $docker stop -t 60 crowdsec-cloudflare-bouncer | Out-Null
    & $docker rm crowdsec-cloudflare-bouncer | Out-Null
    Write-Host "✅ Old bouncer removed. Double-check Cloudflare dashboard -> Workers &" -ForegroundColor Green
    Write-Host "   Pages / Workers KV that nothing named 'crowdsec' was left behind." -ForegroundColor Green
}

Write-Host ""
Write-Host "Deploying the crowdsec engine..." -ForegroundColor Cyan
Push-Location $stackPath
& $docker compose up -d --remove-orphans crowdsec
Pop-Location

Write-Host "Waiting for it to become healthy (installs the Caddy log parser on first boot)..." -ForegroundColor White
$healthy = $false
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    $status = & $docker inspect crowdsec --format '{{.State.Health.Status}}' 2>$null
    if ($status -eq "healthy") { $healthy = $true; break }
    if ($status -eq "unhealthy") { break }
}
if (-not $healthy) {
    Write-Host "❌ crowdsec didn't become healthy - check '$docker logs crowdsec'" -ForegroundColor Red
    exit 1
}
Write-Host "✅ crowdsec engine is up and healthy" -ForegroundColor Green

# Its old bouncer registration is dead weight once the container is gone.
$registered = & $docker exec crowdsec cscli bouncers list -o raw 2>$null
if ($registered -match '(?m)^cloudflarebouncer,') {
    & $docker exec crowdsec cscli bouncers delete cloudflarebouncer | Out-Null
}

# ---------- Step 4: Caddy bouncer config ----------

$globalConf = "$crowdsecConfDir\global.caddy"
$handlerConf = "$crowdsecConfDir\handler.caddy"
$writeConfig = $true
if (Test-Path $globalConf) {
    Write-Host ""
    Write-Host "⚠️  caddy\crowdsec.d\global.caddy already exists - the Caddy bouncer" -ForegroundColor Yellow
    Write-Host "   looks already configured." -ForegroundColor Yellow
    $confirm = Read-Host "Regenerate it with a new bouncer key? (y/N)"
    $writeConfig = ($confirm -eq "y")
}

if ($writeConfig) {
    # Delete-then-add so a regenerate doesn't fail on the existing name
    # (and doesn't leave the old key valid).
    if ($registered -match '(?m)^caddy-bouncer,') {
        & $docker exec crowdsec cscli bouncers delete caddy-bouncer | Out-Null
    }
    $apiKey = (& $docker exec crowdsec cscli bouncers add caddy-bouncer -o raw 2>$null | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Host "❌ Could not mint an API key - is the crowdsec container still running?" -ForegroundColor Red
        exit 1
    }
    (Get-Content "$globalConf.example") -replace 'CHANGE_ME_BOUNCER_KEY_FROM_CSCLI', $apiKey.Trim() |
        Set-Content $globalConf -Encoding UTF8
    Copy-Item "$handlerConf.example" $handlerConf -Force
    Write-Host "✅ caddy\crowdsec.d\global.caddy + handler.caddy written" -ForegroundColor Green
}

# ---------- Step 5: reload Caddy ----------
# Rebuild, not just restart: a deployment from before the bouncer
# existed has a Caddy binary without the module compiled in.

Write-Host ""
Write-Host "Rebuilding and recreating Caddy with the bouncer enabled..." -ForegroundColor Cyan
Push-Location $caddyPath
& $docker compose build caddy
& $docker compose up -d caddy
Pop-Location

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Done" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Confirm Caddy is pulling decisions: '$docker exec crowdsec cscli bouncers list'" -ForegroundColor White
Write-Host "should show caddy-bouncer with a recent 'Last API pull'." -ForegroundColor White
Write-Host ""
