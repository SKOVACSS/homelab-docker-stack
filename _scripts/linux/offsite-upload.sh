#!/usr/bin/env bash
# Uploads the local Restic repository to Proton Drive with the official
# Proton Drive CLI (proton-drive). On Windows the Proton Drive desktop app
# did this by watching the folder; there is no Linux desktop app, so the
# nightly backup calls this after `restic backup` finishes.
#
# Restic never rewrites a file once it is in the repository (packs, index
# and snapshot files are content-addressed), so "upload what is not there
# yet" is a complete sync for a backup. `restic prune` deletes old packs
# locally; those are left on Proton Drive (they cost space, not safety) -
# clear them occasionally by re-uploading to a fresh folder.
#
# One-time setup, as the user that runs the backup:
#   proton-drive auth login        # browser sign-in; the session is kept in
#                                  # the system keyring (libsecret), so a
#                                  # headless server needs gnome-keyring or
#                                  # another Secret Service running
#
# Settings come from _scripts/offsite.env:
#   RESTIC_REPOSITORY=/tank/backups/restic      (local folder)
#   PROTON_DRIVE_PATH=/my-files/Homelab Backup  (destination folder)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$here/offsite.env"
[ -f "$env_file" ] || { echo "offsite.env not found - nothing to upload"; exit 0; }
getenv() { grep -E "^\s*$1\s*=" "$env_file" | head -1 | sed -E "s/^\s*$1\s*=\s*//; s/^[\"']//; s/[\"']\s*$//"; }

repo="$(getenv RESTIC_REPOSITORY)"
dest="$(getenv PROTON_DRIVE_PATH)"
[ -n "$repo" ] && [ -d "$repo" ] || { echo "RESTIC_REPOSITORY is not a local folder - skipping upload"; exit 0; }
[ -n "$dest" ] || { echo "PROTON_DRIVE_PATH not set - skipping upload"; exit 0; }
command -v proton-drive >/dev/null || { echo "proton-drive CLI not installed"; exit 1; }

# Fails fast (non-zero) if the saved session has expired.
proton-drive filesystem list "$dest" >/dev/null

local_count=$(find "$repo" -type f | wc -l)
echo "Uploading $repo ($local_count files) -> $dest"
proton-drive filesystem upload "$repo"/* "$dest" --conflict-strategy skip

# Verify: every snapshot file that exists locally must now be listed remotely.
missing=0
remote="$(proton-drive filesystem list "$dest/snapshots" --json)"
for f in "$repo"/snapshots/*; do
  name="$(basename "$f")"
  grep -q "$name" <<<"$remote" || { echo "MISSING remotely: snapshots/$name"; missing=$((missing + 1)); }
done
[ "$missing" -eq 0 ] || { echo "$missing snapshot file(s) did not upload"; exit 1; }
echo "Off-site upload verified: all snapshots present on Proton Drive."
