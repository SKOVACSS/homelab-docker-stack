#Requires -Version 5.0

<#
.SYNOPSIS
Turns on CrowdSec (+ its Cloudflare bouncer) after initial setup, without re-running gui-installer.ps1.

.DESCRIPTION
gui-installer.ps1 can't fully configure this stack up front the way it
does for most others: the Cloudflare bouncer needs a Worker deployed
in your own Cloudflare account (through their GitHub/GitLab
integration - see SETUP.md), and the bouncer's own API key can only be
generated after the crowdsec engine is already running. That's an
inherently sequential, partly-manual process, so it gets its own script
instead - same reasoning as enable-email.ps1 for Mailu.

What this does, in order:
  1. Writes crowdsec-stack\.env and deploys the crowdsec engine alone
     (log parsing/detection only - no Cloudflare involvement yet, and no
     host-network access needed, so nothing here needs the manual steps
     below to be useful on its own).
  2. Waits for it to become healthy.
  3. Confirms you've already deployed the Cloudflare Worker (SETUP.md
     walks through this - a one-time step in your own Cloudflare/GitHub
     account this script cannot do on your behalf).
  4. Prompts for the broad-permission Cloudflare API token SETUP.md has
     you create, auto-generates the bouncer's Cloudflare account/zone
     config from it, mints the bouncer's own CrowdSec API key via the
     now-running engine, and merges the two into
     crowdsec-stack\cloudflare-bouncer.yaml.
  5. Deploys the bouncer.

Safe to stop after step 1-2 and come back later for the Cloudflare half -
nothing here is destructive, and the engine is useful on its own in the
meantime (CrowdSec's community threat-intel enrichment, a real parser
for Caddy's logs instead of Fail2Ban's regex-only approach).

.EXAMPLE
.\enable-crowdsec.ps1
#>

$appRoot = Split-Path -Parent $PSScriptRoot
$caddyEnvPath = "$appRoot\caddy\.env"
$stackPath = "$appRoot\crowdsec-stack"
$envPath = "$stackPath\.env"
$bouncerConfigPath = "$stackPath\cloudflare-bouncer.yaml"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Enable CrowdSec + Cloudflare Bouncer" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $caddyEnvPath)) {
    Write-Host "❌ caddy\.env not found - run gui-installer.ps1 first (this script only" -ForegroundColor Red
    Write-Host "   adds crowdsec-stack on top of an already-configured deployment)." -ForegroundColor Red
    exit 1
}

