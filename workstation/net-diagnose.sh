#!/usr/bin/env bash
# Collects everything needed to troubleshoot "Wi-Fi connected, no internet"
# (or not connecting at all) into one text file, saved next to this script -
# so when run from the USB kit, the report ends up on the stick and can be
# read on another computer. Works offline. Contains IP/MAC addresses and
# network names, but never Wi-Fi passwords.
#
# Usage:  bash net-diagnose.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/net-report-$(date +%Y%m%d-%H%M%S).txt"
IFACE="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
IFACE="${IFACE:-wlp2s0}"

section() { printf '\n===== %s =====\n' "$*"; }

sudo -v   # ask for the password once, up front

{
  section "When / what"
  date; uname -r; cat /sys/class/dmi/id/product_name 2>/dev/null; echo "iface=$IFACE"

  section "Link (signal, bitrate)"
  iw dev "$IFACE" link 2>&1

  section "Addresses and routes"
  ip -4 -br addr 2>&1; ip route 2>&1

  GW="$(ip route | awk '/default/{print $3; exit}')"
  section "Ping gateway ($GW)"
  if [ -n "$GW" ]; then ping -c5 -W2 "$GW" 2>&1 | tail -3; else echo "no default gateway"; fi

  section "Ping 1.1.1.1 (internet, no DNS)"
  ping -c5 -W2 1.1.1.1 2>&1 | tail -3

  section "DNS"
  resolvectl status "$IFACE" 2>&1 | grep -E "DNS Servers|Current DNS|Link"
  for h in fedoraproject.org github.com; do
    if getent hosts "$h" >/dev/null; then echo "$h: resolves"; else echo "$h: DNS FAILED"; fi
  done

  section "NetworkManager device"
  nmcli -f GENERAL.STATE,GENERAL.CONNECTION,GENERAL.HWADDR,IP4,DHCP4 device show "$IFACE" 2>&1

  section "Visible networks"
  nmcli -f IN-USE,SSID,CHAN,SIGNAL,SECURITY device wifi list 2>&1 | head -15

  section "Fixes in place"
  for f in /usr/lib/firmware/brcm/brcmfmac43602-pcie.txt /etc/modprobe.d/brcmfmac.conf \
           /etc/NetworkManager/conf.d/90-brcmfmac.conf /etc/NetworkManager/conf.d/90-wifi-powersave-off.conf; do
    [ -e "$f" ] && echo "present: $f" || echo "MISSING: $f"
  done
  echo "feature_disable=$(cat /sys/module/brcmfmac/parameters/feature_disable 2>/dev/null || echo '?')"

  section "Driver messages (brcmfmac)"
  sudo dmesg 2>&1 | grep -i brcmf | tail -25

  section "NetworkManager log (this boot, last 40 relevant lines)"
  sudo journalctl -b -u NetworkManager --no-pager 2>&1 \
    | grep -iE "$IFACE|dhcp|reason|4-way|handshake|supplicant|state change" | tail -40
} > "$OUT" 2>&1

echo "Report saved to: $OUT"
echo "Bring that file to another computer and share it."
