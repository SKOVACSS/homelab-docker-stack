# PowerShell Scripts

| Script | Purpose | Needs Admin? |
|---|---|---|
| `gui-installer.ps1` | 5-step wizard that generates every stack's `.env` | Yes |
| `setup-directories.ps1` | Creates `D:\Media\*`, `D:\Sync`, `D:\Nextcloud`, `D:\Paperless\*`, `D:\Backups\*` | No |
| `deploy.ps1` | Deploy/start/stop/restart/status/logs for all stacks, in the right order | No (Docker Desktop handles elevation) |
| `health-check.ps1` | Reports each container's health status | No |
| `backup.ps1` | Backs up every stack's `.env` (and, with `-Full`, every Docker volume) | No |

See [../SETUP.md](../SETUP.md) for the full first-time walkthrough. This
file just documents each script's options.

## gui-installer.ps1

```powershell
.\gui-installer.ps1
```

Walks through: domain/email/timezone -> ProtonVPN credentials -> Plex claim
token -> generate secrets -> review & write. Generates 21 distinct
cryptographically-random secrets (never reuses one across services) and
writes a `.env` into every stack directory: `authentik`, `caddy`,
`media-stack`, `privacy-stack`, `security-stack`, `email-stack`,
`monitoring-stack`, `notification-stack`, `utilities`, `immich-app`.

You can also skip this and edit any stack's `.env` by hand - the variable
*names* just need to match what that stack's `docker-compose.yml` reads.

## deploy.ps1

```powershell
.\deploy.ps1 [-Action <deploy|start|stop|restart|down|status|logs>] [-Stack <name>] [-Pull] [-Quiet]
```

`-Action` defaults to `deploy`, so bare `.\deploy.ps1` does a full deploy.
`deploy` brings every stack up in dependency order: **caddy** first (it
owns the shared `caddy-network`), then **authentik**, then everything else.
Deploying stacks individually and out of order will fail unless `caddy` is
already up.

```powershell
.\deploy.ps1 -Action deploy                          # everything, in order
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
.\backup.ps1 -Action <backup|restore|list|clean> [-Full] [-BackupName <name>] [-BackupRoot <path>] [-GotifyUrl <url>] [-GotifyToken <token>]
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

## Scheduling daily backups

```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\backup.ps1`" -Action backup"
$trigger = New-ScheduledTaskTrigger -Daily -At 2:00AM
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "Homelab_Daily_Backup"
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
