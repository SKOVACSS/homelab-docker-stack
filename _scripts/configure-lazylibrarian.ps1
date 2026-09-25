#Requires -Version 5.0

<#
.SYNOPSIS
Configures LazyLibrarian for this stack: folders, qBittorrent, IRC, API, and Prowlarr indexer sync.

.DESCRIPTION
LazyLibrarian ships unconfigured - no download client, no indexers, no
library folder. This applies the repo's setup and is safe to re-run.

Flow of a book:
  1. You add an author/book/series in LazyLibrarian's web UI and mark it
     Wanted (or follow an author to auto-want new releases).
  2. It searches every provider: Prowlarr-synced torrent indexers
     (including private ones, with their seed rules) and IRC Highway's
     #ebooks channel.
  3. Torrents go to qBittorrent under category "lazylibrarian"
     (/downloads/lazylibrarian); IRC downloads come straight in.
  4. LazyLibrarian COPIES the finished book into /books-ingest (Calibre-
     Web-Automated's ingest folder). CWA imports it into the Calibre
     library and deletes its copy; the torrent's original keeps seeding.

What this does:
  - Writes LazyLibrarian's config.ini (stops the container briefly):
    folders, copy-not-move, qBittorrent host/category, API key, IRC
    Highway #ebooks, telemetry off.
  - Creates the "lazylibrarian" category in qBittorrent.
  - Registers LazyLibrarian as an application in Prowlarr (full sync),
    so every Prowlarr book indexer appears in LazyLibrarian automatically.

NOT done here, on purpose: qBittorrent's WebUI password. Enter it once in
LazyLibrarian -> Config -> Downloaders -> qBittorrent (username/password),
then press Test. This script never reads or stores that credential.

.EXAMPLE
.\configure-lazylibrarian.ps1
#>

param([switch]$Quiet)

$appRoot = Split-Path -Parent $PSScriptRoot

function Write-Info {
    param([string]$Message, [string]$Color = 'White')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path "$dockerBin\docker.exe") { $env:Path += ";$dockerBin" }
    else { Write-Host "❌ docker not found - is Docker Desktop installed?" -ForegroundColor Red; exit 1 }
}

$qbitPort = 8080
$envFile = "$appRoot\media-stack\.env"
if (Test-Path $envFile) {
    $line = Get-Content $envFile | Where-Object { $_ -match '^QBIT_PORT=\d+' } | Select-Object -First 1
    if ($line) { $qbitPort = [int]($line -replace '^QBIT_PORT=', '') }
}

# Section/key names as LazyLibrarian writes them: UPPER sections, lower
# keys. "__GENERATE__" = create a random value once, then keep it.
$settings = [ordered]@{
    'GENERAL'     = [ordered]@{
        ebook_dir        = '/books-ingest'
        # Audiobookshelf's library folder (family-stack) - finished
        # audiobooks land here as Author/Title and show up in the app.
        audio_dir        = '/audiobooks'
        download_dir     = '/downloads/lazylibrarian'
        # Copy into CWA's ingest folder instead of moving: CWA deletes
        # what it imports, and the torrent's original must keep seeding.
        destination_copy = 'True'
    }
    # Off by default in LazyLibrarian's code, but this install had it switched
    # on - __DEFAULT__ removes the override. (LazyLibrarian drops any value
    # equal to its default when it saves, so only non-defaults are listed.)
    'TELEMETRY'   = [ordered]@{ telemetry_enable = '__DEFAULT__' }
    'API'         = [ordered]@{ api_enabled = 'True'; api_key = '__GENERATE__' }
    'TORRENT'     = [ordered]@{ tor_downloader_qbittorrent = 'True' }  # keep_seeding defaults on
    'QBITTORRENT' = [ordered]@{
        qbittorrent_host  = 'gluetun'
        qbittorrent_port  = "$qbitPort"
        qbittorrent_label = 'lazylibrarian'
        qbittorrent_dir   = '/downloads/lazylibrarian'
    }
    # IRC Highway's #ebooks: the biggest IRC ebook source. Searches are
    # "@search <title>"; results arrive by DCC, which LazyLibrarian opens
    # outbound, so it works behind Starlink's CGNAT. This traffic leaves
    # from the home IP, not the VPN.
    'IRC_0'       = [ordered]@{
        dispname = 'IRCHighway'
        enabled  = 'True'
        server   = 'irc.irchighway.net'
        channel  = '#ebooks'
        botnick  = '__GENERATE_NICK__'
    }
}

$image = docker inspect lazylibrarian --format '{{.Config.Image}}' 2>$null
if (-not $image) { Write-Host "❌ lazylibrarian container not found - deploy media-stack first" -ForegroundColor Red; exit 1 }

