# Setup

## Prerequisites

- **Docker Desktop** (Windows/macOS) or Docker Engine + the Compose plugin (Linux). Verify with `docker compose version` (needs the v2 CLI - `docker-compose` with a hyphen is the old, unsupported v1).
- **A domain name on Cloudflare** (nameservers pointed at Cloudflare - free plan is enough). Required, not optional: Caddy gets every certificate through Cloudflare's DNS API, and the whole point of Cloudflare Tunnel (below) is remote access with no port forwarding, which needs Cloudflare in front of the domain either way.
- Accounts/keys you'll be asked for during setup: a [ProtonVPN](https://protonvpn.com) plan with port forwarding (for the media stack's VPN routing). If you want Plex, a Plex account is all you actually need up front - the wizard's [Plex claim token](https://plex.tv/claim) field is optional (see step 5 below for why it's usually easier to just claim it manually after deploying).

## 1. Set up Cloudflare Tunnel

Do this before running the installer - it produces two tokens the wizard
asks for. This is what makes every service reachable from the internet
with zero port forwarding, which matters if you're behind CGNAT (Starlink,
many mobile carriers) where there's no public IP to forward a port on in
the first place - but it's the same setup either way, CGNAT or not.

**Don't want to run an email server at all, or not sure yet?** The wizard
in step 2 has a "Set up email server (Mailu) now" checkbox, unchecked by
default - leave it that way and skip the Mailu-specific parts of step 1.3
below entirely for now. `email-stack/` stays in the repo either way, just
unconfigured; run `_scripts/enable-email.ps1` whenever you're ready to
turn it on, no need to redo any of this.

**Already have real email on this domain through another provider (Proton
Mail, Google Workspace, etc.)?** Don't point Mailu at it - a domain can
only have one real mail provider, and Mailu taking over would break your
existing inbox. Use a second domain for Mailu instead (the "Mail Domain"
field in step 2's wizard, or `enable-email.ps1`'s prompt if you're turning
it on later) - it can be a domain you already own or a new one, and needs
to be added to the same Cloudflare account (a free account holds many
domains). Steps 1 and 3 below both need doing for that second domain too
if so; steps 2 and 4 are shared across every domain on one tunnel.

1. **Create a scoped API token** for Caddy's certificate issuance: [Cloudflare
   dashboard -> My Profile -> API Tokens -> Create Token](https://dash.cloudflare.com/profile/api-tokens),
   using the "Edit zone DNS" template. Add every domain you're actually
   using to the same token's zone list (just your one domain if Mailu
   isn't using a separate one) rather than "All zones". This becomes
   `CLOUDFLARE_API_TOKEN`.
2. **Create the tunnel**: Cloudflare dashboard -> Zero Trust -> Networks ->
   Tunnels -> Create a tunnel -> Cloudflared connector -> give it a name
   (e.g. `homelab`). The setup page shows an install command containing a
   long token after `--token` - that whole token is `CLOUDFLARE_TUNNEL_TOKEN`.
   One tunnel serves every domain - no need for more than one even with a
   separate Mail Domain.
3. **Add Public Hostname rules** on that same tunnel (still in the
   Cloudflare dashboard - this repo's `cloudflared` container reads its
   routing from there, not a local file). Two rules per domain you're
   using - repeat both for your Mail Domain too if it's separate from your
   main domain:
   - Subdomain `*`, the domain, type **HTTPS**, URL `caddy:443`. Under
     "Additional application settings -> TLS", turn on **No TLS Verify**
     (Caddy presents a different real certificate per hostname behind this
     one rule, which the tunnel can't pre-validate against a single
     hostname - the connection itself is still fully encrypted end-to-end,
     this only skips a redundant internal check).
   - Subdomain `mail`, the domain, type **HTTP**, URL `caddy:80`. Only
     needed if you're setting up email now (or ever plan to) - it exists
     separately from the wildcard above because it's the one hostname
     Caddy deliberately serves over plain HTTP (see the
     `http://mail.{$MAIL_DOMAIN}` block in `caddy/Caddyfile`), so Mailu's
     own Let's Encrypt certificate renewal can complete. Cloudflare matches
     the more specific exact hostname over the wildcard automatically, so
     rule order doesn't matter. Skip it for now if you're deferring email
     setup - add it whenever you run `enable-email.ps1`.
4. **Add a cache rule** so Cloudflare doesn't try to cache streaming
   responses: Rules -> Cache Rules -> Create rule, matching each domain's
   subdomains, set to Bypass cache.
5. **If you're using Plex**, one more setting once it's deployed (step 5
   below): Plex Settings -> Network -> Custom server access URLs ->
   `https://plex.yourdomain.com:443`. This is what tells the Plex apps
   (phone, web, and every smart TV app) to connect directly through the
   tunnel instead of Plex's own relay network - the fix if you've had
   reliability problems with Plex's relay before.

**Want CrowdSec's Cloudflare bouncer set up too (optional - the thing
that can actually ban an attacker on this host, unlike Fail2Ban - see
SECURITY.md)?** This bouncer runs in what CrowdSec calls "Daemon Mode" -
the running container deploys its own Cloudflare Worker, KV namespace,
and Worker Routes on startup via the API token below, and tears them
down again on a clean stop. **You do not need CrowdSec's GitHub-based
"Self-Hosted Installer"** - that's a different, alternative setup path
for people who don't want to run a container for this at all; using
both would create two competing Worker deployments. The only manual,
one-time step in your own account is the token itself:

