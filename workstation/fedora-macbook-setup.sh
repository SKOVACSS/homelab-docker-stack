#!/usr/bin/env bash
# Post-install setup that turns a fresh Fedora KDE install on a 2016/2017
# MacBook Pro (MacBookPro13,x / 14,x - Touch Bar or not) into a management
# workstation for this homelab: RDP into the Windows Docker host, SSH, VS
# Code, pwsh, WireGuard. Also applies the hardware fixes these specific
# Macs need, none of which Fedora does for you (see workstation/README.md
# for what each one fixes and why).
#
# Run as your normal user (not root) - it calls sudo itself where needed,
# since some steps (Caps Lock -> Esc, ~/.ssh, ~/.local/bin) are per-user.
# Idempotent - safe to re-run. Re-run it once after the first reboot: the
# speaker driver has to be built against the kernel you're actually
# running, and the first run's `dnf upgrade` usually installs a newer one.
#
# Usage:
#   ./fedora-macbook-setup.sh [--server HOST] [--user WINDOWS_USER]
#                             [--wg-conf PATH] [--no-audio] [--no-codecs]
#
#   --server   LAN hostname/IP of the Windows Docker host. Writes a `homelab`
#              entry to ~/.ssh/config and makes it rdp-homelab's default.
#   --user     Your Windows account name on that host (default: $USER).
#   --wg-conf  A WireGuard peer config from security-stack
#              (wireguard/config/peerN/peerN.conf on the server) to import
#              into NetworkManager, for reaching the host away from home.
#   --no-audio   Skip building the internal speaker driver.
#   --no-codecs  Skip RPM Fusion / full ffmpeg / Intel VA-API driver.

set -euo pipefail

SERVER=""
WIN_USER="$USER"
WG_CONF=""
DO_AUDIO=1
DO_CODECS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --server)    SERVER="${2:?--server needs a value}"; shift 2 ;;
    --user)      WIN_USER="${2:?--user needs a value}"; shift 2 ;;
    --wg-conf)   WG_CONF="${2:?--wg-conf needs a value}"; shift 2 ;;
    --no-audio)  DO_AUDIO=0; shift ;;
    --no-codecs) DO_CODECS=0; shift ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '    \033[33mWARN\033[0m %s\n' "$*"; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not root - it uses sudo where needed." >&2
  exit 1
fi
if ! grep -q '^ID=fedora' /etc/os-release; then
  echo "This script targets Fedora (dnf, dracut, RPM Fusion). Stopping." >&2
  exit 1
fi

# Keep the Mac awake for the whole run. The system update takes a while,
# and on a MacBookPro13,2 the first run was left idle, blanked/slept, and
# never came back (these Macs can't reliably resume until the NVMe fix
# below is in place), forcing a hard power-off mid-update.
if [ -z "${HOMELAB_SETUP_INHIBITED:-}" ] && command -v systemd-inhibit >/dev/null 2>&1 \
   && systemd-inhibit --what=idle:sleep:handle-lid-switch true 2>/dev/null; then
  export HOMELAB_SETUP_INHIBITED=1
  exec systemd-inhibit --what=idle:sleep:handle-lid-switch \
    --who="fedora-macbook-setup.sh" --why="Installing updates - keep the Mac awake" \
    bash "$0" "$@"
fi

MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
case "$MODEL" in
  MacBookPro13,*|MacBookPro14,*) ok "Detected $MODEL" ;;
  *) warn "Detected '$MODEL', not a 2016/2017 MacBook Pro - the hardware fixes below may not apply." ;;
esac

FEDORA_VER="$(rpm -E %fedora)"
STATE_DIR=/var/lib/homelab-workstation
sudo mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
step "Wi-Fi fix (Touch Bar models' BCM43602)"
# Same fixes as running wifi-fix.sh by hand (WPA offload off, no MAC
# randomization, no power saving; no NVRAM) - done first so
# they're in place however you got online to run this. --no-reload: they
# take effect at the next reboot rather than dropping the connection this
# script is about to download over.
if bash "$(dirname "${BASH_SOURCE[0]}")/wifi-fix.sh" --no-reload; then :
else warn "wifi-fix.sh didn't apply (not a BCM43602 Mac, or files missing) - continuing"; fi

# ---------------------------------------------------------------------------
step "Updating the system"
sudo dnf upgrade --refresh -y

# ---------------------------------------------------------------------------
step "Installing base tools"
sudo dnf install -y \
  git curl wget htop btop tmux vim-enhanced \
  remmina remmina-plugins-rdp freerdp \
  wireguard-tools openssh-clients \
  thermald \
  dkms kernel-devel kernel-headers gcc make patch wget \
  libva-utils
sudo systemctl enable --now thermald
ok "thermald running (Intel thermal management - keeps the fans/clock sane)"

