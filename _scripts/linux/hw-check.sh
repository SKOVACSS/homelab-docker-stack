#!/usr/bin/env bash
# Hardware compatibility check for the Linux migration (LINUX-MIGRATION.md).
#
# Run from an Ubuntu live USB ("Try Ubuntu" - nothing is installed and no
# disk is written to) on the server itself, BEFORE migrating:
#
#   sudo bash hw-check.sh | tee hw-check-report.txt
#
# It only reads: which kernel driver claimed each device, whether the Arc
# GPU can do video encode and compute, whether the NICs link, what the
# drives' SMART data says, and whether fan/temperature sensors are visible.
# Each line is PASS / WARN / FAIL; the summary at the end is what matters.

set -u
PASS=0; WARN=0; FAIL=0
pass() { echo "  PASS  $*"; PASS=$((PASS + 1)); }
warn() { echo "  WARN  $*"; WARN=$((WARN + 1)); }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $* =="; }

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo (SMART and sensors need it)."; exit 1; fi

# Tools the live image may lack. Installed into the live session's RAM only.
need=()
for t in lspci:pciutils smartctl:smartmontools sensors:lm-sensors vainfo:vainfo ethtool:ethtool clinfo:clinfo; do
  command -v "${t%%:*}" >/dev/null 2>&1 || need+=("${t##*:}")
