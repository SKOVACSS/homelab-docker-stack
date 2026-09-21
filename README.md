# Homelab Docker Stack

A self-hosted homelab: media automation, private cloud storage, photo backup,
password manager, email, monitoring, and a VPN/brute-force-protected front
door — all behind one reverse proxy with real HTTPS. Designed to be portable
between machines (Windows, Linux, a Synology NAS) and quick to stand up for
family and friends.

**New here?** Start with [SETUP.md](SETUP.md).

## What's included

| Stack | Services |
|---|---|
| `caddy/` | Reverse proxy - HTTPS, security headers, rate limiting. Every other stack routes through this one. |
| `authentik/` | Single sign-on (SSO) for the whole lab. |
| `media-stack/` | Sonarr, Radarr, Prowlarr, Lidarr, qBittorrent (VPN-routed via gluetun), Plex, Jellyfin. |
| `privacy-stack/` | Nextcloud, Navidrome, Syncthing, Paperless-ngx, Wallabag, Trilium, Focalboard, OnlyOffice, Radicale. |
| `immich-app/` | Google Photos replacement. |
| `security-stack/` | Fail2Ban and a WireGuard VPN server. |
| `email-stack/` | Mailu (self-hosted email). |
| `monitoring-stack/` | InfluxDB + Telegraf (host/container metrics - feeds the Grafana in `utilities/`). |
| `utilities/` | Portainer, Vaultwarden, Prometheus + Loki + node-exporter, Grafana (Prometheus/Loki/InfluxDB, alerting to Gotify), Uptime Kuma, Watchtower. |
| `notification-stack/` | Gotify (push notifications for backup/health/security alerts). |

Each stack is an independent Docker Compose project with its own
`docker-compose.yml` and `.env`, deployed in dependency order (Caddy first,
since it owns the shared `caddy-network` every other stack joins).

## Documentation

- **[SETUP.md](SETUP.md)** - first-time deployment, step by step.
- **[PLATFORM.md](PLATFORM.md)** - path/OS differences (Windows, Linux, macOS, Synology) and moving between them.
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - known gotchas and how to work around them.
- **[CHANGELOG.md](CHANGELOG.md)** - what changed in the 1.0 pass, including two removed/replaced services.

## Design notes

- **One reverse proxy.** Caddy terminates TLS and is the only thing that
  should ever be exposed on ports 80/443. Everything else stays on internal
  Docker networks and reaches the outside world only through it (mail's raw
  SMTP/IMAP ports are the one necessary exception - see TROUBLESHOOTING.md).
- **No `:latest` tags.** Every image is pinned to a specific version so an
  update is something you choose, not something that happens to you
  overnight. Watchtower is opt-in per service (see the
  `com.centurylinklabs.watchtower.enable` label) and is disabled by default
  on anything stateful (databases, auth, torrent client).
- **Secrets live in `.env` files, one per stack**, never in the compose
  files themselves. Generate them with `_scripts/gui-installer.ps1`, or by
  hand using `python -c "import secrets; print(secrets.token_urlsafe(32))"`.
  These files hold real credentials - keep them out of any git remote you
  push to (see `.gitignore`).

## Quick reference

```powershell
# One-time setup
cd _scripts
.\gui-installer.ps1          # generates every stack's .env
.\setup-directories.ps1       # creates media/backup folders on D:\

# Deploy everything, in the right order
.\deploy.ps1 -Action deploy

# Day to day
.\deploy.ps1 -Action status
.\health-check.ps1
.\backup.ps1 -Action backup
.\check-versions.ps1         # lists every stack's pinned image versions
```
