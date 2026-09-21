# Troubleshooting & Known Limitations

## Pi-hole: port 53 already in use on native Linux

`dns-stack/`'s `pihole` service publishes host port 53 (UDP/TCP) - real
DNS service for your network, the one port outside Caddy's 80/443 this
repo publishes directly. On a native Linux host (not Docker Desktop),
`systemd-resolved` often already binds port 53 itself, and Pi-hole's
container will fail to start with a port-already-in-use error. Fix:
disable `systemd-resolved`'s stub listener
(`DNSStubListener=no` in `/etc/systemd/resolved.conf`, then
`systemctl restart systemd-resolved`) before deploying this stack.

Also: deploying the container alone does nothing until you actually
point your router or devices' DNS settings at this machine's IP - that
step is outside Docker's control and can't be automated by this repo.
Test with `nslookup <some-ad-domain> <this-machine-ip>` before
repointing a real device, so a misconfiguration doesn't take down DNS
for your whole network.

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

## Mailu runs its own `front` for mail protocols only - not for 80/443

`email-stack/` runs Mailu's full topology - admin, dovecot, postfix,
rspamd, webmail, `front` (Mailu's own nginx), `antivirus` (Mailu's own
ClamAV build), `webdav` (Radicale), and `resolver` (Mailu's own unbound,
required because Mailu's admin container refuses to start without a
DNSSEC-*validating* resolver - Docker's built-in one doesn't validate).

The one deliberate deviation from Mailu's stock setup: `front` does
**not** bind ports 80/443. Caddy already owns those for every other
service, so `front` only binds the actual mail protocol ports
(25/465/587/110/143/993/995) and gets its own Let's Encrypt certificate
via an HTTP-01 challenge that Caddy passes through on
`http://mail.yourdomain.com` (see `caddy/Caddyfile`) - this is Mailu's
own documented pattern for running behind an external reverse proxy,
not something improvised here.

What this means in practice:
- Webmail and the admin panel are reachable through Caddy
  (`webmail.yourdomain.com`, `mailadmin.yourdomain.com`), same as before.
- SMTP/IMAP/POP3 get real TLS from `front`'s own certificate, not the
  unencrypted/self-signed state this stack shipped with prior to the
  rebuild in CHANGELOG 1.0.9.
- Antivirus scanning is active on incoming mail (rspamd + Mailu's own
  ClamAV build), not just spam filtering.
- `front`'s certificate issuance needs a real public domain reachable
  from the internet - untestable locally. If SMTP/IMAP TLS isn't
  working after a real deployment, check `docker logs mailu-front` for
  the certbot output first.

**Also:** most residential ISPs block outbound port 25, which breaks direct
mail delivery regardless of how Mailu is configured. If mail doesn't send,
check that first - the fix is a smart-host relay (e.g. SendGrid, AWS SES),
not anything in this repo.

## One Grafana, two stacks

`utilities/grafana` (port 3000, `grafana.yourdomain.com`) is the only
Grafana - it has Prometheus, Loki, *and* InfluxDB provisioned as
datasources (there used to be a second `grafana-advanced` instance just
for InfluxDB; collapsed into one - see CHANGELOG.md). To reach InfluxDB,
Grafana joins `monitoring-network`, which is created by `monitoring-stack`
and declared `external: true` in `utilities/docker-compose.yml`. That
means **`monitoring-stack` must be deployed before `utilities`** (already
the order `_scripts/deploy.ps1` uses) - if you ever deploy stacks manually
out of order, `utilities` will fail to start with a
"network monitoring-network declared as external, but could not be found"
error. Deploy `monitoring-stack` first and re-run.

If you don't want InfluxDB/Telegraf at all, it's safe to comment out the
`influxdb`/`telegraf` services in `monitoring-stack/docker-compose.yml`
and drop the `monitoring-network` entries from `utilities/docker-compose.yml`
- Grafana works fine with just Prometheus/Loki.

## Grafana alerting only forwards title/message to Gotify, not priority

`utilities/grafana-provisioning/alerting/` wires Grafana's alerting to
Gotify via a webhook contact point pointed at Gotify's real REST endpoint
(`http://gotify:80/message?token=...` - not the `gotify://` shoutrrr URI
Watchtower uses elsewhere in this repo, which Grafana's webhook integration
doesn't understand). Verified live: Grafana's default alert JSON plus a
`title`/`message` template is accepted by Gotify as-is (it only requires
`message` and ignores the rest). A `priority` setting does **not** get
forwarded, though - Grafana's webhook integration only passes through a
fixed set of known settings, so alerts land in Gotify at the default
priority (0, not urgent). Getting a custom priority through needs the full
`payload` template override (with Grafana's `tmpl.Exec`/`coll.Dict`
functions) instead of the simple `title`/`message` fields - skipped as
more fragility than a homelab needs.

This wires the *notification path* - it doesn't include any alert rules
(Grafana ships with none by default). Add rules under Alerting -> Alert
rules in the UI, or provision them under
`grafana-provisioning/alerting/rules.yaml`, and point them at the `gotify`
contact point.

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
