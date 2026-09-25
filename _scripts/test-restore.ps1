#Requires -Version 5.0

<#
.SYNOPSIS
Monthly restore test: proves last night's backup can actually be restored.

.DESCRIPTION
A backup nobody has restored is a hope, not a backup. This takes the newest
D:\Backups\docker\backup_* folder (written by backup.ps1) and, without
touching any live container or volume:

  1. Volume archives - every volumes\<name>\data.tar.gz is read end to end
     (gzip -t plus a full tar listing), so a truncated or corrupt archive
     is caught now rather than on the day it's needed.
  2. Database dumps  - each dumps\*.sql must end with its tool's "dump
     complete" footer (a dump cut short by a crash or full disk doesn't),
     then is REALLY restored into a throwaway container of the same image
     as the live database (same Postgres/MariaDB version and extensions,
     e.g. Immich's vectorchord). Pass = every database comes back with
     tables in it. Throwaway containers run with --rm and no named volumes,
     so they leave nothing behind.
  3. Config          - every stack with a live .env has one in config\.

Results go to the console and, if GOTIFY_TOKEN is set in utilities\.env,
to Gotify (sent from a short-lived curl container on notification-network,
so no public address is needed).

Runs every 4 weeks (Sunday 5 AM) as the "Homelab_Restore_Test" scheduled
task, after that night's backup. It takes
roughly 10-20 minutes, mostly restoring Immich's database.

.EXAMPLE
.\test-restore.ps1
.\test-restore.ps1 -BackupName backup_2026-09-25_02-00-02 -SkipVolumes
#>

param(
    [string]$BackupRoot = "D:\Backups\docker",
    [string]$BackupName = "",
    [string]$LiveRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$SkipVolumes,
    [switch]$NoNotify
)

$ErrorActionPreference = "Continue"

# Scheduled tasks don't always inherit Docker Desktop's PATH entry - same
# fallback as backup.ps1 / health-check.ps1.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path "$dockerBin\docker.exe") { $env:Path += ";$dockerBin" }
}

