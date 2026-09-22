# Troubleshooting & Known Limitations

## Sonarr/Radarr/Prowlarr/Lidarr and Radicale now require a login

Fixed a real security gap found in a full audit: these apps ship with
authentication either off or defaulted to "disabled for local addresses,"
a setting that becomes meaningless once every request arrives via a
reverse proxy (every request looks local to the app at that point) - and
Radicale is configured with `RADICALE_AUTH_TYPE=none` outright. Combined
with Cloudflare Tunnel making every subdomain reachable from the public
internet, these were live with zero credentials required. Fixed with
Caddy-level `basic_auth` in front of all five (`arr_auth` snippet and the
`cal.{$DOMAIN}` block in `caddy/Caddyfile`).

- **Changing the password later**: generate a new hash with
  `docker run --rm caddy:2.11.4 caddy hash-password --plaintext "new-password"`,
  update `ARR_AUTH_HASH` or `RADICALE_AUTH_HASH` in `caddy/.env` with the
  result (double every `$` in it - see the Portainer entry below for why),
  then redeploy: `.\deploy.ps1 -Action restart -Stack caddy`.
- **`gui-installer.ps1` needs Docker Desktop running** to generate these
  two credentials specifically (it shells out to `caddy hash-password` to
  produce a real bcrypt hash, rather than approximating one) - if Docker
  isn't running yet when you click "Generate Passwords," you'll get a
  clear error naming the problem rather than a corrupted hash.
- **One shared login for all four *arr apps**, not a distinct one per
  app - a deliberate, documented exception to this repo's usual
  one-secret-per-service rule, since they're a single trust boundary in
  practice (you, the admin, managing your own automation - not a
  family-facing login). Radicale gets its own separate credential since
  it's genuinely family-facing.
- **CalDAV/CardDAV apps handle this fine.** A Basic-auth challenge from a
  fronting reverse proxy is indistinguishable, from the client's
  perspective, from one issued by the CalDAV server itself - phone
  Calendar/Contacts apps don't need any special configuration for this.

## Cloudflare Tunnel: certificates, Plex relay, and the wildcard dashboard warning

This repo's remote-access model changed from "port-forward 80/443 to
Caddy" to "Cloudflare Tunnel, no ports forwarded at all" - see SETUP.md
step 1. A few things specific to that setup that couldn't be verified
without a real Cloudflare account and domain:

- **Caddy won't issue any certificate at all if `CLOUDFLARE_API_TOKEN` is
  wrong or under-scoped.** Check `docker compose -f caddy/docker-compose.yml
  logs caddy` for `dns.providers.cloudflare` errors - the most common cause
  is a token that isn't scoped to "Edit zone DNS" for the right zone, or a
  token that's expired.
- **The wildcard Public Hostname rule (`*.yourdomain.com`) sometimes shows
  a red/warning indicator in the Cloudflare dashboard.** Multiple reports
  in Cloudflare's own community forums describe this as a display quirk
  of the dashboard, not a functional failure - the rule still works. If
  subdomains genuinely aren't resolving, check the actual DNS record
  Cloudflare created for it (should be a CNAME to
  `<tunnel-id>.cfargotunnel.com`) rather than trusting the warning icon.
- **"No TLS Verify" on the wildcard rule is intentional, not a mistake.**
  Cloudflare Tunnel can't pre-validate a certificate against a wildcard
  target that actually serves a different real certificate per hostname
  (that's Caddy's job). The hop this affects is only cloudflared-to-Caddy,
  which happens inside the tunnel's own encrypted connection anyway - the
  browser-to-Cloudflare hop is unaffected and fully verified as normal.
- **Plex still using relay instead of a direct connection?** Confirm
  Settings -> Network -> Custom server access URLs is actually saved as
  `https://plex.yourdomain.com:443` (must include the port), and that
  Settings -> Network -> "Relay" isn't forced on. This is a per-server
  setting Plex broadcasts to every client (phone, web, smart TVs) via
  plex.tv, so it only needs to be set once, not per device.
- **Mailu's own certificate needs its own Public Hostname rule.**
  `mail.{$MAIL_DOMAIN}` (same as `mail.{$DOMAIN}` unless you set a
  separate Mail Domain - see the next entry) is deliberately excluded from
  the wildcard rule (see SETUP.md step 1.3) because Caddy serves it over
  plain HTTP specifically so Mailu's own Let's Encrypt client can complete
  its challenge - if that rule is missing, `mailu-front`'s certificate
  will never renew. Check `docker logs mailu-front` for certbot output.
