#Requires -Version 5.0

<#
.SYNOPSIS
Applies this repo's Prowlarr indexer policy: proxies, proxy tags, enabled indexers, and private-tracker seeding rules.

.DESCRIPTION
Prowlarr keeps all of this in its own database, not in this repo, so it
was only ever set by hand. This makes it reproducible and safe to re-run
(every step compares first and only writes what differs), then asks
Prowlarr to sync indexers to Radarr/Sonarr/Lidarr so they pick up the
seeding rules too.

Proxies (tag-scoped - an indexer uses a proxy only if it has the tag):
  - flaresolverr: FlareSolverr at http://gluetun:8191 (it rides the VPN,
    see media-stack/docker-compose.yml) - solves Cloudflare challenges.
  - vpn: gluetun's HTTP proxy at gluetun:8888 - routes Prowlarr's OWN
    requests through the VPN, for sites that ban the home IP outright
    (1337x: Cloudflare error 1006). FlareSolverr alone can't fix that:
    Prowlarr only hands a page to FlareSolverr when it sees a solvable
    challenge, and a flat ban isn't one.

Indexers are matched by name; any not listed in $IndexerPolicy are left
alone. Private-tracker seed rules are what Radarr/Sonarr attach to each
torrent they grab (per-torrent share limits in qBittorrent), so these
must be at or above the tracker's minimum - see configure-qbittorrent.ps1
for the matching safety net on the qBittorrent side.

Reads Prowlarr's API key from its own config.xml - nothing to enter.

.EXAMPLE
.\configure-prowlarr.ps1
#>

param([switch]$Quiet)

# Enable = $true/$false; Tags = proxy tag labels; Seed = private-tracker
# seeding minimum (ratio, and minutes for both single torrents and packs).
$IndexerPolicy = [ordered]@{
    '1337x'             = @{ Enable = $true; Tags = @('flaresolverr', 'vpn') }
    'Torrent Downloads' = @{ Enable = $true; Tags = @('flaresolverr') }
    'EZTV'              = @{ Enable = $true; Tags = @('flaresolverr') }
    # EBookBay's only domain (ebb.la) refuses every connection from both
    # the home IP and the VPN (checked 2026-09-24) - the site looks gone.
    # Left disabled rather than deleted in case it comes back.
    'EBookBay'          = @{ Enable = $false; Tags = @() }
    # Its search API is slow enough that Prowlarr's save-time test can
    # time out; a re-run usually gets through.
    'Internet Archive'  = @{ Enable = $true; Tags = @() }
    # Pretome's rule is 0.75 ratio or 3600 minutes, whichever first;
    # margin because the tracker's own accounting can lag Prowlarr's.
    'PreToMe'           = @{ Enable = $true; Tags = @(); Seed = @{ Ratio = 0.8; Minutes = 3720 } }
}

function Write-Info {
    param([string]$Message, [string]$Color = 'White')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

# Scheduled tasks don't inherit Docker Desktop's PATH entry on every
# setup - same fallback as backup.ps1.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path "$dockerBin\docker.exe") { $env:Path += ";$dockerBin" }
    else { Write-Host "❌ docker not found - is Docker Desktop installed?" -ForegroundColor Red; exit 1 }
}

$raw = docker exec prowlarr sh -c "grep -o '<ApiKey>[^<]*</ApiKey>' /config/config.xml" 2>$null
if (-not $raw) { Write-Host "❌ Couldn't read Prowlarr's API key - is the prowlarr container running?" -ForegroundColor Red; exit 1 }
$header = "X-Api-Key: $($raw -replace '</?ApiKey>', '')"
$base = 'http://localhost:9696/api/v1'

# Request bodies go over stdin as BOM-less UTF-8, never as arguments:
# Windows PowerShell 5.1 strips embedded double quotes from native-command
# arguments (see configure-qbittorrent.ps1).
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
function Invoke-Prowlarr {
    param([string]$Method, [string]$Path, $Body)
    if ($null -ne $Body) {
        $out = ($Body | ConvertTo-Json -Depth 20 -Compress) | docker exec -i prowlarr curl -s -w "`n%{http_code}" -X $Method "$base$Path" -H $header -H 'Content-Type: application/json' --data-binary '@-'
    } else {
        $out = docker exec prowlarr curl -s -w "`n%{http_code}" -X $Method "$base$Path" -H $header
    }
    $lines = @($out)
    $code = [int]$lines[-1]
    $text = ($lines[0..($lines.Count - 2)] -join "`n")
    if ($code -ge 400) { throw "Prowlarr $Method $Path failed (HTTP $code): $text" }
    # Assign first: Windows PowerShell 5.1's ConvertFrom-Json emits a JSON
    # array as ONE pipeline object, so `| Where-Object` would see the
    # whole array at once; returning a variable unrolls it.
    if ($text) { $obj = $text | ConvertFrom-Json; return $obj }
}