$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
function Pass([string]$m) { $passes.Add($m); Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail([string]$m) { $failures.Add($m); Write-Host "  FAIL  $m" -ForegroundColor Red }

function Get-EnvValue([string]$File, [string]$Key) {
    if (-not (Test-Path $File)) { return "" }
    $line = Get-Content $File | Where-Object { $_ -match "^\s*$Key\s*=" } | Select-Object -First 1
    if (-not $line) { return "" }
    return ($line -replace "^\s*$Key\s*=\s*", "").Trim().Trim('"').Trim("'")
}

function Send-Gotify([string]$Title, [string]$Message, [int]$Priority) {
    if ($NoNotify) { return }
    $token = Get-EnvValue (Join-Path $LiveRoot "utilities\.env") "GOTIFY_TOKEN"
    if ([string]::IsNullOrEmpty($token) -or $token -like "CHANGE_ME*") { return }
    $body = @{ title = $Title; message = $Message; priority = $Priority } | ConvertTo-Json -Compress
    $tmp = Join-Path $env:TEMP "restore-test-gotify.json"
    [System.IO.File]::WriteAllText($tmp, $body)
    docker run --rm --network notification-network -v "${tmp}:/body.json:ro" curlimages/curl:latest `
        -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" `
        --data-binary "@/body.json" "http://gotify:80/message?token=$token" | Out-Null
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# Waits for a throwaway database container to accept connections.
function Wait-Ready([string]$Name, [string[]]$Probe, [int]$Seconds = 180) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        docker exec $Name @Probe *> $null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

# --- Pick the backup ---------------------------------------------------------
if ($BackupName) {
    $backup = Get-Item (Join-Path $BackupRoot $BackupName) -ErrorAction SilentlyContinue
} else {
    $backup = Get-ChildItem $BackupRoot -Directory -Filter "backup_*" | Sort-Object Name | Select-Object -Last 1
}
if (-not $backup) {
    Write-Host "No backup found under $BackupRoot" -ForegroundColor Red
    Send-Gotify "Restore test FAILED" "No backup folder found under $BackupRoot." 8
    exit 1
}
$started = Get-Date
Write-Host ""
Write-Host "Restore test: $($backup.Name)" -ForegroundColor Cyan

$ageHours = [math]::Round(((Get-Date) - $backup.CreationTime).TotalHours)
if ($ageHours -gt 48) { Fail "newest backup is $ageHours hours old (nightly backup not running?)" }

# --- 1. Volume archives --------------------------------------------------------
Write-Host ""
Write-Host "Volume archives" -ForegroundColor Cyan
$volDir = Join-Path $backup.FullName "volumes"
if ($SkipVolumes) {
    Write-Host "  (skipped)" -ForegroundColor Gray
} elseif (-not (Test-Path $volDir)) {
    Fail "no volumes\ folder in backup"
} else {
    # One container reads every archive; each prints OK/BAD <volume>.
    $check = 'for d in /b/*/; do n=$(basename "$d"); f="$d/data.tar.gz"; ' +
             'if [ ! -s "$f" ]; then echo "BAD $n missing-or-empty"; continue; fi; ' +
             'if gzip -t "$f" 2>/dev/null && tar -tzf "$f" >/dev/null 2>&1; then echo "OK $n"; else echo "BAD $n corrupt"; fi; done'
    $out = docker run --rm -v "${volDir}:/b:ro" alpine:3.22 sh -c $check
    $ok = 0
    foreach ($line in $out) {
        if ($line -like "OK *") { $ok++ }
        elseif ($line -like "BAD *") { Fail "volume $($line.Substring(4))" }
    }
    if ($ok -gt 0) { Pass "$ok volume archives read end to end" }
    if (-not $out) { Fail "volume check produced no output" }
}

# --- 2. Database dumps ---------------------------------------------------------
Write-Host ""
Write-Host "Database dumps" -ForegroundColor Cyan
$dumpDir = Join-Path $backup.FullName "dumps"
$dumps = Get-ChildItem $dumpDir -Filter "*.sql" -ErrorAction SilentlyContinue
if (-not $dumps) { Fail "no database dumps in backup" }

foreach ($dump in $dumps) {
    $source = $dump.BaseName      # dumps are named after their live container
    $tail = (Get-Content $dump.FullName -Tail 15) -join "`n"
    $isPg = $tail -match "PostgreSQL database cluster dump complete"
    $isMaria = $tail -match "-- Dump completed on"
    if (-not ($isPg -or $isMaria)) {
        Fail "$source dump is truncated (no completion footer)"
        continue
    }

    # Same image (and for Postgres, same command - Immich's needs its
    # config_file for vectorchord) as the live database.
    $image = docker inspect $source --format '{{.Config.Image}}' 2>$null
    if (-not $image) { Fail "$source - live container not found, can't pick an image"; continue }
    $cmdJson = docker inspect $source --format '{{json .Config.Cmd}}' 2>$null
    $cmd = @()
    if ($isPg -and $cmdJson -and $cmdJson -ne "null") { $cmd = @($cmdJson | ConvertFrom-Json) }

    $name = "restore-test-$source"
    $pw = [guid]::NewGuid().ToString("N")
    docker stop $name *> $null   # leftover from an interrupted run (--rm removes it)

    if ($isPg) {
        docker run -d --rm --name $name -e "POSTGRES_PASSWORD=$pw" -e POSTGRES_USER=postgres `
            --memory 2g $image @cmd | Out-Null
        $ready = Wait-Ready $name @("pg_isready", "-U", "postgres", "-h", "127.0.0.1")
    } else {
        docker run -d --rm --name $name -e "MARIADB_ROOT_PASSWORD=$pw" --memory 2g $image | Out-Null
        $ready = Wait-Ready $name @("mariadb-admin", "-uroot", "-p$pw", "ping")
    }
    if (-not $ready) { Fail "$source - throwaway $image never became ready"; docker stop $name *> $null; continue }

    # Dumps are written by PowerShell's Out-File, which adds a UTF-8 BOM -
    # strip it or the first statement fails to parse.
    docker cp $dump.FullName "${name}:/tmp/dump.sql" | Out-Null
    docker exec $name sed -i '1s/^\xEF\xBB\xBF//' /tmp/dump.sql

    if ($isPg) {
        $errs = docker exec $name sh -c "psql -U postgres -q -f /tmp/dump.sql -o /dev/null 2>&1 | grep -c ERROR"
        $q = "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"
        $dbs = docker exec $name psql -U postgres -At -c $q
        $summary = @()
        $empty = @()
        foreach ($db in $dbs) {
            if (-not $db) { continue }
            $n = docker exec $name psql -U postgres -d $db -At -c "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')"
            $summary += "$db=$n"
            if ([int]$n -eq 0) { $empty += $db }
        }
    } else {
        $errs = docker exec $name sh -c "mariadb -uroot -p$pw < /tmp/dump.sql 2>&1 | grep -c ERROR"
        $q = "SELECT table_schema, count(*) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') GROUP BY table_schema"
        $rows = docker exec $name mariadb -uroot "-p$pw" -N -e $q
        $summary = @()
        $empty = @()
        foreach ($r in $rows) { $p = $r -split "\s+"; $summary += "$($p[0])=$($p[1])" }
        if (-not $rows) { $empty += "(all)" }
    }
    docker stop $name *> $null

    # A few errors are expected from pg_dumpall (e.g. "role postgres already
    # exists"); what matters is that the data came back.
    if (-not $summary -or $empty.Count -gt 0) {
        Fail "$source restored with no tables in: $($empty -join ', ') (errors: $errs)"
    } else {
        Pass "$source restored - tables $($summary -join ', ') (errors: $errs)"
    }
}

# --- 3. Config ---------------------------------------------------------------
Write-Host ""
Write-Host "Config" -ForegroundColor Cyan
$missing = @()
Get-ChildItem $LiveRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".env") } | ForEach-Object {
    if (-not (Test-Path (Join-Path $backup.FullName "config\$($_.Name)\.env"))) { $missing += $_.Name }
}
if ($missing) { Fail "config backup is missing .env for: $($missing -join ', ')" } else { Pass "every stack's .env is in the backup" }

# --- 4. Off-site copy (only if _scripts\offsite.env is filled in) ------------
$offsiteEnv = Join-Path $PSScriptRoot "offsite.env"
$repo = Get-EnvValue $offsiteEnv "RESTIC_REPOSITORY"
$repoPw = Get-EnvValue $offsiteEnv "RESTIC_PASSWORD"
if ($repo -and $repoPw) {
    Write-Host ""
    Write-Host "Off-site copy" -ForegroundColor Cyan
    $rArgs = @("run", "--rm", "-e", "RESTIC_PASSWORD=$repoPw", "-v", "restic-cache:/root/.cache/restic")
    if ($repo -match '^[A-Za-z]:\\') { $rArgs += @("-e", "RESTIC_REPOSITORY=/repo", "-v", "${repo}:/repo:ro") }
    else { $rArgs += @("-e", "RESTIC_REPOSITORY=$repo") }
    $rArgs += "restic/restic:latest"

    $snapJson = docker @rArgs snapshots --host homelab --latest 1 --json --no-lock 2>$null
    $latest = $null
    try { $latest = ($snapJson | ConvertFrom-Json) | Select-Object -Last 1 } catch {}
    if (-not $latest) {
        Fail "off-site repository has no snapshots (or can't be opened)"
    } else {
        # Restic prints nanoseconds, more than [datetime] parses - drop them.
        $snapTime = [datetime]::Parse(("$($latest.time)" -replace '\.\d+', ''), [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal)
        $age = [math]::Round(((Get-Date).ToUniversalTime() - $snapTime).TotalHours)
        if ($age -gt 48) { Fail "newest off-site snapshot is $age hours old" } else { Pass "newest off-site snapshot is $age hours old" }
        # Structure check plus re-reading a random 2% of the stored data,
        # so corruption anywhere is caught within a few months.
        docker @rArgs check --read-data-subset 2% --no-lock *> $null
        if ($LASTEXITCODE -eq 0) { Pass "off-site repository check (2% of data re-read)" } else { Fail "off-site repository check reported errors" }
    }
}

# --- Report --------------------------------------------------------------------
$mins = [math]::Round(((Get-Date) - $started).TotalMinutes)
Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "Restore test PASSED ($($passes.Count) checks, $mins min)" -ForegroundColor Green
    Send-Gotify "Restore test passed" ("$($backup.Name) restored cleanly in $mins min.`n" + ($passes -join "`n")) 3
    exit 0
} else {
    Write-Host "Restore test FAILED ($($failures.Count) problems)" -ForegroundColor Red
    Send-Gotify "Restore test FAILED" ("$($backup.Name):`n" + ($failures -join "`n")) 8
    exit 1
}