- **Using a separate Mail Domain (e.g. because your main domain already
  has real email through Proton Mail or similar) and Mailu isn't
  reachable?** Every step in SETUP.md step 1 needs doing for that second
  domain too, not just the main one: it needs its own wildcard + `mail`
  Public Hostname rules on the *same* tunnel, its own cache rule, and
  `CLOUDFLARE_API_TOKEN` needs Zone:DNS:Edit permission scoped to include
  it (a token scoped to only the main domain will make Caddy fail to
  issue a certificate for anything on the mail domain, even though
  everything else keeps working - check `docker compose -f
  caddy/docker-compose.yml logs caddy` for a DNS-01 error naming the mail
  domain specifically if this happens). Also confirm `MAIL_DOMAIN` in
  `caddy/.env` and `DOMAIN` in `email-stack/.env` are set to the exact
  same value - a mismatch here means Caddy is issuing certificates for one
  hostname while Mailu is presenting itself as another.
- **Very high-bitrate 4K remux Plex streams are the one case with mixed
  reports** of stalling/buffering through Cloudflare's edge. Ordinary 4K
  or 1080p direct play/transcode is consistently reported as fine. If this
  turns out to matter in practice, WireGuard (already in `security-stack/`)
  remains available as a direct alternative for that specific device/use.

## Plex Claim Token is optional - and usually pointless to set

`plex.tv/claim` tokens expire in 4 minutes, but `gui-installer.ps1` asks
for it in step 3 of 5, then `setup-directories.ps1` and `deploy.ps1` (which
builds a custom Caddy image first) still have to run as separate steps
after the wizard finishes - by the time the Plex container actually
starts and tries to consume the token, it has almost always already
expired. That's why the field is optional: leave it blank, deploy
normally, then visit `http://<this-pc>:32400/web` and sign into your Plex
account there - Plex's own first-run setup claims the server for you with
no time pressure. An expired or missing `PLEX_CLAIM` doesn't cause any
error in `plexinc/pms-docker`'s logs; the container just starts unclaimed.

If you do want the wizard's token to actually work, get it from
`https://plex.tv/claim` only once you're ready to immediately run the
wizard's remaining steps, `setup-directories.ps1`, and
`deploy.ps1 -Action deploy` back to back within about 4 minutes - tight,
but possible if `deploy.ps1` has already built its Caddy image once
before (subsequent deploys skip that build step).

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

## gluetun crash-loops immediately after deploying media-stack

Check `docker logs gluetun` - two specific causes were found by actually
deploying this stack rather than just validating the YAML (`docker compose
config` can't catch either, since both are runtime validation inside the
gluetun binary itself):

- **`ERROR reading VPN settings: wireguard: parsing address:
  netip.ParsePrefix(...): unable to parse IP`** even though `VPN_TYPE` is
  set to `openvpn`. Fixed in the wizard as of 1.6.4, but a `.env` written
  by an older version of `gui-installer.ps1` (or hand-copied from an old
  example) may still have literal placeholder text in
  `PROTON_WIREGUARD_KEY`/`PROTON_WIREGUARD_ADDRESSES` instead of leaving
  them blank. gluetun tries to parse `WIREGUARD_ADDRESSES` as an IP
  whenever it's non-empty, regardless of which `VPN_TYPE` is actually
  selected - a placeholder string like `your-wireguard-addresses` fails
  that parse and crash-loops the container forever. Fix: blank out both
  values in `media-stack/.env` (unless you're actually using
  `VPN_TYPE=wireguard`, in which case put your real WireGuard key/address
  there instead), then `docker compose -f media-stack/docker-compose.yml
  up -d gluetun`.
- **`ERROR ... the country specified is not valid: value is not one of the
  possible choices: ... United States, ...`** - gluetun's ProtonVPN
  provider validates `SERVER_COUNTRIES` against full country names, not
  ISO codes. `US` fails; `United States` is what it actually wants. Fixed
  in the wizard's country dropdown as of 1.6.4; if you're hand-editing
  `PROTON_COUNTRIES`, use the full name gluetun's own error message lists
  (it enumerates every valid choice), not a 2-letter code.

