#Requires -Version 5.0

<#
.SYNOPSIS
Applies this repo's opinionated Radarr/Sonarr/Seerr quality-profile setup via each app's REST API.

.DESCRIPTION
Radarr, Sonarr, and Seerr store their settings in a SQLite database, not
a file this repo can just commit - so unlike every other stack here,
"reproducible on a fresh server" means a script that talks to their
already-running REST APIs and (re)applies the desired state, not a
config file checked into git. This is that script.

What it does, idempotently (safe to re-run any time - on a fresh
deploy, after a Radarr/Sonarr database reset, or just to reassert
things if a setting drifted):

  1. Seerr, by default, points its one Radarr server and one Sonarr
     server at the SAME quality profile it uses for every request -
     there's no dedicated "4K" server entry, so a 4K-only profile
     silently becomes the profile for ALL requests. This splits each
     app into two Seerr server entries (same host/port/API key, just a
     different quality profile): a standard one with no 2160p tier at
     all, and a genuine is4k-flagged one - which makes Seerr show a
     real "Request in 4K" toggle instead of applying it to everything.

  2. The "Ultra-HD" profile (both apps ship this by default) starts
     out allowing ONLY 2160p releases with no fallback - if no 2160p
     release exists for a title, it sits unfulfilled forever, which is
     the bug this whole setup exists to fix. This enables 720p/1080p
     as allowed-but-lower-priority fallback qualities, turns on
     upgradeAllowed so it keeps hunting for a real 4K release
     afterward, and excludes Remux (regularly larger than a
     well-encoded non-remux 2160p file, so it doesn't serve as a
     genuine "lower quality" fallback).

  3. (Radarr only) Two new custom formats: "Hybrid DV+HDR10" (matches
     releases with both a Dolby Vision and an HDR tag, regardless of
     source - the stock "HDR" format's own DV sub-spec excludes
     WEB-DL/WEBRip, which misses genuine WEB-DL hybrids) and "Trusted
     HDR/DV Groups" (currently just AOC - extend the regex alternation
     in this script to add more). The Ultra-HD profile's custom format
     scores get the complete TRaSH-style template this repo's own
     "UHD Bluray + WEB" profile already had sitting unused, plus these
     two new formats. Trusted-group scoring is calibrated to need the
     Hybrid+HDR match too, not just the bare group tag - a release
     claiming only the group name still loses to the LQ blocklist's
     -10000, since Custom Formats can't see which indexer a release
     actually came from (title text is spoofable either way).

  4. Quality Definition max sizes (MB per minute of runtime) on both
     apps' 720p/1080p/2160p tiers - movies get a higher ceiling than
     TV, since one movie is a one-time cost but a TV series' total is
     open-ended (unknown how many seasons it'll run). Remux tiers are
     left uncapped since they're already excluded from every profile
     that matters and capping a "raw stream, no compression" format
     doesn't mean anything.

Requires Radarr, Sonarr, and Seerr already running (reads each app's
own auto-generated API key directly from its container - nothing
sensitive needs to be hardcoded here or committed anywhere).

.EXAMPLE
.\configure-quality-profiles.ps1
#>

$ErrorActionPreference = "Stop"

# ---------- preflight ----------

$docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
if (-not $docker) {
    $fallback = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path $fallback) { $docker = $fallback }
}
if (-not $docker) {
    Write-Host "❌ docker executable not found - is Docker Desktop running?" -ForegroundColor Red
    exit 1
}

function Test-ContainerHealthy {
    param([string]$Name)
    $status = & $docker inspect $Name --format '{{.State.Health.Status}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($status -eq 'healthy' -or $status -eq '')
}

