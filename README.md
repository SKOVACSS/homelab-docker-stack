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
| `caddy/` | Reverse proxy - HTTPS, security headers, rate limiting - plus Cloudflare Tunnel for remote access with zero port forwarding (works behind CGNAT). Every other stack routes through this one. |
| `authentik/` | Single sign-on (SSO) for the whole lab. |
| `media-stack/` | Sonarr, Radarr, Prowlarr, Lidarr, qBittorrent (VPN-routed via gluetun), Plex, Jellyfin, Seerr (movie/show requests). |
| `privacy-stack/` | Nextcloud, Navidrome, Syncthing, Paperless-ngx, Wallabag, Trilium, Focalboard, OnlyOffice, Radicale. |
| `immich-app/` | Google Photos replacement. |
| `security-stack/` | Fail2Ban and a WireGuard VPN server. |
| `email-stack/` | Mailu (self-hosted email) - optional, off by default in the installer. Run `_scripts/enable-email.ps1` any time to turn it on. |
| `monitoring-stack/` | InfluxDB + Telegraf (host/container metrics - feeds the Grafana in `utilities/`). |
| `utilities/` | Portainer, Vaultwarden, Prometheus + Loki + node-exporter, Grafana (Prometheus/Loki/InfluxDB, alerting to Gotify), Uptime Kuma, Watchtower, Diun (new-version notifications). |
| `notification-stack/` | Gotify (push notifications for backup/health/security alerts). |
| `dashboard/` | Homepage - single landing page linking to every service above. |
| `dns-stack/` | Pi-hole (network-wide ad/tracker blocking) + dnscrypt-proxy (encrypted upstream DNS). |

Each stack is an independent Docker Compose project with its own
`docker-compose.yml` and `.env`, deployed in dependency order (Caddy first,
since it owns the shared `caddy-network` every other stack joins).

## Documentation

- **[SETUP.md](SETUP.md)** - first-time deployment, step by step.
- **[PLATFORM.md](PLATFORM.md)** - path/OS differences (Windows, Linux, macOS, Synology) and moving between them.
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - known gotchas and how to work around them.
- **[CHANGELOG.md](CHANGELOG.md)** - what changed in the 1.0 pass, including two removed/replaced services.

## Design notes

- **One reverse proxy, reached through a tunnel, not open ports.** Caddy
  terminates TLS for every subdomain; everything else stays on internal
  Docker networks and reaches the outside world only through it. Nothing
  needs to be exposed on 80/443 at all - Cloudflare Tunnel (`cloudflared`,
  in `caddy/docker-compose.yml`) makes an outbound-only connection instead,
  which is what makes this work behind CGNAT (Starlink, many mobile
  carriers) with no public IP to forward a port on. Mail's raw SMTP/IMAP
  ports are the one necessary exception if you run `email-stack/` - and
  notably don't work under CGNAT regardless - see TROUBLESHOOTING.md.
- **No `:latest` tags.** Every image is pinned to a specific version, so
  what's actually running is always visible in the compose file itself.
  Watchtower auto-updates everything except the locally-built Caddy image,
  which has no upstream tag to check (see the
  `com.centurylinklabs.watchtower.enable` label per service). Whether a
  given image's pin actually floats (patch-level auto-update) or is exact
  (Watchtower effectively idle until the pin itself is bumped) varies by
  image; see CHANGELOG.md.
- **Secrets live in `.env` files, one per stack**, never in the compose
  files themselves. Generate them with `_scripts/gui-installer.ps1`, or by
  hand using `python -c "import secrets; print(secrets.token_urlsafe(32))"`.
  These files hold real credentials - keep them out of any git remote you
  push to (see `.gitignore`).

## Quick reference

```powershell
# One-time setup (see SETUP.md step 1 first - Cloudflare Tunnel needs
# creating in the Cloudflare dashboard before the wizard below can use it)
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

# Optional: also push backups off-site (unset = local-only, unchanged)
.\backup.ps1 -Action backup -ResticRepository "s3:s3.us-west-002.backblazeb2.com/mybucket" -ResticPassword "..."
.\backup.ps1 -Action offsite-snapshots -ResticRepository "..." -ResticPassword "..."

# Optional: turn on the email server later if you skipped it above
.\enable-email.ps1
```