Both are one-line edits to `media-stack/.env` followed by
`docker compose -f media-stack/docker-compose.yml up -d gluetun` - no
need to redeploy the whole stack.

## gluetun shows "unhealthy" even though the VPN is actually connected

`qmcgaw/gluetun:v3.41.3` doesn't ship `curl` (confirmed live -
`docker exec gluetun curl ...` fails with `executable file not found in
$PATH`), so the original healthcheck
(`curl -f http://localhost:8000/v1/openvpn/status`) always failed and
reported "unhealthy" regardless of whether the tunnel actually worked -
check `docker logs gluetun` for `Initialization Sequence Completed` and a
real public IP to confirm it was a false negative, not a real problem.
Fixed as of 1.6.5 to use gluetun's own dedicated healthcheck command
(`/gluetun-entrypoint healthcheck`) instead, which doesn't depend on
whatever HTTP client happens to be bundled in a given image version.
`docker compose -f media-stack/docker-compose.yml up -d gluetun` - no
need to redeploy the whole stack.

## Several other containers showed "unhealthy" too - same underlying cause

A full real deploy (not just `docker compose config`, which can't catch
any of this) turned up eight more healthchecks broken the same way as
gluetun above - a check written against an assumption about the image
that didn't hold for the actual pinned version. All fixed as of 1.6.7;
if you're on an older `.env`/checkout and see one of these, the fix is
just redeploying that one service, same as gluetun above:

| Service | What was wrong | Fix |
|---|---|---|
| `authentik-server` | Image doesn't ship `wget` | Use `/lifecycle/ak healthcheck` (authentik's own binary) |
| `caddy` | `/health` doesn't exist on Caddy's admin API (404) | Use `/config/` instead - see the warning below |
| `nextcloud-db` | `mysqladmin` doesn't exist in this MariaDB image | Use the image's own `healthcheck.sh --connect` |
| `trilium` | No `curl`, and `localhost` resolves to `::1` where nothing listens (Trilium only binds IPv4) | Use `wget` against `127.0.0.1` |
| `prometheus` | Image doesn't ship `curl` | Use `wget` (bundled) against `127.0.0.1` |
| `wireguard` | Checked `/config/wg0.conf`; the image actually writes `/config/wg_confs/wg0.conf` | Fixed the path |
| `focalboard`, `portainer`, `loki` | No shell, curl, wget, *or* busybox in the image at all | No exec-based healthcheck is possible - disabled (`healthcheck: disable: true`); Docker's own running/crash-looping state is the only available signal |

**If you're hand-editing `caddy/docker-compose.yml`'s healthcheck**:
don't drop the `-o /dev/null`. Caddy's admin API has no authentication by
default, and `/config/` echoes back the *entire live config* - including
`CLOUDFLARE_API_TOKEN` and every basic-auth password hash - in the
response body. `-o /dev/null` discards that body so curl only reports the
HTTP status; without it, that full config (secrets included) gets written
into this healthcheck's log on every single successful check
(`docker inspect caddy-caddy-1` under `.State.Health.Log`), which is a
far easier way to leak it than the admin API itself (that's already
`localhost:2019`-only, not published to the host).

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

## Email server setup is optional and deferred by default

`gui-installer.ps1`'s "Set up email server (Mailu) now" checkbox is
unchecked by default - leaving it that way writes no `email-stack\.env`
at all. `email-stack/` stays fully present in the repo (nothing removed,
nothing to undo), just unconfigured; `deploy.ps1 -Action deploy` skips
any stack with no `.env` rather than starting it with every variable
resolving to an empty string. Run `_scripts/enable-email.ps1` any time
later to turn it on - it writes `email-stack\.env` and sets
`MAIL_DOMAIN` in `caddy\.env` without needing to re-run the whole wizard,
and works the same whether this is a fresh install or hardware you set up
months ago. This exists because Mailu is genuinely the most complex,
fragile stack in this repo (see the 1.0.9, 1.2.2, and 1.5.0 CHANGELOG
entries for the real bugs found in it over time) - not everyone setting
up a homelab from this repo will want to take that on.

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

