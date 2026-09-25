#!/usr/bin/env bash
# Fixes the built-in Wi-Fi on 2015-2017 MacBook Pros with the Broadcom
# BCM43602 (every Touch Bar model, e.g. MacBookPro13,2) under Fedora.
# Works fully offline - run it from the USB kit before you have internet.
#
# What it changes (all reversible - see --undo):
#   1. brcmfmac feature_disable=0x82000 - turns off the firmware's broken
#      WPA offload (WPA2 logins failing as "password incorrect").
#   2. NetworkManager: no MAC randomization (brcmfmac mishandles it), and
#      Wi-Fi power saving off (stalls/drops on this chip).
#   3. Installs the board's NVRAM calibration file (firmware/brcmfmac43602-
#      pcie.txt, from Apple's Boot Camp driver), which linux-firmware
#      lacks. Without it the firmware never settles on a country: 2.4 GHz
#      only (no 5 GHz band at all) and a weak signal. On a MacBookPro13,2
#      it took Wi-Fi from ~1 Mbps on 2.4 GHz to ~47 Mbps on 5 GHz.
#      The chip has no MAC address of its own on these boards - it uses the
#      NVRAM's macaddr= line - so that line must stay: without it the
#      firmware crashes on load ("Retrieving cur_etheraddr failed",
#      "Firmware has halted or crashed"). Rather than the file's shared
#      placeholder (00:90:4c:0d:f4:3e), it's set to an address unique to
#      this Mac, derived from its hardware UUID so it survives reinstalls
#      (or pass --mac to use a specific one, e.g. its old macOS address).
# Then it reloads the driver so the changes apply without a reboot.
#
# Usage:  bash wifi-fix.sh [--ssid NAME] [--mac XX:XX:XX:XX:XX:XX]
#                          [--no-nvram] [--no-reload] [--undo]
#   --ssid NAME  Forget and reconnect to this network afterwards (asks for
#                the password).
#   --mac ADDR   Use this Wi-Fi MAC address instead of the derived one.
#   --no-nvram   Skip step 3 (and remove an NVRAM this script installed).
#   --no-reload  Don't reload the driver now; changes apply at next boot.
#   --undo       Remove everything this script installed.
#
# If Wi-Fi later drops and won't come back (the firmware occasionally
# hangs - `sudo dmesg | grep brcmf` shows "timed out waiting for
# txstatus" / "bus is down"), reloading the driver recovers it:
#   sudo modprobe -r brcmfmac_wcc brcmfmac; sudo modprobe brcmfmac

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

SSID=""; MAC=""; DO_NVRAM=1; DO_RELOAD=1; UNDO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ssid)      SSID="${2:?--ssid needs a value}"; shift 2 ;;
    --mac)       MAC="${2:?--mac needs a value}"; shift 2 ;;
    --nvram)     DO_NVRAM=1; shift ;;  # the default; kept for older instructions
    --no-nvram)  DO_NVRAM=0; shift ;;
    --no-reload) DO_RELOAD=0; shift ;;
    --undo)      UNDO=1; shift ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
done

