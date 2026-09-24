# PowerShell Scripts

| Script | Purpose | Needs Admin? |
|---|---|---|
| `gui-installer.ps1` | 5-step wizard that generates every stack's `.env` | No |
| `setup-directories.ps1` | Creates `D:\Media\*`, `D:\Sync`, `D:\Nextcloud`, `D:\Paperless\*`, `D:\Backups\*` | No |
| `deploy.ps1` | Deploy/start/stop/restart/status/logs for all stacks, in the right order | No (Docker Desktop handles elevation) |
| `health-check.ps1` | Reports each container's health status | No |
| `backup.ps1` | Backs up every stack's `.env` (and, with `-Full`, every Docker volume; optionally off-site via Restic) | No |
| `check-versions.ps1` | Lists every stack's pinned image version, registry, and tag | No |
| `enable-email.ps1` | Turns on the email server (Mailu) later, if you skipped it in the wizard | No |
| `detect-gpu.ps1` | Detects usable NVIDIA/AMD/Intel GPU acceleration for Immich/Plex/Jellyfin and writes it to their `.env` files | No |
| `heal-network-dependents.ps1` | Auto-recreates qBittorrent/slskd if gluetun's container ID changed under them | No |

See [../SETUP.md](../SETUP.md) for the full first-time walkthrough. This
file just documents each script's options.

## gui-installer.ps1

```powershell
.\gui-installer.ps1
```

Walks through: domain/email/timezone/Cloudflare tokens/email-server
toggle -> ProtonVPN credentials -> Plex claim token (optional - leave
blank and claim manually at `http://<this-pc>:32400/web` after deploying;
it expires in 4 minutes and `setup-directories.ps1`/`deploy.ps1` run as
separate steps afterward, so a token entered here rarely survives long
enough to still be valid) -> generate secrets -> review & write (see
SETUP.md step 1 for how to get the two Cloudflare tokens - they need to
exist before this wizard can use them). Generates
21 distinct cryptographically-random secrets when email setup is on, 19
when it's off (never reuses one across services) and writes a `.env` into
every stack directory: `authentik`, `caddy`, `media-stack`,
`privacy-stack`, `security-stack`, `monitoring-stack`,
`notification-stack`, `utilities`, `immich-app`, `dashboard`, `dns-stack`,
and `email-stack` too if you left the "Set up email server" checkbox on
(unchecked by default - see `enable-email.ps1` below to turn it on later
instead).

Also writes `credentials-export.json` (repo root, gitignored) - every
credential above in Bitwarden's JSON export format (not CSV - Proton
Pass's Bitwarden importer only accepts JSON/ZIP, and its generic CSV
importer silently drops every username/password, confirmed live), each
with its site URL included so it autofills right away. Import as
**Bitwarden** (Vaultwarden: Tools -> Import Data -> Bitwarden (json);
Proton Pass: Settings -> Import -> Bitwarden) and then delete the file.

The final step also has an unchecked-by-default checkbox to run
`setup-directories.ps1`, `deploy.ps1 -Action deploy`, and
`health-check.ps1` itself immediately after writing the `.env` files
(Docker Desktop must already be running) - their output goes to the
console the wizard was launched from, not the wizard window. Leave it
unchecked to review the `.env` files and run those three by hand instead.

You can also skip this and edit any stack's `.env` by hand - the variable
*names* just need to match what that stack's `docker-compose.yml` reads.

## enable-email.ps1

```powershell
.\enable-email.ps1
.\enable-email.ps1 -MailDomain mail-only-domain.com
```

Mailu is the most complex, fragile stack in this repo (see CHANGELOG.md's
1.0.9, 1.2.2, and 1.5.0 entries for the real bugs found in it), so
`gui-installer.ps1` leaves it unconfigured by default - this script fills
that gap in whenever you're actually ready for it, without re-running the
whole wizard. Interactive: asks whether to use the same domain as
everything else or a separate one (pass `-MailDomain` to skip that
prompt), confirms you've already done the Cloudflare-dashboard steps a
second domain needs if that applies, generates `MAILU_SECRET_KEY` and
`MAIL_ADMIN_PASSWORD`, writes `email-stack\.env`, and sets `MAIL_DOMAIN`
in `caddy\.env`. Safe to re-run against an already-configured
`email-stack` too (asks to confirm first) - useful for rotating the admin
password or moving Mailu to a different domain later.

## detect-gpu.ps1

```powershell
.\detect-gpu.ps1 [-WhatIf] [-Quiet]
```

