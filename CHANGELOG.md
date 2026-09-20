# Changelog

## 1.0 - Full audit and remediation pass (2026-09-20)

Earlier documentation in this repo's history repeatedly declared the stack
"production ready" / "zero errors" while, in fact, 5 of 9 compose files
contained invalid YAML that would fail to even parse. This pass started
from scratch: every compose file was validated with `docker compose config`,
every image tag was checked against its actual registry, every generated
`.env` was tested against the real compose files, and the Caddy rate-limit
plugin was actually built and validated rather than assumed to work. What
follows is what was actually found and fixed, not a re-assertion that
everything is now perfect.

### Deployment-blocking bugs fixed

- **Invalid YAML** in `privacy-stack`, `security-stack`, `email-stack`,
  `monitoring-stack`, and `notification-stack`'s `docker-compose.yml` -
  each had a duplicate top-level `networks:` key, which is a YAML parse
  error. None of these five stacks could have been deployed as they were.
- **Nonexistent Mailu image tags**: `mailu/admin:2024.12` (and the same
  `:2024.12` tag on dovecot/postfix/rspamd/roundcube) does not exist - no
  such Mailu release was ever published, and the images have since moved
  from Docker Hub to `ghcr.io/mailu/*` entirely. Fixed to the verified real
  tag `ghcr.io/mailu/{admin,dovecot,postfix,rspamd}:2024.06.10` and
  `ghcr.io/mailu/webmail:2024.06.10` (Mailu renamed roundcube's image to
  `webmail`).
- **Wrong Gotify image name**: `gotify/gotify-server` isn't a real Docker
  Hub repository - the actual image is `gotify/server`. Fixed, and bumped
  to the current major (3.x).
- **Wrong Authentik image name**: the project referenced
  `ghcr.io/goauthentik/authentik`, an old/renamed path - current image is
  `ghcr.io/goauthentik/server`. Fixed and bumped from 2024.12.1 to 2026.8.3.