foreach ($c in @('radarr', 'sonarr', 'seerr')) {
    if (-not (Test-ContainerHealthy $c)) {
        Write-Host "❌ Container '$c' isn't running (or isn't healthy yet) - start media-stack first." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Configure Radarr/Sonarr/Seerr Quality Profiles" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ---------- generic helpers ----------

function Get-ArrApiKey {
    # Radarr/Sonarr both write their own API key into config.xml on
    # first boot - reading it directly means nothing needs to be
    # entered or stored anywhere else.
    param([string]$Container)
    $raw = & $docker exec $Container sh -c "grep -o '<ApiKey>[^<]*</ApiKey>' /config/config.xml" 2>$null
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Could not read an API key from $Container's config.xml"
    }
    return ($raw -replace '</?ApiKey>', '')
}

function Get-SeerrApiKey {
    param([string]$RelayContainer)
    # Seerr's own container has neither curl nor jq (busybox wget only,
    # and wget can't do PUT) - every Seerr API call in this script goes
    # through curl running inside Radarr's container instead, which
    # shares media-network with Seerr and reaches it as http://seerr:5055.
    $json = & $docker exec seerr sh -c "cat /app/config/settings.json" 2>$null
    if ([string]::IsNullOrWhiteSpace($json)) { throw "Could not read Seerr's settings.json" }
    $key = ($json | & $docker exec -i $RelayContainer jq -r '.main.apiKey' 2>$null)
    if ([string]::IsNullOrWhiteSpace($key) -or $key -eq 'null') { throw "Could not read Seerr's API key" }
    return $key
}

function Invoke-ArrApi {
    # Ports aren't published to the host (confirmed live - `docker port`
    # returns nothing for any of these three apps), so every call runs
    # curl inside the target app's own container against localhost.
    param(
        [string]$Container, [int]$Port, [string]$ApiKey,
        [string]$Method, [string]$Path, [string]$Body = $null
    )
    $url = "http://localhost:$Port$Path"
    if ($Body) {
        $tmp = New-TemporaryFile
        try {
            $Body | Out-File -Encoding utf8 $tmp.FullName -NoNewline
            $result = Get-Content $tmp.FullName -Raw | & $docker exec -i $Container sh -c "curl -s -X $Method '$url' -H 'X-Api-Key: $ApiKey' -H 'Content-Type: application/json' --data-binary @-"
        } finally {
            Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
        }
    } else {
        $result = & $docker exec $Container curl -s -X $Method $url -H "X-Api-Key: $ApiKey"
    }
    return $result
}

function Invoke-SeerrApi {
    # Relayed through Radarr's container - see Get-SeerrApiKey.
    param([string]$RelayContainer, [string]$ApiKey, [string]$Method, [string]$Path, [string]$Body = $null)
    $url = "http://seerr:5055$Path"
    if ($Body) {
        $tmp = New-TemporaryFile
        try {
            $Body | Out-File -Encoding utf8 $tmp.FullName -NoNewline
            $result = Get-Content $tmp.FullName -Raw | & $docker exec -i $RelayContainer sh -c "curl -s -X $Method '$url' -H 'X-Api-Key: $ApiKey' -H 'Content-Type: application/json' --data-binary @-"
        } finally {
            Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
        }
    } else {
        $result = & $docker exec $RelayContainer curl -s -X $Method $url -H "X-Api-Key: $ApiKey"
    }
    return $result
}

function ConvertTo-CompactJson {
    param($InputObject)
    return ($InputObject | ConvertTo-Json -Depth 20 -Compress)
}

function Set-AllowedByName {
    # Recurses a quality profile's items tree, flipping `allowed` for
    # any node (leaf quality or WEB/group wrapper) whose name is in
    # $Names. Matches by name, not numeric quality id - ids happen to
    # already line up between Radarr and Sonarr for the qualities this
    # script touches, but name matching doesn't depend on that holding
    # true forever.
    param($Node, [string[]]$Names, [bool]$Value)
    $nodeName = if ($Node.quality) { $Node.quality.name } else { $Node.name }
    if ($nodeName -and ($Names -contains $nodeName)) { $Node.allowed = $Value }
    if ($Node.items) { foreach ($child in $Node.items) { Set-AllowedByName $child $Names $Value } }
}

function Find-QualityIdByName {
    # Named $QualityProfile, not $Profile - PSScriptAnalyzer flags $Profile
    # as shadowing PowerShell's own automatic variable of that name.
    param($QualityProfile, [string]$Name)
    foreach ($item in $QualityProfile.items) {
        if ($item.quality -and $item.quality.name -eq $Name) { return $item.quality.id }
        if ($item.items) {
            foreach ($child in $item.items) {
                if ($child.quality -and $child.quality.name -eq $Name) { return $child.quality.id }
            }
        }
    }
    throw "Quality '$Name' not found in this profile's items"
}

# The Ultra-HD 4K fallback ladder - same names in both apps' quality
# lists. 2160p tiers are already allowed by Radarr/Sonarr's stock
# Ultra-HD profile; this only needs to ADD the fallback tiers plus
# explicitly turn off Remux (see script header for why).
$fallbackQualityNames = @(
    'HDTV-720p', 'WEBDL-720p', 'WEBRip-720p', 'WEB 720p', 'Bluray-720p',
    'HDTV-1080p', 'WEBDL-1080p', 'WEBRip-1080p', 'WEB 1080p', 'Bluray-1080p'
)
$remuxQualityNames = @('Remux-1080p', 'Remux-2160p', 'Bluray-1080p Remux', 'Bluray-2160p Remux')

function Set-UltraHdProfile {
    param([string]$App, [string]$Container, [int]$Port, [string]$ApiKey, [string]$CutoffQualityName)

    $profiles = Invoke-ArrApi $Container $Port $ApiKey GET '/api/v3/qualityprofile' | ConvertFrom-Json -Depth 20
    $uhd = $profiles | Where-Object { $_.name -eq 'Ultra-HD' } | Select-Object -First 1
    if (-not $uhd) {
        Write-Host "⚠️  $App has no 'Ultra-HD' profile (expected as a stock default) - skipping." -ForegroundColor Yellow
        return
    }

    foreach ($item in $uhd.items) { Set-AllowedByName $item $fallbackQualityNames $true }
    foreach ($item in $uhd.items) { Set-AllowedByName $item $remuxQualityNames $false }
    $uhd.upgradeAllowed = $true
    $uhd.cutoff = Find-QualityIdByName $uhd $CutoffQualityName

    $null = Invoke-ArrApi $Container $Port $ApiKey PUT "/api/v3/qualityprofile/$($uhd.id)" (ConvertTo-CompactJson $uhd)
    Write-Host "✅ ${App}: Ultra-HD profile - 720p/1080p fallback enabled, Remux excluded, upgradeAllowed on, cutoff=$CutoffQualityName" -ForegroundColor Green
    return $uhd.id
}

function Get-OrCreateStandardProfile {
    # "HD - 720p/1080p" isn't a stock Radarr/Sonarr default - it's this
    # repo's own non-4K profile for Seerr's standard (non-4K) server
    # entry. Created from scratch if a fresh install doesn't have it
    # yet; left alone if it already exists (nothing here changes an
    # existing one's own tuning).
    param([string]$App, [string]$Container, [int]$Port, [string]$ApiKey)

    $profiles = Invoke-ArrApi $Container $Port $ApiKey GET '/api/v3/qualityprofile' | ConvertFrom-Json -Depth 20
    $std = $profiles | Where-Object { $_.name -eq 'HD - 720p/1080p' } | Select-Object -First 1
    if ($std) {
        Write-Host "✅ ${App}: 'HD - 720p/1080p' profile already exists (id $($std.id))" -ForegroundColor Green
        return $std.id
    }

    # Base it on the existing HD-1080p profile's item structure (a
    # guaranteed stock default) so it has the right quality id/name
    # shape, then widen it to include 720p too.
    $hd1080 = $profiles | Where-Object { $_.name -eq 'HD-1080p' } | Select-Object -First 1
    if (-not $hd1080) {
        Write-Host "⚠️  $App has neither 'HD - 720p/1080p' nor 'HD-1080p' to build from - skipping." -ForegroundColor Yellow
        return $null
    }
    $new = $hd1080 | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $new.PSObject.Properties.Remove('id')
    $new.name = 'HD - 720p/1080p'
    foreach ($item in $new.items) { Set-AllowedByName $item @('HDTV-720p', 'WEBDL-720p', 'WEBRip-720p', 'WEB 720p', 'Bluray-720p') $true }
    $new.upgradeAllowed = $false

    $created = Invoke-ArrApi $Container $Port $ApiKey POST '/api/v3/qualityprofile' (ConvertTo-CompactJson $new) | ConvertFrom-Json -Depth 20
    Write-Host "✅ ${App}: created 'HD - 720p/1080p' profile (id $($created.id))" -ForegroundColor Green
    return $created.id
}

function Set-QualityDefinitionMaxSizes {
    param([string]$App, [string]$Container, [int]$Port, [string]$ApiKey, [hashtable]$MaxByNamePattern)

    $defs = Invoke-ArrApi $Container $Port $ApiKey GET '/api/v3/qualitydefinition' | ConvertFrom-Json -Depth 10
    foreach ($def in $defs) {
        if ($def.quality.name -match 'Remux') { continue }
        foreach ($pattern in $MaxByNamePattern.Keys) {
            if ($def.quality.name -match $pattern) {
                # Bulk PUT /api/v3/qualitydefinition/update silently
                # no-ops on this Radarr/Sonarr version (confirmed live)
                # - individual PUTs per id are what actually persists.
                $def | Add-Member -NotePropertyName maxSize -NotePropertyValue $MaxByNamePattern[$pattern] -Force
                $null = Invoke-ArrApi $Container $Port $ApiKey PUT "/api/v3/qualitydefinition/$($def.id)" (ConvertTo-CompactJson $def)
                break
            }
        }
    }
    Write-Host "✅ ${App}: quality definition max sizes applied" -ForegroundColor Green
}

# ---------- Radarr ----------

Write-Host "--- Radarr ---" -ForegroundColor Cyan
$radarrKey = Get-ArrApiKey radarr
$radarrPort = 7878

Set-UltraHdProfile Radarr radarr $radarrPort $radarrKey 'Bluray-2160p' | Out-Null
$radarrStdProfileId = Get-OrCreateStandardProfile Radarr radarr $radarrPort $radarrKey

# Custom formats: Hybrid DV+HDR10, and trusted release groups (title-text
# matching only - see script header for why the trust score needs the
# Hybrid/HDR match too, not just the bare group tag).
$hybridSpec = @{
    name = 'Hybrid DV+HDR10'; includeCustomFormatWhenRenaming = $false
    specifications = @(@{
        name = 'DV+HDR co-occurrence'; implementation = 'ReleaseTitleSpecification'
        negate = $false; required = $true
        fields = @(@{ name = 'value'; value = '(?=.*\b(DV|DoVi|Dolby[ .]?Vision)\b)(?=.*\bHDR(10)?\b)' })
    })
}
# Extend this alternation to trust more release groups - each still
# needs the Hybrid+HDR match to actually clear the LQ blocklist's score.
$trustedGroupSpec = @{
    name = 'Trusted HDR/DV Groups'; includeCustomFormatWhenRenaming = $false
    specifications = @(@{
        name = 'AOC'; implementation = 'ReleaseTitleSpecification'
        negate = $false; required = $true
        fields = @(@{ name = 'value'; value = '(?<=-)(AOC)\b' })
    })
}

function Get-OrCreateCustomFormat {
    param([string]$Container, [int]$Port, [string]$ApiKey, [hashtable]$Spec)
    $existing = Invoke-ArrApi $Container $Port $ApiKey GET '/api/v3/customformat' | ConvertFrom-Json -Depth 20
    $match = $existing | Where-Object { $_.name -eq $Spec.name } | Select-Object -First 1
    if ($match) { return $match.id }
    $created = Invoke-ArrApi $Container $Port $ApiKey POST '/api/v3/customformat' (ConvertTo-CompactJson $Spec) | ConvertFrom-Json -Depth 20
    return $created.id
}

$hybridFormatId = Get-OrCreateCustomFormat radarr $radarrPort $radarrKey $hybridSpec
$trustedFormatId = Get-OrCreateCustomFormat radarr $radarrPort $radarrKey $trustedGroupSpec
Write-Host "✅ Radarr: custom formats ready (Hybrid DV+HDR10=$hybridFormatId, Trusted HDR/DV Groups=$trustedFormatId)" -ForegroundColor Green

# Full TRaSH-style scoring template, taken from this repo's own
# "UHD Bluray + WEB" profile (which had it sitting unused - every
# format in the actually-active Ultra-HD profile scored 0 before this).
$radarrFormatNameScores = @{
    'WEB Tier 01' = 1700; 'WEB Tier 02' = 1650; 'WEB Tier 03' = 1600
    'Repack/Proper' = 5; 'Repack2' = 6; 'Repack3' = 7
    'UHD Bluray Tier 01' = 1800; 'UHD Bluray Tier 02' = 1750; 'UHD Bluray Tier 03' = 1700
    'TrueHD ATMOS' = 5000; 'DTS X' = 4500; 'ATMOS (undefined)' = 3000; 'DD+ ATMOS' = 3000
    'TrueHD' = 2750; 'DTS-HD MA' = 2500; 'FLAC' = 2250; 'PCM' = 2250; 'DTS-HD HRA' = 2000
    'DD+' = 1750; 'DTS-ES' = 1500; 'DTS' = 1250; 'AAC' = 1000; 'DD' = 750
    'HDR' = 500; 'BCORE' = 15; 'CRiT' = 20; 'MA' = 20
    'x265 (no HDR/DV)' = -10000; '3D' = -10000; 'Bad Dual Groups' = -10000
    'Black and White Editions' = -10000; 'BR-DISK' = -10000; 'Extras' = -10000
    'Generated Dynamic HDR' = -10000; 'Line/Mic Dubbed' = -10000; 'LQ' = -10000
    'LQ (Release Title)' = -10000; 'Sing-Along Versions' = -10000; 'Upscaled' = -10000
    'Hybrid DV+HDR10' = 1500
    # Large enough that a genuine release (which also matches Hybrid
    # DV+HDR10 and/or HDR) clears the LQ blocklist's -10000 with a
    # comfortable margin, while a release claiming only the bare group
    # tag - with none of those other real quality signals - still
    # nets negative and stays rejected.
    'Trusted HDR/DV Groups' = 8500
}

$allFormats = Invoke-ArrApi radarr $radarrPort $radarrKey GET '/api/v3/customformat' | ConvertFrom-Json -Depth 20
$uhdProfile = Invoke-ArrApi radarr $radarrPort $radarrKey GET '/api/v3/qualityprofile' | ConvertFrom-Json -Depth 20 | Where-Object { $_.name -eq 'Ultra-HD' } | Select-Object -First 1
if ($uhdProfile) {
    # Rebuilt from scratch (one entry per known custom format, by id)
    # rather than "find the existing entry and update it, else append" -
    # confirmed live that the find-or-append version silently doubled
    # every targeted entry on a second run against this exact Radarr
    # instance (82 non-zero entries instead of 41 - a real duplication,
    # not a display artifact) despite the matching logic working
    # correctly in isolation. Root cause not pinned down for certain;
    # rebuilding sidesteps it by construction instead - Group-Object by
    # format id can't produce duplicates in its output regardless of
    # what the input array already contains.
    $existingByFormat = @{}
    foreach ($group in ($uhdProfile.formatItems | Group-Object -Property format)) {
        $existingByFormat[[int]$group.Name] = ($group.Group | Select-Object -Last 1)
    }
    $newFormatItems = @()
    foreach ($fmt in $allFormats) {
        $score = if ($radarrFormatNameScores.ContainsKey($fmt.name)) {
            $radarrFormatNameScores[$fmt.name]
        } elseif ($existingByFormat.ContainsKey([int]$fmt.id)) {
            $existingByFormat[[int]$fmt.id].score
        } else {
            0
        }
        $newFormatItems += [PSCustomObject]@{ format = $fmt.id; name = $fmt.name; score = $score }
    }
    $uhdProfile.formatItems = $newFormatItems
    $null = Invoke-ArrApi radarr $radarrPort $radarrKey PUT "/api/v3/qualityprofile/$($uhdProfile.id)" (ConvertTo-CompactJson $uhdProfile)
    Write-Host "✅ Radarr: Ultra-HD custom format scores applied" -ForegroundColor Green
}

Set-QualityDefinitionMaxSizes Radarr radarr $radarrPort $radarrKey @{ '720p' = 70; '1080p' = 130; '2160p' = 200 }

# ---------- Sonarr ----------

Write-Host ""
Write-Host "--- Sonarr ---" -ForegroundColor Cyan
$sonarrKey = Get-ArrApiKey sonarr
$sonarrPort = 8989

Set-UltraHdProfile Sonarr sonarr $sonarrPort $sonarrKey 'HDTV-2160p' | Out-Null
$sonarrStdProfileId = Get-OrCreateStandardProfile Sonarr sonarr $sonarrPort $sonarrKey
Set-QualityDefinitionMaxSizes Sonarr sonarr $sonarrPort $sonarrKey @{ '720p' = 35; '1080p' = 75; '2160p' = 135 }

# ---------- Seerr ----------

Write-Host ""
Write-Host "--- Seerr ---" -ForegroundColor Cyan
$seerrKey = Get-SeerrApiKey radarr

function Set-SeerrServerSplit {
    # Splits Seerr's Radarr/Sonarr connections into a standard (no 4K)
    # entry and a genuine is4k-flagged entry - see script header for
    # why this matters (without it, Seerr applies whatever profile the
    # ONE entry has to every request, 4K-toggled or not).
    param(
        [string]$App, [string]$Path, [string]$Hostname, [int]$Port, [string]$ApiKey,
        [int]$StdProfileId, [string]$StdProfileName, [int]$UhdProfileId,
        [string]$Directory, [string]$ExternalUrlHint, [scriptblock]$ExtraFields = {}
    )
    $servers = Invoke-SeerrApi radarr $seerrKey GET $Path | ConvertFrom-Json -Depth 20
    $std = $servers | Where-Object { -not $_.is4k } | Select-Object -First 1
    $uhd = $servers | Where-Object { $_.is4k } | Select-Object -First 1

    $base = @{
        hostname = $Hostname; port = $Port; apiKey = $ApiKey; useSsl = $false; baseUrl = ''
        activeDirectory = $Directory; minimumAvailability = 'announced'; tags = @()
        syncEnabled = $true; preventSearch = $false; tagRequests = $true
        externalUrl = if ($std -and $std.externalUrl) { $std.externalUrl } elseif ($uhd -and $uhd.externalUrl) { $uhd.externalUrl } else { $ExternalUrlHint }
    }

    $stdBody = $base.Clone()
    $stdBody.name = $App; $stdBody.is4k = $false; $stdBody.isDefault = $true
    $stdBody.activeProfileId = $StdProfileId; $stdBody.activeProfileName = $StdProfileName
    & $ExtraFields $stdBody $std

    $uhdBody = $base.Clone()
    $uhdBody.name = "$App 4K"; $uhdBody.is4k = $true; $uhdBody.isDefault = $true
    $uhdBody.activeProfileId = $UhdProfileId; $uhdBody.activeProfileName = 'Ultra-HD'
    & $ExtraFields $uhdBody $uhd

    if ($std) {
        $null = Invoke-SeerrApi radarr $seerrKey PUT "$Path/$($std.id)" (ConvertTo-CompactJson $stdBody)
        Write-Host "✅ Seerr: updated standard $App entry -> $StdProfileName" -ForegroundColor Green
    } else {
        $null = Invoke-SeerrApi radarr $seerrKey POST $Path (ConvertTo-CompactJson $stdBody)
        Write-Host "✅ Seerr: created standard $App entry -> $StdProfileName" -ForegroundColor Green
    }

    if ($uhd) {
        $null = Invoke-SeerrApi radarr $seerrKey PUT "$Path/$($uhd.id)" (ConvertTo-CompactJson $uhdBody)
        Write-Host "✅ Seerr: updated 4K $App entry -> Ultra-HD" -ForegroundColor Green
    } else {
        $null = Invoke-SeerrApi radarr $seerrKey POST $Path (ConvertTo-CompactJson $uhdBody)
        Write-Host "✅ Seerr: created 4K $App entry -> Ultra-HD" -ForegroundColor Green
    }
}

if ($radarrStdProfileId) {
    Set-SeerrServerSplit -App 'Radarr' -Path '/api/v1/settings/radarr' -Hostname 'radarr' -Port $radarrPort -ApiKey $radarrKey `
        -StdProfileId $radarrStdProfileId -StdProfileName 'HD - 720p/1080p' -UhdProfileId $uhdProfile.id `
        -Directory '/movies' -ExternalUrlHint ''
}

if ($sonarrStdProfileId) {
    $sonarrUhdId = (Invoke-ArrApi sonarr $sonarrPort $sonarrKey GET '/api/v3/qualityprofile' | ConvertFrom-Json -Depth 20 | Where-Object { $_.name -eq 'Ultra-HD' } | Select-Object -First 1).id
    Set-SeerrServerSplit -App 'Sonarr' -Path '/api/v1/settings/sonarr' -Hostname 'sonarr' -Port $sonarrPort -ApiKey $sonarrKey `
        -StdProfileId $sonarrStdProfileId -StdProfileName 'HD - 720p/1080p' -UhdProfileId $sonarrUhdId `
        -Directory '/tv' -ExternalUrlHint '' `
        -ExtraFields {
            param($body, $existing)
            # Anime gets its own profile pair too - 4K anime requests
            # use Ultra-HD same as regular 4K requests, standard anime
            # keeps whatever this instance already had configured (or
            # HD-1080p if this is a genuinely fresh install).
            $body.enableSeasonFolders = $true; $body.monitorNewItems = 'all'
            $body.tags = @(); $body.animeTags = @()
            if ($body.is4k) {
                $body.activeAnimeProfileId = $body.activeProfileId
                $body.activeAnimeProfileName = $body.activeProfileName
            } elseif ($existing -and $existing.activeAnimeProfileId) {
                $body.activeAnimeProfileId = $existing.activeAnimeProfileId
                $body.activeAnimeProfileName = $existing.activeAnimeProfileName
            } else {
                $body.activeAnimeProfileId = $body.activeProfileId
                $body.activeAnimeProfileName = $body.activeProfileName
            }
            $body.activeAnimeDirectory = $body.activeDirectory
        }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Done" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Confirm in Seerr (Settings -> Services) that both Radarr and both" -ForegroundColor White
Write-Host "Sonarr entries look right, and that a movie/show request now shows a" -ForegroundColor White
Write-Host "real 'Request in 4K' option separate from the standard request." -ForegroundColor White
Write-Host ""