ok()   { printf '  \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }

reload_driver() {
  echo "Reloading the Wi-Fi driver (Wi-Fi drops for a few seconds)..."
  sudo modprobe -r brcmfmac_wcc 2>/dev/null || true
  sudo modprobe -r brcmfmac 2>/dev/null || true
  sleep 1
  sudo modprobe brcmfmac
  sudo systemctl restart NetworkManager
  # The firmware takes a variable few seconds to come up.
  for _ in $(seq 1 30); do
    if nmcli -t -f TYPE device 2>/dev/null | grep -qx wifi; then
      ok "driver reloaded, Wi-Fi device is back"; return 0
    fi
    sleep 1
  done
  warn "no Wi-Fi device after 30 s - see: sudo dmesg | grep -i brcmf | tail -20"
  return 1
}

if [ "$UNDO" -eq 1 ]; then
  for f in "$MODPROBE_CONF" "$NM_CONF" "$NM_PS_CONF" "$NVRAM_DEST"; do
    if [ -f "$f" ] && sudo grep -qF "$MARKER" "$f"; then
      sudo rm -f "$f"; ok "removed $f"
    fi
  done
  if [ "$DO_RELOAD" -eq 1 ]; then reload_driver || true; fi
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

# --- NVRAM ------------------------------------------------------------------
PLACEHOLDER_MAC="00:90:4c:0d:f4:3e"
if [ "$DO_NVRAM" -eq 1 ]; then
  if [ ! -f "$NVRAM_SRC" ]; then
    warn "brcmfmac43602-pcie.txt not found in $HERE/firmware/ or $HERE/ - copy it from the kit and re-run"
    exit 1
  fi
  if [ -z "$MAC" ]; then
    # Locally administered unicast (02:...), stable per machine.
    SEED="$(sudo cat /sys/class/dmi/id/product_uuid 2>/dev/null || cat /etc/machine-id)"
    H="$(printf '%s' "$SEED" | sha256sum | cut -c1-10)"
    MAC="02:${H:0:2}:${H:2:2}:${H:4:2}:${H:6:2}:${H:8:2}"
  fi
  MAC="$(printf '%s' "$MAC" | tr 'A-F' 'a-f')"
  if ! printf '%s' "$MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
    echo "--mac: '$MAC' isn't a MAC address (expected XX:XX:XX:XX:XX:XX)" >&2
    exit 1
  fi
  # Replace a file this script installed, or a verbatim manual copy of the
  # same NVRAM (recognisable by the shared placeholder MAC); leave any
  # other NVRAM alone.
  if [ -e "$NVRAM_DEST" ] && ! sudo grep -qF "$MARKER" "$NVRAM_DEST" \
     && ! sudo grep -qx "macaddr=$PLACEHOLDER_MAC" "$NVRAM_DEST"; then
    warn "$NVRAM_DEST already exists and isn't ours - leaving it alone"
  else
    TMP="$(mktemp)"
    { echo "$MARKER"; sed "s/^macaddr=.*/macaddr=$MAC/" "$NVRAM_SRC"; } > "$TMP"
    sudo install -Dm644 "$TMP" "$NVRAM_DEST"
    rm -f "$TMP"
    ok "NVRAM installed to $NVRAM_DEST (Wi-Fi MAC: $MAC)"
  fi
elif [ -f "$NVRAM_DEST" ] && sudo grep -qF "$MARKER" "$NVRAM_DEST"; then
  sudo rm -f "$NVRAM_DEST"
  ok "removed previously installed NVRAM (--no-nvram)"
fi

# --- Driver option -----------------------------------------------------------
printf '%s\noptions brcmfmac feature_disable=0x82000\n' "$MARKER" | sudo tee "$MODPROBE_CONF" >/dev/null
ok "brcmfmac feature_disable=0x82000"

# --- NetworkManager ----------------------------------------------------------
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
# Also pin it on every saved Wi-Fi connection: a per-connection setting
# (or Fedora's own stable-ssid default) otherwise still randomizes the MAC,
# as seen on a MacBookPro13,2 - which breaks DHCP reservations.
while IFS=: read -r name type; do
  if [ "$type" = "802-11-wireless" ]; then
    sudo nmcli connection modify "$name" 802-11-wireless.cloned-mac-address permanent 2>/dev/null || true
  fi
done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
ok "MAC randomization and Wi-Fi power saving off"

# --- Apply -------------------------------------------------------------------
if [ "$DO_RELOAD" -eq 1 ]; then
  reload_driver || exit 1
else
  echo "Changes apply at next boot."
fi

if [ -n "$SSID" ]; then
  # A connection saved while the old settings were active keeps them
  # (e.g. a random MAC), so start it over.
  if nmcli -t -f NAME connection show | grep -qxF "$SSID"; then
    sudo nmcli connection delete "$SSID" >/dev/null
  fi
  if [ "$DO_RELOAD" -eq 1 ]; then
    nmcli device wifi rescan 2>/dev/null || true
    sleep 3
    nmcli --ask device wifi connect "$SSID"
  else
    echo "After booting, connect with: nmcli --ask device wifi connect \"$SSID\""
  fi
fi

if [ "$DO_RELOAD" -eq 1 ]; then
  echo
  nmcli -f IN-USE,SSID,CHAN,SIGNAL,SECURITY device wifi list 2>/dev/null | head -8 || true
fi
echo
echo "Trouble? bash net-diagnose.sh"
