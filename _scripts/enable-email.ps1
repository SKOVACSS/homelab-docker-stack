#Requires -Version 5.0

<#
.SYNOPSIS
Turns on the email server (Mailu) after initial setup, without re-running gui-installer.ps1.

.DESCRIPTION
gui-installer.ps1 lets you skip setting up email-stack entirely (it's the
most complex, fragile stack in this repo - not everyone wants to run
their own mail server). This script fills that gap in later: it writes
email-stack\.env, sets caddy\.env's MAIL_DOMAIN, and tells you exactly
what's left to do in the Cloudflare dashboard and to deploy.

Safe to run against an already-configured email-stack too (with
confirmation first) - useful for rotating MAIL_ADMIN_PASSWORD or moving
Mailu to a different domain later.

.PARAMETER MailDomain
The domain Mailu should use. Defaults to the same domain caddy\.env
already uses for everything else if you don't pass this - only set it
separately if this domain already has real email through another
provider (Proton Mail, Google Workspace, etc.), since a domain can only
have one real mail provider at a time.

.EXAMPLE
.\enable-email.ps1
.\enable-email.ps1 -MailDomain mail-only-domain.com
#>

param(
    [string]$MailDomain = ""
)

$appRoot = Split-Path -Parent $PSScriptRoot
$caddyEnvPath = "$appRoot\caddy\.env"
$emailEnvPath = "$appRoot\email-stack\.env"

function Generate-SecurePassword {
    # Same cryptographic RNG approach as gui-installer.ps1 - duplicated
    # rather than shared, since this repo has no shared PowerShell module
    # and it's a handful of lines.
    param([int]$Length = 32)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*'
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Set-EnvValue {
    # Updates KEY=value in an existing .env file if the key is already
    # there, or appends it if not - preserves every other line untouched,
    # so this is safe to run against a real, hand-edited .env.
    param([string]$Path, [string]$Key, [string]$Value)
    $line = "$Key=$Value"
    if (Test-Path $Path) {
        $content = Get-Content $Path
        if ($content -match "^$Key=") {
            $content = $content -replace "^$Key=.*", $line
            $content | Set-Content $Path -Encoding UTF8
            return
        }
        Add-Content -Path $Path -Value $line -Encoding UTF8
        return
    }
    $line | Out-File $Path -Encoding UTF8
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Enable Email Server (Mailu)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $caddyEnvPath)) {
    Write-Host "❌ caddy\.env not found - run gui-installer.ps1 first (this script only" -ForegroundColor Red
    Write-Host "   adds email-stack on top of an already-configured deployment)." -ForegroundColor Red
    exit 1
}

if (Test-Path $emailEnvPath) {
    Write-Host "⚠️  email-stack\.env already exists - email-stack looks already configured." -ForegroundColor Yellow
    Write-Host "   Continuing regenerates MAILU_SECRET_KEY and MAIL_ADMIN_PASSWORD." -ForegroundColor Yellow
    Write-Host "   This does not delete mail data (Mailu keeps its own SQLite database" -ForegroundColor Yellow
    Write-Host "   in the mailu-data volume, untouched by either of those two values) -" -ForegroundColor Yellow
    Write-Host "   it changes the admin login password and invalidates existing sessions" -ForegroundColor Yellow
    Write-Host "   (INITIAL_ADMIN_MODE=update means the account is updated, not recreated)." -ForegroundColor Yellow
    $confirm = Read-Host "Continue and overwrite? (y/N)"
    if ($confirm -ne "y") {
        Write-Host "Cancelled - nothing changed." -ForegroundColor Cyan
        exit 0
    }
}

$mainDomain = (Get-Content $caddyEnvPath | Where-Object { $_ -match "^DOMAIN=" } | Select-Object -First 1) -replace "^DOMAIN=", ""
if ([string]::IsNullOrEmpty($mainDomain)) {
    Write-Host "❌ Could not read DOMAIN from caddy\.env - is that file intact?" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrEmpty($MailDomain)) {
    Write-Host "Domain for everything else: $mainDomain" -ForegroundColor White
    Write-Host ""
    Write-Host "Does this domain already have real email through another provider" -ForegroundColor White
    Write-Host "(Proton Mail, Google Workspace, etc.)? If so, Mailu needs a DIFFERENT" -ForegroundColor White
    Write-Host "domain - a domain can only have one real mail provider at a time." -ForegroundColor White
    $mailDomainInput = Read-Host "Mail Domain (press Enter to use $mainDomain)"
    $MailDomain = if ([string]::IsNullOrWhiteSpace($mailDomainInput)) { $mainDomain } else { $mailDomainInput.Trim() }
}

Write-Host ""
Write-Host "Before continuing, confirm you've already done this in the Cloudflare" -ForegroundColor White
Write-Host "dashboard for $MailDomain (see SETUP.md step 1 - same steps as the main" -ForegroundColor White
Write-Host "domain, repeated for this one if it's different):" -ForegroundColor White
Write-Host "  1. Wildcard (*) and 'mail' Public Hostname rules on your existing tunnel" -ForegroundColor White
Write-Host "  2. A cache-bypass rule for this domain's subdomains" -ForegroundColor White
Write-Host "  3. CLOUDFLARE_API_TOKEN in caddy\.env has Zone:DNS:Edit permission" -ForegroundColor White
Write-Host "     for THIS domain too, not just $mainDomain" -ForegroundColor White
$ready = Read-Host "Done all three? (y/N)"
if ($ready -ne "y") {
    Write-Host "Come back once that's done - nothing has been changed." -ForegroundColor Cyan
    exit 0
}

$mailuSecretKey = Generate-SecurePassword 24
$mailAdminPassword = Generate-SecurePassword

$emailEnv = @"
# Same as caddy\.env's MAIL_DOMAIN - must match exactly.
DOMAIN=$MailDomain
MAILU_SECRET_KEY=$mailuSecretKey
MAIL_ADMIN_USER=admin
MAIL_ADMIN_PASSWORD=$mailAdminPassword
TZ=UTC
"@
$emailEnv | Out-File $emailEnvPath -Encoding UTF8 -Force

Set-EnvValue -Path $caddyEnvPath -Key "MAIL_DOMAIN" -Value $MailDomain

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Done" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "email-stack\.env written. caddy\.env's MAIL_DOMAIN set to: $MailDomain" -ForegroundColor White
Write-Host ""
Write-Host "Admin login (save this in your password manager now):" -ForegroundColor Yellow
Write-Host "  URL:      https://mailadmin.$MailDomain (also works at webmail.$MailDomain)" -ForegroundColor White
Write-Host "  User:     admin" -ForegroundColor White
Write-Host "  Password: $mailAdminPassword" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. .\deploy.ps1 -Action restart -Stack caddy    # picks up the new MAIL_DOMAIN" -ForegroundColor White
Write-Host "  2. .\deploy.ps1 -Action deploy -Stack email-stack" -ForegroundColor White
Write-Host "  3. .\health-check.ps1                           # confirm it comes up healthy" -ForegroundColor White
Write-Host ""
