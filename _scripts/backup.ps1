#Requires -Version 5.0

<#
.SYNOPSIS
Backup and Restore Script for Docker Home Lab

.DESCRIPTION
Automates backing up and restoring Docker volumes and important data.

.PARAMETER Action
backup - Create a backup (also pushes it off-site if Restic is configured)
restore - Restore from backup
list - List available backups
clean - Remove old local backups, keeping the last 5
offsite-snapshots - List off-site (Restic) snapshots
offsite-check - Verify off-site repository integrity

.EXAMPLE
.\backup.ps1 -Action backup

#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'ResticPassword', Justification='Passed straight through to `docker run -e` as a plain env var either way - SecureString would need decrypting back to plain text before use here, adding friction with no real security benefit. Matches how every other credential in this repo (GOTIFY_TOKEN, MAIL_ADMIN_PASSWORD, etc.) already flows through plain .env files and script parameters.')]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("backup", "restore", "list", "clean", "offsite-snapshots", "offsite-check")]
    [string]$Action,

    [string]$BackupName = "",
    [switch]$Full = $false,
    [string]$BackupRoot = "D:\Backups\docker",

    # Optional: notify Gotify when a backup finishes. Create an Application
    # in Gotify's web UI (gotify.DOMAIN -> Apps -> Create) to get a token -
    # there's no default token, this is opt-in.
    [string]$GotifyUrl = "",
    [string]$GotifyToken = "",

    # Optional: push each local backup off-site with Restic. Both must be
    # set for this to do anything - unset (the default) means local-only
    # backups, same as before this existed. RESTIC_REPOSITORY can be any
    # backend Restic supports (s3:..., b2:..., sftp:..., a plain local
    # path for testing); backend-specific credentials (e.g. B2_ACCOUNT_ID/
    # B2_ACCOUNT_KEY, AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY) are read
    # from this process's own environment - set them before invoking this
    # script rather than passing them as script parameters, since the set
    # of variables needed depends entirely on which backend you pick.
    [string]$ResticRepository = "",
    [string]$ResticPassword = "",

    # -Full skips volumes matching this regex: caches that re-download
    # themselves on demand (Hugging Face / Immich ML models - ~22GB of
    # the ~35GB total on this host) and anonymous volumes (64-hex names,
    # left behind by image-declared VOLUMEs, not app state). Pass "" to
    # back up everything.
    [string]$ExcludeVolumes = '(hf-cache|model-cache)$|^[0-9a-f]{64}$'
)

# Scheduled tasks don't inherit Docker Desktop's PATH entry on every
# setup - confirmed live on this host, where `docker` is on neither the
# machine nor the user PATH, so a scheduled -Full run found no volumes.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path "$dockerBin\docker.exe") { $env:Path += ";$dockerBin" }
}

$appRoot = Split-Path -Parent $PSScriptRoot
$backupRoot = $BackupRoot
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

function Send-GotifyNotification {
    param([string]$Title, [string]$Message, [int]$Priority = 5)
    if ([string]::IsNullOrEmpty($GotifyUrl) -or [string]::IsNullOrEmpty($GotifyToken)) { return }
    try {
        $body = @{ title = $Title; message = $Message; priority = $Priority } | ConvertTo-Json
        Invoke-RestMethod -Uri "$GotifyUrl/message?token=$GotifyToken" -Method Post -Body $body -ContentType "application/json" | Out-Null
    } catch {
        Write-Host "  (Gotify notification failed: $_)" -ForegroundColor Yellow
    }
}