1. **Create a broader Cloudflare API token** - this is a *different*
   token from `CLOUDFLARE_API_TOKEN` above (that one is DNS-only; this
   one needs Workers KV/Scripts Edit, Turnstile Edit, Account
   Settings/Analytics Read, and Zone DNS/Workers Routes/Zone Read -
   [this pre-filled link](https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22workers_kv_storage%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22workers_scripts%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22turnstile%22%2C%22type%22%3A%22edit%22%7D%5D&name=CrowdSec+Cloudflare+bouncer)
   from CrowdSec's own docs sets most of these for you - review and add
   the Read-only ones before creating it). Keep it somewhere safe for a
   minute; `enable-crowdsec.ps1` asks for it once and doesn't store it
   anywhere itself.
2. Run `_scripts/enable-crowdsec.ps1` - it deploys the engine, mints the
   bouncer's own API key, generates the Cloudflare config from your
   token, and starts the bouncer, which then deploys the Worker/KV/
   Routes itself on its own first startup.
3. **After that first startup, switch the new Worker Route's Fail Mode
   to FAIL OPEN** (Cloudflare dashboard -> your zone -> Worker Routes ->
   the route the bouncer just created -> Edit) - can't be done ahead of
   time, since the route doesn't exist until step 2 creates it. Fail
   Closed (Cloudflare's default for a new route) means a Worker error or
   a plan quota overrun shows visitors an error page instead of your
   site; Fail Open lets traffic through to Caddy normally instead.

**One real tradeoff worth knowing before turning this on**: because the
bouncer deploys and tears down that Cloudflare-side infrastructure on
every start/stop, and Watchtower auto-updates this container like most
others in this repo, every auto-update causes a brief window (typically
seconds) where the Worker doesn't exist and that zone is unprotected by
it - not by design, just a consequence of how "Daemon Mode" manages its
own Cloudflare-side state. Caddy's own security headers/rate limiting
still apply underneath regardless, so this isn't a bare-exposure window,
just a temporary loss of this one extra layer.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for what to check if any of
this doesn't come up cleanly - a lot of it (real DNS, a real Cloudflare
account) can't be dry-run locally before your first real deployment.

## 2. Generate configuration

```powershell
cd _scripts
.\gui-installer.ps1
```

The wizard collects your domain, email, the two Cloudflare tokens from
step 1, whether to set up the email server now at all (unchecked by
default - see the note in step 1 above), an optional separate Mail Domain
if you do, ProtonVPN credentials, and Plex token, generates a unique
cryptographically-random secret for every database/service that needs one
(22 in total with email setup on, 20 without - including a shared Caddy
basic-auth login for Sonarr/Radarr/Prowlarr/Lidarr and one for Radicale,
always generated regardless - see TROUBLESHOOTING.md for why those two
needed adding), and writes a correct `.env` file into every stack
directory that's actually being set up.

