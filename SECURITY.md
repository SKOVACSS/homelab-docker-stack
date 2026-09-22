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
- **`trusted_proxies` configured in `caddy/Caddyfile`, and real access
  logging on every route.** Neither existed before - confirmed live, and
  worse than a missing nice-to-have: every request Caddy handled looked
  like it came from cloudflared's own container IP (the actual TCP peer
  for all tunnel-routed traffic), never the real visitor. That silently
  broke rate limiting's per-client key (pooled across every real visitor
  instead of actually per-client), every `X-Real-IP` header forwarded to
  backend apps (their own login/ban logic saw the same wrong shared IP
  for everyone), and Fail2Ban (see below) all at once. Fixed by trusting
  caddy-network's subnet specifically (`servers { trusted_proxies static
  172.20.0.0/16 }`) - confirmed live afterward: Caddy's access log now
  shows a real `client_ip` distinct from `remote_ip`, and rate limiting/
  `X-Real-IP` both use it correctly.
- **Rate limiting** on most routes (30 req/min per client IP, per route) via
  a real `caddy-ratelimit` plugin build - see TROUBLESHOOTING.md for how it
  works and its limits. This was silently rate-limiting by cloudflared's
  IP, not per real visitor, until the `trusted_proxies` fix above.
- **Fail2Ban, rebuilt from a non-functional starting point.** The
  previous config had three independent bugs, any one of which alone
  would have made it a total no-op: its filter regex was written for
  Apache-style log lines against a Caddy that produced no access logs at
  all (fixed above); its custom jail/filter files sat in
  `/etc/fail2ban/jail.d`, a path this specific image (`crazymax/fail2ban`)
  never reads custom config from (it expects `/data/jail.d`,
  `/data/filter.d` - see `security-stack/fail2ban/data/`); and it used
  `failregex2`/`failregex3`/`maxretry2`/`maxretry3`, which are not real
  Fail2Ban directives and were silently ignored. Rebuilt correctly and
  verified live end-to-end: a real 401 from Sonarr's API showed up in
  Caddy's access log with the correct `client_ip`, and Fail2Ban's own
  jail status immediately showed `Total failed: 1` for it.
  **This still cannot actually block anything on this host** - Docker
  Desktop runs containers inside a Linux VM, so the iptables rules
  Fail2Ban inserts never reach the real Windows host's network stack (see
  TROUBLESHOOTING.md). The detection logic is now genuinely correct - the
  ban action itself needs either a native Linux host, or something that
  bans upstream of that limitation entirely (see "What you need to do"
  below).
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
- **Every app-facing route relies on that app's own real login - confirmed,
  not assumed.** Sonarr, Radarr, Prowlarr, Lidarr, and qBittorrent each
  have their own mandatory login (Settings > General > Security,
  `AuthenticationRequired` set to `Enabled`, not the "disabled for local
  addresses" default some of these apps ship with - which would have been
  meaningless behind a reverse proxy, since every request looks local to
  the app). This was confirmed live before removing Caddy's own
  `arr_auth`/`qbit_auth` `basic_auth` layer that used to duplicate it - a
  second login added no real protection once the app's own login was
  verified genuinely enforced, and HTTP Basic's browser-native prompt
  doesn't autofill from a password manager the way an app's own HTML
  login form does. Each of those apps now gets exactly one login: its own.
  Radicale is the one exception - its own auth is disabled entirely
  (no in-app account system to enable), so Caddy's `basic_auth` (see
  `cal.{$DOMAIN}` in `caddy/Caddyfile`) is its only real gate, and stays.
  **LazyLibrarian is a known gap, not a parity decision** - see "What you
  need to do" below.
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
- **Database backups are consistent dumps, not a live tar of a running
  database's data directory.** `_scripts/backup.ps1` runs `pg_dumpall`/
  `mariadb-dump` against every Postgres/MariaDB container in this repo
  (authentik-postgresql, immich_postgres, paperless-db, wallabag-db,
  nextcloud-db) before the raw volume copy, asking each engine for a
  restorable snapshot instead of copying its files mid-write - confirmed
  live against all five. The raw volume copy of these still happens too
  (harmless, just redundant) - prefer the dump under `dumps/` in a
  backup for restoring any of these five.
- **The dashboard (Homepage) is gated behind Authentik SSO**, not left
  open. It's a single page linking to - and showing live stats for -
  every other service in this repo, so it's exactly the kind of thing
  that shouldn't be reachable with zero login just because none of the
  individual services it points to are exposed directly.
- **Exactly one deliberately public, no-login page: the family guide**
  (`family.{$DOMAIN}`, served by Caddy from `family-guide/`). This is a
  conscious design choice, not an oversight - it holds no credentials, no
  personal data, and nothing state-changing, only links and instructions
  pointing at services that each have their own real login. Don't take
  "no login" elsewhere in this repo as license by association; everything
  else with no login is a gap to close (see LazyLibrarian below), not a
  precedent this page sets.

## What you need to do

- **Consider CrowdSec (with its Cloudflare bouncer) instead of - or
  alongside - Fail2Ban for actual brute-force blocking.** Fail2Ban's
  detection is now correct (see "What's in place" above) but its ban
  action is structurally inert on this host, full stop, because of how
  Docker Desktop isolates containers from the real Windows network stack
  - no amount of further config fixes it. CrowdSec's Cloudflare bouncer
  bans at Cloudflare's edge via API instead of local iptables, which
  sidesteps that limitation entirely rather than working around it - it
  would actually block traffic today, not just log it. Not set up here;
  a real decision (new service, new Cloudflare API token scope), not
  something to add silently.
- **LazyLibrarian currently has no authentication at all - not even a
  default password to change, unlike Wallabag below.** Confirmed directly
  against the live config (`config.ini` has no `http_user`/`http_pass`
  set, and there's no Caddy-level `basic_auth` in front of
  `lazylibrarian.{$DOMAIN}` either) - anyone who knows or guesses that
  subdomain currently has full admin access: search provider settings,
  download destinations, the works. This is unlike Sonarr/Radarr/Prowlarr/
  Lidarr/qBittorrent, which all have their own real login already (see
  "What's in place" above) - LazyLibrarian just doesn't, and nothing else
  in this repo currently covers for it. Set `http_user`/`http_pass` in
  its config (Config > Interface in its own web UI), or add a Caddy
  `basic_auth` block the way Radicale has one, before treating this
  subdomain as anything other than fully public.
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
- **Break-glass access, if Authentik itself goes down: verified, not just
  assumed.** Homepage (the dashboard) is genuinely OIDC-only with no
  fallback - confirmed live, its login page offers nothing but "Login via
  Authentik." But Homepage is just a links page with no admin capability
  of its own, so losing it is an inconvenience, not a lockout. The tool
  that actually matters - Portainer, since that's how you'd restart a
  broken Authentik/its Postgres/its Redis in the first place - was also
  confirmed live to have its own independent native login, completely
  unaffected by Authentik's health. Keep it that way: don't wire
  Portainer into Authentik-only auth later without keeping a native
  fallback account, or this stops being true.
- **Cloudflare Tunnel and heavy media traffic - a real account-level risk,
  not just a performance one.** TROUBLESHOOTING.md already covers very
  high-bitrate 4K Plex remux *buffering* through the tunnel. Separately,
  Cloudflare's terms restrict using the platform as a bulk CDN for
  non-HTML traffic, which Plex/Jellyfin/Immich sync/Nextcloud arguably
  are - the realistic enforcement is aimed at people running the free
  tier as their primary video CDN for a public-facing streaming
  operation, not a small household's occasional use, but it's a real
  account/domain risk, not a hypothetical one. Not fixed here - the fix
  changes the architecture (route heavy media through the WireGuard VPN
  already in `security-stack/` instead of the tunnel, or a cheap VPS
  running WireGuard as a relay if you're behind CGNAT), which is a real
  decision with real tradeoffs, not something to silently reroute.