# ---------- Tags ----------
$tags = @{}
foreach ($t in (Invoke-Prowlarr GET '/tag')) { $tags[$t.label] = $t.id }
foreach ($label in @('flaresolverr', 'vpn')) {
    if (-not $tags.ContainsKey($label)) {
        $tags[$label] = (Invoke-Prowlarr POST '/tag' @{ label = $label }).id
        Write-Info "✅ Created tag '$label'" Green
    }
}

# ---------- Proxies ----------
$wantedProxies = @(
    @{ Implementation = 'FlareSolverr'; Name = 'FlareSolverr'; Tag = 'flaresolverr'; Fields = @{ host = 'http://gluetun:8191/'; requestTimeout = 60 } }
    @{ Implementation = 'Http'; Name = 'Gluetun VPN'; Tag = 'vpn'; Fields = @{ host = 'gluetun'; port = 8888 } }
)
$proxies = @(Invoke-Prowlarr GET '/indexerproxy')
foreach ($w in $wantedProxies) {
    $p = $proxies | Where-Object { $_.implementation -eq $w.Implementation } | Select-Object -First 1
    $isNew = -not $p
    if ($isNew) {
        $p = Invoke-Prowlarr GET '/indexerproxy/schema' | Where-Object { $_.implementation -eq $w.Implementation } | Select-Object -First 1
        $p.name = $w.Name
    }
    $changed = $isNew
    foreach ($f in $p.fields) {
        if ($w.Fields.ContainsKey($f.name) -and "$($f.value)" -ne "$($w.Fields[$f.name])") { $f | Add-Member -NotePropertyName value -NotePropertyValue $w.Fields[$f.name] -Force; $changed = $true }
    }
    if (@($p.tags) -notcontains $tags[$w.Tag]) { $p.tags = @($tags[$w.Tag]); $changed = $true }
    if ($changed) {
        # Prowlarr tests a proxy on save - a FlareSolverr that is still
        # starting fails that test, so re-run this once it's healthy.
        if ($isNew) { $null = Invoke-Prowlarr POST '/indexerproxy' $p } else { $null = Invoke-Prowlarr PUT "/indexerproxy/$($p.id)" $p }
        Write-Info "✅ Proxy '$($w.Name)' set (tag '$($w.Tag)')" Green
    }
}

# ---------- Indexers ----------
# (Field values below are set with Add-Member -Force, not `$f.value =`:
# Prowlarr omits `value` entirely for empty fields, so there's often no
# property to assign to.)
$synced = $false
foreach ($ix in (Invoke-Prowlarr GET '/indexer')) {
    if (-not $IndexerPolicy.Contains($ix.name)) { continue }
    $want = $IndexerPolicy[$ix.name]
    $changed = $false
    if ($ix.enable -ne $want.Enable) { $ix.enable = $want.Enable; $changed = $true }
    $wantTags = @($want.Tags | ForEach-Object { $tags[$_] } | Sort-Object)
    if ((@($ix.tags | Sort-Object) -join ',') -ne ($wantTags -join ',')) { $ix.tags = $wantTags; $changed = $true }
    if ($want.Seed) {
        $seedValues = @{
            'torrentBaseSettings.seedRatio'    = $want.Seed.Ratio
            'torrentBaseSettings.seedTime'     = $want.Seed.Minutes
            'torrentBaseSettings.packSeedTime' = $want.Seed.Minutes
        }
        foreach ($f in $ix.fields) {
            if ($seedValues.ContainsKey($f.name) -and "$($f.value)" -ne "$($seedValues[$f.name])") { $f | Add-Member -NotePropertyName value -NotePropertyValue $seedValues[$f.name] -Force; $changed = $true }
        }
    }
    if ($changed) {
        try {
            $null = Invoke-Prowlarr PUT "/indexer/$($ix.id)" $ix
            Write-Info "✅ $($ix.name): enabled=$($want.Enable), tags=[$($want.Tags -join ', ')]$(if ($want.Seed) { ", seed $($want.Seed.Ratio) ratio / $($want.Seed.Minutes) min" })" Green
            $synced = $true
        } catch {
            # Prowlarr tests an indexer on save; a site that's down right
            # now fails that, and the rest of the policy still applies.
            Write-Host "⚠️  $($ix.name): not saved - $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Push indexer changes (including seed rules) to Radarr/Sonarr/Lidarr now
# rather than waiting for Prowlarr's own periodic sync.
if ($synced) {
    $null = Invoke-Prowlarr POST '/command' @{ name = 'ApplicationIndexerSync' }
    Write-Info "✅ Indexer sync to apps queued" Green
}
Write-Info "✅ Prowlarr policy applied" Green
