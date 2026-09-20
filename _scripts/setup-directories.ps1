#Requires -Version 5.0

<#
.SYNOPSIS
Setup Helper - Creates required directories and permissions

.DESCRIPTION
Sets up all required directories for Docker volumes and media storage.

.EXAMPLE
.\setup-directories.ps1

#>

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Setting Up Required Directories" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Define directories needed
$directories = @(
    # Media
    "D:\Media\Movies",
    "D:\Media\TV",
    "D:\Media\Music",
    "D:\Media\Books",
    "D:\Media\Photos",
    "D:\Media\Downloads",
    
    # Syncthing
    "D:\Sync",
    
    # Nextcloud
    "D:\Nextcloud",
    
    # Paperless
    "D:\Paperless\consume",
    "D:\Paperless\archive",
    
    # Backups
    "D:\Backups",
    "D:\Backups\docker",
    "D:\Backups\databases"
)

# Create directories
foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Host "✅ Created: $dir" -ForegroundColor Green
        }
        catch {
            Write-Host "❌ Failed to create: $dir" -ForegroundColor Red
            Write-Host "   Error: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "✅ Already exists: $dir" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Verifying Permissions" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Check permissions
foreach ($dir in $directories) {
    if (Test-Path $dir) {
        $acl = Get-Acl $dir
        $owner = $acl.Owner
        Write-Host "  $dir" -ForegroundColor White
        Write-Host "    Owner: $owner" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Setup Complete" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Run: .\gui-installer.ps1 (or configure .env manually)" -ForegroundColor White
Write-Host "  2. Run: .\deploy.ps1 -Action deploy" -ForegroundColor White
Write-Host "  3. Run: .\health-check.ps1" -ForegroundColor White
Write-Host ""