# ---------------------------------------------------------------------------
if [ "$DO_CODECS" -eq 1 ]; then
  step "Enabling RPM Fusion + full ffmpeg + Intel VA-API driver"
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    sudo dnf install -y \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm"
  fi
  if rpm -q ffmpeg-free >/dev/null 2>&1; then
    sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
  fi
  sudo dnf install -y intel-media-driver
  if vainfo 2>/dev/null | grep -qi 'H264'; then
    ok "Hardware H.264 decode available (RDP AVC444 mode will use the GPU)"
  else
    warn "vainfo doesn't list H.264 yet - re-check after a reboot with: vainfo | grep H264"
  fi
fi

# ---------------------------------------------------------------------------
step "Installing VS Code and PowerShell 7 (Microsoft repos)"
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
if [ ! -f /etc/yum.repos.d/vscode.repo ]; then
  sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
fi
if [ ! -f /etc/yum.repos.d/microsoft-prod.repo ]; then
  # Microsoft doesn't publish a Fedora repo for PowerShell; the RHEL 9 one
  # is what their own install docs point Fedora users at.
  curl -fsSL https://packages.microsoft.com/config/rhel/9/prod.repo \
    | sudo tee /etc/yum.repos.d/microsoft-prod.repo >/dev/null
fi
sudo dnf install -y code
sudo dnf install -y powershell || warn "PowerShell install failed - see https://learn.microsoft.com/powershell/scripting/install/install-rhel"

# ---------------------------------------------------------------------------
step "Keyboard/trackpad drivers in the initramfs (disk-encryption prompt)"
# The internal keyboard and trackpad hang off Apple's SPI bus, not USB.
# Without these in the initramfs the keyboard is dead at the LUKS
# passphrase prompt, before the real root filesystem (and its modules)
# is available. Harmless if the disk isn't encrypted. Module names
# are filtered against what this kernel actually ships, since dracut
# treats a missing add_drivers module as an error.
MODS=""
for m in applespi intel_lpss_pci spi_pxa2xx_platform spi_pxa2xx_pci; do
  if modinfo "$m" >/dev/null 2>&1; then MODS="$MODS $m"; fi
done
CONF=/etc/dracut.conf.d/10-macbook-keyboard.conf
WANT="add_drivers+=\"${MODS} \""
if [ "$(cat "$CONF" 2>/dev/null)" != "$WANT" ]; then
  echo "$WANT" | sudo tee "$CONF" >/dev/null
  sudo dracut -f --regenerate-all
  ok "initramfs rebuilt with:${MODS}"
else
  ok "already configured (${MODS# })"
fi

# ---------------------------------------------------------------------------
step "Suspend/resume fix for the Apple NVMe SSD"
# 2016/2017 MacBook Pros fail to wake from suspend (or the SSD vanishes on
# resume) when the kernel lets the Apple NVMe controller enter D3cold.
# The controller is found through the NVMe driver (/sys/class/nvme) rather
# than by PCI class: on a MacBookPro13,2 it doesn't report the standard
# NVMe class code, so a class match silently found nothing. The udev rule
# then matches that exact Apple vendor/device ID, so it survives slot
# renumbering.
RULE=/etc/udev/rules.d/90-apple-nvme-d3cold.rules
RULES=""
for ctrl in /sys/class/nvme/nvme*; do
  [ -e "$ctrl/device" ] || continue
  dev="$(readlink -f "$ctrl/device")"
  [ -f "$dev/vendor" ] || continue
  if [ "$(cat "$dev/vendor")" = "0x106b" ]; then
    id="$(cat "$dev/device")"
    RULES="${RULES}ACTION==\"add\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"0x106b\", ATTR{device}==\"$id\", ATTR{d3cold_allowed}=\"0\"
"
    echo 0 | sudo tee "$dev/d3cold_allowed" >/dev/null
    ok "d3cold disabled on $(basename "$dev") (Apple NVMe $id)"
  fi
done
if [ -n "$RULES" ]; then
  printf '%s' "$RULES" | sudo tee "$RULE" >/dev/null
  ok "udev rule written to $RULE (applies at every boot)"
else
  sudo rm -f "$RULE"
  warn "no Apple NVMe controller found - not applied (check: lspci -nn | grep -i 106b)"
fi

# ---------------------------------------------------------------------------
step "Caps Lock -> Esc (the Touch Bar's Esc is unreliable on Linux)"
if command -v kwriteconfig6 >/dev/null 2>&1; then
  kwriteconfig6 --file kxkbrc --group Layout --key ResetOldOptions true
  kwriteconfig6 --file kxkbrc --group Layout --key Options caps:escape
  ok "set for KDE - takes effect at next login"
else
  warn "kwriteconfig6 not found (not KDE?) - set 'caps:escape' in your desktop's keyboard settings"
