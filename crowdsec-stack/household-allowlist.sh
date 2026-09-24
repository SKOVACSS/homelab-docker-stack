#!/bin/sh
# Keeps CrowdSec's "household" allowlist pointed at this network's current
# public IP, so nothing - a local scenario or the community blocklist -
# can ban the household out of its own services. Starlink (like most
# residential ISPs) hands out a dynamic IP, so a static allowlist entry
# would silently go stale; this re-checks every $INTERVAL seconds and
# swaps the entry when the IP changes.
#
# Runs in the household-allowlist service (see docker-compose.yml), which
# shares crowdsec's network namespace (cscli talks to its LAPI on
# localhost) and egresses the same way crowdsec does - straight out the
# home connection, not through any VPN.
#
# Tradeoff: under CGNAT the public IP is shared with other customers of
# the same ISP, and they're allowlisted too. Accepted deliberately - a
# false ban takes down every app for the whole household, while a real
# attacker would have to share this exact CGNAT address to benefit.

LIST=household
INTERVAL=${INTERVAL:-300}

cscli allowlists create "$LIST" -d "Current household public IP (auto-updated)" >/dev/null 2>&1 || true

while true; do
    ip=$(wget -qO- -T 10 https://api.ipify.org 2>/dev/null || wget -qO- -T 10 https://ipv4.icanhazip.com 2>/dev/null)
    ip=$(echo "$ip" | tr -d '[:space:]')
    if echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        current=$(cscli allowlists inspect "$LIST" -o raw 2>/dev/null | awk -F, 'NR>1 {print $3}')
        if [ "$current" != "$ip" ]; then
            # shellcheck disable=SC2086 # one value per word, intentionally
            [ -n "$current" ] && cscli allowlists remove "$LIST" $current >/dev/null
            cscli allowlists add "$LIST" "$ip" >/dev/null
            # An allowlist only prevents new decisions - lift any ban that
            # already exists for the new IP too.
            cscli decisions delete -i "$ip" >/dev/null 2>&1
            echo "$(date -u +%FT%TZ) household IP is now $ip (was ${current:-none})"
        fi
    else
        echo "$(date -u +%FT%TZ) could not determine public IP - keeping current entry"
    fi
    sleep "$INTERVAL"
done
