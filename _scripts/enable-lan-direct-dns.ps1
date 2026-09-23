#Requires -Version 5.0

<#
.SYNOPSIS
Makes devices on your own network reach every *.{$DOMAIN} app directly instead of round-tripping through Cloudflare.

.DESCRIPTION
Without this, a device on your own LAN - including the Docker host
itself - resolves plex.{$DOMAIN}, chat.{$DOMAIN}, every app in this
repo, to Cloudflare's public proxy IP, the same as anyone on the
internet. Every request then leaves your network, crosses Cloudflare's
edge, and comes back in through cloudflared - a real round trip over
your own internet connection for traffic that's physically a few feet
away, confirmed live to add real latency and to fail outright if your
internet connection is down even though the app itself is running
fine on the LAN.

caddy/docker-compose.yml already publishes 80/443 straight to this
host for exactly this reason (see its own comment) - Caddy will happily
accept a direct connection and serve the same valid Let's Encrypt
certificate either way. The missing piece is DNS: this script adds a
wildcard local override in Pi-hole (dnsmasq's `address=/domain/ip`
directive, via Pi-hole v6's FTLCONF_misc_dnsmasq_lines) so any device
using Pi-hole as its resolver gets your LAN IP back for *.{$DOMAIN}
instead of Cloudflare's, while remote/WAN requests keep going through
the tunnel exactly as before - nothing about that path changes.

Only benefits devices that actually use Pi-hole as their DNS resolver
(the common case if Pi-hole is set as your router's DNS, or handed out
via its own DHCP) - a device pointed at a different resolver (a VPN
client with its own DNS leak protection, a phone on cellular data,
etc.) won't see this override and keeps resolving publicly, which is
usually what you want in those cases anyway.

Idempotent - safe to re-run (e.g. after your LAN IP changes).

.EXAMPLE
.\enable-lan-direct-dns.ps1
#>

$appRoot = Split-Path -Parent $PSScriptRoot
$caddyEnvPath = "$appRoot\caddy\.env"
$dnsStackPath = "$appRoot\dns-stack"
$dnsEnvPath = "$dnsStackPath\.env"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Enable LAN-Direct DNS" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $caddyEnvPath)) {
    Write-Host "❌ caddy\.env not found - run gui-installer.ps1 first." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $dnsEnvPath)) {
    Write-Host "❌ dns-stack\.env not found - deploy dns-stack (Pi-hole) first." -ForegroundColor Red
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

# ---------- detect this host's real LAN IP ----------
# Excludes VPN tunnels and virtual/Docker/Hyper-V/WSL adapters by name -
# a VPN interface can just as easily be in 10.0.0.0/8 as a real LAN, so
# private-range matching alone isn't enough (confirmed live against a
# ProtonVPN client: its own tunnel adapter and the host's real LAN
# adapter both landed in a private range a naive "10.*/192.168.*"
# filter would match equally, with no way to tell them apart by IP
# alone - only the interface name distinguished them).
$excludePattern = 'VPN|Tunnel|WireGuard|Tailscale|Proton|NordVPN|OpenVPN|Virtual|vEthernet|Docker|WSL|Loopback|Bluetooth'
$candidates = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.IPAddress -match '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)') -and
        ($_.InterfaceAlias -notmatch $excludePattern) -and
        ($_.AddressState -eq 'Preferred')
    }

if (-not $candidates) {
    Write-Host "❌ Couldn't auto-detect a LAN IP for this host (every candidate looked" -ForegroundColor Red
    Write-Host "   like a VPN/virtual adapter). Find it yourself (ipconfig) and re-run" -ForegroundColor Red
    Write-Host "   with that value if this keeps happening - this script has no" -ForegroundColor Red
    Write-Host "   -LanIp override yet, open an issue if you need one." -ForegroundColor Red
    exit 1
}