# Edit config.ini with LazyLibrarian stopped - it rewrites the file on
# shutdown, so a live edit would be lost. Python from its own image, fed
# the settings over stdin (Windows PowerShell 5.1 mangles quotes in
# native-command arguments).
$py = @'
import sys, json, secrets, configparser
path = "/config/config.ini"
p = configparser.ConfigParser(interpolation=None)
p.optionxform = str.lower
p.read(path)
changed = []
# utf-8-sig: Windows PowerShell 5.1 prefixes piped input with a BOM.
for sec, kv in json.loads(sys.stdin.buffer.read().decode("utf-8-sig")).items():
    if not p.has_section(sec):
        p.add_section(sec)
    for k, v in kv.items():
        cur = p.get(sec, k, fallback=None)
        if v == "__DEFAULT__":
            if cur is not None:
                p.remove_option(sec, k)
                changed.append(f"{sec}.{k}")
            continue
        if v in ("__GENERATE__", "__GENERATE_NICK__"):
            if cur:
                continue
            v = secrets.token_hex(16) if v == "__GENERATE__" else "ll" + secrets.token_hex(3)
        if cur != v:
            p.set(sec, k, v)
            changed.append(f"{sec}.{k}")
if changed:
    with open(path, "w") as f:
        p.write(f)
print(json.dumps({"changed": changed, "api_key": p.get("API", "api_key")}))
'@
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
docker stop lazylibrarian | Out-Null
$pyFile = New-TemporaryFile
try {
    [IO.File]::WriteAllText($pyFile.FullName, $py)
    $out = ($settings | ConvertTo-Json -Depth 5 -Compress) |
        docker run --rm -i --volumes-from lazylibrarian -v "$($pyFile.FullName):/tmp/apply_config.py:ro" --entrypoint python3 $image /tmp/apply_config.py
} finally {
    Remove-Item $pyFile.FullName -Force -ErrorAction SilentlyContinue
}
docker start lazylibrarian | Out-Null
$result = $out | ConvertFrom-Json
if (-not $result) { Write-Host "❌ Couldn't update LazyLibrarian's config.ini" -ForegroundColor Red; exit 1 }
Write-Info "✅ LazyLibrarian config: $(if ($result.changed.Count) { $result.changed -join ', ' } else { 'already up to date' })" Green

# ---------- qBittorrent category ----------
$cats = docker exec gluetun wget -qO- "http://127.0.0.1:$qbitPort/api/v2/torrents/categories" | ConvertFrom-Json
if (-not ($cats.PSObject.Properties.Name -contains 'lazylibrarian')) {
    # Empty savePath = qBittorrent's default <save path>/<category>, i.e.
    # /downloads/lazylibrarian, matching the other *arr categories.
    docker exec gluetun wget -qO- --post-data 'category=lazylibrarian&savePath=' "http://127.0.0.1:$qbitPort/api/v2/torrents/createCategory" | Out-Null
    Write-Info "✅ qBittorrent category 'lazylibrarian' created" Green
}

# ---------- Prowlarr application ----------
for ($i = 0; $i -lt 24; $i++) {
    if ((docker inspect lazylibrarian --format '{{.State.Health.Status}}') -eq 'healthy') { break }
    Start-Sleep 5
}
$raw = docker exec prowlarr sh -c "grep -o '<ApiKey>[^<]*</ApiKey>' /config/config.xml" 2>$null
if (-not $raw) { Write-Host "⚠️  Prowlarr not reachable - skipped indexer sync setup" -ForegroundColor Yellow; exit 0 }
$header = "X-Api-Key: $($raw -replace '</?ApiKey>', '')"
# Assign before filtering: Windows PowerShell 5.1's ConvertFrom-Json emits a
# JSON array as ONE pipeline object (see configure-prowlarr.ps1).
$apps = docker exec prowlarr curl -s http://localhost:9696/api/v1/applications -H $header | ConvertFrom-Json
if (-not ($apps | Where-Object { $_.implementation -eq 'LazyLibrarian' })) {
    $schema = docker exec prowlarr curl -s http://localhost:9696/api/v1/applications/schema -H $header | ConvertFrom-Json
    $app = $schema |
        Where-Object { $_.implementation -eq 'LazyLibrarian' } | Select-Object -First 1
    $app | Add-Member -NotePropertyName name -NotePropertyValue 'LazyLibrarian' -Force
    $app.syncLevel = 'fullSync'
    $values = @{ prowlarrUrl = 'http://prowlarr:9696'; baseUrl = 'http://lazylibrarian:5299'; apiKey = $result.api_key }
    foreach ($f in $app.fields) {
        if ($values.ContainsKey($f.name)) { $f | Add-Member -NotePropertyName value -NotePropertyValue $values[$f.name] -Force }
    }
    $resp = ($app | ConvertTo-Json -Depth 10 -Compress) |
        docker exec -i prowlarr curl -s -w "`n%{http_code}" -X POST http://localhost:9696/api/v1/applications -H $header -H 'Content-Type: application/json' --data-binary '@-'
    $code = @($resp)[-1]
    if ([int]$code -lt 300) {
        $null = ('{"name":"ApplicationIndexerSync"}') | docker exec -i prowlarr curl -s -X POST http://localhost:9696/api/v1/command -H $header -H 'Content-Type: application/json' --data-binary '@-'
        Write-Info "✅ LazyLibrarian added to Prowlarr - indexers syncing now" Green
    } else {
        Write-Host "⚠️  Prowlarr rejected the LazyLibrarian app (HTTP $code) - re-run once LazyLibrarian is up" -ForegroundColor Yellow
    }
}

Write-Info ""
Write-Info "One manual step: LazyLibrarian -> Config -> Downloaders -> qBittorrent:" Cyan
Write-Info "enter qBittorrent's WebUI username/password, then Test." Cyan
