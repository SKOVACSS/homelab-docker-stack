# Troubleshooting & Known Limitations

## Fail2Ban won't actually block anything under Docker Desktop

Fail2Ban bans IPs by inserting iptables rules on the host's network stack.
Docker Desktop (Windows/macOS) runs containers inside a Linux VM, so
Fail2Ban's bans apply *inside that VM*, not on your real host - they will
not block inbound WAN traffic on Windows/macOS. Fail2Ban works as intended
on a native Linux host (a real Linux server, or a Synology). If you're
running Docker Desktop and exposing services to the internet, treat Caddy's
rate limiting (below) as your actual brute-force defense, and consider a
router/firewall-level ban list as well.

## Rate limiting - how it actually works

`caddy/Caddyfile` uses the [caddy-ratelimit](https://github.com/mholt/caddy-ratelimit)
plugin, compiled into a custom image by `caddy/Dockerfile` (the stock Caddy
image doesn't include third-party modules). Each protected route gets its
own zone (30 requests/minute per client IP, e.g. `import rate_limit
sonarr`) so one busy site block can't exhaust another's quota. To change the
limit, edit the `events`/`window` values in the `(rate_limit)` snippet in
the Caddyfile and redeploy the caddy stack (`docker compose -f
caddy/docker-compose.yml up -d --build`).

## qBittorrent: QBIT_PORT vs BT_PORT

These are two different ports and must stay different:

- `QBIT_PORT` is qBittorrent's WebUI port. Static - set it once and forget it.
- `BT_PORT` is the BitTorrent peer-listening port, which **must match
  whatever port ProtonVPN forwards you**. Check `docker compose -f
  media-stack/docker-compose.yml logs gluetun | grep -i port` after gluetun
  connects, then update `BT_PORT` in `media-stack/.env` and redeploy. If
  ProtonVPN reassigns your forwarded port later, incoming peer connections
  silently stop working until you update this again.

Giving both the same value breaks qBittorrent - it needs two separate
sockets (one HTTP, one for BitTorrent) and can't bind the same port twice.

## Mailu is a minimal build, not the full official topology

`email-stack/` runs Mailu's admin/dovecot/postfix/rspamd/webmail
components directly, without Mailu's own `front` (nginx) container or
antivirus (ClamAV) service. This was a deliberate scope decision: Mailu's
`front` wants to own ports 80/443 for its own ACME/TLS handling, which
conflicts with Caddy already owning those ports for every other service.
Reconciling the two would need either a TCP-multiplexing layer in front of
both or moving mail off Caddy's ports entirely - either is a bigger,
separately-testable change.

What this means in practice:
- Webmail and the admin panel are reachable through Caddy
  (`webmail.yourdomain.com`, `mailadmin.yourdomain.com`) - that part works
  the same as if Mailu's own front were there.
- No antivirus scanning on incoming mail (rspamd still does spam filtering).
- If you want the fully-featured, officially-supported topology instead,
  generate one at [setup.mailu.io](https://setup.mailu.io) and adapt its
  networking to sit behind Caddy, or run it standalone on its own IP/ports.

**Also:** most residential ISPs block outbound port 25, which breaks direct
mail delivery regardless of how Mailu is configured. If mail doesn't send,
check that first - the fix is a smart-host relay (e.g. SendGrid, AWS SES),
not anything in this repo.

## Two separate Grafana instances

`monitoring-stack/grafana-advanced` (port 3001, `metrics.yourdomain.com`)
visualizes InfluxDB/Telegraf host metrics. `utilities/grafana` (port 3000,
`grafana.yourdomain.com`) visualizes Prometheus/Loki container metrics and
logs. This is redundant for a small homelab - two things doing overlapping
jobs - kept as two only because collapsing them into one Grafana with both
datasources is a bigger change than this pass covers. If you don't need
both, it's safe to comment out the `influxdb`/`telegraf`/`grafana-advanced`
services in `monitoring-stack/docker-compose.yml` and lean on
`utilities/`'s Prometheus + node-exporter for host metrics instead (add a
Prometheus scrape target or dashboard as needed).

## InfluxDB is pinned to 2.x, not 3.x

InfluxDB 3 is a ground-up rewrite (different query language, different
config, different write API) that Telegraf's `outputs.influxdb_v2` plugin
here doesn't speak. 2.x is still a supported, maintained release line - just
not the latest major. Moving to 3.x means also rewriting the Telegraf output
config and the dashboard queries; treat it as a separate project, not a
version bump.

## node-exporter reports the Docker Desktop VM, not your real host

On Windows/macOS, `network_mode: host` (needed for node-exporter to see the
*actual* host's stats) only works inside Docker Desktop's Linux VM, not on
your real OS. `utilities/docker-compose.yml`'s `node-exporter` service runs
without host networking so it starts cleanly everywhere, but on Docker
Desktop it's reporting the VM's CPU/memory/disk, not your Windows/macOS
host's. On a native Linux/Synology deployment, add `pid: host` and
`network_mode: host` to that service (and drop its `networks:` list) for
accurate numbers.

## Portainer: no `PORTAINER_PASSWORD_HASHED` env var (there never was one)

Portainer's admin password is set via a CLI flag
(`--admin-password-file`), not an environment variable - an
env var named `PORTAINER_PASSWORD_HASHED` does nothing, and a bcrypt hash
placed in a `.env` file gets mangled anyway (docker compose treats `$` as
the start of a variable reference, so a hash like `$2y$05$...` needs every
`$` doubled to `$$` to survive). Simplest fix, already applied: leave it
unset and create the admin account the first time you open Portainer's web
UI - it prompts automatically and locks the setup page after the first
account exists.

## Two apps were removed or replaced during the 1.0 pass

See [CHANGELOG.md](CHANGELOG.md) for the full list. In short: **Readarr**
was removed (its upstream project was archived/retired in 2025 and never
left beta), and **Trilium** now points at the actively-maintained
**TriliumNext** fork instead of the abandoned original. **Focalboard** and
**OnlyOffice** are still included but are on unmaintained or slow-moving
upstreams - see the comment above the Focalboard block in
`caddy/Caddyfile`.

## "docker compose" vs "docker-compose"

Every command in this repo's scripts/docs uses `docker compose` (a Docker
CLI plugin, v2). The older, hyphenated `docker-compose` (v1) is
end-of-life and not what these compose files were tested against - if
you have both installed, make sure `docker compose version` reports a
v2.x release.

## A stack won't come up

```powershell
docker compose -f <stack>/docker-compose.yml --env-file <stack>/.env config
```

This resolves every `${VAR}` and prints the fully-expanded config without
starting anything - it's the fastest way to spot a missing/misspelled
environment variable before it turns into a confusing container crash.