Detects whatever GPU hardware acceleration is actually *usable* (not just
present) for Immich's machine learning and video transcoding, and
Plex/Jellyfin's video transcoding, then writes the result into
`immich-app\.env` and `media-stack\.env` - `TRANSCODE_HWACCEL`,
`ML_HWACCEL`, `ML_IMAGE_SUFFIX`, `PLEX_HWACCEL`, `JELLYFIN_HWACCEL`. Works
across NVIDIA, AMD, and Intel without you picking a vendor - `deploy.ps1`
runs it automatically before every deploy, so this is normally a
zero-config, "it just uses the GPU if there is one" situation. `-WhatIf`
shows what it would detect and write without touching any `.env` file;
useful for checking what it found without deploying anything.

No GPU, or an unsupported one? Every value defaults to `cpu` (software) in
the compose files themselves, so this is always safe either way.

Device access alone doesn't turn hardware transcoding *on* inside each
app - Jellyfin (Dashboard > Playback) and Immich (Admin > Settings > Video
Transcoding) each have their own hardware-acceleration setting that needs
to match what got detected, and Plex additionally needs a Plex Pass
subscription for hardware transcoding to activate at all. The script
prints a reminder whenever it picks something other than `cpu`.

See `immich-app/hwaccel.ml.yml`, `immich-app/hwaccel.transcoding.yml`, and
`media-stack/hwaccel.transcoding.yml` for exactly what each detected
profile maps to (devices, volumes, environment) - these compose files
list every backend this script knows how to pick between.

## deploy.ps1

```powershell
.\deploy.ps1 [-Action <deploy|start|stop|restart|down|status|logs>] [-Stack <name>] [-Pull] [-Quiet]
```

`-Action` defaults to `deploy`, so bare `.\deploy.ps1` does a full deploy.
`deploy` with no `-Stack` brings every stack up in dependency order:
**caddy** first (it owns the shared `caddy-network`), then **authentik**,
then everything else - a stack with no `.env` (e.g. `email-stack` if you
skipped setting it up) is skipped with a message rather than started with
broken empty variables. `deploy -Stack <name>` targets just that one
stack instead of the full sequence, for bringing up a stack on its own
after the rest is already running (caddy/authentik still need to already
be up). Deploying stacks individually and out of order otherwise will
fail unless `caddy` is already up.

```powershell
.\deploy.ps1 -Action deploy                          # everything, in order
.\deploy.ps1 -Action deploy -Stack email-stack        # just one stack, e.g. after enable-email.ps1
.\deploy.ps1 -Action status                          # per-stack up/down summary
.\deploy.ps1 -Action logs -Stack media-stack          # follow logs for one stack
.\deploy.ps1 -Action restart -Stack authentik         # restart one stack
.\deploy.ps1 -Action down                             # remove containers, keep volumes (asks to confirm)
```

## health-check.ps1

```powershell
.\health-check.ps1 [-Detailed] [-JSON] [-GotifyUrl <url>] [-GotifyToken <token>]
```

Walks every stack, reports each container as healthy / running-without-a-
healthcheck / unhealthy / not-running, and prints an overall percentage.
`-Detailed` adds network/volume/disk-usage info. Exit code is 0 if
everything is healthy, 1 otherwise (useful in a scheduled task). Pass
`-GotifyUrl`/`-GotifyToken` to get a push notification when something's
unhealthy or down (same opt-in pattern as `backup.ps1`).

## heal-network-dependents.ps1

```powershell
.\heal-network-dependents.ps1 [-Quiet] [-GotifyUrl <url>] [-GotifyToken <token>]
```

qBittorrent and slskd both use `network_mode: service:gluetun` to route
their traffic through the VPN, which Docker binds to gluetun's specific
container ID at creation time - not its name. Whenever gluetun gets
recreated for any reason (a Docker Desktop/WSL2 restart, a host reboot,
a manual `--force-recreate`) without qBittorrent/slskd being recreated
alongside it, they're left holding a reference to a container ID that no
longer exists - confirmed live, this isn't hypothetical. Neither a plain
`docker start` nor the normal `restart: unless-stopped` policy can fix
this (they keep retrying the same broken reference); only
`docker compose up -d` re-resolves it. This script checks for exactly
that broken state and runs the fix automatically. Exit code 0 if nothing
needed fixing or everything recovered, 1 if something's still broken
after attempting to fix it (useful in a scheduled task, same pattern as
`health-check.ps1`). Same opt-in Gotify pattern too.