done
if [ ${#need[@]} -gt 0 ]; then
  echo "Installing into the live session: ${need[*]}"
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "${need[@]}" >/dev/null 2>&1 \
    || echo "  (could not install some tools - connect a network cable and re-run for full results)"
fi

section "System"
echo "  Kernel:  $(uname -r)"
echo "  Distro:  $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
echo "  Board:   $(cat /sys/class/dmi/id/board_vendor 2>/dev/null) $(cat /sys/class/dmi/id/board_name 2>/dev/null)"
echo "  BIOS:    $(cat /sys/class/dmi/id/bios_version 2>/dev/null) ($(cat /sys/class/dmi/id/bios_date 2>/dev/null))"
echo "  CPU:     $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
echo "  Memory:  $(free -g | awk '/^Mem:/ {print $2}') GB"
kmaj=$(uname -r | cut -d. -f1); kmin=$(uname -r | cut -d. -f2)
if [ "$kmaj" -gt 6 ] || { [ "$kmaj" -eq 6 ] && [ "$kmin" -ge 12 ]; }; then
  pass "kernel $(uname -r) is new enough for the Arc B580 (needs 6.12+)"
else
  fail "kernel $(uname -r) is too old for the Arc B580 (needs 6.12+) - use a newer release or the HWE kernel"
fi

section "Devices and their drivers"
# vendor:device -> what it is. Anything without a driver is a problem.
declare -A want=(
  [8086:e20b]="Intel Arc B580 (AI, transcoding)"
  [1002:13c0]="AMD integrated graphics"
  [10ec:8126]="Realtek 5GbE (the port in use)"
  [8086:1521]="Intel I350 quad gigabit"
  [17cb:1107]="Qualcomm Wi-Fi 7 (unused on a server)"
  [1b21:1064]="ASMedia SATA (both 20TB drives)"
  [1022:43f6]="AMD chipset SATA"
  [15b7:5006]="WD NVMe SSD"
)
for id in "${!want[@]}"; do
  line=$(lspci -nnk -d "$id" 2>/dev/null)
  if [ -z "$line" ]; then warn "${want[$id]} [$id] not found on the bus"; continue; fi
  drv=$(echo "$line" | awk -F': ' '/Kernel driver in use/ {print $2; exit}')
  if [ -n "$drv" ]; then pass "${want[$id]} -> driver '$drv'"
  elif [ "$id" = "17cb:1107" ]; then warn "${want[$id]} has no driver (not needed)"
  else fail "${want[$id]} [$id] has NO driver loaded"; fi
done

section "Arc B580"
if lspci -nnk -d 8086:e20b 2>/dev/null | grep -q 'driver in use: xe'; then
  pass "xe kernel driver loaded"
else
  fail "xe driver not loaded for the B580"
fi
render=""
for d in /sys/class/drm/renderD*; do
  [ -e "$d/device/vendor" ] && [ "$(cat "$d/device/vendor")" = "0x8086" ] && render="/dev/dri/$(basename "$d")"
done
if [ -n "$render" ]; then
  pass "render node $render"
  if command -v vainfo >/dev/null 2>&1; then
    va=$(vainfo --display drm --device "$render" 2>/dev/null)
    echo "$va" | grep -q 'VAEntrypointEncSlice' && pass "hardware video ENCODE available (Jellyfin/Plex/Tdarr)" || warn "no VA-API encode entrypoints (install intel-media-va-driver-non-free)"
    echo "$va" | grep -qi 'AV1' && pass "AV1 supported" || warn "AV1 not listed"
  fi
else
  fail "no Intel render node under /dev/dri"
fi
if command -v clinfo >/dev/null 2>&1 && clinfo -l 2>/dev/null | grep -qi 'arc\|intel'; then
  pass "OpenCL/compute runtime sees the GPU (vLLM, Immich ML)"
else
  warn "compute runtime not present in the live image (normal) - installed later with intel-opencl-icd / level-zero"
fi

section "Network"
for dev in /sys/class/net/*; do
  n=$(basename "$dev"); [ "$n" = lo ] && continue
  [ -e "$dev/device" ] || continue
  drv=$(basename "$(readlink -f "$dev/device/driver")" 2>/dev/null)
  state=$(cat "$dev/operstate" 2>/dev/null); speed=$(cat "$dev/speed" 2>/dev/null || echo "?")
  if [ "$state" = up ]; then pass "$n ($drv) link up at ${speed} Mb/s"; else echo "  info  $n ($drv) $state"; fi
done
ip -4 -o addr show scope global | grep -q . && pass "has an IPv4 address" || warn "no IPv4 address (cable in the 5GbE port?)"

section "Drives"
for d in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print $1}'); do
  info=$(smartctl -i "/dev/$d" 2>/dev/null)
  model=$(echo "$info" | awk -F': *' '/Device Model|Model Number/ {print $2; exit}')
  serial=$(echo "$info" | awk -F': *' '/Serial Number/ {print $2; exit}')
  [ -z "$model" ] && continue
  health=$(smartctl -H "/dev/$d" 2>/dev/null | awk -F': *' '/overall-health|SMART Health Status/ {print $2; exit}')
  crc=$(smartctl -A "/dev/$d" 2>/dev/null | awk '$1==199 {print $10}')
  realloc=$(smartctl -A "/dev/$d" 2>/dev/null | awk '$1==5 {print $10}')
  msg="/dev/$d $model ...${serial: -4}: health=${health:-n/a}${realloc:+ reallocated=$realloc}${crc:+ cable-CRC-errors=$crc}"
  case "$health" in PASSED|OK) pass "$msg" ;; *) warn "$msg" ;; esac
done
echo "  note  a cable-CRC-errors count that RISES between two runs means that drive's cable/port is bad"

section "Sensors (fan and temperature monitoring)"
modprobe nct6683 2>/dev/null; modprobe k10temp 2>/dev/null
if sensors 2>/dev/null | grep -qiE 'fan[0-9]+:'; then pass "fan speeds readable"
else warn "fan speeds not exposed by the stock driver (MSI boards need the nct6687d module, added during setup)"; fi
sensors 2>/dev/null | grep -qiE 'Tctl|Tdie' && pass "CPU temperature readable" || warn "CPU temperature not readable"

section "Boot"
[ -d /sys/firmware/efi ] && pass "booted in UEFI mode" || fail "booted in legacy BIOS mode - switch the USB to UEFI"
if command -v mokutil >/dev/null 2>&1; then echo "  info  Secure Boot: $(mokutil --sb-state 2>/dev/null | head -1)"; fi

echo
echo "================ SUMMARY: $PASS passed, $WARN warnings, $FAIL failed ================"
[ "$FAIL" -eq 0 ] && echo "No blockers found. Send hw-check-report.txt back for review." || echo "Blockers found - do not migrate yet. Send hw-check-report.txt back for review."
