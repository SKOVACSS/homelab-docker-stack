# Setup

## Prerequisites

- **Docker Desktop** (Windows/macOS) or Docker Engine + the Compose plugin (Linux). Verify with `docker compose version` (needs the v2 CLI - `docker-compose` with a hyphen is the old, unsupported v1).
- **A domain name on Cloudflare** (nameservers pointed at Cloudflare - free plan is enough). Required, not optional: Caddy gets every certificate through Cloudflare's DNS API, and the whole point of Cloudflare Tunnel (below) is remote access with no port forwarding, which needs Cloudflare in front of the domain either way.
- Accounts/keys you'll be asked for during setup: a [ProtonVPN](https://protonvpn.com) plan with port forwarding (for the media stack's VPN routing), a [Plex claim token](https://plex.tv/claim) if you want Plex.

## 1. Set up Cloudflare Tunnel

Do this before running the installer - it produces two tokens the wizard
asks for. This is what makes every service reachable from the internet
with zero port forwarding, which matters if you're behind CGNAT (Starlink,
many mobile carriers) where there's no public IP to forward a port on in
the first place - but it's the same setup either way, CGNAT or not.

1. **Create a scoped API token** for Caddy's certificate issuance: [Cloudflare
   dashboard -> My Profile -> API Tokens -> Create Token](https://dash.cloudflare.com/profile/api-tokens),
   using the "Edit zone DNS" template, scoped to your one domain (not "All
   zones"). This becomes `CLOUDFLARE_API_TOKEN`.
2. **Create the tunnel**: Cloudflare dashboard -> Zero Trust -> Networks ->
   Tunnels -> Create a tunnel -> Cloudflared connector -> give it a name
   (e.g. `homelab`). The setup page shows an install command containing a
   long token after `--token` - that whole token is `CLOUDFLARE_TUNNEL_TOKEN`.
3. **Add two Public Hostname rules** on that same tunnel (still in the
   Cloudflare dashboard - this repo's `cloudflared` container reads its
   routing from there, not a local file):
   - Subdomain `*`, your domain, type **HTTPS**, URL `caddy:443`. Under
     "Additional application settings -> TLS", turn on **No TLS Verify**
     (Caddy presents a different real certificate per hostname behind this
     one rule, which the tunnel can't pre-validate against a single
     hostname - the connection itself is still fully encrypted end-to-end,
     this only skips a redundant internal check).
   - Subdomain `mail`, your domain, type **HTTP**, URL `caddy:80`. This one
     needs to exist separately from the wildcard above - it's the one
     hostname Caddy deliberately serves over plain HTTP (see the
     `http://mail.{$DOMAIN}` block in `caddy/Caddyfile`), so Mailu's own
     Let's Encrypt certificate renewal can complete. Cloudflare matches the
     more specific exact hostname over the wildcard automatically, so rule
     order doesn't matter.
4. **Add a cache rule** so Cloudflare doesn't try to cache streaming
   responses: Rules -> Cache Rules -> Create rule, matching your domain's
   subdomains, set to Bypass cache.
5. **If you're using Plex**, one more setting once it's deployed (step 5
   below): Plex Settings -> Network -> Custom server access URLs ->
   `https://plex.yourdomain.com:443`. This is what tells the Plex apps
   (phone, web, and every smart TV app) to connect directly through the
   tunnel instead of Plex's own relay network - the fix if you've had
   reliability problems with Plex's relay before.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for what to check if any of
this doesn't come up cleanly - a lot of it (real DNS, a real Cloudflare
account) can't be dry-run locally before your first real deployment.

## 2. Generate configuration

```powershell
cd _scripts
.\gui-installer.ps1
```

The wizard collects your domain, email, the two Cloudflare tokens from
step 1, ProtonVPN credentials, and Plex token, generates a unique
cryptographically-random secret for every database/service that needs one
(20 in total - no password is reused across services), and writes a
correct `.env` file into every stack directory.

Don't want to use the wizard? Every stack's `.env` file is plain text -
open any of them and edit directly. Just keep the variable *names* as they
are; the compose files reference them by name.

## 3. Create host directories

```powershell
.\setup-directories.ps1
```

Creates `D:\Media\{Movies,TV,Music,Books,Photos,Downloads}`,
`D:\Sync`, `D:\Nextcloud`, `D:\Paperless\{consume,archive}`, and
`D:\Backups\{docker,databases}`. On Linux/Synology, see
[PLATFORM.md](PLATFORM.md) for the equivalent paths and update each stack's
`.env` to match before continuing.

## 4. Deploy

```powershell
.\deploy.ps1 -Action deploy
```

This deploys stacks in the order that matters: **Caddy first** (it owns the
shared `caddy-network` that every other stack joins as `external: true`),
then **Authentik**, then everything else. Deploying out of order will fail -
if you ever deploy a stack manually, always bring `caddy` up first.

The first `deploy` also builds a custom Caddy image (see
`caddy/Dockerfile`) with the `caddy-ratelimit` and `caddy-dns/cloudflare`
plugins compiled in, which takes a minute or two the first time.

## 5. Verify

```powershell
.\health-check.ps1
```

Then open a few subdomains in a browser and confirm certificates issue
and pages load. First check that the tunnel itself is actually connected:
`docker compose -f caddy/docker-compose.yml logs cloudflared` should show
a handful of `Registered tunnel connection` lines (it opens several for
redundancy) with no repeating error - if you see `Provided Tunnel token is
not valid`, double check `CLOUDFLARE_TUNNEL_TOKEN` in `caddy/.env` against
the token from the Cloudflare dashboard. First-run setup for a few services:

- **Authentik**: visit `auth.yourdomain.com`, log in as `akadmin` with the
  `BOOTSTRAP_PASSWORD` from `authentik/.env`.
- **Portainer**: visit `portainer.yourdomain.com`, set the admin account on
  first visit (there's no pre-set password - see TROUBLESHOOTING.md).
- **qBittorrent**: check `docker compose -f media-stack/docker-compose.yml
  logs gluetun` for the port ProtonVPN forwarded you, then update `BT_PORT`
  in `media-stack/.env` and redeploy that stack (`.\deploy.ps1 -Action
  restart -Stack media-stack`).
- **Seerr** (`requests.yourdomain.com`): lets family/friends request movies
  and shows instead of asking you directly. First-run setup, all through
  its own web UI:
  1. Sign in with Plex, or point it at Jellyfin's server URL + an API key
     from Jellyfin's dashboard - either way, it can then import your
     Plex/Jellyfin user accounts, so people log in with a login they
     already have.
  2. Add Sonarr and Radarr as request targets (Settings -> Services),
     using each one's own API key (find it under Settings -> General in
     Sonarr/Radarr's own web UI).
  3. Set each user's approval permission (Users tab) - auto-approve for
     people you trust to request freely, manual-approval-required for
     anyone else (you'll get a request to approve/deny instead).
  4. Optional: Settings -> Notifications -> Gotify, once you've created an
     Application for it in Gotify's web UI to get a token - same pattern as
     Watchtower/Diun's Gotify setup.

## 6. Back up

```powershell
.\backup.ps1 -Action backup          # config only
.\backup.ps1 -Action backup -Full    # config + all Docker volumes
```

Backs up every stack's `.env` plus (with `-Full`) a tarball of every Docker
volume, into `D:\Backups\docker\backup_<timestamp>\`. `-Action list` shows
existing backups, `-Action restore -BackupName <name>` restores one,
`-Action clean` prunes down to the 5 most recent.

## Redeploying to different hardware

Since every stack's config lives in its own `.env` file (not baked into any
image), moving this whole setup to new hardware is: copy the repo + your
`.env` files + your media directories to the new machine, then run
`.\deploy.ps1 -Action deploy` there. See [PLATFORM.md](PLATFORM.md) for
path differences between operating systems.
