#Requires -Version 5.0

<#
.SYNOPSIS
Backup and Restore Script for Docker Home Lab

.DESCRIPTION
Automates backing up and restoring Docker volumes and important data.

.PARAMETER Action
backup - Create a backup
restore - Restore from backup
list - List available backups

.EXAMPLE
.\backup.ps1 -Action backup

#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("backup", "restore", "list", "clean")]
    [string]$Action,

    [string]$BackupName = "",
    [switch]$Full = $false,
    [string]$BackupRoot = "D:\Backups\docker",

    # Optional: notify Gotify when a backup finishes. Create an Application
    # in Gotify's web UI (gotify.DOMAIN -> Apps -> Create) to get a token -
    # there's no default token, this is opt-in.
    [string]$GotifyUrl = "",
    [string]$GotifyToken = ""
)

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
    
    Get-ChildItem $appRoot -Recurse -Filter ".env" | ForEach-Object {
        $dest = Join-Path $configPath $_.FullName.Replace("$appRoot\", "")
        $dir = Split-Path -Parent $dest
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item $_.FullName -Destination $dest -Force
        Write-Host "  ✅ Backed up: $($_.Name)" -ForegroundColor Green
    }
    
    # Backup Docker volumes
    if ($Full) {
        Write-Host ""
        Write-Host "Backing up Docker volumes..." -ForegroundColor Cyan
        $volumesPath = Join-Path $backupPath "volumes"
        New-Item -ItemType Directory -Path $volumesPath -Force | Out-Null
        
        $volumes = docker volume ls --quiet
        foreach ($vol in $volumes) {
            Write-Host "  → Backing up volume: $vol" -ForegroundColor White
            $volPath = Join-Path $volumesPath $vol
            docker run --rm -v "${vol}:/data" -v "${volPath}:/backup" alpine tar czf /backup/data.tar.gz -C /data .
            Write-Host "  ✅ Backed up: $vol" -ForegroundColor Green
        }
    }
    
    # Create manifest
    $manifest = @{
        Date = Get-Date
        Timestamp = $timestamp
        Full = $Full
        IncludedVolumes = if ($Full) { $volumes.Count } else { 0 }
        IncludedConfigs = (Get-ChildItem $appRoot -Recurse -Filter ".env" | Measure-Object).Count
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
}