if (@($candidates).Count -gt 1) {
    Write-Host "Multiple candidate network adapters found:" -ForegroundColor White
    $i = 1
    foreach ($c in $candidates) {
        Write-Host "  $i. $($c.IPAddress)  ($($c.InterfaceAlias))" -ForegroundColor White
        $i++
    }
    $choice = Read-Host "Which one is this host's real LAN IP? (1-$(@($candidates).Count))"
    $lanIp = (@($candidates)[[int]$choice - 1]).IPAddress
} else {
    $lanIp = $candidates.IPAddress
    Write-Host "Detected LAN IP: $lanIp ($($candidates.InterfaceAlias))" -ForegroundColor White
}

if ([string]::IsNullOrWhiteSpace($lanIp)) {
    Write-Host "❌ No valid LAN IP selected - nothing changed." -ForegroundColor Red
    exit 1
}

# ---------- write dns-stack\.env and apply ----------

$dnsmasqLine = "address=/$domain/$lanIp"

function Set-EnvValue {
    # Same helper as enable-email.ps1 - updates KEY=value if the key is
    # already there, appends it if not, leaves everything else alone.
    param([string]$Path, [string]$Key, [string]$Value)
    $line = "$Key=$Value"
    $content = Get-Content $Path
    if ($content -match "^$Key=") {
        $content = $content -replace "^$Key=.*", $line
        $content | Set-Content $Path -Encoding UTF8
        return
    }
    Add-Content -Path $Path -Value $line -Encoding UTF8
}

Set-EnvValue -Path $dnsEnvPath -Key "PIHOLE_DNSMASQ_LINES" -Value $dnsmasqLine
Write-Host "✅ dns-stack\.env: PIHOLE_DNSMASQ_LINES=$dnsmasqLine" -ForegroundColor Green

Write-Host ""
Write-Host "Recreating Pi-hole to pick up the new setting..." -ForegroundColor Cyan
Push-Location $dnsStackPath
& $docker compose up -d pihole
Pop-Location

Write-Host "Waiting for it to become healthy..." -ForegroundColor White
$healthy = $false
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 5
    $status = & $docker inspect pihole --format '{{.State.Health.Status}}' 2>$null
    if ($status -eq "healthy") { $healthy = $true; break }
    if ($status -eq "unhealthy") { break }
}
if (-not $healthy) {
    Write-Host "❌ pihole didn't become healthy - check '$docker logs pihole'" -ForegroundColor Red
    exit 1
}

# Confirm live, not just that the container is healthy - a syntax
# mistake in the generated line wouldn't necessarily fail the
# healthcheck, only actual resolution proves it took effect.
$resolved = & $docker exec pihole dig "+short" $domain "@127.0.0.1" 2>$null | Select-Object -First 1
Write-Host ""
if ($resolved -eq $lanIp) {
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Done - verified live" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "Any device using Pi-hole as its DNS resolver now gets $lanIp for" -ForegroundColor White
    Write-Host "*.$domain instead of Cloudflare's public IP - direct LAN speed, and" -ForegroundColor White
    Write-Host "it keeps working even if your internet connection goes down." -ForegroundColor White
    Write-Host ""
    Write-Host "This only applies to devices that actually use Pi-hole as their" -ForegroundColor White
    Write-Host "resolver (confirmed live: a VPN client's own DNS leak protection on" -ForegroundColor White
    Write-Host "the same host can silently bypass this - if a device still resolves" -ForegroundColor White
    Write-Host "publicly after this, check what DNS server it's actually using" -ForegroundColor White
    Write-Host "before assuming this script didn't work)." -ForegroundColor White
} else {
    Write-Host "⚠️  pihole is healthy but resolving $domain to '$resolved', not $lanIp -" -ForegroundColor Yellow
    Write-Host "   something didn't take. Check 'docker exec pihole cat /etc/pihole/pihole.toml'" -ForegroundColor Yellow
    Write-Host "   for the misc.dnsmasq_lines value directly." -ForegroundColor Yellow
    exit 1
}
Write-Host ""