function Invoke-Restic {
    # Runs restic via docker so no separate install is needed - same
    # pattern already used for volume backups (docker run --rm ... alpine
    # tar ...) above. Backend credentials (B2_ACCOUNT_ID, AWS_ACCESS_KEY_ID,
    # etc.) are forwarded from this process's own environment if present;
    # naming a var without a value tells `docker run` to read it from the
    # invoking shell, and an unset one just comes through empty - harmless,
    # since only the backend you've actually configured will have these set.
    param([string[]]$ResticArgs, [string]$MountPath = "")

    $dockerArgs = @(
        "run", "--rm",
        "-e", "RESTIC_REPOSITORY=$ResticRepository",
        "-e", "RESTIC_PASSWORD=$ResticPassword",
        "-e", "B2_ACCOUNT_ID", "-e", "B2_ACCOUNT_KEY",
        "-e", "AWS_ACCESS_KEY_ID", "-e", "AWS_SECRET_ACCESS_KEY", "-e", "AWS_DEFAULT_REGION",
        "-e", "AZURE_ACCOUNT_NAME", "-e", "AZURE_ACCOUNT_KEY",
        "-e", "GOOGLE_PROJECT_ID"
    )
    if ($MountPath) {
        $dockerArgs += @("-v", "${MountPath}:/data:ro")
    }
    $dockerArgs += @("restic/restic:latest")
    $dockerArgs += $ResticArgs

    & docker @dockerArgs
    # No explicit return: callers check the ambient $LASTEXITCODE directly
    # after calling this (matching how PowerShell already tracks the last
    # native command's exit code) rather than this function's own return
    # value - returning $LASTEXITCODE here would put it into the same
    # output stream as restic's own passthrough text, corrupting output
    # for callers (like Get-OffSiteSnapshots) that want to show it as-is.
}

function Test-ResticConfigured {
    if ([string]::IsNullOrEmpty($ResticRepository) -or [string]::IsNullOrEmpty($ResticPassword)) {
        Write-Host "Off-site backup not configured (set -ResticRepository and -ResticPassword to enable) - skipping." -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Backup-OffSite {
    param([string]$LocalBackupPath, [string]$BackupLabel)

    if (-not (Test-ResticConfigured)) { return }

    Write-Host ""
    Write-Host "Pushing off-site with Restic..." -ForegroundColor Cyan

    # `restic snapshots` fails on a repository that's never been
    # initialized - use that to decide whether `init` is needed, rather
    # than always attempting init and ignoring the "already exists" error.
    Invoke-Restic -ResticArgs @("snapshots") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Repository not yet initialized - running restic init..." -ForegroundColor White
        Invoke-Restic -ResticArgs @("init") | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  restic init failed - off-site backup skipped." -ForegroundColor Red
            Send-GotifyNotification -Title "Off-site backup failed" -Message "$BackupLabel - restic init failed" -Priority 8
            return
        }
    }

    Invoke-Restic -MountPath $LocalBackupPath -ResticArgs @("backup", "/data", "--tag", $BackupLabel) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  restic backup failed." -ForegroundColor Red
        Send-GotifyNotification -Title "Off-site backup failed" -Message "$BackupLabel - restic backup failed" -Priority 8
        return
    }

    Write-Host "  Off-site backup complete." -ForegroundColor Green
    Send-GotifyNotification -Title "Off-site backup complete" -Message $BackupLabel -Priority 3
}

function Get-OffSiteSnapshots {
    if (-not (Test-ResticConfigured)) { return }
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Off-Site Snapshots" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Invoke-Restic -ResticArgs @("snapshots")
}

function Test-OffSiteIntegrity {
    if (-not (Test-ResticConfigured)) { return }
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Checking Off-Site Repository Integrity" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Invoke-Restic -ResticArgs @("check") | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Repository integrity OK." -ForegroundColor Green
    } else {
        Write-Host "Repository integrity check FAILED." -ForegroundColor Red
        Send-GotifyNotification -Title "Off-site integrity check failed" -Message "restic check reported errors" -Priority 8
    }
}

