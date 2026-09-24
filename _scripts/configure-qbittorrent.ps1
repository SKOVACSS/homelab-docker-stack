#Requires -Version 5.0

<#
.SYNOPSIS
Applies this repo's qBittorrent queue/seeding policy and enforces private-tracker seeding minimums.

.DESCRIPTION
qBittorrent keeps its settings in its own config volume, not in this repo,
so anything set by hand in its WebUI is lost on a volume reset and can
silently drift (confirmed live: queueing turned itself back off after a
container recreate). This reasserts the policy via qBittorrent's WebUI
API, and is safe to run on a schedule - every step is idempotent.

Policy:
  - Queueing on, $MaxActiveDownloads (default 10) active downloads.
    Slow torrents still count toward it (otherwise every thin-swarm
    torrent slipped past the cap).
  - Unlimited active seeds - a private-tracker torrent must never sit
    queued, since queued time doesn't count as seeding time.
  - Global share limit ratio 0 / action Stop: public torrents stop the
    moment they finish downloading.
  - Private trackers ($PrivateTrackers) get a per-torrent limit instead,
    which overrides the global one. Default is Pretome's rule (seed to
    0.75 ratio or 3600 minutes, whichever comes first) plus a margin,
    since the tracker's own accounting can lag qBittorrent's.
  - Any private-tracker torrent that stopped before meeting its limit
    (e.g. grabbed before the Prowlarr seed settings existed, so the
    global ratio-0 rule stopped it) is resumed - the hit-and-run guard.

Radarr/Sonarr also set per-torrent limits on grab when the indexer has
Seed Ratio/Seed Time configured in Prowlarr - this is the safety net
for when they don't.

Cleanup: turns on "Remove Completed" in Radarr's and Sonarr's
qBittorrent download client. They then delete a torrent and its files
only once BOTH the release is imported into the library AND qBittorrent
has stopped it for reaching its share limit - so a private-tracker
torrent is never removed before its seeding minimum. Downloads and the
library are separate bind mounts, so imports are copies, not hardlinks,
and this is what frees the duplicate space. Torrents added by hand
(not grabbed by an *arr) are never touched.

Talks to the API from inside gluetun's network namespace (where
qBittorrent's WebUI listens on localhost), relying on qBittorrent's
WebUI\LocalHostAuth=false - no credentials handled here at all.

.EXAMPLE
.\configure-qbittorrent.ps1
.\configure-qbittorrent.ps1 -Quiet    # for a scheduled task
#>

param(
    [int]$MaxActiveDownloads = 10,
    [string[]]$PrivateTrackers = @('pretome'),
    [double]$PrivateRatio = 0.8,
    [int]$PrivateSeedMinutes = 3720,
    [switch]$Quiet
)

$appRoot = Split-Path -Parent $PSScriptRoot

function Write-Info {
    param([string]$Message, [string]$Color = 'White')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

# Scheduled tasks don't inherit Docker Desktop's PATH entry on every
# setup - confirmed live on this host, where `docker` is not on the
# machine or user PATH at all.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path "$dockerBin\docker.exe") { $env:Path += ";$dockerBin" }
    else { Write-Host "❌ docker not found - is Docker Desktop installed?" -ForegroundColor Red; exit 1 }
}

$port = 8080
$envFile = "$appRoot\media-stack\.env"
if (Test-Path $envFile) {
    $line = Get-Content $envFile | Where-Object { $_ -match '^QBIT_PORT=\d+' } | Select-Object -First 1
    if ($line) { $port = [int]($line -replace '^QBIT_PORT=', '') }
}
$base = "http://127.0.0.1:$port/api/v2"

function Invoke-QbitApi {
    param([string]$Path, [string]$PostData)
    if ($PostData) {
        docker exec gluetun wget -qO- --post-data "$PostData" "$base/$Path"
    } else {
        docker exec gluetun wget -qO- "$base/$Path"
    }
    if ($LASTEXITCODE -ne 0) { throw "qBittorrent API call failed: $Path" }
}

try {
    $null = Invoke-QbitApi 'app/version'
} catch {
    Write-Host "❌ qBittorrent API not reachable through gluetun - are both running, and is WebUI\LocalHostAuth=false set?" -ForegroundColor Red
    exit 1
}

