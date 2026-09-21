# Security

What's actually implemented, and what you still have to do yourself.

## What's in place

- **HTTPS everywhere.** Caddy auto-provisions and renews Let's Encrypt
  certificates for every subdomain via Cloudflare's DNS API (no inbound
  port needed to prove domain ownership - see SETUP.md step 1); HTTP
  requests are redirected to HTTPS.
- **No inbound ports required for web access at all.** Cloudflare Tunnel
  (`cloudflared` in `caddy/docker-compose.yml`) makes an outbound-only
  connection to Cloudflare - every subdomain is reachable without
  forwarding a single port, which also means the host firewall can block
  *all* unsolicited inbound WAN traffic to 80/443 and it changes nothing
  about reachability.
- **Security headers** (HSTS, X-Content-Type-Options, X-Frame-Options, CSP,
  Referrer-Policy, Permissions-Policy) applied to every route - see the
  `(security_headers)` snippet in `caddy/Caddyfile`.
- **Rate limiting** on most routes (30 req/min per client IP, per route) via
  a real `caddy-ratelimit` plugin build - see TROUBLESHOOTING.md for how it
  works and its limits.
- **Fail2Ban**, watching Caddy's logs for repeated failures - see
  TROUBLESHOOTING.md for why this doesn't actually block anything under
  Docker Desktop on Windows/macOS (it needs a native Linux host).
- **Network segmentation.** Each stack has its own internal Docker network;
  only the specific services that need to be reachable from outside join
  the shared `caddy-network`. Databases and caches never do.
- **No service is directly reachable on a host port unless it genuinely
  needs to be.** A security audit found several services (Portainer,
  Uptime Kuma, Vaultwarden, Grafana, Sonarr, Radarr, Prowlarr, Lidarr,
  qBittorrent's WebUI, Loki, Prometheus, InfluxDB, OnlyOffice, and
  Radicale) directly published to the host despite either already routing
  through Caddy or having no legitimate reason to be reachable at all -
  all fixed. What's still published and why: WireGuard (51820/udp - it's
  the VPN's actual listening port), Pi-hole (53 - real DNS, not HTTP),
  Plex/Jellyfin/Syncthing's non-HTTP protocol and discovery ports (Caddy
  can only proxy HTTP), mail's raw SMTP/IMAP ports, and Caddy's own
  80/443 (kept for LAN-direct access, optional - see its
  `docker-compose.yml`).
- **Caddy-level `basic_auth` in front of services with no real
  authentication of their own.** Sonarr, Radarr, Prowlarr, and Lidarr
  don't ship with auth enabled by default; Radicale's own default is no
  auth at all. Confirmed live (a raw request succeeded with zero
  credentials) before fixing - see `arr_auth`/`cal.{$DOMAIN}` in
  `caddy/Caddyfile`.
- **No unnecessary Docker socket access.** `mailu-admin` used to mount
  `/var/run/docker.sock` read-write for no reason - confirmed against
  Mailu's own upstream source that nothing in the admin service's runtime
  code (as opposed to their own test harness) ever uses it. Removed; every
  remaining `docker.sock` mount in this repo is read-only and belongs to a
  service that genuinely inspects other containers (Portainer, Watchtower,
  Diun, Homepage, Telegraf).
- **No `:latest` tags anywhere** - every image is pinned, so what's running
  is always visible in the compose file. Watchtower auto-updates every
  service except the locally-built Caddy image, which has no upstream tag
  to check. This includes Gotify - the notification channel every other
  alert in this stack depends on - on the basis that it's small, mature,
  single-binary software with no history of breaking changes, so the
  realistic risk is low; a deliberate call, not an oversight. Whether
  auto-update is actually continuous for a given service depends on
  whether its pinned tag floats (e.g. `postgres:18-alpine`) or is exact
  (e.g. `mariadb:11.4.13`, where Watchtower stays idle until the pin
  itself is bumped by hand).
- **Resource limits** on every service (`deploy.resources`), so one runaway
  container can't starve the others.
- **Health checks** on nearly every service, surfaced by
  `_scripts/health-check.ps1`.

## What you need to do

- **Generate real secrets.** `_scripts/gui-installer.ps1` does this for you
  (a distinct cryptographically-random value per service - see
  CHANGELOG.md). If you fill in `.env` files by hand instead, use
  `python -c "import secrets; print(secrets.token_urlsafe(32))"` and never
  reuse one password across services.
- **Keep `.env` files out of any git remote.** They hold real credentials.
  If you initialize git here, make sure `.gitignore` excludes `**/.env`
  before your first commit (it does, unless you've changed it).
- **Set first-run admin passwords promptly** for the services that create
  their admin account on first web UI visit rather than from an env var:
  Portainer, Trilium, Focalboard, and Jellyfin - see SETUP.md step 5.
  **Wallabag is a different, more urgent case**: it ships with a fixed
  default login (`admin`/`wallabag`), not a first-visit setup wizard -
  change that password immediately after deploying, since it's a real,
  publicly-documented default rather than something only you know until
  you set it. (Nextcloud and Paperless-ngx look similar to the first
  group but aren't in either category - both auto-create their admin
  account straight from
  `NEXTCLOUD_ADMIN_USER`/`PASSWORD` and `PAPERLESS_ADMIN_USER`/`PASSWORD`
  in their `.env`, confirmed against each project's own docs, so
  `gui-installer.ps1`'s generated passwords already take effect with no
  extra step.)
- **Firewall your host.** With Cloudflare Tunnel handling web access (see
  above), nothing needs an inbound port opened at all for 80/443 traffic -
  block unsolicited inbound WAN traffic entirely if your router/firewall
  lets you. The exceptions: 51820/udp if you want WireGuard reachable
  directly (it isn't routed through the tunnel), and mail's raw SMTP/IMAP
  ports (25, 465, 587, 143, 993, 110, 995) if you run `email-stack/` and
  have a real public IP - see TROUBLESHOOTING.md for why none of that
  works under CGNAT regardless of firewall rules.
- **Rotate secrets if you ever suspect exposure**, and after that, update
  every affected `.env` and redeploy that stack
  (`.\deploy.ps1 -Action restart -Stack <name>`). Changing a database
  password in `.env` alone does not change it inside an already-initialized
  database - you'd need to update it there too (e.g. via that service's own
  admin tooling), not just edit the file.
- **Back up before you touch secrets.** `_scripts/backup.ps1 -Action backup
  -Full` snapshots every `.env` and every Docker volume.