# Every Postgres/MariaDB container in this repo, and how to dump it -
# `docker exec ... pg_dumpall`/`mysqldump` before the raw volume tar
# below, not instead of it: taring a database's data directory while its
# engine is live and writing (no stop step, no snapshot) risks a
# corrupted/inconsistent restore from uncommitted WAL or a torn write
# mid-copy. A dump asks the engine itself for a consistent, restorable
# snapshot instead. The raw volume copy still happens too for these
# containers - harmless, just redundant; prefer the dump for restores.
# Postgres dumps run as their own POSTGRES_USER via the container's local
# socket (trusted, no password needed - matches how these images'
# entrypoints authenticate themselves). MariaDB needs the root password
# explicitly, passed via MYSQL_PWD so it doesn't show up in `docker top`.
function Get-EnvValue {
    param([string]$EnvFile, [string]$Key)
    if (-not (Test-Path $EnvFile)) { return $null }
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split "=", 2)[1]
}

function Backup-Databases {
    param([string]$DumpPath)

    Write-Host ""
    Write-Host "Dumping databases (consistent snapshot, not a live volume copy)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $DumpPath -Force | Out-Null

    # Credentials live in each stack's own .env, not this script's - same
    # reasoning as every other cross-stack credential in this repo
    # (dashboard/HOMEPAGE_VAR_*, etc.): read them from the file directly
    # rather than requiring them to be duplicated into this script's own
    # environment ahead of time.
    $pgUser = Get-EnvValue "$appRoot\authentik\.env" "PG_USER"
    $immichUser = Get-EnvValue "$appRoot\immich-app\.env" "DB_USERNAME"
    $nextcloudRootPass = Get-EnvValue "$appRoot\privacy-stack\.env" "NEXTCLOUD_DB_ROOT_PASS"

    $databaseContainers = @(
        @{ Container = "authentik-postgresql"; Engine = "postgres"; User = $pgUser }
        @{ Container = "immich_postgres";      Engine = "postgres"; User = $immichUser }
        @{ Container = "paperless-db";         Engine = "postgres"; User = "paperless" }
        @{ Container = "wallabag-db";          Engine = "postgres"; User = "wallabag" }
        @{ Container = "nextcloud-db";         Engine = "mariadb";  User = "root"; RootPassword = $nextcloudRootPass }
    )

    foreach ($db in $databaseContainers) {
        $running = docker inspect $db.Container --format '{{.State.Running}}' 2>$null
        if ($running -ne "true") {
            Write-Host "  ⏭️  $($db.Container) not running - skipping (stack likely not deployed)" -ForegroundColor DarkGray
            continue
        }
        if (-not $db.User -or ($db.Engine -eq "mariadb" -and -not $db.RootPassword)) {
            Write-Host "  ⚠️  $($db.Container) is running but its credentials weren't found in .env - skipping, raw volume copy is the only backup for it this run" -ForegroundColor Yellow
            continue
        }

        $dumpFile = Join-Path $DumpPath "$($db.Container).sql"
        try {
            if ($db.Engine -eq "postgres") {
                docker exec $db.Container pg_dumpall -U $db.User 2>$null | Out-File -FilePath $dumpFile -Encoding utf8
            } else {
                # mariadb-dump, not mysqldump - confirmed live against
                # this image (mariadb:11.4.13): the mysqldump binary name
                # doesn't exist in it at all, only the newer mariadb-*
                # rename MariaDB ships now.
                docker exec -e "MYSQL_PWD=$($db.RootPassword)" $db.Container mariadb-dump -u $db.User --all-databases 2>$null | Out-File -FilePath $dumpFile -Encoding utf8
            }
            if ($LASTEXITCODE -eq 0 -and (Test-Path $dumpFile) -and (Get-Item $dumpFile).Length -gt 0) {
                Write-Host "  ✅ Dumped: $($db.Container)" -ForegroundColor Green
            } else {
                Write-Host "  ❌ Dump failed or empty: $($db.Container)" -ForegroundColor Red
                Send-GotifyNotification -Title "Backup: database dump failed" -Message "$($db.Container) - dump was empty or exited non-zero, raw volume copy is the only backup for it this run" -Priority 7
            }
        } catch {
            Write-Host "  ❌ Dump failed: $($db.Container) - $_" -ForegroundColor Red
            Send-GotifyNotification -Title "Backup: database dump failed" -Message "$($db.Container): $_" -Priority 7
        }
    }
}

