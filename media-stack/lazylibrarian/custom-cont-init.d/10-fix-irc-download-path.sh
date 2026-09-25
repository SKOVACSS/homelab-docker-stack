#!/bin/sh
# LazyLibrarian IRC download fix (runs as root at container start, via
# linuxserver's /custom-cont-init.d hook).
#
# Upstream bug (still in master as of 2026-09-25): ircbot.py builds the
# download path as "<cache>/IRCCache/<name>" and then sanitizes the WHOLE
# path, turning every "/" into "_". The result is a bare filename like
# "_config_cache_IRCCache_Book.zip", which is written to the working
# directory ("/", not writable) and fails with PermissionError - so no
# IRC download ever completes. Sanitize only the file name instead.
#
# Idempotent and self-retiring: it changes nothing once upstream fixes the
# line (the pattern no longer matches) or on a restart after patching.
F=/app/lazylibrarian/lazylibrarian/ircbot.py
BUG='self.filename = sanitize(self.filename, is_folder_or_file=True)'
if [ -f "$F" ] && grep -q "self.filename = f\"{self.localfolder}/{self.filename}\"" "$F" && grep -q "$BUG" "$F"; then
    sed -i \
        -e 's|self.filename = f"{self.localfolder}/{self.filename}"|self.filename = os.path.join(self.localfolder, sanitize(self.filename, is_folder_or_file=True))|' \
        -e "s|^\( *\)$BUG|\1pass  # (homelab: sanitized above, file name only)|" \
        "$F"
    echo "[homelab] patched LazyLibrarian IRC download path"
fi
