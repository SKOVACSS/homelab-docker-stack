#!/usr/bin/env bash
# Fixes the built-in Wi-Fi on 2015-2017 MacBook Pros with the Broadcom
# BCM43602 (every Touch Bar model, e.g. MacBookPro13,2) under Fedora.
# Works fully offline - run it from the USB kit before you have internet.
#
# What it changes (all reversible - see --undo):
#   1. Installs the board's missing NVRAM calibration file
#      (firmware/brcmfmac43602-pcie.txt next to this script). linux-firmware
#      ships only the .bin for this chip; without the NVRAM, the firmware's
#      country detection never completes: 2.4 GHz only, a fraction of the
#      real signal, and WPA handshakes that time out and show up as
#      "password incorrect". Its macaddr= line is dropped so the chip keeps
#      its own burned-in address.
#   2. brcmfmac feature_disable=0x82000 - turns off the firmware's broken
#      WPA offload.
#   3. NetworkManager: no MAC randomization (brcmfmac mishandles it), and
#      Wi-Fi power saving off (stalls/drops on this chip).
# Then reboot. (Reloading the driver in place doesn't work on this chip: on
# a MacBookPro13,2, `modprobe -r/modprobe brcmfmac` left the firmware
# crashed - "dongle is not responding" - until a full power cycle.)
#
# Usage:  bash wifi-fix.sh [--ssid NAME] [--no-nvram] [--undo]
#   --ssid NAME  Forget this saved network, so it's set up fresh (with the
#                new settings) when you reconnect after the reboot.
#   --no-nvram   Skip step 1 (e.g. to test whether it's what helps).
#   --undo       Remove everything this script installed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Normally in firmware/ next to this script; also accept it right beside
# the script, in case the kit's folders got flattened while copying.
NVRAM_SRC="$HERE/firmware/brcmfmac43602-pcie.txt"
[ -f "$NVRAM_SRC" ] || NVRAM_SRC="$HERE/brcmfmac43602-pcie.txt"
NVRAM_DEST=/usr/lib/firmware/brcm/brcmfmac43602-pcie.txt
MODPROBE_CONF=/etc/modprobe.d/brcmfmac.conf
NM_CONF=/etc/NetworkManager/conf.d/90-brcmfmac.conf
NM_PS_CONF=/etc/NetworkManager/conf.d/90-wifi-powersave-off.conf
MARKER="# installed by homelab-docker-stack workstation/wifi-fix.sh"

SSID=""; DO_NVRAM=1; UNDO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ssid)      SSID="${2:?--ssid needs a value}"; shift 2 ;;
    --no-nvram)  DO_NVRAM=0; shift ;;
    --no-reload) shift ;;  # accepted for older callers; never reloads now
    --undo)      UNDO=1; shift ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
done

ok()   { printf '  \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }

if [ "$UNDO" -eq 1 ]; then
  for f in "$MODPROBE_CONF" "$NM_CONF" "$NM_PS_CONF" "$NVRAM_DEST"; do
    if [ -f "$f" ] && sudo grep -qF "$MARKER" "$f"; then
      sudo rm -f "$f"; ok "removed $f"
    fi
  done
  echo "Reboot (or shut down fully and start again) to apply."
  exit 0
fi

# --- Is this the right hardware? -------------------------------------------
FOUND=""
for dev in /sys/bus/pci/devices/*; do
  if [ "$(cat "$dev/vendor")" = "0x14e4" ]; then
    case "$(cat "$dev/device")" in
      0x43ba|0x43bb|0x43bc) FOUND="$(basename "$dev")" ;;
    esac
  fi
done
if [ -z "$FOUND" ]; then
  echo "No BCM43602 Wi-Fi found - this Mac doesn't need this fix." >&2
  exit 1
fi
ok "BCM43602 found at $FOUND"

# --- 1. NVRAM ----------------------------------------------------------------
if [ "$DO_NVRAM" -eq 1 ]; then
  if [ ! -f "$NVRAM_SRC" ]; then
    warn "brcmfmac43602-pcie.txt not found in $HERE/firmware/ or $HERE/ - copy it from the kit and re-run"
    exit 1
  fi
  if [ -e "$NVRAM_DEST" ] && ! sudo grep -qF "$MARKER" "$NVRAM_DEST"; then
    warn "$NVRAM_DEST already exists and isn't ours - leaving it alone"
  else
    TMP="$(mktemp)"
    { echo "$MARKER"; sed '/^macaddr=/d' "$NVRAM_SRC"; } > "$TMP"
    sudo install -Dm644 "$TMP" "$NVRAM_DEST"
    rm -f "$TMP"
    ok "NVRAM installed to $NVRAM_DEST"
  fi
fi

# --- 2. Driver option --------------------------------------------------------
printf '%s\noptions brcmfmac feature_disable=0x82000\n' "$MARKER" | sudo tee "$MODPROBE_CONF" >/dev/null
ok "brcmfmac feature_disable=0x82000"

# --- 3. NetworkManager -------------------------------------------------------
sudo mkdir -p /etc/NetworkManager/conf.d
sudo tee "$NM_CONF" >/dev/null <<EOF
$MARKER
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=permanent
EOF
sudo tee "$NM_PS_CONF" >/dev/null <<EOF
$MARKER
[connection]
# 2 = disable
wifi.powersave = 2
EOF
ok "MAC randomization and Wi-Fi power saving off"

# --- Finish ------------------------------------------------------------------
if [ -n "$SSID" ] && nmcli -t -f NAME connection show 2>/dev/null | grep -qxF "$SSID"; then
  # A connection saved under the old settings keeps them (e.g. a random MAC).
  sudo nmcli connection delete "$SSID" >/dev/null
  ok "forgot saved network '$SSID'"
fi

echo
echo "Now SHUT DOWN fully (not restart), wait 10 seconds, and power on - a"
echo "warm restart can leave this chip's firmware stuck. Then connect with:"
echo "    nmcli --ask device wifi connect \"${SSID:-YourNetwork}\""
echo "5 GHz networks in 'nmcli device wifi list' and a higher SIGNAL than before"
echo "mean the NVRAM took effect. No Wi-Fi device at all afterwards:"
echo "    bash wifi-fix.sh --undo   then shut down/start again, and try"
echo "    bash wifi-fix.sh --no-nvram"
echo "Other trouble: bash net-diagnose.sh"