**If you're behind CGNAT (Starlink, many mobile carriers) - a bigger
problem: receiving mail from the outside world doesn't work at all, and
there is no fix within this repo.** Cloudflare Tunnel (see SETUP.md step 1)
solves remote access for every *HTTP(S)* service in this stack, but its
free tier only proxies HTTP(S) traffic (and private WARP-routed TCP for
your own enrolled devices) - it cannot accept arbitrary inbound SMTP
connections from random mail servers on the internet trying to deliver you
mail. That needs either a real public IP (not available under CGNAT) or
Cloudflare Spectrum, a separate paid product for raw TCP/UDP proxying.
Realistic options if this matters: run `email-stack/` for outbound
sending (via a smart-host relay) and webmail/internal use only, and keep a
regular hosted provider (Gmail, Proton, Fastmail, etc.) as your actual
address for receiving mail from the outside world - or ask your ISP about
a non-CGNAT plan / static IP add-on if owning your inbound mail matters
enough to you.

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

## A database container crash-loops with "password authentication failed"

Every Postgres/MariaDB-backed service here (`authentik`, `immich-app`,
and `privacy-stack`'s Nextcloud/Paperless/Wallabag databases) sets its
root/app password from a `.env` variable
(`DB_PASSWORD`/`PG_PASS`/`NEXTCLOUD_DB_PASS`/etc.) - but that variable
only takes effect the *first* time the database image initializes a
genuinely empty data directory. If that directory already has data in it
from an earlier attempt (a previous deploy, an old copy of this repo, or
re-running `gui-installer.ps1` - which generates a brand new random
password every single time it runs), the database keeps whatever
password it was actually initialized with, `.env`'s value silently stops
matching it, and the app container that connects to it (immich_server,
authentik-server, Nextcloud, etc.) crash-loops on `password
authentication failed` forever - confirmed live against a leftover
`immich-app/postgres` data directory from a much older test of this repo.

Fix without losing any data - update the database's *actual* password to
match `.env` instead of touching the data directory:

```powershell
# Postgres (authentik, immich-app, and two of privacy-stack's databases)
docker exec <postgres-container-name> psql -U <db-username> -c "ALTER USER <db-username> PASSWORD '<value-from-.env>';"

# MariaDB (privacy-stack's Nextcloud database)
docker exec <mariadb-container-name> mariadb -u root -p<old-root-password> -e "ALTER USER '<db-username>'@'%' IDENTIFIED BY '<value-from-.env>';"
```

Then restart the app container that depends on it. If you'd rather start
that one database completely fresh instead (only sensible if you're sure
there's nothing worth keeping in it), delete its data directory/volume
before the next `docker compose up` so first-run initialization actually
runs again.

## qBittorrent bans itself behind a basic_auth-protected reverse proxy

**Update:** `qbit_auth` no longer exists in this Caddyfile as of the
change described below - removed once it was confirmed qBittorrent
already has its own real, mandatory login, making Caddy's copy pure
redundant friction (and, per this exact bug, actively harmful). This
specific instance can no longer recur here, but the entry stays as
general knowledge for the underlying pattern, which still applies to
Radicale's `cal.{$DOMAIN}` (its own auth is genuinely disabled, so
Caddy's basic_auth there is load-bearing, not redundant - this bug class
doesn't apply there since there's no second login for the header to
collide with) or any new app you ever put a Caddy login in front of that
also happens to have its own separate login underneath.

If `qbit.{$DOMAIN}` intermittently (or permanently) returns "Your IP
address has been banned after too many failed authentication attempts"
even with correct credentials at every layer, this is not Cloudflare and
not Caddy's own rate limiter - it's qBittorrent banning itself.

Caddy's `basic_auth` (the `qbit_auth` snippet, a separate credential from
qBittorrent's own login) validates the incoming `Authorization` header
and then, by default, `reverse_proxy` still forwards that same header
upstream. qBittorrent's WebUI sees it and tries to use it as a login
attempt against *its own* password - which never matches, since it's
Caddy's credential, not qBittorrent's - and counts it as a failed login.
This happens on every single request that reaches qBittorrent through
Caddy, so its own "ban IP after N failed logins" setting (Options > Web
UI, default 5 failures) is guaranteed to eventually ban whatever address
`reverse_proxy` connects from - the one address every real user's
traffic shares. Once banned, everyone using the proxy is locked out
regardless of correct credentials, until the ban expires.

Confirm by checking `docker exec qbittorrent tail -f
/config/data/logs/qbittorrent.log` while loading the site through
Caddy - a login failure logged against gluetun/Caddy's container IP with
`attempt count` climbing on every page load is this bug, not a real bad
password anywhere.

Fix: strip the header before it reaches qBittorrent, in that service's
`reverse_proxy` block in `caddy/Caddyfile`:

```
reverse_proxy gluetun:{$QBIT_PORT} {
  header_up -Authorization
}
```

Then clear any active ban immediately with `docker restart qbittorrent`
(the ban list is in-memory only - restarting Caddy does *not* clear it,
only restarting qBittorrent itself does). This class of bug applies to
any backend proxied behind Caddy `basic_auth` that also implements its
own separate login - worth checking if you add another one.

## Setting up Homepage's Authentik OIDC provider by hand/API hits two traps

If you create the OAuth2 Provider + Application for Homepage via
Authentik's API or Django shell instead of its own admin UI wizard (the
wizard fills in sane defaults for both of these; a bare
`OAuth2Provider.objects.create(...)` does not), you'll hit two separate
failures in sequence, both looking like generic OIDC errors with no
obvious cause:

**`invalid_request` / "The request is otherwise malformed" on every
authorize attempt, regardless of login state.** Confirmed live via
Authentik's own source (`authentik/providers/oauth2/views/authorize.py`,
`check_grant()`): it rejects the request unless
`self.grant_type in self.provider.grant_types` - and a provider created
without explicitly setting `grant_types` defaults to `[]`, which no
grant type can ever be a member of. Set it explicitly:

```python
from authentik.providers.oauth2.models import OAuth2Provider, GrantTypes
p = OAuth2Provider.objects.get(name="Homepage")
p.grant_types = [GrantTypes.AUTHORIZATION_CODE, GrantTypes.REFRESH_TOKEN]
p.save()
```

**`unexpected JWT alg received, expected RS256, got: HS256`** from the
client (Homepage/NextAuth) after that's fixed. A provider with no
`signing_key` set signs ID tokens with HS256 (symmetric, using the
client secret) - most OIDC client libraries, including Homepage's,
expect and require RS256 by default. Assign one of Authentik's own
certificates:

```python
from authentik.crypto.models import CertificateKeyPair
p.signing_key = CertificateKeyPair.objects.get(name="authentik Self-signed Certificate")
p.save()
```

Also don't forget scope mappings - a freshly-scripted provider has
`property_mappings: []` too, which won't produce the `invalid_request`
error above but will silently omit `email`/`profile` claims from the ID
token. Attach Authentik's shipped defaults:

```python
from authentik.providers.oauth2.models import ScopeMapping
p.property_mappings.set(ScopeMapping.objects.filter(managed__startswith="goauthentik.io/providers/oauth2/scope-"))
```

All three are one-time setup steps - fix them on the Provider object
once and every future login works normally.

## Unpackerr: how the extract-then-import pipeline actually fits together

Sonarr/Radarr/Lidarr already import a completed download automatically
(Completed Download Handling) - that's built in and was never the
problem. What they can't do is extract an archive, so a torrent that
ships as a multi-part RAR just sits "complete" with nothing importable
inside it. Unpackerr (`media-stack/docker-compose.yml`) fills that one
gap: it polls each app's `/queue` API on its own interval (2 minutes by
default) and extracts any archive it finds at a queue item's download
path once that item shows as fully downloaded.

**Why this already waits for the right moment, with nothing extra to
configure**: qBittorrent never marks a torrent "complete" until every
file in it - including every `.r00`/`.r01`/... volume of a split RAR -
has finished downloading and passed its hash check. A partially-arrived
archive is never visible as "complete" to Sonarr/Radarr/Lidarr's queue in
the first place, so Unpackerr can't (and doesn't need to try to) jump the
gun. For an uncompressed download, there's nothing to extract - the
app's own existing import logic just runs as it always did.