function Create-Backup {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Creating Backup" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    $backupName = "backup_$timestamp"
    $backupPath = Join-Path $backupRoot $backupName
    
    # Create backup directory
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    Write-Host "✅ Backup directory created: $backupPath" -ForegroundColor Green
    
    # Backup .env files
    Write-Host ""
    Write-Host "Backing up configuration files..." -ForegroundColor Cyan
    $configPath = Join-Path $backupPath "config"
    New-Item -ItemType Directory -Path $configPath -Force | Out-Null
    
    # -Depth 1: every .env sits directly in a stack folder. A full -Recurse
    # walked into bind-mounted app data (immich-app/library - the whole
    # photo library) and took long enough that a scheduled run looked hung.
    Get-ChildItem $appRoot -Depth 1 -Filter ".env" | ForEach-Object {
        $dest = Join-Path $configPath $_.FullName.Replace("$appRoot\", "")
        $dir = Split-Path -Parent $dest
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item $_.FullName -Destination $dest -Force
        Write-Host "  ✅ Backed up: $($_.Name)" -ForegroundColor Green
    }
    
    # Database dumps - before the raw volume copy below, see
    # Backup-Databases for why (consistent snapshot vs. a live tar).
    if ($Full) {
        $dumpsPath = Join-Path $backupPath "dumps"
        Backup-Databases -DumpPath $dumpsPath
    }

    # Backup Docker volumes
    if ($Full) {
        Write-Host ""
        Write-Host "Backing up Docker volumes..." -ForegroundColor Cyan
        $volumesPath = Join-Path $backupPath "volumes"
        New-Item -ItemType Directory -Path $volumesPath -Force | Out-Null
        
        $volumes = docker volume ls --quiet
        if ($ExcludeVolumes) {
            $skipped = @($volumes | Where-Object { $_ -match $ExcludeVolumes })
            $volumes = @($volumes | Where-Object { $_ -notmatch $ExcludeVolumes })
            if ($skipped.Count) { Write-Host "  (skipping $($skipped.Count) cache/anonymous volume(s) - see -ExcludeVolumes)" -ForegroundColor DarkGray }
        }
        $failedVolumes = @()
        foreach ($vol in $volumes) {
            Write-Host "  → Backing up volume: $vol" -ForegroundColor White
            $volPath = Join-Path $volumesPath $vol
            docker run --rm -v "${vol}:/data" -v "${volPath}:/backup" alpine tar czf /backup/data.tar.gz -C /data .
            # A non-zero exit means a cut-short archive (e.g. Docker
            # crashing mid-write, as on 2026-09-25) - never report it as
            # backed up. test-restore.ps1 checks the archives monthly too.
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ❌ FAILED: $vol (tar exit $LASTEXITCODE)" -ForegroundColor Red
                $failedVolumes += $vol
            } else {
                Write-Host "  ✅ Backed up: $vol" -ForegroundColor Green
            }
        }
        if ($failedVolumes.Count) {
            Send-GotifyNotification -Title "Backup: volume archive failed" -Message "$backupName - incomplete: $($failedVolumes -join ', ')" -Priority 8
        }
    }
    
    # Create manifest
    $manifest = @{
        Date = Get-Date
        Timestamp = $timestamp
        Full = $Full
        IncludedVolumes = if ($Full) { $volumes.Count } else { 0 }
        FailedVolumes = if ($Full) { $failedVolumes } else { @() }
        IncludedConfigs = (Get-ChildItem $appRoot -Depth 1 -Filter ".env" | Measure-Object).Count
    }
    
    $manifest | ConvertTo-Json | Out-File -FilePath "$backupPath\manifest.json" -Encoding UTF8 -Force
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Backup Complete" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "Location: $backupPath" -ForegroundColor Cyan
    $sizeMb = "{0:N2}" -f ((Get-ChildItem $backupPath -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB)
    Write-Host "Size: $sizeMb MB" -ForegroundColor Cyan
    Write-Host ""

    Send-GotifyNotification -Title "Backup complete" -Message "$backupName ($sizeMb MB)" -Priority 3

    Backup-OffSite -LocalBackupPath $backupPath -BackupLabel $backupName
}

function List-Backups {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Available Backups" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-Path $backupRoot)) {
        Write-Host "No backups found" -ForegroundColor Yellow
        return
    }
    
    $backups = Get-ChildItem $backupRoot -Directory | Sort-Object -Property Name -Descending
    
    foreach ($backup in $backups) {
        $manifest = Get-Content "$($backup.FullPath)\manifest.json" -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        $size = ("{0:N2}" -f ((Get-ChildItem $backup.FullPath -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB))
        
        Write-Host "  📦 $($backup.Name)" -ForegroundColor Cyan
        if ($manifest) {
            Write-Host "     Date: $($manifest.Date)" -ForegroundColor White
            Write-Host "     Size: $size MB" -ForegroundColor White
            Write-Host "     Full: $($manifest.Full)" -ForegroundColor White
        }
    }
    
    Write-Host ""
}

function Restore-Backup {
    param([string]$BackupName)
    
    if ([string]::IsNullOrEmpty($BackupName)) {
        Write-Host "Specify backup name: -BackupName <name>" -ForegroundColor Red
        return
    }
    
    $backupPath = Join-Path $backupRoot $BackupName
    
    if (-not (Test-Path $backupPath)) {
        Write-Host "Backup not found: $BackupName" -ForegroundColor Red
        return
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  Restore Backup" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "⚠️  WARNING: This will overwrite current configuration!" -ForegroundColor Red
    Write-Host ""
    
    $confirm = Read-Host "Restore from $BackupName? (y/N)"
    if ($confirm -ne "y") {
        Write-Host "Cancelled" -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "Restoring configuration files..." -ForegroundColor Cyan
    
    $configPath = Join-Path $backupPath "config"
    if (Test-Path $configPath) {
        Get-ChildItem $configPath -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Replace($configPath, "")
            $destPath = Join-Path $appRoot $relativePath.TrimStart('\')
            $dir = Split-Path -Parent $destPath
            
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Copy-Item $_.FullName -Destination $destPath -Force
            Write-Host "  ✅ Restored: $(Split-Path -Leaf $_)" -ForegroundColor Green
        }
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Restore Complete" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
}

function Clean-OldBackups {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  Cleaning Old Backups" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    
    if (-not (Test-Path $backupRoot)) {
        Write-Host "No backups to clean" -ForegroundColor Cyan
        return
    }
    
    $backups = Get-ChildItem $backupRoot -Directory | Sort-Object -Property CreationTime
    $keep = $backups | Select-Object -Last 5
    $remove = $backups | Where-Object {$_ -notin $keep}
    
    foreach ($backup in $remove) {
        $size = ("{0:N2}" -f ((Get-ChildItem $backup.FullName -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB))
        Remove-Item $backup.FullName -Recurse -Force
        Write-Host "  ✅ Removed: $($backup.Name) ($size MB)" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "Keeping last 5 backups" -ForegroundColor Cyan
    Write-Host ""
}

# Main execution
switch ($Action) {
    "backup" {
        Create-Backup
    }
    "restore" {
        Restore-Backup $BackupName
    }
    "list" {
        List-Backups
    }
    "clean" {
        Clean-OldBackups
    }
    "offsite-snapshots" {
        Get-OffSiteSnapshots
    }
    "offsite-check" {
        Test-OffSiteIntegrity
    }
}