Scheduling it to run every 15 minutes catches this well before it'd
otherwise be noticed:
```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\heal-network-dependents.ps1`" -Quiet"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "Homelab_Heal_Network_Dependents"
```

## setup-directories.ps1

```powershell
.\setup-directories.ps1
```

Creates the Windows host directories every stack's `.env` expects to bind-
mount (see `PLATFORM.md` for the Linux/macOS/Synology equivalents - you'll
need to create those manually and update the relevant `.env` files to
match).

## backup.ps1

```powershell
.\backup.ps1 -Action <backup|restore|list|clean|offsite-snapshots|offsite-check> [-Full] [-BackupName <name>] [-BackupRoot <path>] [-GotifyUrl <url>] [-GotifyToken <token>] [-ResticRepository <repo>] [-ResticPassword <password>]
```

Pass `-GotifyUrl`/`-GotifyToken` to get a push notification when a backup
finishes (create an Application in Gotify's web UI to get a token - this is
opt-in, nothing is sent if you leave these unset).

```powershell
.\backup.ps1 -Action backup              # every stack's .env, fast
.\backup.ps1 -Action backup -Full        # + a tarball of every Docker volume
.\backup.ps1 -Action list
.\backup.ps1 -Action restore -BackupName backup_2026-01-15_14-30-45
.\backup.ps1 -Action clean               # keeps the 5 most recent backups
```

Defaults to `D:\Backups\docker` - override with `-BackupRoot` if you're
backing up to a different drive (e.g. a NAS mount).

**Off-site backup (optional, via Restic)**: pass `-ResticRepository`
and `-ResticPassword` (any Restic-supported backend - S3, B2, Azure, GCS;
backend-specific credentials like `AWS_ACCESS_KEY_ID` are read from your
own shell environment, not script parameters, since the needed set varies
by backend) to push volumes off-site as part of a normal `-Full` backup:

```powershell
.\backup.ps1 -Action backup -Full -ResticRepository "s3:s3.us-west-002.backblazeb2.com/mybucket" -ResticPassword "..."
.\backup.ps1 -Action offsite-snapshots -ResticRepository "..." -ResticPassword "..."   # list what's up there
.\backup.ps1 -Action offsite-check -ResticRepository "..." -ResticPassword "..."       # verify repository integrity
```

## check-versions.ps1

```powershell
.\check-versions.ps1 [-JSON]
```

Lists every stack's pinned image (registry, repository, tag) in one table
- a quick way to see what's actually running without opening every
`docker-compose.yml` by hand, or to diff against Diun's notifications when
deciding whether to bump a pin.

## Scheduling daily backups

`-Full` is what actually protects app state (every *arr/Seerr/qBittorrent
database and setting lives in a Docker volume, not in this repo); the
plain backup only copies `.env` files. Running `clean` afterward keeps
the last 5:
```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"& '$PSScriptRoot\backup.ps1' -Action backup -Full; & '$PSScriptRoot\backup.ps1' -Action clean`""
$trigger = New-ScheduledTaskTrigger -Daily -At 2:00AM
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "Homelab_Daily_Backup"
```

## configure-qbittorrent.ps1

```powershell
.\configure-qbittorrent.ps1 [-MaxActiveDownloads 10] [-PrivateTrackers pretome] [-PrivateRatio 0.8] [-PrivateSeedMinutes 3720] [-Quiet]
```

Reasserts the qBittorrent queue/seeding policy (10 active downloads by default,
unlimited seeds, public torrents stop when complete) and, for private
trackers, sets a per-torrent seeding minimum and resumes any torrent
that stopped short of it - a hit-and-run guard. See the script header
for the full policy. Hourly is a good schedule; it also undoes any
change to these settings made by hand in the WebUI, so change the
script instead:
```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\configure-qbittorrent.ps1`" -Quiet"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "Homelab_Configure_qBittorrent"
```

## Troubleshooting

**Script won't run at all** - PowerShell's execution policy is blocking it:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Deploy fails** - check Docker Desktop is actually running (`docker ps`),
then validate the specific stack's config:
```powershell
docker compose -f ..\<stack>\docker-compose.yml --env-file ..\<stack>\.env config
```

## Validation (also runs in CI - see .github/workflows/validate.yml)

```bash
# Every stack's docker-compose.yml is syntactically valid, and every ${VAR}
# it references is documented in ../.env.example. Catches the exact class
# of bug (invalid YAML, undocumented variables) this repo's 1.0 pass found.
bash validate-stacks.sh
```

```powershell
# Static analysis on these scripts (path-resolution bugs, unsafe patterns).
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

## configure-prowlarr.ps1

```powershell
.\configure-prowlarr.ps1 [-Quiet]
```

Applies the Prowlarr indexer policy kept in the script's `$IndexerPolicy`:
which indexers are enabled, which proxy tags they use (`flaresolverr` for
Cloudflare challenges, `vpn` for sites that ban the home IP outright),
the two proxies themselves (both ride gluetun's VPN), and private-tracker
seeding minimums that Radarr/Sonarr attach to every torrent they grab.
Idempotent - only writes what differs - then syncs indexers to the apps.
Prowlarr tests an indexer before saving it, so a site that is down at
the moment is skipped with a warning; re-run later.