fi

# ---------------------------------------------------------------------------
if [ "$DO_AUDIO" -eq 1 ]; then
  step "Internal speakers (Cirrus CS8409 codec driver)"
  # Mainline's CS8409 driver only covers Dell machines; Apple's wiring of
  # the same codec needs davidjo's patched driver. Upstream has verified it
  # on MacBookPro13,1/13,3/14,3 but not 13,2 (13" Touch Bar), so on that
  # model it may build fine and still leave the speakers silent. It builds against the
  # running kernel's source, so it's skipped until you've rebooted into the
  # newest installed kernel.
  RUNNING="$(uname -r)"
  NEWEST="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)"
  if [ "$RUNNING" != "$NEWEST" ]; then
    warn "Running $RUNNING but $NEWEST is installed - reboot, then re-run this script for audio."
  elif [ -f "$STATE_DIR/audio-$RUNNING" ]; then
    ok "already built for $RUNNING"
  else
    sudo dnf install -y "kernel-devel-$RUNNING"
    TMP="$(mktemp -d)"
    git clone --depth 1 https://github.com/davidjo/snd_hda_macbookpro.git "$TMP/snd_hda_macbookpro"
    if (cd "$TMP/snd_hda_macbookpro" && sudo ./install.cirrus.driver.sh); then
      sudo touch "$STATE_DIR/audio-$RUNNING"
      ok "installed - reboot for sound"
    else
      warn "driver build failed - see https://github.com/davidjo/snd_hda_macbookpro for current instructions"
    fi
    rm -rf "$TMP"
  fi
fi

# ---------------------------------------------------------------------------
step "SSH key"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [ ! -f ~/.ssh/id_ed25519 ]; then
  echo "    Creating ~/.ssh/id_ed25519 - set a passphrase when asked (KDE Wallet can remember it)."
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "$USER@$(hostname -s)"
fi
ok "public key: $(cat ~/.ssh/id_ed25519.pub)"

if [ -n "$SERVER" ] && ! grep -q '^Host homelab$' ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config <<EOF

Host homelab
    HostName $SERVER
    User $WIN_USER
    IdentityFile ~/.ssh/id_ed25519
EOF
  chmod 600 ~/.ssh/config
  ok "added 'Host homelab' to ~/.ssh/config (ssh homelab)"
fi

# ---------------------------------------------------------------------------
step "rdp-homelab launcher"
mkdir -p ~/.local/bin
cat > ~/.local/bin/rdp-homelab <<EOF
#!/usr/bin/env bash
# Generated by workstation/fedora-macbook-setup.sh.
# Usage: rdp-homelab [HOST] [USER] [extra FreeRDP options...]
host="\${1:-${SERVER}}"; user="\${2:-${WIN_USER}}"
[ -n "\$host" ] || { echo "usage: rdp-homelab HOST [USER]" >&2; exit 1; }
shift \$(( \$# > 2 ? 2 : \$# ))
# SDL client first: it's native Wayland, so it stays sharp under KDE's
# fractional scaling where the X11 client (via XWayland) can go blurry.
for c in sdl-freerdp3 sdl-freerdp xfreerdp3 xfreerdp; do
  command -v "\$c" >/dev/null && exec "\$c" /v:"\$host" /u:"\$user" \\
    /gfx:AVC444 /dynamic-resolution /scale-desktop:200 +clipboard /cert:tofu "\$@"
done
echo "No FreeRDP client found - sudo dnf install freerdp" >&2; exit 1
EOF
chmod +x ~/.local/bin/rdp-homelab
ok "$HOME/.local/bin/rdp-homelab installed${SERVER:+ (default host: $SERVER)}"

# ---------------------------------------------------------------------------
if [ -n "$WG_CONF" ]; then
  step "Importing WireGuard peer config"
  NAME="$(basename "$WG_CONF" .conf)"
  if nmcli -t -f NAME connection show | grep -qx "$NAME"; then
    ok "'$NAME' already imported"
  else
    sudo nmcli connection import type wireguard file "$WG_CONF"
    # Imported connections auto-connect by default; this one should only
    # come up when you're away from home and ask for it.
    sudo nmcli connection modify "$NAME" connection.autoconnect no
    ok "imported as '$NAME' - toggle it from the network tray icon when away from home"
  fi
fi

# ---------------------------------------------------------------------------
step "Done"
cat <<EOF
    Next:
      1. Reboot, then re-run this script once (builds the speaker driver
         against the new kernel if it was skipped above).
      2. Add the public key above to the Windows host - see
         workstation/README.md ("Windows side"), which also covers
         _scripts/enable-remote-management.ps1 for OpenSSH + RDP.
      3. Connect:  ssh homelab   /   rdp-homelab
EOF