$domain = (Get-Content $caddyEnvPath | Where-Object { $_ -match "^DOMAIN=" } | Select-Object -First 1) -replace "^DOMAIN=", ""
if ([string]::IsNullOrEmpty($domain)) {
    Write-Host "❌ Could not read DOMAIN from caddy\.env - is that file intact?" -ForegroundColor Red
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

# ---------- Step 1: engine ----------

if (-not (Test-Path $envPath)) {
    "TZ=UTC" | Out-File $envPath -Encoding UTF8
    Write-Host "✅ crowdsec-stack\.env written" -ForegroundColor Green
} else {
    Write-Host "⚠️  crowdsec-stack\.env already exists - engine looks already set up." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Deploying the crowdsec engine (log parsing/detection only for now)..." -ForegroundColor Cyan
Push-Location $stackPath
& $docker compose up -d crowdsec
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

Write-Host ""
Write-Host "That's the detection half done. It's already useful on its own -" -ForegroundColor White
Write-Host "CrowdSec is now parsing Caddy's access log with the community" -ForegroundColor White
Write-Host "'caddy' collection and CrowdSec's shared threat-intel." -ForegroundColor White
Write-Host ""
$continueToCloudflare = Read-Host "Continue on to the Cloudflare bouncer setup now? (y/N)"
if ($continueToCloudflare -ne "y") {
    Write-Host ""
    Write-Host "Stopping here - nothing more to do. Re-run this script any time to" -ForegroundColor Cyan
    Write-Host "finish the Cloudflare half; the engine keeps running as-is." -ForegroundColor Cyan
    exit 0
}

# ---------- Step 2: Cloudflare bouncer ----------

Write-Host ""
Write-Host "Before continuing, confirm you've already done this in your own" -ForegroundColor White
Write-Host "Cloudflare/GitHub account (see SETUP.md's CrowdSec section):" -ForegroundColor White
Write-Host "  1. Deployed the Remediation Worker via Cloudflare's Self-Hosted" -ForegroundColor White
Write-Host "     Installer (a one-time GitHub/GitLab integration - this script" -ForegroundColor White
Write-Host "     cannot do this step for you, it needs your own account)." -ForegroundColor White
Write-Host "  2. Created a Cloudflare API token with the broad permission set" -ForegroundColor White
Write-Host "     SETUP.md lists (Workers KV/Scripts Edit, Turnstile Edit," -ForegroundColor White
Write-Host "     Account Settings/Analytics Read, Zone DNS/Workers Routes/Zone" -ForegroundColor White
Write-Host "     Read) - this is a DIFFERENT, broader token than the DNS-only" -ForegroundColor White
Write-Host "     one caddy\.env already has." -ForegroundColor White
$ready = Read-Host "Done both? (y/N)"
if ($ready -ne "y") {
    Write-Host "Come back once that's done - the engine keeps running as-is." -ForegroundColor Cyan
    exit 0
}

if (Test-Path $bouncerConfigPath) {
    Write-Host ""
    Write-Host "⚠️  cloudflare-bouncer.yaml already exists - the bouncer looks already" -ForegroundColor Yellow
    Write-Host "   configured. Continuing regenerates it and mints a new bouncer API" -ForegroundColor Yellow
    Write-Host "   key (the old one stops working - one key can be revoked safely via" -ForegroundColor Yellow
    Write-Host "   'cscli bouncers list'/'delete' on the crowdsec container if you want" -ForegroundColor Yellow
    Write-Host "   to clean up the old one afterward)." -ForegroundColor Yellow
    $confirm = Read-Host "Continue and overwrite? (y/N)"
    if ($confirm -ne "y") {
        Write-Host "Cancelled - nothing changed." -ForegroundColor Cyan
        exit 0
    }
}

$cfToken = Read-Host "Cloudflare API token (the broad one from step above)"
if ([string]::IsNullOrWhiteSpace($cfToken)) {
    Write-Host "❌ No token entered - nothing changed." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Auto-generating Cloudflare account/zone config from that token..." -ForegroundColor White
$genPath = "$stackPath\cloudflare-bouncer.generated.yaml"
& $docker run --rm crowdsecurity/cloudflare-worker-bouncer -g $cfToken 2>$null | Out-File $genPath -Encoding UTF8
if (-not (Test-Path $genPath) -or (Get-Item $genPath).Length -eq 0) {
    Write-Host "❌ Generation failed or produced an empty file - check the token's" -ForegroundColor Red
    Write-Host "   permissions match SETUP.md's list exactly." -ForegroundColor Red
    exit 1
}

Write-Host "Minting the bouncer's CrowdSec API key..." -ForegroundColor White
$lapiKey = (& $docker exec crowdsec cscli -oraw bouncers add cloudflarebouncer 2>$null | Select-Object -Last 1).Trim()
if ([string]::IsNullOrWhiteSpace($lapiKey)) {
    Write-Host "❌ Could not mint an API key - is the crowdsec container still running?" -ForegroundColor Red
    Remove-Item $genPath -Force -ErrorAction SilentlyContinue
    exit 1
}

# The generated file has a literal `${API_KEY}` placeholder and defaults
# to localhost:8080 (the README's bare-docker-run example, where the
# bouncer and engine share a network namespace) - this stack runs them
# as two separate containers on crowdsec-network instead, so the LAPI is
# reachable by container name, not localhost.
(Get-Content $genPath) `
    -replace '\$\{API_KEY\}', $lapiKey `
    -replace 'lapi_url:\s*http://localhost:8080/?', 'lapi_url: http://crowdsec:8080/' `
    | Set-Content $bouncerConfigPath -Encoding UTF8
Remove-Item $genPath -Force

Write-Host "✅ crowdsec-stack\cloudflare-bouncer.yaml written" -ForegroundColor Green
Write-Host ""
Write-Host "⚠️  Review it now before deploying: the auto-generated defaults use" -ForegroundColor Yellow
Write-Host "   the 'captcha' action, not 'ban' - decide per zone whether you want" -ForegroundColor Yellow
Write-Host "   a hard block or a Turnstile challenge, and confirm routes_to_protect" -ForegroundColor Yellow
Write-Host "   covers what you actually want covered (everything, by default, if" -ForegroundColor Yellow
Write-Host "   your token had access to the whole zone)." -ForegroundColor Yellow
$reviewed = Read-Host "Reviewed and ready to deploy? (y/N)"
if ($reviewed -ne "y") {
    Write-Host "Stopping here - the file is written, deploy whenever you're ready:" -ForegroundColor Cyan
    Write-Host "  .\deploy.ps1 -Action deploy -Stack crowdsec-stack" -ForegroundColor White
    exit 0
}

Write-Host ""
Write-Host "Deploying the bouncer..." -ForegroundColor Cyan
Push-Location $stackPath
& $docker compose up -d cloudflare-bouncer
Pop-Location

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Done" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Confirm it's actually syncing decisions: '$docker logs crowdsec-cloudflare-bouncer'" -ForegroundColor White
Write-Host "should show it polling the LAPI and pushing to Cloudflare with no errors." -ForegroundColor White
Write-Host ""
