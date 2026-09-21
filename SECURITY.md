# Security

What's actually implemented, and what you still have to do yourself.

## What's in place

- **HTTPS everywhere.** Caddy auto-provisions and renews Let's Encrypt
  certificates for every subdomain; HTTP requests are redirected to HTTPS.
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
- **Set first-run admin passwords promptly.** A few services (Portainer,
  Nextcloud, Paperless-ngx, Wallabag, Trilium, Focalboard) create their
  admin account on first web UI visit rather than from an env var - see
  SETUP.md step 5.
- **Firewall your host.** Only ports 80, 443, and 51820/udp (WireGuard)
  should ever need to be reachable from the internet - everything else
  should be internal-only or reached through Caddy. Mail's raw SMTP/IMAP
  ports (25, 465, 587, 143, 993, 110, 995) are the one exception if you run
  `email-stack/` - see TROUBLESHOOTING.md.
- **Rotate secrets if you ever suspect exposure**, and after that, update
  every affected `.env` and redeploy that stack
  (`.\deploy.ps1 -Action restart -Stack <name>`). Changing a database
  password in `.env` alone does not change it inside an already-initialized
  database - you'd need to update it there too (e.g. via that service's own
  admin tooling), not just edit the file.
- **Back up before you touch secrets.** `_scripts/backup.ps1 -Action backup
  -Full` snapshots every `.env` and every Docker volume.
