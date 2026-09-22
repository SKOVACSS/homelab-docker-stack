# Changelog

## 1.14.0 - Local LLM chat, GPU-accelerated via vLLM's Level-Zero/XPU backend (2026-09-22)

**Added a new `ai-stack`**: vLLM (Intel's official XPU-enabled image) +
Open WebUI as a self-hosted, GPU-accelerated local chat alternative to a
cloud LLM service, exposed at `chat.{$DOMAIN}`. Getting here took two
attempts, both verified empirically rather than assumed - the working
one first, then the dead end for the record:

- **What works**: vLLM's XPU backend uses Level-Zero/oneAPI - the same
  compute path (not Vulkan/VAAPI) that already gets Immich's OpenVINO
  machine learning working over `/dev/dxg` on this host. Confirmed by
  actually running inference, not just checking device detection:
  `torch.xpu.is_available()` returns `True`, the B580 shows up in
  `sycl-ls` as `[level_zero:gpu]`, and a real chat completion came back
  from the model running on it. Needs `/usr/lib/wsl:/usr/lib/wsl`
  mounted alongside `/dev/dxg` (Microsoft's WSL2 D3D12 paravirtualization
  libs Level-Zero depends on) - same mount Immich's
  `openvino-wsl-dxgonly` hwaccel profile already uses, see
  `immich-app/hwaccel.ml.yml`. Ships with Qwen2.5-7B-Instruct-AWQ
  (~5GB), sized to leave comfortable VRAM headroom for an 8192-token
  context on the B580's 12GB - a 14B AWQ model was tried first and its
  ~9.4GB of weights alone left only 0.15GB free for KV cache, not enough
  to serve even one request, confirmed by actually hitting that error
  rather than estimating it up front.
- **What doesn't work**: the original plan was llama.cpp's `server-vulkan`
  image, on the theory that Mesa's WSL2 `dzn` driver would translate
  Vulkan to D3D12 over the same `/dev/dxg` device. It doesn't - confirmed
  directly inside the container (`dpkg -L mesa-vulkan-drivers`) that
  Ubuntu's Mesa package doesn't build the `dzn` ICD at all, not a
  configuration gap, a missing driver. `server-intel` (SYCL) was already
  ruled out earlier for needing `/dev/dri`, which this host doesn't
  expose to containers either. Full writeup in TROUBLESHOOTING.md, kept
  for the record since it's the kind of thing that looks plausible from
  documentation alone and only breaks on contact with the actual host.

Also looked into whether Docker Desktop's new **Docker VMM** backend
(public beta as of Docker Desktop v4.86, GA targeted end of October
2026) would do any better here. It doesn't help today: Docker's own GPU
support docs still say hardware acceleration is WSL2-backend-only, Docker
VMM's own docs don't mention GPU passthrough at all, and no one's
reported testing it yet either way - worth revisiting after GA, not
something to switch to now. See TROUBLESHOOTING.md.

## 1.13.0 - Automated ebook acquisition and Kindle delivery (2026-09-22)

**Added LazyLibrarian + Calibre-Web-Automated**, automating a workflow
the user was previously doing by hand: finding and downloading ebooks via
IRCHighway's `#ebooks` channel, then getting them onto Kindle devices.
LazyLibrarian is the maintained Readarr replacement this repo already
pointed at (see the 1.0 removal note) and its standout feature here is a
native IRC/XDCC download provider - no other *arr-family app has this,
since IRC (not torrents) is the primary ebook source in that community.
Calibre-Web-Automated watches the same folder LazyLibrarian downloads
into, auto-converts to Kindle-friendly formats, and can email new books
straight to a `@kindle.com` address (Amazon's own free delivery method) -
both apps' setup (IRC provider, SMTP, per-user Kindle addresses) is
web-UI only in both cases, no env-var equivalent exists for either.

Found and preserved an existing Calibre library at deploy time - it
lives nested inside `MEDIA_BOOKS/CalibreLibrary`, not at `MEDIA_BOOKS`
directly, alongside some unrelated loose files. Mounting `MEDIA_BOOKS`
itself into Calibre-Web-Automated's library volume would have made it
unable to find the existing `metadata.db` and likely created a second,
conflicting library - added a dedicated `CALIBRE_LIBRARY_PATH` pointed
at the actual library folder instead, confirmed live via CWA's own
"Existing library found... mounting now" log line rather than assumed.

## 1.12.0 - Immich OAuth via Authentik, GPU/ML verification (2026-09-22)

**Verified GPU hardware acceleration end-to-end** rather than assuming
`_scripts/detect-gpu.ps1`'s automation (added in an earlier pass) was
still correct and actually applied live. It was: `TRANSCODE_HWACCEL=cpu`
and `ML_HWACCEL=openvino-wsl-dxgonly` are both live and correct for this
host's real hardware situation - Docker Desktop's WSL2 backend exposes
`/dev/dxg` but not `/dev/dri` here, so ffmpeg-based video transcoding
(Immich, Plex, Jellyfin) genuinely cannot be hardware-accelerated no
matter the config, while Immich's OpenVINO-based machine learning can
and does run accelerated against `/dev/dxg` alone. Confirmed all four ML
features (facial recognition, smart search, duplicate detection, OCR)
are enabled and pointed at the accelerated ML service - see
TROUBLESHOOTING.md for the full hardware explanation.

**Replaced Immich's OAuth login.** It was configured but pointed at a
now-deleted Cloudflare Access app and left disabled the whole time.
Set up a proper Authentik OAuth2Provider instead (all four required
redirect URIs registered, covering web + iOS + Android + the mobile
fallback bridge), applying the grant_types/signing_key/property_mappings
fixes from the earlier Homepage OIDC work up front this time instead of
hitting the same bugs again. Created Authentik accounts for four family
members with emails matching their existing Immich accounts, so their
first OAuth login links to their existing photos instead of creating a
duplicate account - confirmed this linking behavior directly from
Immich's own source, since its docs don't cover it. Password login
remains available for everyone as a fallback.

## 1.11.0 - Tuned Sonarr/Radarr's automated search and release selection (2026-09-22)

**PreToMe is now indexer priority 1 (highest)** in Prowlarr, synced through
to both Sonarr and Radarr - it's a private tracker and the preferred first
option over the public trackers added in 1.10.0, which are now spread
across priority 30-45 instead of all sitting at the same default (25).

**Removed two dead legacy indexers.** Sonarr's "Torrent RSS Feed" and
Radarr's "PreToMe RSS Feed" both pre-dated Prowlarr entirely - hand-
configured `TorrentRssIndexer` entries pointed directly at PreToMe's RSS
URL, with `supportsSearch: false` (RSS-only, no active/interactive
search). Fully superseded by the new Prowlarr-managed PreToMe indexer,
which supports both RSS and full search - the old ones were pure
duplication at this point, so they're gone rather than left as clutter.

**Added Recyclarr**, which syncs TRaSH Guides' community-maintained
Custom Formats and Quality Profiles into Sonarr/Radarr on a schedule.
This is the actual "improve automated search and selection" piece:
before this, a search just grabbed whatever came back; now releases are
scored - cam/telesync/upscaled/fake releases are rejected outright,
well-regarded release groups and correct HDR/audio handling are
preferred. Added new profiles ("HD Bluray + WEB"/"UHD Bluray + WEB" in
Radarr, "WEB-1080p"/"WEB-2160p" in Sonarr) alongside the existing ones,
deliberately not reassigning any existing library item or changing
either app's default profile - that's left as your call.

Hit one real bug getting Recyclarr working: syncing more than one
instance definition that shares the same `base_url` silently skips all
of them (no error, exit code 0) - not obvious from the individual
per-profile template files each app ships, which each define their own
separate top-level instance. Fixed by consolidating each app's HD and
UHD profiles into one instance definition with two `quality_profiles`
entries, per Recyclarr's own documented pattern for this. Documented in
TROUBLESHOOTING.md along with the reasoning for why the two profiles per
app were combined this way.

## 1.10.0 - Added indexers, FlareSolverr, and a Soulseek pipeline for Lidarr (2026-09-22)

**Prowlarr now has real indexers.** It shipped with only book/archive
trackers (EBookBay, Internet Archive, PreToMe) configured - nothing for
movies/TV. Added 1337x, YTS, EZTV, LimeTorrents, The Pirate Bay, and
Torrent Downloads, all public, no credentials needed. Three of them
(1337x, EZTV, and a Kickass Torrents mirror) sit behind Cloudflare's bot
challenge and failed Prowlarr's own connectivity test with "blocked by
CloudFlare Protection" until FlareSolverr (a headless-browser proxy that
solves the challenge on Prowlarr's behalf) was added and tagged onto just
those three indexers - untagged indexers bypass it entirely, so this adds
no overhead to the trackers that didn't need it. The Kickass mirror still
fails even through FlareSolverr (a 403 from that specific mirror, not a
Cloudflare block) - left disabled pending a working mirror URL.

**Added slskd + soularr for lossless/hi-res music.** Public torrent
trackers are a poor source for FLAC/hi-res releases; Soulseek is not.
slskd is a headless Soulseek client with a REST API, routed through
gluetun exactly like qBittorrent (Soulseek is P2P - every peer you
transfer with sees your IP unless it's tunneled). soularr watches
Lidarr's wanted/missing list, searches Soulseek via slskd for each one,
and lets Lidarr import the result - the same role Completed Download
Handling plays for qBittorrent, just for a source Lidarr has no native
concept of. Its default format preference already favors FLAC over mp3.
slskd's web UI is reachable at `slskd.{$DOMAIN}` for manual searches; it
has its own built-in login, so - like every arr app - no extra Caddy
`basic_auth` layer was added on top of it.

**MusicBrainz Picard** (manual tag/metadata cleanup) was deliberately
*not* containerized - recommended to run natively on a desktop instead,
since it's an occasional hands-on tool rather than an always-on service.

## 1.9.0 - Auto-extract archives before Sonarr/Radarr/Lidarr import (2026-09-22)

**Added Unpackerr to media-stack.** Sonarr, Radarr, and Lidarr already
import a finished qBittorrent download automatically via their own
Completed Download Handling - that part needed no changes. What none of
them can do is extract an archive: a torrent that ships as a multi-part
RAR (or zip) just sits there "complete" but unimportable, since there's
no video/audio file for the *arr app to recognize yet. Unpackerr closes
that gap - it polls each app's queue API, and once qBittorrent reports an
item fully downloaded (which, for a split RAR, means every `.rNN` volume
has already arrived and hash-checked - qBittorrent never reports a
torrent "complete" on a partial set), Unpackerr extracts any archive it
finds at that item's download path. The *arr app's existing import scan
then picks up the extracted file on its normal polling interval, exactly
like any other completed download. No new "transfer" logic was needed -
extraction was the only missing step.

Needs one API key per app (`SONARR_API_KEY`, `RADARR_API_KEY`,
`LIDARR_API_KEY` in `media-stack/.env`) - see `SETUP.md`. `DELETE_ORIG` is
left at its default (off) deliberately: this stack downloads over
BitTorrent, and deleting the source archive right after extraction would
corrupt an in-progress seed.

## 1.8.0 - Homepage SSO via Authentik, and a systemic secret-generation bug (2026-09-22)

Two unrelated fixes bundled together since both surfaced in the same
session while restoring a backup-migrated deployment.

**Homepage now requires login, via Authentik SSO.** It had no
authentication of its own configured - anyone reaching `home.{$DOMAIN}`
saw a full directory of every service in this stack with zero
credentials. Homepage supports OIDC login natively (since v2.0), and
since this repo already runs Authentik, that's a real supported
integration rather than another bolted-on Caddy `basic_auth` layer.
`dashboard/docker-compose.yml` now sets `HOMEPAGE_AUTH_ENABLED`,
`HOMEPAGE_OIDC_ISSUER`/`CLIENT_ID`/`CLIENT_SECRET` pointing at an OAuth2
Provider + Application created in Authentik (name/slug `homepage`,
redirect URI `https://home.{$DOMAIN}/api/auth/callback/homepage-oidc`).

**`Generate-SecurePassword`'s charset included a literal `$`** -
`!@#$%^&*` - used for every general secret this repo generates (roughly
19-21 per deployment). Docker Compose's own `${VAR}` `.env` interpolation
treats a bare `$` as the start of a variable reference: a password like
`...UMe$nJGLkNnrR` silently truncates to `...UMe` wherever it's actually
read, since `$nJGLkNnrR` doesn't match any real variable. Statistically,
about a third of all generated secrets in any given deployment hit this
- confirmed live as the actual cause of a completely broken Authentik
bootstrap admin login (the credential the wizard told you to use never
matched what the container actually received). Audited every live
`.env` afterward and found five more secrets silently truncated the same
way, most self-consistent (an app and its own database both reading the
identical truncated value, so nothing outwardly broke - just weaker than
the intended length) but still worth fixing. Removed `$` from the
charset entirely - simpler and more robust than doubling it at every
call site that writes one of these into a `.env` file, which is an easy
step to forget (see `caddy/Caddyfile`'s bcrypt hashes, which already
need exactly that and are the one place it's unavoidable, since bcrypt's
own hash format contains `$` regardless of the input password).

## 1.7.4 - Fix Gotify's login username and Paperless's CSRF rejection (2026-09-22)

Two more restored-backup/first-deploy gaps found and fixed the same way
as everything else this session - confirmed live, not assumed.

**Gotify**: `GOTIFY_DEFAULTUSER_USER` is not a real Gotify config key
(silently ignored) - the actual login name only ever comes from
`GOTIFY_DEFAULTUSER_NAME`, which `notification-stack/docker-compose.yml`
had hardcoded to `Administrator` regardless of `GOTIFY_ADMIN_USER`'s
value. The password was always correct; only the username the
credentials export told you to use (`admin`) never matched what Gotify
actually created on first boot. Fixed the compose file for future
deployments (`GOTIFY_DEFAULTUSER_NAME=${GOTIFY_ADMIN_USER}`) - an
already-existing account needs renaming via the API or web UI instead,
since this env var only applies on first-ever startup against an empty
database.

**Paperless-ngx**: had no `PAPERLESS_URL` set, which Django (Paperless's
framework) needs to correctly derive `CSRF_TRUSTED_ORIGINS`/
`ALLOWED_HOSTS` behind a reverse proxy. Without it, every login attempt
failed with "CSRF verification failed" even though the login page itself
loaded fine - Django trusted the page load but not the POST arriving via
Caddy on this domain. Added `PAPERLESS_URL=https://papers.${DOMAIN}` to
`privacy-stack/docker-compose.yml`.

## 1.7.3 - Drop redundant Caddy logins from Sonarr/Radarr/Prowlarr/Lidarr/qBittorrent (2026-09-22)

These five apps were each gated by two separate logins: a Caddy-level
basic-auth (arr_auth/qbit_auth) plus the app's own. Checked live and
confirmed all five already had a real, mandatory login of their own
(Sonarr/Radarr/Prowlarr/Lidarr: `AuthenticationMethod=Forms`,
`AuthenticationRequired=Enabled`, not the "disabled for local addresses"
default this repo's comments had assumed; qBittorrent: its own WebUI
login, independently confirmed working in 1.7.2) - meaning Caddy's copy
added no real protection, just a second credential to remember, and HTTP
Basic's browser-native prompt doesn't autofill from a password manager
the way an app's own HTML login form does.

Removed the `arr_auth`/`qbit_auth` basic_auth snippets and their
`import` lines from `caddy/Caddyfile` entirely - each of these five apps
now has exactly one login: its own, matching every other app in this
stack. `ARR_AUTH_USER`/`ARR_AUTH_HASH`/`QBIT_AUTH_USER`/`QBIT_AUTH_HASH`
are gone from `.env.example`, `caddy/docker-compose.yml`, and
`gui-installer.ps1` (which also no longer generates those two
passwords - down to 19/21 secrets from 21/23). The credentials export
now points to each app's own first-run login screen instead, same
pattern already used for Portainer/Trilium/Focalboard/Jellyfin.

Radicale (the calendar) keeps its Caddy-level login unchanged - its own
auth is deliberately disabled entirely (`RADICALE_AUTH_TYPE=none`), so
Caddy is genuinely its only gate, not a redundant second one. Also
rotated `RADICALE_AUTH_HASH` live: the previously-rotated password from
earlier in this same session was never actually recorded anywhere
retrievable, so the login "provided at install" didn't work - same
"generate fresh, verify live, hand over the new value" fix used
throughout tonight for qBittorrent.

Confirmed live end-to-end for all five apps: each shows its own
login/redirects to its own `/login` with zero credentials sent, no Caddy
challenge appears, and a correct app-native login succeeds and grants
access to an authenticated session.

## 1.7.2 - Fix qBittorrent self-banning on every single request through Caddy (2026-09-22)

Root-caused the long-standing "Your IP address has been banned after too
many failed authentication attempts" error on qbit.stevenks.com, which
earlier investigation this same day had (incorrectly) suspected was
Cloudflare's WAF or edge rate limiting.

The real cause: `caddy/Caddyfile`'s `qbit.{$DOMAIN}` block validates the
`qbit_auth` basic_auth header (Caddy's own credential, gating the proxy
from the internet) and then - unlike you'd expect - Caddy's
`reverse_proxy` forwards that same `Authorization` header upstream by
default. qBittorrent's own WebUI sees it and tries to use it as a login
attempt against *its own separate* password, which can never match
(it's Caddy's credential, not qBittorrent's) - counting as a failed
login. This happened on literally every request that reached
qBittorrent through Caddy, so its own "ban IP after N failed logins"
feature was guaranteed to eventually ban whatever address Caddy's
reverse_proxy connects from - which every real user shares, since they
all arrive via Caddy. Once banned, ALL further requests were rejected
regardless of correct credentials at any layer, until the ban expired.

Confirmed by reproducing the exact "banned" response on demand (curling
qBittorrent directly with a fabricated `Authorization` header) and then
reproducing a clean login by removing it. Fixed by adding
`header_up -Authorization` to the `qbit.{$DOMAIN}` `reverse_proxy` block,
so qBittorrent never sees Caddy's own credential and relies purely on
its own cookie-based session. Also raised qBittorrent's own
`web_ui_max_auth_fail_count` (5 -> 50) and lowered
`web_ui_ban_duration` (3600s -> 300s) as defense-in-depth, so a genuine
run of bad logins is more forgiving and self-clears faster.

## 1.7.1 - Fix Caddy's rate limit throttling normal Sonarr/Radarr/Prowlarr/Lidarr usage (2026-09-22)

`caddy/Caddyfile`'s shared `rate_limit` snippet allowed only 30
requests/minute per client on every arr app plus qBittorrent and Seerr.
That sounds generous until you remember these are SPA dashboards:
Sonarr/Radarr/Prowlarr/Lidarr each fire 15-30+ API calls just loading
their status page, and qBittorrent/Seerr poll every few seconds for live
queue/activity updates. Confirmed live via Caddy's own logs
(`"msg":"rate limit exceeded","zone":"sonarr_zone"`) that normal
single-user browsing tripped this within seconds of opening a tab -
surfacing to the user as Sonarr's "Failed to load system status from
API", indistinguishable from the app actually being down. This is likely
what "these apps keep becoming inaccessible" was actually describing,
more than a one-off.

Also worth noting: `order rate_limit after basic_auth` (set globally,
above the snippet) means this limiter runs *after* login is already
checked, so it was never actually providing brute-force protection
either - a wrong password gets rejected by `basic_auth` before ever
reaching the rate counter. It's pure defense-in-depth against abuse, not
an auth guard.

Raised the shared zone to 600 events/minute - well above realistic
dashboard-polling volume while still bounding runaway abuse. Confirmed
live via Caddy's admin API (`/config/`) that every zone (`sonarr_zone`,
`radarr_zone`, `prowlarr_zone`, `lidarr_zone`, `qbit_zone`,
`requests_zone`) picked up `max_events: 600` after a `caddy reload`.

## 1.7.0 - Automatic, vendor-agnostic GPU hardware acceleration (2026-09-21)

Generalizes 1.6.9's manual Intel Arc GPU wiring into something that works
unattended for NVIDIA, AMD, or Intel, with no GPU at all being just as
safe. New `_scripts/detect-gpu.ps1`, run automatically by `deploy.ps1`
before every deploy:

- Tests what's actually *usable* rather than trusting what's merely
  *present* - a real `docker run --gpus all` probe for NVIDIA, and
  mounting `/dev/dri`/`/dev/dxg`/`/dev/kfd` into a throwaway container to
  see whether the host path even exists, rather than guessing from
  platform/vendor alone. This distinction is real: confirmed live that
  `/dev/dri` doesn't exist on Docker Desktop's WSL2 backend even with a
  present, working, up-to-date GPU and driver.
- Picks the right profile per app from three new/extended compose files -
  `immich-app/hwaccel.ml.yml` (extended with an `openvino-wsl-dxgonly`
  profile, this repo's own addition, for hosts with `/dev/dxg` but no
  `/dev/dri`), `immich-app/hwaccel.transcoding.yml` (upstream Immich,
  unchanged in substance, comments added), and a new
  `media-stack/hwaccel.transcoding.yml` shared by Plex and Jellyfin,
  modeled on Immich's own file.
- `immich-app/docker-compose.yml` and `media-stack/docker-compose.yml`
  now select a profile via Docker Compose's `extends:` (confirmed
  variable interpolation works in `extends.service` before committing to
  this design) instead of a hardcoded device list - `immich-server`,
  `immich-machine-learning`, `plex`, and `jellyfin` all default to `cpu`
  (software, empty profile) if `.env` doesn't set anything, so this is
  safe on a host with no GPU or with detection disabled/failed.
- Immich's machine learning additionally needs a different *image* per
  backend (`-openvino`, `-cuda`, `-rocm` - each accelerator is a separate
  build, unlike transcoding which shares one ffmpeg for every backend) -
  `ML_IMAGE_SUFFIX` handles that half separately from `ML_HWACCEL`'s
  device/volume selection.

Video transcoding hardware acceleration remains unavailable on Docker
Desktop's WSL2 backend for now regardless of GPU vendor (`/dev/dri`
doesn't exist there yet) - `detect-gpu.ps1` correctly falls back to `cpu`
for it rather than picking a profile that would fail to start. Immich's
own ML acceleration doesn't have this limitation (OpenVINO/CUDA/ROCm work
through `/dev/dxg` or `/dev/dri` directly, not through ffmpeg's VAAPI
code path), so that part *does* get GPU acceleration on WSL2 today.

## 1.6.9 - Fix silently-broken basic-auth hashes, add qBittorrent a real login, wire up Intel Arc GPU (2026-09-21)

Three fixes found while setting up Plex/Immich remote access and Intel Arc
B580 GPU passthrough:

**`arr_auth`/`radicale_auth` were unauthenticatable with ANY password, since
this repo started using them.** `gui-installer.ps1` escaped literal `$`
characters in bcrypt hashes (needed so docker compose's own `${VAR}`
interpolation doesn't misread part of the hash as a variable reference)
via `-replace '\$', '$$'`. That looks right but is a no-op: PowerShell's
`-replace` runs its replacement argument through .NET regex substitution
syntax, where `$$` is the *escape sequence* for a single literal `$` - so
the hash came out un-doubled every time, and docker compose then silently
deleted a chunk of every hash it interpolated (`$2a$14$IjrAc...` -> treated
`IjrAc...` as a variable name, found it unset, substituted empty string).
Confirmed live: the container's actual `ARR_AUTH_HASH` was missing a whole
segment compared to the `.env` file. Fixed by switching to the literal
`.Replace()` string method (no substitution-pattern semantics). Rotated
the live Sonarr/Radarr/Prowlarr/Lidarr and Radicale passwords since the
old ones were never actually valid credentials to begin with.

**qBittorrent had no stable login at all.** Unlike every other admin UI in
this repo, `qbit.{$DOMAIN}` had no Caddy `basic_auth` in front of it -
its only protection was qBittorrent's own WebUI login, which was never
set to anything permanent (hotio's image generates a random temporary
password every container start, logged but never surfaced anywhere
lasting). Added a dedicated `qbit_auth` Caddy snippet (a separate
credential from `arr_auth` on purpose - qBittorrent controls what gets
downloaded, a worse outcome if leaked than reaching the Arr apps) and
wired its generation/export into `gui-installer.ps1` the same way
`arr_auth`/`radicale_auth` already work.

**Intel Arc B580 (or any GPU) needs `/dev/dxg`, not `/dev/dri`, on Docker
Desktop's WSL2 backend - and `/dev/dri` doesn't exist there at all.**
Confirmed live: `/dev/dri` is absent both inside Docker Desktop's own WSL
VM and inside a full Ubuntu WSL distro with systemd-udevd running, on a
current WSL2 kernel (6.6.87.2) with an up-to-date Arc driver - this is a
WSL2 platform limitation, not a driver or config problem. Consequences:
- `immich-machine-learning` now runs the `-openvino` image variant with
  `/dev/dxg` passed through - confirmed working via a real
  `onnxruntime.InferenceSession` against `OpenVINOExecutionProvider`
  device_type=GPU. Face detection/CLIP smart search now use the GPU.
- Video transcoding (Immich, and by extension Plex/Jellyfin) can NOT use
  the Arc GPU right now: ffmpeg's VAAPI backend hard-requires a
  `/dev/dri` render node to initialize even with `LIBVA_DRIVER_NAME=d3d12`
  set - confirmed by an actual failed hwaccel init
  ("No available render device for DRM render node"). Immich's
  `ffmpeg.accel` was left set to `vaapi` from a stale prior config with no
  working device behind it, which would have failed every video transcode
  job going forward - set to `disabled` (software encode) until Microsoft
  exposes `/dev/dri` for WSL2 GPU passthrough.

## 1.6.8 - Switch credentials export from CSV to Bitwarden JSON (2026-09-21)

Found live: importing `credentials-export.csv` into Proton Pass via its
"Bitwarden" import option isn't possible at all - that path only accepts
Bitwarden's JSON/ZIP export, not CSV. Importing the same file as a
*generic* CSV instead brought every item's name in, but silently dropped
every username and password, since a generic importer has no built-in
knowledge that `login_username`/`login_password` columns mean anything.

Switched `gui-installer.ps1`'s `Export-Credentials` to write
`credentials-export.json` in Bitwarden's actual JSON export schema
instead of CSV - Vaultwarden's Bitwarden (json) importer accepts this
natively, and it's the only Bitwarden-labeled path Proton Pass supports
at all. Also fixed a real bug hit while building this: PowerShell's
`if/else` statement unwraps a single-element array result down to its
bare element during assignment (`$x = if(cond){@()}else{@(one item)}`
left `$x` as a plain Hashtable, not an array), which made a login's
`uris` field serialize as a JSON object instead of a one-element array -
silently invalid against Bitwarden's schema. Fixed by building `uris`
with an `ArrayList` instead, which isn't subject to that unwrapping.

Also extended `New-CredRow` to accept multiple URLs per entry, and used
it for the shared Sonarr/Radarr/Prowlarr/Lidarr login so it now autofills
on all four sites instead of just Sonarr's.

Confirmed live: reproduced the CSV import silently dropping credentials
in Proton Pass first, then verified the new JSON's schema by round-
tripping it back through `ConvertFrom-Json` and checking every item's
`uris` field is a real array, and drove the wizard through all 5 steps
to confirm the real generated file has correct multi-URL entries and
every password intact.

## 1.6.7 - Fix nine more broken healthchecks found by an actual full deploy (2026-09-21)

After fixing gluetun's healthcheck (1.6.5), audited every other container
reporting "unhealthy" across a real, fully-deployed homelab instead of
assuming they were fine. Found the same underlying pattern repeatedly:
a healthcheck written against an assumption about the image (it has
curl/wget, `localhost` means what you think, the file is where you'd
guess) that didn't hold for the actual pinned image version. None of
these were caught by `docker compose config` or CI, which can't run a
container to find out - only an actual deploy surfaces them:

- **authentik-server**: image doesn't ship `wget`. Switched to
  authentik's own `/lifecycle/ak healthcheck` subcommand.
- **caddy**: `/health` doesn't exist on Caddy's admin API (404) - `/config/`
  does, but echoes back the *entire live config including the Cloudflare
  API token and every basic-auth hash*. Fixed to hit `/config/` with
  `-o /dev/null` so curl never prints that body anywhere (including into
  Docker's own healthcheck log) - confirmed by deliberately fetching it
  once to find the right endpoint, then locking down how it's checked
  from then on. Also fixed to use the correct endpoint after the fact.
  (If a Cloudflare token you use with this repo may have been printed to
  an untrusted console/log while diagnosing this, rotate it as a
  precaution.)
- **nextcloud-db**: `mysqladmin` doesn't exist in this MariaDB image
  (renamed/removed upstream). Switched to the image's own bundled
  `healthcheck.sh --connect`.
- **trilium**: image doesn't ship `curl`, and `localhost` resolves to
  `::1` in the container while Trilium only binds `0.0.0.0` (IPv4) -
  "Connection refused" forever. Switched to `wget` against `127.0.0.1`.
- **prometheus**: image doesn't ship `curl`. Switched to `wget` (bundled)
  against `127.0.0.1` (same IPv6 trap as trilium, avoided pre-emptively).
- **wireguard**: healthcheck checked `/config/wg0.conf`, but this image
  actually writes it to `/config/wg_confs/wg0.conf` - the checked path
  never existed. Fixed the path.
- **focalboard, portainer, loki**: none of these three images ship a
  shell, curl, wget, *or* busybox - there is no executable left inside
  them capable of running any Docker healthcheck at all. Disabled their
  healthchecks explicitly rather than leave a check that can only ever
  fail; Docker's own "is the container running" state is the only signal
  actually available for these three.

Every fix was confirmed live: reproduced the original failure inside the
running container first, then confirmed the replacement command actually
exits 0 before touching the compose file, then redeployed each affected
service and confirmed it reports `healthy` (or cleanly `Up` for the three
that no longer have a check at all).

## 1.6.6 - Document the stale-database-password gotcha (2026-09-21)

Hit live: `immich_server` crash-looped with `password authentication
failed for user "postgres"` right after a fresh deploy. Root cause
wasn't a bug in this repo - `immich-app/postgres`'s data directory
already existed from a much older test of this repo (dated back to
2025), so Postgres kept whatever password it was actually initialized
with back then. `gui-installer.ps1` generates a brand new random
`DB_PASSWORD` every time it runs, and that value only takes effect on a
genuinely empty data directory - on an already-initialized one, it's
silently ignored, so the newly-generated password never matches what the
database actually has.

Fixed the immediate case with `ALTER USER postgres PASSWORD '...'`
against the running container - no data lost, no redeploy needed - and
documented the general pattern in TROUBLESHOOTING.md, since it applies
to every Postgres/MariaDB-backed service in this repo (`authentik`,
`immich-app`, and privacy-stack's Nextcloud/Paperless/Wallabag
databases), not just Immich.

## 1.6.5 - Fix gluetun's healthcheck reporting false "unhealthy" (2026-09-21)

Found immediately after fixing 1.6.4's crash-loop and getting gluetun
actually connected: it stayed reported as "unhealthy" even with a
confirmed working tunnel (real ProtonVPN IP, port forwarding active,
`Initialization Sequence Completed` in the logs). The healthcheck
(`curl -f http://localhost:8000/v1/openvpn/status`) was the problem, not
the VPN - `qmcgaw/gluetun:v3.41.3` doesn't ship `curl` at all, confirmed
via `docker exec gluetun curl ...` failing with "executable file not
found in $PATH". Every healthcheck attempt was failing before it could
even reach the URL.

Replaced it with gluetun's own dedicated healthcheck command,
`/gluetun-entrypoint healthcheck`, which doesn't depend on whichever
HTTP client happens to be bundled in a given image version. Confirmed
live: gluetun now correctly reports `healthy`.

## 1.6.4 - Fix gluetun crash-looping on a wizard-generated media-stack/.env (2026-09-21)

Found by actually deploying the stack for the first time, not by static
validation (`docker compose config` can't catch either of these - both
are runtime checks inside the gluetun binary itself):

1. `gui-installer.ps1` wrote literal placeholder text
   (`your-wireguard-private-key`, `your-wireguard-addresses`) into
   `PROTON_WIREGUARD_KEY`/`PROTON_WIREGUARD_ADDRESSES` even though the
   wizard always sets `VPN_TYPE=openvpn` and has no fields to actually
   collect WireGuard credentials. gluetun tries to parse
   `WIREGUARD_ADDRESSES` as an IP whenever it's non-empty regardless of
   `VPN_TYPE`, so the placeholder crashed it on every startup. `.env.example`
   already had this right (genuinely blank) - only the wizard's generated
   output had the bug. Fixed to write both blank, matching `.env.example`.
2. The wizard's VPN Country dropdown offered ISO codes (`US`, `UK`, `CA`,
   ...), but gluetun's ProtonVPN provider validates `SERVER_COUNTRIES`
   against full country names (`United States`, `United Kingdom`, ...) -
   a code fails with "the country specified is not valid". Fixed the
   dropdown to use full names.

Both were live-reproduced against a real deploy and confirmed fixed
(gluetun connected, got a ProtonVPN IP, and forwarded a port) before
being documented in TROUBLESHOOTING.md for anyone who already has a
`.env` written by the old, buggy version of the wizard.

## 1.6.3 - Let the wizard deploy and health-check itself (2026-09-21)

Added an unchecked-by-default checkbox to the wizard's final step:
"Also run setup-directories.ps1, deploy.ps1, and health-check.ps1 now".
Previously the wizard only ever wrote `.env` files and told you to run
those three commands yourself.

Left unchecked, nothing changes. Checked, after writing the `.env` files
it also creates the host directories, deploys every configured stack in
order, waits 20 seconds for slower-starting containers (database
init, first-run migrations) to settle, then runs a health check - all
three via a direct call to the real scripts, so their own output (color-
coded progress, per-stack status) prints to the console the wizard was
launched from exactly as if you'd run them by hand. A failed deploy is
reported without running the health check or claiming success, and
points at the console for which stack failed.

Left unchecked deliberately: this runs real, consequential actions
(pulls/builds Docker images, starts every stack with real credentials),
so it stays opt-in the same way the email-server checkbox is, rather
than happening automatically just because you clicked "Create .env
Files".

## 1.6.2 - Make the Plex Claim Token field optional (2026-09-21)

The wizard's step 3 required a Plex claim token before letting you
continue, but `plex.tv/claim` tokens expire in 4 minutes while
`setup-directories.ps1` and `deploy.ps1` (which builds a custom Caddy
image on first run) both happen as separate steps after the wizard
finishes - by the time the Plex container actually starts, the token
was almost always already dead on arrival. An expired/missing
`PLEX_CLAIM` doesn't error, it just leaves Plex unclaimed, which you fix
by signing in at `http://<host>:32400/web` afterward - no time pressure.

Made the field genuinely optional (no longer required to proceed), reworded
the wizard's warning text and step 5 review summary to explain the
manual-claim path as the normal route rather than a fallback, and
documented the timing issue and manual-claim instructions in SETUP.md
and TROUBLESHOOTING.md.

## 1.6.1 - Fix gui-installer.ps1 scoping bugs (2026-09-21)

Two related PowerShell/WinForms scoping bugs, found only once someone
actually clicked through the wizard for the first time (neither was
caught by static analysis or CI, which can't drive a real GUI):

1. Every button's event handler referenced controls from its enclosing
   `Show-StepN` function's local scope via a plain `{}` scriptblock.
   PowerShell resolves those references through the *live* scope chain at
   the moment the event fires, not at definition time - since `Show-StepN`
   returns immediately after wiring up its screen (well before
   `$form.ShowDialog()` starts listening for clicks), every field read
   back as `$null` the instant you clicked anything.
2. The first fix for that (`.GetNewClosure()` on each handler) solved it,
   but `GetNewClosure()` turns out to also mishandle explicitly
   scope-qualified variables like `$script:data` - it silently rebinds
   them to `$null` inside the closure instead of deferring to the real
   script-scope lookup, breaking `$script:data`/`$script:step` the moment
   the previous bug was fixed.

Replaced `GetNewClosure()` entirely: every control read from inside a
handler (plus `$form` itself) is now `$script:`-scoped instead, the same
mechanism `$script:data`/`$script:step` already relied on successfully
throughout this file. Verified by driving the real wizard programmatically
through all 5 steps end-to-end rather than just parsing it.

## 1.6.0 - Make the email server optional and deferrable (2026-09-21)

Mailu is by far the most complex, fragile stack in this repo - see the
1.0.9, 1.2.2, and 1.5.0 entries above for the real bugs found in it over
time. Not everyone using `gui-installer.ps1` to set up a homelab (new
hardware later, or helping someone else set theirs up) will want to take
that on, and until now the wizard always generated Mailu secrets and
wrote `email-stack\.env` regardless.

Added a "Set up email server (Mailu) now" checkbox to the wizard's first
step, **unchecked by default**. Leaving it unchecked:
- Skips generating `MailuSecretKey`/`MailAdminPassword` (20 secrets total
  instead of 22)
- Writes no `email-stack\.env` at all - the stack stays fully present in
  the repo, just unconfigured, nothing to undo later
- Skips the Mailu rows in `credentials-export.csv`
- Disables (greys out) the Mail Domain field, since it means nothing
  without email being set up

**New `_scripts/enable-email.ps1`** turns email on later without
re-running the whole wizard: prompts for the same domain-or-separate-
domain choice the installer would have asked, confirms the Cloudflare
dashboard steps a separate domain needs are already done, generates the
same two secrets, writes `email-stack\.env`, and updates `MAIL_DOMAIN` in
`caddy\.env` in place (preserving every other line). Also safe to re-run
against an already-configured `email-stack` (asks to confirm first) -
useful for rotating the admin password or moving Mailu to a different
domain later, since neither secret's rotation is destructive to existing
mail data (Mailu's SQLite database in the `mailu-data` volume is
untouched by either).

**`deploy.ps1` changes to support this properly**: `Deploy-Stack` now
skips any stack with no `.env` file with a clear message, rather than
starting containers with every `${VAR}` resolving to an empty string -
this was already a latent gap (nothing previously stopped `-Action
deploy` from doing exactly that to any stack missing its `.env`, not just
email-stack). Also added `-Stack` support to the `deploy` action itself
(previously only `start`/`stop`/`restart` supported targeting one stack),
so `enable-email.ps1`'s "what to run next" instructions can point at
`deploy.ps1 -Action deploy -Stack email-stack` directly.

Live-tested: ran `Create-EnvFiles` standalone against both an email-
enabled and email-skipped scenario, confirmed `email-stack\.env` is
written correctly in one case and doesn't exist at all in the other, and
confirmed `caddy\.env`'s `MAIL_DOMAIN` line and comment adjust correctly
to match. Tested `enable-email.ps1` end-to-end (with its interactive
prompts short-circuited, since this environment's PowerShell runs
non-interactively) against a fresh `caddy\.env`, confirmed it correctly
appends `MAIL_DOMAIN`, writes a correct `email-stack\.env` with real
generated secrets, and confirmed the "already configured, overwrite?"
safety check leaves an existing file untouched when declined.

## 1.5.0 - Security audit: no-auth services, a dangerous docker.sock mount, redundant port exposure (2026-09-21)

A dedicated security pass across the whole codebase, not just the
diff-by-diff review each feature already got. Three categories of real,
independently-confirmed findings:

**Services with no real authentication, now closed:**
- **Radicale** (calendar/contacts) ran with `RADICALE_AUTH_TYPE=none` -
  its own image's default, confirmed live via a raw `PROPFIND` request
  returning a normal response with zero credentials. Anyone who reached
  `cal.{$DOMAIN}` could read/write every family member's calendar and
  contacts. Fixed at the Caddy layer (`basic_auth` on the `cal.{$DOMAIN}`
  route, one shared family credential) rather than Radicale's own more
  limited auth options - CalDAV/CardDAV clients (phone Calendar/Contacts
  apps) handle a Basic-auth challenge from a fronting proxy identically to
  one from the server itself, so this isn't a workaround.
- **Sonarr, Radarr, Prowlarr, Lidarr** had no authentication of their own
  either (these apps don't ship with auth enabled by default). Same fix:
  Caddy `basic_auth` on all four routes, one shared credential distinct
  from Radicale's (admin-only vs. family-facing).
- Both new credentials (`ARR_AUTH_HASH`, `RADICALE_AUTH_HASH`) are bcrypt
  hashes generated via `caddy hash-password`, never plaintext -
  `gui-installer.ps1` generates them the same way it already shells out to
  Docker for other setup steps.

**A genuinely dangerous, unnecessary Docker socket mount, removed:**
`mailu-admin` mounted `/var/run/docker.sock` read-write - full root-
equivalent host access from an internet-facing container (reachable at
`mailadmin.{$MAIL_DOMAIN}`) that processes untrusted mail-related input.
Confirmed via Mailu's own upstream source that this does nothing: the
only actual Docker SDK usage anywhere in Mailu's codebase is in their own
test harness, not the admin service's runtime code, and their official
reference `docker-compose.yml` mounts only `data` and `dkim` for `admin` -
no socket at all. Live-tested the removal: `mailu-admin` reaches healthy
and creates its admin account identically with no socket access.

**A silent data-loss bug found while fixing the above**: Radicale's
volume was mounted at `/var/lib/radicale`, but this exact pinned image
version's actual default `filesystem_folder` is `/data/collections` -
confirmed by inspecting the image's own baked-in default config directly.
Every calendar/contact would have been written to the container's
ephemeral filesystem instead of the named volume, gone on the next
recreation. Fixed by mounting the volume where the image actually reads
from.

**Redundant direct port publishing, removed repo-wide**: continuing the
pattern already fixed for Gotify (1.2.1), found the same issue on
Portainer, Uptime Kuma, Vaultwarden, Grafana, Sonarr, Radarr, Prowlarr,
Lidarr, and qBittorrent's WebUI port - all reachable via Caddy already,
all *also* directly published to the host, bypassing Caddy's TLS/rate-
limiting/security-headers/basic_auth entirely. Also removed the same
exposure from three services with no Caddy route and no reason to be
reachable at all: Loki, Prometheus, and InfluxDB (pure backend data
sources Grafana/Telegraf already reach internally), OnlyOffice (JWT-
protected already, but still unnecessary exposure - Nextcloud reaches it
over `privacy-network`), and Portainer's unused Edge Agent port. Live-
tested: brought up Grafana and Vaultwarden with no published ports,
confirmed `docker port` shows nothing bound, confirmed both remain fully
reachable over the internal Docker network exactly as Caddy needs.

## 1.4.3 - Documentation accuracy pass (2026-09-21)

Ran a systematic documentation audit (every top-level `.md` file and
`.env.example`, cross-referenced against actual current compose/script
behavior) rather than relying on catching drift opportunistically as
each feature landed. Found and fixed, all in `_scripts/README.md` unless
noted:

- Understated which stacks `gui-installer.ps1` writes a `.env` for (said
  10, actually 12 - missing `dashboard` and `dns-stack`, both added back
  in 1.1.1/1.2.0 without this doc catching up).
- Missing `check-versions.ps1` from the script table entirely, despite it
  existing and being referenced correctly from the top-level `README.md`.
- Stale secret count ("21", correct value is 20 as of 1.2.2's Mailu
  Postgres removal).
- `backup.ps1`'s documented usage line was missing the `offsite-snapshots`/
  `offsite-check` actions and `-ResticRepository`/`-ResticPassword`
  params added in 1.1.2 - present in the top-level README's Quick
  Reference but never brought into this file.
- Also fixed a real "Needs Admin?" inaccuracy in the script table itself:
  still said `gui-installer.ps1` needs admin rights, which stopped being
  true when 1.2.2 removed its `RunAsAdministrator` requirement.
- **`SECURITY.md`**: its first-run-admin-account list was itself wrong in
  a different way than the one 1.4.1 already fixed - it named Wallabag as
  a "sets its own account on first visit" service, but Wallabag actually
  ships with a fixed, publicly-documented default login (`admin`/
  `wallabag`), which is a more urgent problem than an unset password, not
  the same category. Jellyfin (genuinely first-visit setup) was missing
  from the list entirely. Corrected in both `SECURITY.md` and `SETUP.md`.
- **`PLATFORM.md`**: didn't mention Cloudflare Tunnel/DNS-01 anywhere,
  despite being the doc a cross-platform reader would check for exactly
  this kind of "does this differ by OS" question. Added a short note that
  the Cloudflare setup is identical regardless of platform.

## 1.4.2 - Let Mailu live on a separate domain from everything else (2026-09-21)

**The problem**: this deployment's main domain already has real email
through Proton Mail. Mailu can't also serve `@maindomain` addresses
without taking the MX records away from Proton, breaking the working
inbox - a domain only has one real mail provider at a time. Every
Mailu-related hostname (`mail.`, `mailadmin.`, `webmail.`) was hardcoded
to `{$DOMAIN}`, the same domain as everything else, with no way around it.

**The fix**: added a new `MAIL_DOMAIN` variable (`caddy/.env`), separate
from `DOMAIN`, that the three Mailu routes in `caddy/Caddyfile` now use
instead. It defaults to the same value as `DOMAIN` via Compose's own
`${MAIL_DOMAIN:-${DOMAIN}}` interpolation if never set, so this is
backward compatible with every existing single-domain deployment -
nothing changes unless you deliberately point Mailu elsewhere.
`email-stack/.env`'s own `DOMAIN` (already an independent variable, since
every stack has its own `.env`) is what actually gets set to the second
domain. `gui-installer.ps1` gained an optional "Mail Domain" field in
step 1 (leave blank to keep the old single-domain behavior), and both the
review screen and `credentials-export.csv` reflect whichever domain
Mailu's admin/webmail routes actually live on. Cloudflare Tunnel doesn't
care how many domains it serves - the same tunnel just needs Public
Hostname rules and cache rules added for the second domain too (SETUP.md
step 1 now covers this), and the API token needs DNS-edit permission
scoped to both zones instead of one.

Live-tested: confirmed via `docker compose config` that Compose's
`${VAR:-${VAR2}}` nested-default syntax actually resolves both ways
(falls back correctly when unset, uses the override when set - not
something to assume without checking); confirmed via `caddy adapt`
against the real built image that `mail`/`mailadmin`/`webmail` route to
the mail domain while every other route stays on the main domain; ran
`Create-EnvFiles` standalone against both a same-domain and a
separate-domain scenario and confirmed `caddy/.env` and
`email-stack/.env` end up with matching values in both cases.

## 1.4.1 - Export every generated credential to a password-manager-ready CSV (2026-09-21)

`gui-installer.ps1` now writes `credentials-export.csv` (repo root,
gitignored) alongside the `.env` files it's always generated - every
login, API token, and internal database password it just generated or
collected, in Bitwarden's CSV import format. Chose that specific format
deliberately: Vaultwarden speaks it natively, and Proton Pass explicitly
lists "Bitwarden (csv)" as a supported import source, so one file covers
both password managers named as the target with no reformatting.

26 entries per install: every service with its own login gets its
URL/username/password; internal-only database passwords (Postgres/
MariaDB credentials nothing ever logs into directly) are included too
under "future access and ongoing maintenance," labeled as internal rather
than a login page; the handful of services that create their own admin
account on first web visit instead of from an env var (Portainer,
Trilium, Focalboard, Jellyfin) get a blank placeholder entry with a note,
rather than being silently left out of the manifest entirely.

Also fixed a real, unrelated documentation bug found while cataloging
which services actually need this treatment: SECURITY.md claimed
Nextcloud and Paperless-ngx create their admin account on first web UI
visit. They don't - both auto-provision their admin account straight from
the `NEXTCLOUD_ADMIN_USER`/`PASSWORD` and `PAPERLESS_ADMIN_USER`/`PASSWORD`
env vars `gui-installer.ps1` already generates, confirmed against each
project's own documentation. Corrected rather than left standing next to
new, more careful credential-handling docs.

Live-tested: ran the export function standalone against a full set of
simulated wizard data (all 26 rows), confirmed the CSV round-trips through
PowerShell's own `Import-Csv` cleanly with every field populated
correctly, and confirmed a clean `Invoke-ScriptAnalyzer` pass after fixing
a real blocking error the first draft introduced (a helper function with
both a `Username` and `Password` parameter trips
`PSAvoidUsingUsernameAndPasswordParams` - renamed rather than suppressed,
since the flagged pattern was trivial to avoid entirely here).

## 1.4.0 - Remote access via Cloudflare Tunnel (no port forwarding, works behind CGNAT) (2026-09-21)

**The problem this solves**: this server is on Starlink, which uses CGNAT -
there's no public IP to forward a port to, so the "point DNS at your
server's public IP" model this repo used until now was never actually
going to work for a real deployment here. Evaluated three alternatives
(Cloudflare Tunnel, Tailscale, staying WireGuard-only) against the actual
requirement - non-technical family reaching services from their phones and
work networks, plus friends' smart TV Plex apps working - and chose
Cloudflare Tunnel: it needs no client install for anyone but the admin,
unlike Tailscale, and (after actually reading Cloudflare's current Self-
Serve Subscription Agreement rather than relying on out-of-date community
lore) neither the free tier's 100MB request-body cap nor its terms of
service actually restrict video streaming - that cap is upload-only and
the ToS clause this fear was based on isn't in the current agreement.

**Architecture**: added `cloudflared` (`cloudflare/cloudflared:2026.9.1`)
to `caddy/docker-compose.yml`, using a token-based (remotely-managed)
tunnel rather than a local `config.yml` + `credentials.json` - the routing
lives in the Cloudflare dashboard as two Public Hostname rules (a wildcard
covering every service, one exact-match exception for Mailu's own
certificate renewal), so the only secret this repo needs is one token,
matching how every other user-obtained credential here already works
(Plex claim token, ProtonVPN password). Caddy itself switched from
HTTP-01/TLS-ALPN-01 certificate challenges (which need an inbound
request - impossible under CGNAT) to DNS-01 via a new `caddy-dns/cloudflare`
plugin compiled into `caddy/Dockerfile`, proving domain ownership via a
DNS TXT record instead. This is a **required** change, not additive -
every deployment now needs a Cloudflare-managed domain and API token, since
Caddy has no fallback certificate path anymore. Updated `gui-installer.ps1`
to collect both new tokens (widened the wizard window to fit them) and
`SETUP.md` with the exact one-time Cloudflare-dashboard steps this repo
can't automate (creating the tunnel, the token, and the two Public Hostname
rules).

**Real, honest limitation surfaced by this work, not solved by it**:
receiving mail from the outside world (inbound SMTP) fundamentally does
not work behind CGNAT + Cloudflare Tunnel's free tier - that needs either
a real public IP or Cloudflare Spectrum (a separate paid product for raw
TCP proxying), neither of which this repo provides. `email-stack/` remains
usable for outbound sending (via a smart-host relay, as already
documented) and webmail/internal use; receiving real external mail needs
a regular hosted provider. Documented in TROUBLESHOOTING.md rather than
glossed over.

**For Plex specifically**: this should be a straight reliability
improvement over Plex's own relay network, once Settings -> Network ->
Custom server access URLs is set to `https://plex.yourdomain.com:443` (a
server-side setting Plex broadcasts to every client, so it covers phone
apps, the web app, and smart TV apps identically with no per-device setup).
The one honest caveat found in research: very high-bitrate 4K remux
streaming has mixed community reports through Cloudflare's edge; ordinary
4K/1080p direct play or transcode is consistently reported as solid.

Also updated: `.env.example` (two new caddy/.env vars), `SECURITY.md`
(firewall guidance - nothing needs an inbound port anymore for web access),
`README.md`, and a new TROUBLESHOOTING.md section covering the specific
gotchas of this setup (a cosmetic "invalid" warning Cloudflare's own
dashboard sometimes shows on wildcard rules, why `noTLSVerify` on that
rule is intentional, and what to check if Plex still prefers relay).

Live-tested as far as possible without a real Cloudflare account/domain:
rebuilt the Caddy image and confirmed the `caddy-dns/cloudflare` plugin
loads and validates token format at config-parse time; confirmed
`cloudflared` reads `TUNNEL_TOKEN` correctly and fails with a clean,
expected error on a syntactically-invalid token rather than crashing.
Actually establishing a tunnel and issuing a real certificate needs a real
account and domain, same untestable-locally category as Mailu's own
Let's Encrypt issuance.

## 1.3.0 - Add Seerr: let family/friends request movies and shows (2026-09-21)

New service in `media-stack/`: Seerr (`ghcr.io/seerr-team/seerr:v3.4.1`),
reachable at `requests.{$DOMAIN}`. Lets family/friends browse and request
movies/shows themselves instead of asking directly - it talks to
Sonarr/Radarr to actually fulfill approved requests.

**Chose Seerr over Overseerr or Jellyseerr deliberately**: Overseerr was
archived by its own maintainers in early 2026, and its team merged efforts
with Jellyseerr into Seerr - the actively maintained successor to both.
It's also the only one of the three that supports both Plex AND Jellyfin as
a backend, which matters here since this stack runs both; either one's
user accounts can be imported directly, so family members request media
with a login they already have rather than a new one.

Joins `media-network` (to reach Sonarr/Radarr) and `caddy-network` (its own
route, and to reach Plex/Jellyfin directly). No new secrets or `.env`
changes needed - it keeps its own SQLite config, and Sonarr/Radarr/Plex/
Jellyfin connections plus each user's approval policy (auto vs.
manual-approval-required, configurable per person) are first-run/admin-UI
setup, the same pattern as Portainer/Nextcloud's own first-visit setup -
see SETUP.md for the exact steps. Also wired for Gotify notifications
(opt-in, same pattern as Watchtower/Diun).

Live-tested: pulled and ran the pinned image standalone, confirmed it
boots cleanly and serves `/api/v1/status` (200, real JSON) within seconds,
confirmed the Homepage dashboard tile parses correctly, and validated the
new Caddy route (`caddy validate` against the rebuilt custom image).

## 1.2.2 - Fix Mailu admin bootstrap, dead Postgres container, GUI installer cleanup (2026-09-21)

Reviewed `_scripts/gui-installer.ps1` end to end (unmodified since before the
Mailu rebuild, Diun, Homepage, Restic, and Pi-hole all landed) to check that
what it generates still actually matches every stack's `.env` requirements.
The installer itself was fine on that front - Pi-hole and dashboard `.env`
blocks were both already present and correct. Found three real, unrelated
bugs while verifying the Mailu credentials it writes actually produce a
working admin login, each confirmed live rather than by inspection alone:

**Mailu's initial-admin account was never actually being created.** The
bootstrap variable name was `INITIAL_ADMIN_PASSWORD` - not a real Mailu
config key (the correct name is `INITIAL_ADMIN_PW`) - and `INITIAL_ADMIN_DOMAIN`
was missing entirely (required to build the `admin@domain` address). Also
removed `MAIL_ADMIN=admin`, which was never a real Mailu variable either.
Added `INITIAL_ADMIN_MODE=update` per Mailu's own docs, so this doesn't
error out the next time the stack restarts. Confirmed live: before the fix,
admin's logs never mentioned account creation; after, `created admin user`
appears on every boot.

**The `mailu-database` Postgres container has been dead weight this whole
time.** It was wired up via `DATABASE_URL`, which is not a real Mailu
config variable (the actual key is `SQLALCHEMY_DATABASE_URI`) - so admin
had silently been running on its own default SQLite database
(`sqlite:////data/main.db`, inside the already-mounted `mailu-data` volume)
regardless, confirmed live via the migration log reporting `SQLiteImpl`.
Rather than fix the variable name, removed the Postgres container, its
volume, and `MAILU_DB_PASSWORD` entirely - Mailu's own docs recommend
against bothering with an external database for admin specifically because
there's so little data to store that SQLite is "sufficient, simpler and
more reliable." One less service, one less secret, one less thing that can
break, and it matches upstream's own recommended default rather than
fighting it.

**Mailu admin's healthcheck could never pass.** It curled `/`, which
404s unconditionally - not a bug introduced by anything in this repo, just
never actually verified end-to-end before now. The real app lives at
`/admin/` (redirects to `/sso/login`, which returns 200 without needing
auth first). Confirmed live: the container sat at `starting` indefinitely
under the old healthcheck and reached `healthy` within one interval under
the new one. This one mattered beyond cosmetics - `health-check.ps1` and
its Gotify alerting depend on this signal being real.

**`_scripts/gui-installer.ps1` cleanup**: removed two leftover `Write-Host
"DEBUG: ..."` lines that shouldn't have shipped, removed the unnecessary
`#Requires -RunAsAdministrator` (the script only writes plain-text `.env`
files inside the repo directory itself - nothing it does needs elevation,
and the requirement was pure UAC-prompt friction), and fixed the review
screen's hardcoded secret count, which had already drifted to "20" when
Pi-hole's password brought the real count to 21 in 1.2.0 - now correctly
20 again after removing `MailuDbPassword` from the generated set.

## 1.2.1 - Fix Homepage dashboard: missing container names, missing tiles (2026-09-21)

Post-implementation GUI audit of the Homepage dashboard added in 1.1.1,
done before starting on remote-access work. Found and fixed:

**Live status widgets were silently broken for ~20 services.**
`media-stack`, `privacy-stack`, `authentik`, and `utilities` never set an
explicit `container_name` on their services, so Docker Compose's default
naming (`<project>-<service>-1`) meant the actual container names never
matched the bare names `dashboard/config/services.yaml` references (e.g.
`sonarr`, `nextcloud`, `authentik-server`). The link tiles still worked
(hrefs don't depend on container name), but every live CPU/memory/status
widget on those tiles had nothing to attach to. Fixed by adding an
explicit `container_name` to every affected service, matching the name
already used as its DNS hostname elsewhere in each stack (Caddyfile,
inter-service env vars) - purely additive, no behavior change to
networking. Confirmed live: brought up a subset of previously-unnamed
containers (`vaultwarden`, `portainer`, `gotify`) after the fix and
verified `docker ps` reports the bare names Homepage expects.

**Immich's dashboard tile referenced the wrong container name** -
`immich-server` (hyphen) in `services.yaml` vs. the real
`immich_server` (underscore), Immich's own official-compose convention.
Fixed the reference rather than renaming Immich's containers.

**Two running services had no dashboard presence at all**: Pi-hole
(added in 1.2.0) and Gotify. Added a Pi-hole tile under a new "Network"
category, and added Gotify to the Authentication & Email category, plus
a `gotify.{$DOMAIN}` Caddy route (security headers, rate limiting) so
it's reachable the same way as every other admin UI in this repo.
Removed Gotify's direct host port publish (`8765:80`) as part of that -
it was the only admin UI in this stack bypassing Caddy's TLS/rate-
limiting/security-header path via a raw published port, which
SECURITY.md already documents as against this repo's policy ("only 80,
443, and WireGuard's UDP port should ever be reachable from the
internet"). No other script or doc referenced port 8765.

Also added missing live-status `container:` references to Focalboard,
Wallabag, Trilium, and Radicale tiles, which had links but no widget
data despite the underlying containers already existing and being
reachable.

Live-tested: validated every stack's compose config
(`_scripts/validate-stacks.sh`), rebuilt and syntax-validated the custom
Caddy image against the updated Caddyfile (`caddy validate`, including
the new `gotify.{$DOMAIN}` block), and brought up Homepage + Gotify +
Vaultwarden + Portainer together to confirm the dashboard's
`/api/services` endpoint parses the new "Network" section and Gotify
tile correctly and that container names now match on the wire.

## 1.2.0 - Add Pi-hole: network-wide DNS ad/tracker blocking (2026-09-21)

New `dns-stack/` stack: Pi-hole + a dedicated dnscrypt-proxy for
encrypted upstream resolution. Self-contained by design - this
dnscrypt-proxy instance doesn't share anything with any other
cloudflared/tunnel setup elsewhere in your infrastructure, keeping this
whole stack removable as one atomic unit.

**Plan changed mid-implementation, based on a live finding:** the
original plan was cloudflared's own `proxy-dns` mode for encrypted
upstream, reusing the same tool already used elsewhere for tunneling.
Actually running it failed outright - `proxy-dns` was removed from
cloudflared entirely as of version 2026.2.0 ("dns-proxy feature is no
longer supported"). Switched to `dnscrypt-proxy`
(`klutchell/dnscrypt-proxy`), the current community-standard replacement
for exactly this Pi-hole + encrypted-upstream pattern. Pinned to a
specific `build-<sha>` tag rather than `main`, since this maintainer
doesn't publish semver releases - reads unusually compared to every
other image in this repo, but it's still a genuine, reproducible pin.

**Both `pihole` and `dns-resolver` are deliberately excluded from the
fleet-wide Watchtower auto-update from 1.0.7/1.0.8**, on Pi-hole's own
documented recommendation: "you should not have a system automatically
update your Pi-hole container. Especially unattended." DNS for your
whole network failing at 2am from an unattended update is a worse
outcome than any of the other exceptions already made (Caddy, Gotify).
Diun still watches both and notifies when an update is available - you
apply it by hand, same idea as Caddy/Gotify.

New Caddy route: `pihole.{$DOMAIN}` for the admin UI only - the actual
DNS service (port 53) is published directly by the container, not
proxied through Caddy, since DNS isn't an HTTP protocol.

Live-tested end-to-end: brought up both containers together, confirmed
`pihole`'s resolved config actually points at `dns-resolver` (not a
silent fallback), confirmed real DNS resolution works through the full
chain (`nslookup cloudflare.com` via Pi-hole), and confirmed the admin
web UI responds. One real bug caught immediately by
`validate-stacks.sh`: the initial healthcheck array was missing the
required `CMD` prefix.

Added the new stack everywhere this repo tracks its stack list by hand,
and a new TROUBLESHOOTING.md entry for the port-53-already-in-use
conflict with `systemd-resolved` on native Linux (not reproducible under
Docker Desktop, where this was tested).

### Also: `TROUBLESHOOTING.md`'s Mailu entry was stale

Updated the "Mailu is a minimal build" entry, written before the 1.0.9
rebuild - it described exactly the gap that rebuild closed (missing
`front`/antivirus, no real TLS). Left uncorrected, it would have told a
future reader the opposite of what's actually true.

## 1.1.2 - Add off-site backup via Restic to backup.ps1 (2026-09-21)

Extends `_scripts/backup.ps1` rather than adding a new script or
container: `-Action backup` now also pushes the just-created local
backup off-site via Restic (run through `docker run`, same pattern this
script already uses for volume backups) whenever `-ResticRepository` and
`-ResticPassword` are both supplied - unset (the default) means exactly
the same local-only behavior as before this existed. Two new actions,
`offsite-snapshots` and `offsite-check`, list off-site snapshots and
verify repository integrity on demand.

`RESTIC_REPOSITORY` can be any backend Restic supports (S3, B2, SFTP,
etc.) - backend-specific credentials (`B2_ACCOUNT_ID`, `AWS_ACCESS_KEY_ID`,
etc.) are read from the invoking process's own environment rather than
added as script parameters, since which ones are needed depends entirely
on the backend chosen. No off-site account was available to test
against, so this was live-verified against a temporary local REST
server standing in for a real S3/B2 endpoint - the exact same code path
a real backend would use (network-accessible repository, no special
local-path handling), just pointed at a throwaway target. Confirmed:
first run detects an uninitialized repository and runs `restic init`
automatically, `restic backup` succeeds and tags the snapshot with the
local backup's name, a second run correctly skips re-init, and both new
actions list/verify correctly.

Two real bugs caught by that live test, not written blind:
- `Invoke-Restic` returned `$LASTEXITCODE` explicitly, putting it into
  the same output stream as restic's own passthrough text - harmless
  for callers that pipe to `Out-Null` and check the ambient
  `$LASTEXITCODE` themselves, but `offsite-snapshots` (whose entire job
  is showing restic's real output) printed a stray trailing `0` after
  the snapshot table. No caller actually used the returned value - all
  of them already checked `$LASTEXITCODE` directly - so the return was
  dead code causing its own bug. Removed.
- That same bug initially manifested as `offsite-snapshots` printing
  nothing at all, from an over-correction (`| Out-Null`) that suppressed
  restic's real output along with the exit code. Fixed by removing the
  cause instead of routing around it.

Suppresses `PSAvoidUsingPlainTextForPassword` for `-ResticPassword`
specifically (not the whole rule) - it's passed straight through to
`docker run -e` as a plain env var regardless, so a `SecureString` would
just add friction with no real security benefit here, consistent with
every other credential in this repo.

## 1.1.1 - Add Homepage: single dashboard for every service (2026-09-21)

New `dashboard/` stack: [Homepage](https://github.com/gethomepage/homepage),
a single landing page linking to every service in this repo instead of
bookmarking ~40 separate URLs. Config lives in `dashboard/config/`
(`services.yaml`, `settings.yaml`, `docker.yaml`) as plain files checked
into git, matching this repo's config-as-code pattern - not something
edited through a UI. Several tiles use the Docker socket (read-only) for
live container status; the rest are plain links.

Service links use Homepage's `{{HOMEPAGE_VAR_DOMAIN}}` templating (backed
by `HOMEPAGE_VAR_DOMAIN` in `dashboard/.env`) rather than a hardcoded
domain, so the same config works regardless of what domain this was
actually installed with.

New route: `home.{$DOMAIN}` in `caddy/Caddyfile`.

Added `dashboard` to every place this repo tracks its stack list by hand
(`_scripts/validate-stacks.sh`, `_scripts/health-check.ps1`,
`_scripts/deploy.ps1`, `_scripts/gui-installer.ps1`, `.env.example`) -
none of these auto-discover stacks the way `check-versions.ps1` does.

Live-tested with the real config files mounted: confirmed via Homepage's
own `/api/services` endpoint that `services.yaml` parses correctly and
the `{{HOMEPAGE_VAR_DOMAIN}}` substitution resolves as expected.

## 1.1.0 - Add Diun: notify about new image tags Watchtower won't catch (2026-09-21)

Adds `diun` to `utilities/docker-compose.yml`. Complements Watchtower
rather than duplicating it: Watchtower only re-triggers when the digest
behind an *already-pinned* tag changes, so for the many exact-pinned
images in this repo it never notices a genuinely new version being
published upstream (see the tag-floating-vs-exact caveat in 1.0.7). Diun
watches every image for new tags/digests and only notifies - it never
applies anything.

Configured to watch every container by default
(`DIUN_PROVIDERS_DOCKER_WATCHBYDEFAULT=true`) rather than requiring a
`diun.enable=true` label on ~40 services individually - safe to default
to broad here since it's read-only, unlike Watchtower's actual
auto-update behavior which does need that per-service opt-in.
Notifications go to Gotify, same opt-in pattern as Watchtower: unset by
default, starts working the moment `GOTIFY_TOKEN` is set in
`utilities/.env`.

Live-tested against the real Docker daemon (read-only socket mount):
correctly discovered and analyzed real running containers with no
errors, scheduled its next run correctly.

## 1.0.9 - Rebuild email-stack against Mailu's own reference architecture (2026-09-21)

Follow-up to the "Mailu front gap" flagged earlier: rebuilt `email-stack`
from Mailu's actual official reference compose instead of continuing to
patch a hand-built version - the earlier audit found `front`, `antivirus`,
and `webdav` all missing, plus TLS silently disabled on Dovecot and
entirely unconfigured on Postfix. All three are now present, using
Mailu's own images rather than generic third-party ones (same rspamd/
version-lockstep wiring, no reinventing the integration).

**New services**: `mailu-front` (Mailu's nginx gateway - TLS termination
for SMTP/IMAP/POP3 only; does **not** bind 80/443, Caddy keeps owning
those - see `caddy/Caddyfile`'s `http://mail.{$DOMAIN}` passthrough for
front's own Let's Encrypt HTTP-01 challenge), `mailu-antivirus` (Mailu's
own ClamAV build - same engine as a standalone ClamAV container would've
used, but pre-wired for rspamd and version-tracked with the rest of
Mailu), `mailu-webdav` (CalDAV/CardDAV tied to mail accounts, distinct
from privacy-stack's general-purpose Radicale), and `mailu-resolver`
(Mailu's own `unbound` build - required because Mailu's admin container
refuses to start without a DNSSEC-*validating* resolver, and Docker's
built-in 127.0.0.11 doesn't validate).

**Every wiring bug below was caught by actually running the containers
together, not by reading docs** - this stack was originally built by a
different model, and every one of these is the same failure pattern:
Mailu's containers default to expecting stock service names (`admin`,
`redis`, `front`...); since this repo uses `mailu-*` names, every
cross-service reference needed an explicit override, and several were
missing entirely:
- `mailu-smtp`/`mailu-imap`/`mailu-webmail` were all missing `HOSTNAMES` -
  Postfix/Dovecot/Roundcube's config templating fails outright without it.
- `mailu-webmail` was missing `SECRET_KEY` and `MESSAGE_SIZE_LIMIT`.
- `mailu-webmail`'s nginx template hardcodes `set_real_ip_from front`
  unless `FRONT_ADDRESS` is set - needed `FRONT_ADDRESS=mailu-front`.
- `mailu-admin`'s session/rate-limit storage silently defaults to a host
  named `redis`, controlled by `REDIS_ADDRESS` - a **different** variable
  from `REDIS_URL`, which admin also uses but for something else.
- `mailu-front` was missing `POSTMASTER` (KeyError at startup).
- **`mailu-admin`'s healthcheck (and Caddy's `mailadmin.{$DOMAIN}` route)
  were pointed at port 80 - admin actually listens on 8080.** This was a
  pre-existing bug, not introduced here; only surfaced because this is
  the first time anyone actually curl'd the container instead of assuming
  the port. Both fixed.
- `mailu/clamav`'s versioning is independent of Mailu's `2024.06.x` train
  (tracks the ClamAV engine's own release cycle) - confirmed via GHCR's
  actual tags rather than assumed; pinned to `2.0.43`.

**Known, inherent limitation, not a bug**: `mailu-front`'s TLS certificate
comes from its own Let's Encrypt HTTP-01 challenge, which needs a real
public domain reachable from the internet - can't be completed in a local
test. `mailu-front`, `mailu-imap`'s TLS listener, and `mailu-webmail`'s
health all depend on that certificate existing, so they show unhealthy in
isolation. Every wiring/config-rendering piece up to that point was
verified live (all env vars resolve, `mailu-admin`'s DNSSEC startup gate
passes, rspamd's rendered config correctly points at `mailu-antivirus:3310`,
every other container reaches a genuine `healthy` state) - only the final
"does Let's Encrypt actually issue a cert" step needs a real deployment
to confirm.

### Unrelated regression found and fixed along the way: Postgres 18 refuses to start with this repo's existing volume convention

While live-testing `mailu-database`, found that **every service already
bumped to `postgres:18-alpine` in 1.0.8** (`authentik`, `mailu-database`,
`privacy-stack`'s `paperless-db` and `wallabag-db`) fails to start at all
- not a warning, a hard `Error:` and crash-loop. Postgres 18's image
changed its expected volume layout: it now wants a mount at
`/var/lib/postgresql` (letting it manage a version-specific subdirectory
itself for `pg_upgrade` compatibility), not `/var/lib/postgresql/data`
as every prior major version used - confirmed live, the old mount path
crash-loops with a clear error pointing at the new convention. Fixed by
changing the mount point on all four affected services. This shipped
in 1.0.8 without being caught because that testing only ran Postgres 18
standalone, without a mounted named volume - exactly the condition that
triggers this.

## 1.0.8 - Version-currency pass: bring every image to latest (2026-09-21)

One-time audit against actual current tags (Docker Hub API + GitHub
releases, not memory - several of these projects release too often to
trust anything older than a live lookup), done now specifically because
nothing in this deployment is live yet, so there's no data-migration risk
on the major-version bumps below.

**Real version bumps found and applied:**
| Image | Old | New |
|---|---|---|
| `prom/node-exporter` | v1.9.1 | v1.12.1 |
| `paperless-ngx/paperless-ngx` | 3.1.3 | 3.2.1 |
| `mattermost/focalboard` | 7.10.0 | 7.11.4 |
| `ghcr.io/mailu/*` (all 5 services) | 2024.06.10 | 2024.06.58 |
| `telegraf` | 1.38.1 | 1.40.0 |
| `postgres` (authentik, mailu-database, paperless-db, wallabag-db) | 16-alpine / 17-alpine | 18-alpine |
| `redis` (mailu-redis, paperless-redis) | 7-alpine | 8-alpine |
| `valkey/valkey` (immich) | same tag, stale digest | digest updated to match Immich's own current `v3.2.2` reference compose |

**Live-verified before landing**, given this project's history of
"looked configured, wasn't" bugs (Telegraf's original crash-loop,
Watchtower's inert labels):
- `telegraf:1.40.0 --test` against the existing `telegraf.conf` - loads
  and runs every plugin cleanly, no repeat of the 1.38 plugin-schema
  breakage. One new deprecation warning worth knowing: 1.40.0 changes the
  default for `skip_processors_after_aggregators` - not an error, not
  acted on here, just flagged for whoever next touches this config.
- `postgres:18-alpine` and `redis:8-alpine` both start and accept
  connections cleanly in isolation.

**Confirmed already current** (checked, not assumed): fail2ban,
Navidrome, Gotify, Grafana, Loki, Jellyfin, Nextcloud, Uptime Kuma,
Watchtower, OnlyOffice, Plex, Portainer, Prometheus, Gluetun, Syncthing,
Radicale, Trilium, Vaultwarden, Wallabag, Wireguard, Authentik, the
Immich postgres companion image's digest, and the hotio arr-suite images
(already floating on `:release`).

**Deliberately not bumped:**
- `mariadb:11.4.13` - this is already the latest patch on its LTS
  branch. Newer branches exist (12.x, 13.x) but that's a support-tier
  choice, not a patch bump, so left for a deliberate decision rather
  than changed silently here.
- `influxdb:2-alpine` - InfluxDB 3.x is an architecturally different
  product (different config format and storage engine, not a drop-in
  replacement), so out of scope for a version-currency pass.

## 1.0.7 - Enable Watchtower auto-update fleet-wide, notify-only for Gotify (2026-09-21)

Found while wiring up Watchtower notifications: `SECURITY.md` documented
Watchtower as opt-in per service, "excludes every database, Authentik,
and qBittorrent by default" - implying everything else was opted in.
In reality every single service across all ~40 containers in every stack
was labeled `com.centurylinklabs.watchtower.enable=false`. Auto-update
had been fully configured (schedule, cleanup, notification wiring) but
was completely inert - nothing was ever eligible to update. Same class
of bug as the Telegraf crash-loop: looked configured, never exercised.

**Decision:** auto-update everything. Flipped every `enable=false` label
to `true`, including Gotify - initially carved out as `monitor-only`
(notified, never auto-applied) since it's the notification channel every
other alert in this stack depends on, but revisited: Gotify is small,
mature, single-binary software with a conservative release history and
no pattern of breaking changes, so the realistic failure risk is low.
Folded in as a deliberate call made with that blast-radius tradeoff
explicit, not because the risk was reassessed as zero.
- **Caddy** - left `false`. It's a local build (`build: .`), not pulled
  from a registry, so there's no upstream tag for Watchtower to check;
  enabling it would be a no-op that only adds log noise.

**Caveat worth knowing:** Watchtower only re-triggers when the digest
behind a service's *currently pinned tag* changes upstream. Some images
here are already on a floating-enough tag (Postgres `16-alpine`/
`17-alpine`, Redis `7-alpine`, the hotio arr-suite's `:release`) where
this produces genuine continuous auto-updates. Others are pinned to an
exact version (MariaDB `11.4.13`, Plex, Grafana, Nextcloud, etc.), where
Watchtower stays idle until that exact pin is bumped by hand - flipping
the label alone doesn't make those continuously current. Converting the
exact-pinned images to appropriate floating tags, where each upstream
project supports it safely, is follow-up work, not done here.

Also updated `SECURITY.md` and `README.md`, which both described the
old (never-actually-true) opt-in-by-default behavior.

**Not yet applied to any running container** - Watchtower reads labels
off the live container, not the compose file, so this takes effect only
once each affected stack is redeployed (`deploy.ps1 -Action deploy`).

## 1.0.6 - Version-drift checker: image inventory (2026-09-20)

First piece of the version-drift checker: `_scripts/check-versions.ps1`
walks every stack directory (any folder with a `docker-compose.yml`,
auto-discovered rather than hardcoded) and extracts each service's image
reference into `{Stack, Service, Registry, Repository, Tag, ResolvedTag,
IsVariable, VariableName, Digest}`. Handles the three image reference
styles actually used across the ~30 images in this repo: plain
`repo:tag`, digest-pinned (`repo:tag@sha256:...`), and `.env`-driven
(`repo:${VAR:-default}`, used by both Immich services).

Caught and fixed one parsing bug before it shipped: a
`${VAR:-default}` substitution's own `:` was colliding with the
tag-separator `:`, corrupting `Repository`/`Tag` for both Immich images
(the console table happened to display the corrupted fields back in the
right order by coincidence, which would have hidden the bug from a
visual-only check - caught by inspecting the underlying JSON object
fields directly instead of trusting the formatted output).

This is inventory only - no registry lookups yet. That's the next,
costlier phase (querying Docker Hub/GHCR/lscr.io for latest tags/digests
and live-verifying against real images), planned as a follow-up once
there's budget for the live-testing it requires.

## 1.0.5 - Fix all 5 PowerShell scripts failing under the default Windows PowerShell (2026-09-20)

Found while doing a visual/UX review of the GUI installer: none of the
five scripts in `_scripts/` would actually run under stock **Windows
PowerShell 5.1** - the version that ships by default on every Windows
10/11 machine, and what a typical user gets from "Run with PowerShell" or
opening a plain "Windows PowerShell" shortcut. Every parse-check run
throughout this whole project (including in this repo's own CI) had been
done with PowerShell 7 (`pwsh`), which handles this correctly by default -
so the bug was invisible until the actual target runtime was tested.

**Root cause:** all five files contain emoji/box-drawing characters
(✅❌⚠️🔐 etc.) encoded as UTF-8 with no byte-order-mark (BOM). PowerShell 7
assumes UTF-8 for BOM-less script files; Windows PowerShell 5.1 assumes
the system's legacy ANSI codepage instead. Reading UTF-8 multi-byte
sequences as CP1252 corrupts them into byte patterns that broke
tokenization outright in 4 of the 5 files - confirmed live, each with a
different parser error:

| File | PS 5.1 result before fix |
|---|---|
| `gui-installer.ps1` | `Unexpected token '' in expression or statement.` |
| `deploy.ps1` | `The string is missing the terminator: '.` |
| `health-check.ps1` | `You must provide a value expression following the '%' operator.` |
| `backup.ps1` | `The '<' operator is reserved for future use.` |
| `setup-directories.ps1` | Parsed (by luck - its specific corrupted bytes happened to stay syntactically valid), but would have rendered garbled boxes/emoji instead of the intended output. |

**Fix:** added a UTF-8 BOM to all five files (raw byte-level fix - existing
content otherwise untouched). Verified every file now parses cleanly under
*both* Windows PowerShell 5.1 and PowerShell 7, and re-ran
`setup-directories.ps1` for real under PS 5.1 to confirm its emoji now
render correctly instead of as mojibake.

Also un-excluded `PSUseBOMForUnicodeEncodedFile` from
`_scripts/PSScriptAnalyzerSettings.psd1`, where it had been incorrectly
lumped in with genuinely stylistic rules (Write-Host usage, verb naming) -
it was flagging this exact bug the whole time. CI will now catch a BOM
regression instead of staying silent about it.

### Two more real bugs found doing an actual visual pass of the GUI

Rendered every wizard step with a real screenshot (not just read the
source) and found two more display bugs, both fixed:

- `🔐 Generate Passwords` and `⚠️ WARNING: ...` rendered as an empty "tofu"
  box where the emoji should be - Segoe UI's default (non-emoji) rendering
  has no glyph for these specific compound/supplementary-plane characters.
  Removed the emoji from both; the surrounding text already made the
  meaning clear ("WARNING:" in red italic, a green "Generate Passwords"
  button).
- `"Step 5 of 5: Review & Create"` rendered as `"Step 5 of 5: Review
  Create"` - a single `&` in a WinForms Label's Text is a mnemonic marker
  and gets silently swallowed unless doubled (`&&`) or escaped. Reworded
  to "Review and Create" rather than relying on an easy-to-reintroduce
  escaping convention.

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
