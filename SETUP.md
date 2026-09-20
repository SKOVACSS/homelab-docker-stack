# Setup

## Prerequisites

- **Docker Desktop** (Windows/macOS) or Docker Engine + the Compose plugin (Linux). Verify with `docker compose version` (needs the v2 CLI - `docker-compose` with a hyphen is the old, unsupported v1).
- **A domain name** you control, with DNS access (to point subdomains like `sonarr.yourdomain.com` at your server).
- **Windows only:** run PowerShell as Administrator for the scripts in `_scripts/` (the GUI installer needs it to write files across the project).
- Accounts/keys you'll be asked for during setup: a [ProtonVPN](https://protonvpn.com) plan with port forwarding (for the media stack's VPN routing), a [Plex claim token](https://plex.tv/claim) if you want Plex.

## 1. Generate configuration

```powershell
cd _scripts
.\gui-installer.ps1
```

The wizard collects your domain, email, ProtonVPN credentials, and Plex
token, generates a unique cryptographically-random secret for every
database/service that needs one (21 in total - no password is reused across
services), and writes a correct `.env` file into every stack directory.

Don't have a domain yet, or want to fill things in yourself? Every stack's
`.env` file is plain text - open any of them and edit directly. Just keep the
variable *names* as they are; the compose files reference them by name.

## 2. Create host directories

```powershell
.\setup-directories.ps1
```

Creates `D:\Media\{Movies,TV,Music,Books,Photos,Downloads}`,
`D:\Sync`, `D:\Nextcloud`, `D:\Paperless\{consume,archive}`, and
`D:\Backups\{docker,databases}`. On Linux/Synology, see
[PLATFORM.md](PLATFORM.md) for the equivalent paths and update each stack's
`.env` to match before continuing.

## 3. Point DNS at your server

For every subdomain you plan to use (`sonarr.yourdomain.com`,
`vault.yourdomain.com`, `auth.yourdomain.com`, etc. - see `caddy/Caddyfile`
for the full list), create an A/AAAA record pointing at your server's public
IP. Caddy requests a Let's Encrypt certificate for a subdomain the first
time it sees a request for it, so DNS has to already resolve before you hit
each URL for the first time.

## 4. Deploy

```powershell
.\deploy.ps1 -Action deploy
```

This deploys stacks in the order that matters: **Caddy first** (it owns the
shared `caddy-network` that every other stack joins as `external: true`),
then **Authentik**, then everything else. Deploying out of order will fail -
if you ever deploy a stack manually, always bring `caddy` up first.

The first `deploy` also builds a custom Caddy image (see
`caddy/Dockerfile`) with the `caddy-ratelimit` plugin compiled in, which
takes a minute or two the first time.

## 5. Verify

```powershell
.\health-check.ps1
```

Then open a few subdomains in a browser and confirm certificates issue
and pages load. First-run setup for a few services:

- **Authentik**: visit `auth.yourdomain.com`, log in as `akadmin` with the
  `BOOTSTRAP_PASSWORD` from `authentik/.env`.
- **Portainer**: visit `portainer.yourdomain.com`, set the admin account on
  first visit (there's no pre-set password - see TROUBLESHOOTING.md).
- **qBittorrent**: check `docker compose -f media-stack/docker-compose.yml
  logs gluetun` for the port ProtonVPN forwarded you, then update `BT_PORT`
  in `media-stack/.env` and redeploy that stack (`.\deploy.ps1 -Action
  restart -Stack media-stack`).

## 6. Back up

```powershell
.\backup.ps1 -Action backup          # config only
.\backup.ps1 -Action backup -Full    # config + all Docker volumes
```

Backs up every stack's `.env` plus (with `-Full`) a tarball of every Docker
volume, into `D:\Backups\docker\backup_<timestamp>\`. `-Action list` shows
existing backups, `-Action restore -BackupName <name>` restores one,
`-Action clean` prunes down to the 5 most recent.

## Redeploying to different hardware

Since every stack's config lives in its own `.env` file (not baked into any
image), moving this whole setup to new hardware is: copy the repo + your
`.env` files + your media directories to the new machine, then run
`.\deploy.ps1 -Action deploy` there. See [PLATFORM.md](PLATFORM.md) for
path differences between operating systems.