It also writes `credentials-export.json` in the repo root - every login,
token, and internal database password it just generated or collected, in
Bitwarden's JSON export format, with every login's site URL included so it
autofills immediately (a shared login used across several subdomains,
like the Arr stack's, lists all of them). Import it as **Bitwarden**:
in Vaultwarden, Tools -> Import Data -> Bitwarden (json); in Proton Pass,
Settings -> Import -> Bitwarden -> select this file. **Not CSV** - Proton
Pass's Bitwarden importer only accepts JSON/ZIP, and its generic CSV
importer doesn't know what a `login_username`/`login_password` column
means, so a CSV import there silently drops every password (confirmed
live). Once imported and confirmed, **delete the file** - it's plaintext
and gitignored, but not something that should sit on disk longer than it
takes to import once.

The last step (review & write) also has a checkbox, **unchecked by
default**, to run steps 3-5 below (`setup-directories.ps1`, `deploy.ps1
-Action deploy`, `health-check.ps1`) itself right after writing the `.env`
files - Docker Desktop needs to already be running for that. Their output
prints to the PowerShell console the wizard was launched from, not the
wizard window itself. Leave it unchecked to review the generated `.env`
files first and run those three yourself instead.

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
- **Plex** (`plex.yourdomain.com`): the wizard's Plex Claim Token field is
  optional and normally left blank - `setup-directories.ps1` and
  `deploy.ps1` run as separate steps after the wizard finishes, so a token
  (4-minute lifetime) almost always expires before the Plex container
  actually starts. That's fine, not a failure: visit
  `http://<this-pc>:32400/web` and sign in with your Plex account there
  instead - Plex's own first-run setup will claim the server for you, no
  time pressure. Only bother with the wizard's token field if you can
  finish the wizard, `setup-directories.ps1`, and `deploy.ps1` all within
  about 4 minutes of generating it.
- **Portainer, Trilium, Focalboard, Jellyfin**: each sets its own admin
  account through its own first-visit web UI (no pre-set password to
  change) - do this for all four promptly after deploying, same reasoning
  as Wallabag below.
- **Wallabag**: ships with a fixed default login (`admin`/`wallabag`, not
  something only you know) - log in and change it immediately, this one's
  more urgent than the first-visit group above since the default is
  public knowledge, not just unset.
- **qBittorrent**: check `docker compose -f media-stack/docker-compose.yml
  logs gluetun` for the port ProtonVPN forwarded you, then update `BT_PORT`
  in `media-stack/.env` and redeploy that stack (`.\deploy.ps1 -Action
  restart -Stack media-stack`).
- **Unpackerr** (auto-extracts split RAR/zip downloads before Sonarr/
  Radarr/Lidarr import them - see `TROUBLESHOOTING.md` for how the whole
  pipeline fits together): needs `SONARR_API_KEY`, `RADARR_API_KEY`, and
  `LIDARR_API_KEY` in `media-stack/.env`, one from each app's own Settings
  -> General -> Security page. Only fill these in once those three apps
  have started at least once (they don't generate a key until first boot),
  then redeploy media-stack. `docker compose -f
  media-stack/docker-compose.yml logs unpackerr` should show all three
  apps connecting with `apikey:true` and no errors.
- **slskd + soularr** (Soulseek client, bridged to Lidarr's wanted list -
  for lossless/hi-res music that public torrent trackers rarely carry; see
  `TROUBLESHOOTING.md` for the full pipeline explanation): needs
  `SLSKD_SLSK_USERNAME`/`SLSKD_SLSK_PASSWORD` (your Soulseek network
  identity - picking a new username/password here registers it
  automatically, there's no separate signup), `SLSKD_USERNAME`/
  `SLSKD_PASSWORD` (slskd's own web UI login - change these from any
  placeholder immediately, same urgency as Wallabag above), and
  `SLSKD_API_KEY` (any 32-character random hex string) in
  `media-stack/.env`. Then copy `media-stack/soularr/config.ini.example`
  to `media-stack/soularr/config.ini` and fill in the same
  `LIDARR_API_KEY` and `SLSKD_API_KEY` values. slskd's web UI is at
  `slskd.yourdomain.com`; `docker compose -f media-stack/docker-compose.yml
  logs slskd` should show `Logged in to the Soulseek server as
  <your username>` within a few seconds of startup.
- **MusicBrainz Picard**: not part of this stack - it's a manual tagging
  tool, better run natively from [picard.musicbrainz.org](https://picard.musicbrainz.org)
  on your own PC pointed at your `MEDIA_MUSIC` folder than containerized,
  since you'd only reach for it occasionally rather than leaving it
  running.
- **Recyclarr** (syncs TRaSH Guides' Custom Formats and Quality Profiles
  into Sonarr/Radarr - see `TROUBLESHOOTING.md` for what this actually
  changes and a real gotcha it hit on first deploy): copy
  `media-stack/recyclarr/recyclarr.yml.example` to
  `media-stack/recyclarr/recyclarr.yml` and fill in the same
  `SONARR_API_KEY`/`RADARR_API_KEY` already in `media-stack/.env`. It
  syncs on its own schedule (`CRON_SCHEDULE` in `docker-compose.yml`,
  default once daily) once deployed, or force an immediate run with
  `docker compose -f media-stack/docker-compose.yml run --rm recyclarr
  sync`. This only adds new Quality Profiles ("HD Bluray + WEB", "UHD
  Bluray + WEB" in Radarr; "WEB-1080p", "WEB-2160p" in Sonarr) alongside
  whatever profiles you already had - it does not touch your existing
  profiles or reassign any movie/show away from the profile it's
  currently using. Set one of the new profiles as your default (Settings
  -> Profiles) and/or manually reassign existing library items if you
  want them to benefit from the new scoring too - that's a deliberate,
  not-yet-made call, not an oversight.
- **LazyLibrarian** (`lazylibrarian.yourdomain.com`) + **Calibre-Web-
  Automated** (`calibre.yourdomain.com`): book/ebook automation with
  IRC/XDCC as a download source (IRCHighway's `#ebooks`), auto-conversion,
  and Send-to-Kindle. Two first-run steps, both web-UI only (confirmed no
  env-var equivalent exists for either):
  1. **LazyLibrarian** - Config -> Search Providers -> enable IRC, server
     `irc.irchighway.net`, channel `#ebooks`. No login/credentials needed
     (anonymous IRC, same as using it manually) - this provider is a
     known intermittent one upstream (occasional join/connection drops),
     so don't be surprised if a search occasionally needs retrying. Set
     its download destination to LazyLibrarian's own `/downloads` (this
     is already the `BOOKS_INGEST_PATH` folder Calibre-Web-Automated
     watches - see TROUBLESHOOTING.md for why this has to be a folder
     separate from your actual library).
  2. **Calibre-Web-Automated** - ships with the documented Calibre-Web
     default login (`admin`/`admin123`) - change this immediately, same
     urgency as Wallabag above, since it's public knowledge not just
     unset. Then Admin -> Edit Mail Server Settings for SMTP (needed for
     Send-to-Kindle - Amazon also requires whitelisting whatever address
     you send from under your Amazon account's "Approved Personal
     Document E-mail List"), and each family member sets their own
     `@kindle.com` address under their own profile's "Send to eReader
     Email Address" field.
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
- **Family Guide** (`family.yourdomain.com`): a static, no-login page
  (`family-guide/index.html`, served directly by Caddy - see the
  `family.{$DOMAIN}` block in `caddy/Caddyfile`) with plain-language links
  and short how-tos for the household-facing apps only (Photos, Movies &
  Shows, Seerr requests, Music, Files, Books/Kindle, the AI assistant,
  Passwords, Email) - deliberately excludes every admin-only tool (Sonarr,
  Pi-hole, Portainer, etc). No setup needed beyond deploying the stack;
  visitors type in the family's domain once and it's remembered in their
  browser (`localStorage`) from then on. Nothing to configure through a
  web UI, unlike everything else in this section.
- **Immich** (`photos.yourdomain.com`): machine learning (facial
  recognition, smart search, duplicate detection, OCR) is on by default
  and needs no setup - `_scripts/detect-gpu.ps1` (run automatically by
  `deploy.ps1`) already points it at whatever GPU acceleration this host
  actually supports. Video transcoding hardware acceleration is a
  separate, less commonly available thing - see TROUBLESHOOTING.md if
  yours shows `cpu`/`disabled` and you expected otherwise. For OAuth
  login via Authentik (optional, but the only way to get one-tap mobile
  login instead of typing a password): create an OAuth2 Provider +
  Application in Authentik named "Immich" with all four redirect URIs -
  `https://photos.yourdomain.com/auth/login`,
  `https://photos.yourdomain.com/user-settings`,
  `app.immich:///oauth-callback`, and
  `https://photos.yourdomain.com/api/oauth/mobile-redirect` - then set
  `oauth.enabled: true` plus the issuer URL/client ID/secret in Immich's
  Admin -> Settings -> OAuth. See TROUBLESHOOTING.md for the exact
  provider settings that avoid the same two Authentik gotchas Homepage's
  setup hit, and for how to bring additional family members onto OAuth
  without splitting their existing account in two.
- **Open WebUI** (`chat.yourdomain.com`, `ai-stack`): local LLM chat,
  GPU-accelerated via vLLM's Level-Zero/XPU backend (see
  TROUBLESHOOTING.md for why this specific backend, not llama.cpp's
  Vulkan one). No pre-set login - the first account created through its
  own signup page becomes the admin account, same pattern as
  Portainer/Trilium/Focalboard/Jellyfin above. First boot downloads the
  default model (Qwen2.5-7B-Instruct-AWQ, ~5GB) then runs vLLM's
  `torch.compile` warmup (roughly a minute) before it can respond to
  anything, including its own healthcheck, so expect the stack to show
  unhealthy for several minutes right after first deploy - this is
  expected, not a failure. Change the model by editing the `vllm serve`
  arguments in `ai-stack/docker-compose.yml` - stay AWQ-quantized and
  check the VRAM math in TROUBLESHOOTING.md before sizing up, a 12GB card
  has less headroom than it looks like once vLLM's own overhead is
  accounted for.

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
