#Requires -Version 5.0

<#
.SYNOPSIS
Adds "Log in with Authentik" to Nextcloud (user_oidc app). Safe to re-run.

.DESCRIPTION
Authentik's side is authentik/blueprints/app-logins.yaml (client "nextcloud").
This installs Nextcloud's official user_oidc app and registers Authentik
as a provider. The client secret is read inside the container from
NEXTCLOUD_OIDC_CLIENT_SECRET (privacy-stack/.env) - it never appears on a
command line or in this script's output.

Accounts: Authentik sends the username as the user ID, so signing in as
an Authentik user whose name matches an existing Nextcloud account lands
in that account; anyone else gets a new Nextcloud account on first login.
The normal Nextcloud login form stays available for local accounts and
app passwords (desktop/phone sync clients keep using those).

allow_local_remote_servers is turned on because auth.DOMAIN resolves to
Caddy's private caddy-network address inside Docker (see caddy's network
alias), and Nextcloud otherwise refuses to fetch from private addresses.

.EXAMPLE
.\configure-nextcloud-oidc.ps1
#>

$ErrorActionPreference = 'Stop'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = 'C:\Program Files\Docker\Docker\resources\bin'
    if (Test-Path $dockerBin) { $env:Path += ";$dockerBin" } else { throw 'docker not found' }
}

# Piped to sh via stdin: Windows PowerShell 5.1 strips embedded double
# quotes from native-command arguments, which would mangle this.
$script = @'
set -e
occ() { php /var/www/html/occ "$@"; }
if [ -z "$NEXTCLOUD_OIDC_CLIENT_SECRET" ]; then
  echo "NEXTCLOUD_OIDC_CLIENT_SECRET is not set in privacy-stack/.env - recreate the nextcloud container after adding it." >&2
  exit 1
fi
DOMAIN="${OVERWRITEHOST#nextcloud.}"
if occ app:list --shipped=false | grep -q 'user_oidc'; then
  occ app:enable user_oidc >/dev/null
else
  occ app:install user_oidc
fi
occ config:system:set allow_local_remote_servers --value=true --type=boolean >/dev/null
occ user_oidc:provider Authentik \
  --clientid=nextcloud \
  --clientsecret="$NEXTCLOUD_OIDC_CLIENT_SECRET" \
  --discoveryuri="https://auth.$DOMAIN/application/o/nextcloud/.well-known/openid-configuration" \
  --scope="openid email profile" \
  --unique-uid=0 \
  --mapping-uid=preferred_username \
  --mapping-display-name=name \
  --mapping-email=email \
  --send-id-token-hint=1 >/dev/null
echo "Authentik login configured."
occ user_oidc:provider | grep -i authentik >/dev/null && echo "Provider registered."
'@

$script -replace "`r", '' | docker exec -i -u www-data nextcloud sh
if ($LASTEXITCODE -ne 0) { throw "Nextcloud OIDC setup failed (exit $LASTEXITCODE)" }