- **A path-resolution bug in every PowerShell script** (`deploy.ps1`,
  `health-check.ps1`, `gui-installer.ps1`) walked *two* directories up from
  `_scripts/` instead of one, resolving the project root to the drive root
  (`D:\`) instead of the actual project folder. Every stack lookup, and
  every `.env` file the GUI installer wrote, silently went to the wrong
  place. This alone made the documented "GUI installer -> deploy ->
  health-check" flow completely non-functional.
- **The GUI installer wrote the wrong variable names** for 6 of 9 stacks
  (e.g. it generated `AUTHENTIK_PASSWORD`/`POSTGRES_PASSWORD` for a stack
  whose compose file reads `PG_PASS`/`BOOTSTRAP_PASSWORD`/`SECRET_KEY` -
  none of the names matched). Every generated `.env` has been rewritten to
  match the real compose files, and verified end-to-end with `docker
  compose config` against generator output.
- **`immich-app/` had no `docker-compose.yml`** - only a `.env` and the
  standard hardware-acceleration helper files. Immich could not be deployed
  at all. Added, based on Immich's official compose template, wired into
  `caddy-network` and the deployment/health-check scripts.
- **Caddy never actually received `DOMAIN`** as a container environment
  variable, so every `{$DOMAIN}` substitution in the Caddyfile resolved to
  an empty string - every site block except the auth ones would have had
  an invalid hostname. Fixed by passing `DOMAIN` (and `QBIT_PORT`) through
  in `caddy/docker-compose.yml`.
- **Caddy's rate limiting was never real**: the Caddyfile used a made-up
  `rate 10r/m` directive that doesn't exist in Caddy or any plugin - it
  would have failed to parse on startup. Replaced with a real
  `caddy-ratelimit` plugin build (see `caddy/Dockerfile`), with per-route
  zones, and validated against the actual compiled binary.
- **qBittorrent's WebUI and peer ports were set to the same number**
  (`QBIT_PORT=BT_PORT=6969`), which means one of its two listening sockets
  would fail to bind. Split into a static WebUI port (8080) and a
  separately-tracked peer port that follows ProtonVPN's forwarded port.
  `gluetun` also hardcoded the BitTorrent port to 6881 regardless of the
  `BT_PORT` variable - fixed to actually use it.
- **`gluetun` wasn't on `caddy-network`**, so Caddy's `qbit.{$DOMAIN}` route
  could never reach it. Added.
- **InfluxDB 2.x was configured with InfluxDB 1.x setup variables**
  (`INFLUXDB_DB`, `INFLUXDB_ADMIN_USER`, `INFLUXDB_HTTP_AUTH_ENABLED`),
  which the 2.x image's entrypoint doesn't recognize - it would have booted
  unconfigured. Fixed to the real `DOCKER_INFLUXDB_INIT_*` variables, and
  Telegraf's InfluxDB v2 token wiring fixed to match.
- **media-stack's `.env` used Linux container-style paths** (e.g.
  `/mnt/media/movies`, `QBIT_DOWNLOADS_PATH=/downloads`) on what is a
  Windows deployment, while `setup-directories.ps1` creates
  `D:\Media\Movies` etc. - the bind mounts would not have pointed at real
  folders. Fixed to match.
- Grafana had no datasources or dashboards actually wired up (the
  `grafana-provisioning` folders it mounted either didn't exist or, in
  `monitoring-stack`, were a Docker-managed named volume with nothing in
  it - the same practical effect). Added real provisioning
  (`*/grafana-provisioning/`) for both Grafana instances, and fixed the one
  pre-built dashboard JSON, which had leading comment lines that made it
  invalid JSON and used measurement fields Telegraf never emits.

### Security fixes

- The password generator behind the GUI installer used `System.Random`,
  which is not a cryptographic RNG and is not appropriate for generating
  secrets. Replaced with `System.Security.Cryptography.RandomNumberGenerator`.
- The installer previously reused a small number of generated passwords
  across many unrelated databases (Nextcloud, Paperless, Wallabag all
  shared one). Now generates a distinct secret per service/database (21
  total) - one leak no longer compromises everything.
- `mailu-admin`, `mailu-webmail`, and `mailu-rspamd` were publishing ports
  directly on the host in addition to being routed through Caddy, which
  goes against the stack's own "only 80/443/WireGuard exposed" model.
  Removed the direct port bindings - reachable through Caddy only now.

### Removed / replaced

- **Readarr removed.** Its upstream (hotio/Readarr) was archived in June
  2025 and officially retired - it never reached a stable release in its
  entire lifetime. If you want book automation, look at LazyLibrarian or
  Chaptarr.
- **Trilium -> TriliumNext.** `zadam/trilium` is abandoned upstream;
  switched to `triliumnext/trilium`, the actively-maintained community
  fork (same data format).
- **Watchtower -> nicholas-fedor's fork.** `containrrr/watchtower` was
  archived in December 2025 with no further releases; switched to
  `nickfedor/watchtower`, the fork the original project's own discussion
  thread points to.

### Version currency

Every pinned image tag was checked against its actual registry (not
assumed) and bumped to current stable where a straightforward bump was
possible on a fresh install: Caddy, Authentik, WireGuard (was pinned to a
~2021 build), qBittorrent/Sonarr/Radarr/Prowlarr/Lidarr (switched to
hotio's documented `release` channel tag rather than a numeric pin hotio
doesn't actually support long-term), Plex, Jellyfin, gluetun, Navidrome,
Syncthing, Nextcloud, MariaDB, Paperless-ngx, Wallabag, OnlyOffice,
Radicale, Postgres, Grafana, Prometheus, Loki, Telegraf, Portainer,
Vaultwarden, Uptime Kuma, Gotify. See TROUBLESHOOTING.md for the two cases
(InfluxDB, and the general Docker-Desktop-vs-native-Linux caveats) that
were deliberately *not* bumped to a new major version.

### Documentation

Consolidated ~50 overlapping/contradictory markdown files (many asserting
"production ready," "zero errors," or "field certified" that this pass
disproved) down to README.md, SETUP.md, PLATFORM.md, TROUBLESHOOTING.md,
and this file.

### Housekeeping

- Removed duplicate nested `authentik/authentik/`, `caddy/caddy/`, and
  `email-stack/email-stack/` directories (leftover copy artifacts,
  identical to their parents).
- Removed the obsolete `version: '3.8'` field from every compose file
  (ignored and warned-about since Compose v2).