# ---------- Global policy ----------
$prefs = @{
    queueing_enabled                  = $true
    max_active_downloads              = $MaxActiveDownloads
    max_active_uploads                = -1
    max_active_torrents               = -1
    dont_count_slow_torrents          = $false
    max_ratio_enabled                 = $true
    max_ratio                         = 0
    max_ratio_act                     = 0
    max_seeding_time_enabled          = $false
    max_inactive_seeding_time_enabled = $false
} | ConvertTo-Json -Compress
# URL-encoded, not raw: Windows PowerShell 5.1 (what a scheduled task
# runs) strips embedded double quotes from native-command arguments, and
# qBittorrent silently ignores the resulting malformed JSON - confirmed
# live, the run "succeeded" while every setting stayed unchanged.
$null = Invoke-QbitApi 'app/setPreferences' "json=$([uri]::EscapeDataString($prefs))"
Write-Info "✅ Queue: $MaxActiveDownloads active downloads, unlimited seeds; public torrents stop when complete" Green

# ---------- Private-tracker seeding minimums ----------
$torrents = Invoke-QbitApi 'torrents/info' | ConvertFrom-Json
$trackerPattern = ($PrivateTrackers | ForEach-Object { [regex]::Escape($_) }) -join '|'
$private = @()
foreach ($t in $torrents) {
    # The top-level `tracker` field is empty whenever no tracker is
    # currently working (stopped torrents included), so check the full
    # tracker list instead.
    $urls = (Invoke-QbitApi "torrents/trackers?hash=$($t.hash)" | ConvertFrom-Json).url -join ' '
    if ($urls -match $trackerPattern) { $private += $t }
}

if ($private.Count -gt 0) {
    $needLimit = $private | Where-Object { $_.ratio_limit -ne $PrivateRatio -or $_.seeding_time_limit -ne $PrivateSeedMinutes }
    if ($needLimit) {
        $hashes = ($needLimit.hash) -join '|'
        # shareLimitAction is required on this WebAPI version - omitting it
        # is a bare 400 with no body (confirmed live, WebAPI 2.15).
        $null = Invoke-QbitApi 'torrents/setShareLimits' "hashes=$hashes&ratioLimit=$PrivateRatio&seedingTimeLimit=$PrivateSeedMinutes&inactiveSeedingTimeLimit=-2&shareLimitAction=Default"
        Write-Info "✅ Seeding limit set on $(@($needLimit).Count) private-tracker torrent(s)" Green
    }

    $stoppedEarly = $private | Where-Object {
        $_.state -in @('stoppedUP', 'pausedUP') -and
        $_.ratio -lt $PrivateRatio -and
        ($_.seeding_time / 60) -lt $PrivateSeedMinutes
    }
    if ($stoppedEarly) {
        $null = Invoke-QbitApi 'torrents/start' "hashes=$(($stoppedEarly.hash) -join '|')"
        Write-Host "⚠️  Resumed $(@($stoppedEarly).Count) private-tracker torrent(s) that stopped before meeting their seeding minimum:" -ForegroundColor Yellow
        $stoppedEarly | ForEach-Object { Write-Host "   $($_.name)" -ForegroundColor Yellow }
    }
}
Write-Info "✅ $($private.Count) private-tracker torrent(s) checked" Green

# ---------- Radarr/Sonarr: remove downloads once imported + seeded ----------
# Body goes over stdin, not as an argument (same Windows PowerShell 5.1
# quote-stripping as above), as BOM-less UTF-8 - 5.1 otherwise pipes to
# native commands as ASCII.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
foreach ($app in @(@{ Name = 'radarr'; Port = 7878 }, @{ Name = 'sonarr'; Port = 8989 })) {
    $running = docker inspect $app.Name --format '{{.State.Running}}' 2>$null
    if ($running -ne 'true') { continue }
    $raw = docker exec $app.Name sh -c "grep -o '<ApiKey>[^<]*</ApiKey>' /config/config.xml" 2>$null
    if (-not $raw) { Write-Host "⚠️  $($app.Name): couldn't read its API key - skipping cleanup setting" -ForegroundColor Yellow; continue }
    $header = "X-Api-Key: $($raw -replace '</?ApiKey>', '')"
    $url = "http://localhost:$($app.Port)/api/v3/downloadclient"
    $clients = docker exec $app.Name curl -s $url -H $header | ConvertFrom-Json
    foreach ($c in ($clients | Where-Object { $_.implementation -eq 'QBittorrent' -and -not $_.removeCompletedDownloads })) {
        $c.removeCompletedDownloads = $true
        $null = ($c | ConvertTo-Json -Depth 10 -Compress) | docker exec -i $app.Name curl -s -X PUT "$url/$($c.id)" -H $header -H 'Content-Type: application/json' --data-binary '@-'
        Write-Info "✅ $($app.Name): 'Remove Completed' turned on for '$($c.name)'" Green
    }
}
