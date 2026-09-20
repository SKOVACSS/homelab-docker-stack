# Changelog

## 1.0.4 - Fix Telegraf crash-loop (2026-09-20)

Follow-up to the bug flagged (but not fixed) in 1.0.3. Turned out to be
three separate, layered bugs - fixing the first one just uncovered the
next, each confirmed by actually running the container rather than
assuming a fix worked:

1. **Invalid config fields**, rejected by Telegraf 1.38's stricter
   validation: `inputs.disk`'s `paths` (doesn't exist - `mount_points`
   already did this), `inputs.docker`'s `total`/`perdevice`/
   `container_names` (replaced by list-valued `total_include`/
   `perdevice_include`; `container_names` never existed), and
   `inputs.file`'s `from_beginning`/`tag_files` (belong to a different
   plugin, `inputs.tail`). The `inputs.file` block itself (reading
   `/proc/cpuinfo`/`/proc/meminfo`) was removed rather than patched -
   `inputs.file` expects its files already in a parseable metrics format,
   which raw `/proc` contents aren't, and `inputs.cpu`/`inputs.mem`
   already cover that data correctly via native OS calls. Also removed a
   duplicate `[[inputs.processes]]` block.
2. **Docker socket permission denied**, masked until fix #1 let Telegraf
   get far enough to actually try connecting. The image's default user
   (uid 999) can't read the bind-mounted `docker.sock`. `user: root` in
   compose looked like the fix but wasn't enough on its own: the image's
   own `/entrypoint.sh` unconditionally drops from root to the `telegraf`
   user via `setpriv` before launching, and deliberately excludes the
   `root` group (which is what owns the socket here) from what it carries
   over - see
   [influxdata-docker#724](https://github.com/influxdata/influxdata-docker/issues/724).
   A host-specific docker-group GID via `group_add` would work on native
   Linux but isn't portable across the Windows/Synology hosts this repo
   targets. Fixed by overriding `entrypoint: ["/usr/bin/telegraf"]` to
   bypass the image's privilege-drop script entirely.
3. **`inputs.influxdb` only supports InfluxDB 1.x's `/debug/vars`
   endpoint** - this project runs 2.x. It was logging `invalid character
   '<' looking for beginning of value` (an HTML error page, not JSON)
   every 30s and gathering nothing. Replaced with
   `inputs.prometheus` pointed at InfluxDB 2.x's real `/metrics` endpoint,
   which does the same job (InfluxDB's own internal stats) correctly.

Verified live end-to-end: Telegraf runs with zero errors/warnings besides
expected benign ones (diskio can't see host block devices from inside a
container, which is normal), and real metrics - including
`usage_active`, the field the Grafana dashboard actually queries, and
InfluxDB's own internal stats - are confirmed landing in InfluxDB via a
direct Flux query.

## 1.0.3 - Collapse the two Grafana instances; wire Grafana -> Gotify alerting (2026-09-20)

### One Grafana instead of two

`monitoring-stack/grafana-advanced` (InfluxDB/Telegraf) and
`utilities/grafana` (Prometheus/Loki) are now just `utilities/grafana`,
provisioned with all three datasources. `utilities/docker-compose.yml`
joins `monitoring-network` (owned by `monitoring-stack`) externally so
Grafana can reach InfluxDB by container name - this makes `utilities` now
depend on `monitoring-stack` being deployed first, which is already the
order `_scripts/deploy.ps1` uses (see TROUBLESHOOTING.md for what happens
if you deploy them out of order manually). The InfluxDB dashboard moved
from `monitoring-stack/grafana-provisioning/` (now removed) into
`utilities/grafana-provisioning/dashboards/`.

Verified live: deployed both stacks, confirmed all three datasources
loaded, and confirmed Grafana could actually query InfluxDB across the
cross-stack network (`"datasource is working. 3 buckets found"`) - not
just that the config parses.

**Found in passing, not fixed (separate, pre-existing bug):**
`monitoring-stack/telegraf.conf` fails to start on Telegraf 1.38 - several
plugin fields it uses (`inputs.disk`'s `paths`, `inputs.docker`'s `total`/
`container_names`/`perdevice`) aren't valid for this version, so Telegraf
crash-loops. This was never caught before because nobody had actually run
Telegraf itself against this config until this session's live test.

### Grafana -> Gotify alerting

Added `utilities/grafana-provisioning/alerting/` (contact point +
notification policy). Verified live end-to-end: fired a real test
notification through Grafana's alerting API and confirmed Gotify received
a correctly-rendered message (`"FIRING - TestAlert (1 alert)"` /
`"This is a live test from Claude"`). Two things worth knowing (both in
TROUBLESHOOTING.md):
- The contact point targets Gotify's actual REST endpoint, not the
  `gotify://` shoutrrr URI Watchtower uses elsewhere - confirmed Grafana's
  generic webhook integration has no concept of shoutrrr schemes.
- A `priority` setting is silently dropped by Grafana's webhook
  integration (only documented settings like title/message/url pass
  through) - alerts land in Gotify at default priority. Fixing that needs
  the full custom `payload` template override, which wasn't worth the
  added fragility here.

This wires the notification *path* only - no alert rules are provisioned
(Grafana ships with none by default), since "what should page you" is a
judgment call outside this scope.

## 1.0.2 - Fix a data-loss bug in validate-stacks.sh (2026-09-20)

While testing 1.0.1's `validate-stacks.sh` against an interrupt (Ctrl-C)
mid-run, a bug in its backup/restore logic caused every stack's real
`.env` file to be deleted. Nothing was deployed at the time, so no live
credentials were lost, but this is worth being explicit about since the
whole point of that script was to be safe to run against real files.

Root cause: a single global `trap ... EXIT INT TERM` handler looped over
*every* stack to restore/clean up, backed by one shared temp directory
that could be (and was) removed by an earlier invocation of the same trap
while the main loop was still mid-iteration - the interrupted stack's
backup lookup then silently failed and its `.env` was left holding
placeholder values instead of being restored.

Fixed by removing the shared trap/temp-directory design entirely:
- Only `immich-app` actually needs an on-disk `.env` swap (its compose
  file uses `env_file:`, which Compose reads straight off disk regardless
  of `--env-file`) - every other stack never touches the real file at all.
- The one stack that does swap backs up to a plainly-named sibling file
  (`immich-app/.env.validate-stacks-backup`), not a temp directory that
  gets programmatically deleted - so even in the worst case, the backup
  survives on disk and is recoverable by hand.
- The script now self-heals on every run: if it finds a leftover
  `*.env.validate-stacks-backup` from a previous interrupted run, it
  restores that first before doing anything else.
- Verified: normal run leaves no files behind; a real `.env` present for
  immich-app survives byte-for-byte; a simulated interrupted prior run
  (backup file present, dummy content left in `.env`) is correctly healed
  on the next run.

## 1.0.1 - Quick wins (2026-09-20)

Follow-up pass after tagging v1.0.0: notification wiring, and a set of real
bugs found by actually running the fixed scripts against a live stack
rather than just parse-checking them (below), plus CI to stop regressions.

- **Fixed a live misclassification bug in `health-check.ps1`**: it parsed
  `docker compose ps`'s human-readable table by splitting on whitespace,
  which breaks the moment the STATUS column contains a space (e.g. "Up 5
  hours (healthy)") - and its unhealthy-detection branch was unreachable
  dead code, since the earlier `-match "Up"` branch caught every running
  container, healthy or not, before the unhealthy check ever ran. An
  actually-unhealthy container would have been reported as fine. Rewrote
  to use `docker compose ps --format json`'s real `State`/`Health` fields,
  and verified against live containers in all three states (healthy,
  unhealthy, not running).
- **Fixed the same class of bug in `deploy.ps1`**'s status/wait-for-healthy
  logic: `Show-Status`'s "total" count included the table header row (so
  running-count could never equal total-count, even when everything was
  actually up), and `Deploy-Stack`'s health-wait loop matched the substring
  "healthy" anywhere in the output rather than checking every container.
  Both switched to the same `--format json` approach.
- **Fixed a dead code path in `health-check.ps1`**: `docker ps` always
  prints a header row even with zero containers running, so the "nothing
  is running" early-exit check (`-not $containers`) could never actually
  trigger. Switched to `docker ps -q`.
- Replaced `Invoke-Expression` in `deploy.ps1` with a direct argument-array
  call (avoids shell-string quoting hazards).
- Fixed `deploy.ps1 -Action` being both `Mandatory` and defaulted to
  `"deploy"` (contradictory - the default could never apply). Now optional,
  defaulting to `deploy`.
- Renamed a local `$pwd` in `gui-installer.ps1` that shadowed PowerShell's
  automatic current-directory variable.
- Implemented `health-check.ps1 -JSON` for real (previously accepted but
  did nothing) - now emits clean, `ConvertFrom-Json`-able output with no
  decorative text mixed in.
- Added optional Gotify push notifications to `backup.ps1` (on completion)
  and `health-check.ps1` (on unhealthy/down), and to Watchtower itself (on
  update) - all opt-in, off unless a token is configured, all verified
  against a live Gotify instance including a real end-to-end Watchtower
  notification.
- Added `_scripts/validate-stacks.sh` and a GitHub Actions workflow
  (`.github/workflows/validate.yml`) that runs it plus PSScriptAnalyzer on
  every push: `docker compose config` against every stack using
  `.env.example`'s documented variables, failing on invalid YAML or on a
  `${VAR}` the compose file references that isn't documented. Confirmed it
  actually catches both bug classes from the 1.0 pass by reintroducing them
  temporarily and watching it fail.

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