**If extraction isn't happening**: `docker compose -f
media-stack/docker-compose.yml logs unpackerr` first. The most common
cause is one of the three `*_API_KEY` values in `media-stack/.env` being
blank or stale (each is generated by that app itself on first boot, not
by this stack - see `SETUP.md`) - the log line for that app will show
`apikey:true` even for a wrong key, since Unpackerr only checks that a
key is *configured*, not that the app *accepted* it; an actual rejection
shows up as an HTTP error on the next queue poll instead. The second most
common cause is a path mismatch: Unpackerr matches an archive to a queue
item by container path, so its own `/downloads` volume mount must point
at the exact same host folder as qBittorrent's and the *arr apps' - if
you ever change `QBIT_DOWNLOADS_PATH`, Unpackerr picks it up automatically
since it reads the same variable, but a custom path added directly in
Unpackerr's `paths` config instead would silently stop matching anything.

**`DELETE_ORIG` is deliberately left at its default (off)** rather than
set to auto-clean the source archive after extraction. This stack
downloads over BitTorrent, where the original files are still the seed -
deleting them right after extraction would corrupt the torrent's own
data on disk mid-seed. Turn it on only if you stop seeding immediately
after a download completes.

## slskd's documented default Soulseek port (50300) fails on Windows

Confirmed live: `docker compose up` on the `slskd` service failed with
`bind: An attempt was made to access a socket in a way forbidden by its
access permissions` when `SLSK_PORT` was left at slskd's own documented
default of 50300. Cause: Windows reserves large chunks of the high port
range for Hyper-V's dynamic port allocation (`netsh int ipv4 show
excludedportrange protocol=tcp` lists them), and on this machine that
range happened to swallow 50300 entirely. This isn't specific to slskd -
any container publishing a port in one of these ranges hits the same
error. Fixed by moving `SLSK_PORT` to 42300 in `.env.example` (outside
every default Windows exclusion range) - if you still hit this on your
own machine, run the `netsh` command above and pick a port outside
whatever ranges it lists.

## Soulseek pipeline: how slskd + soularr actually fit together

Same shape as the Unpackerr entry above, for a completely different
source: Lidarr has no native concept of Soulseek, so nothing about this
touches Lidarr's own Completed Download Handling. soularr is the bridge -
it polls Lidarr's wanted/missing list directly via API, searches Soulseek
for each one via slskd's REST API, and once slskd finishes a transfer,
calls Lidarr's import API pointed at the download folder itself (not
Lidarr's normal download-client-queue mechanism), so grabbed albums never
appear in Lidarr's Activity queue the way a qBittorrent grab does - check
soularr's own log/web UI (port 8265) instead to see what it's doing.

**`http://gluetun:5030`, not `http://slskd:5030`, in
`soularr/config.ini`'s `[Slskd] host_url`.** slskd runs on
`network_mode: service:gluetun` (to tunnel Soulseek traffic through the
VPN, same reasoning as qBittorrent - Soulseek is P2P, so every peer you
transfer with sees your IP unless it's tunneled), which means it has no
network identity of its own for other containers to resolve by name -
exactly the same gotcha documented for Sonarr/Radarr/Prowlarr's qBittorrent
download-client setting elsewhere in this stack.

**The Soulseek peer port (`SLSK_PORT`) is not actually reachable from the
internet**, unlike `BT_PORT`. ProtonVPN's port forwarding assigns exactly
one forwarded port per VPN connection, and `BT_PORT` (qBittorrent)
already claims it, since both share gluetun's single VPN tunnel. Soulseek
still works fully for searching and downloading either way - the only
effect is reduced visibility as an upload source to other peers, the same
degradation any P2P client sees behind an unforwarded NAT.

## Changing a Caddyfile `{$VAR}` means updating TWO files, not one

Confirmed live: adding a new `{$SOME_VAR}` reference to `caddy/Caddyfile`
(for the `slskd.{$DOMAIN}` route) and updating `.env` alone was not
enough - the site came back with every request failing `dial tcp ...:80:
connect: connection refused`, because the variable resolved to an empty
string inside the container. Caddy reads `{$VAR}` substitutions from its
own **process environment**, not from a `.env` file directly - and
`caddy/docker-compose.yml`'s `environment:` block only forwards the
specific variables it explicitly lists (see `DOMAIN`, `QBIT_PORT`,
`CLOUDFLARE_API_TOKEN` there). A new `{$VAR}` used in the Caddyfile has to
be added to that list too, or it silently resolves to nothing - Caddy
doesn't error on an undefined `{$VAR}`, it just substitutes empty string,
which is much harder to spot than a startup crash. After adding a
variable to the Caddyfile, grep `caddy/docker-compose.yml`'s
`environment:` block before redeploying, not just `caddy/.env`.
