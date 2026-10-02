#!/usr/bin/env bash
# Installs the systemd timers that replace the Windows scheduled tasks
# (Homelab_Daily_Backup, Homelab_Restore_Test, Homelab_Check_Storage,
# Homelab_Configure_qBittorrent, Homelab_Check_Model_Updates).
# Expects the live checkout at /opt/homelab and PowerShell 7 as /usr/bin/pwsh.
# Run with sudo. Safe to re-run.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/systemd"
command -v pwsh >/dev/null || { echo "PowerShell 7 (pwsh) is not installed."; exit 1; }
[ -d /opt/homelab/_scripts ] || { echo "/opt/homelab/_scripts not found."; exit 1; }
install -m 0644 "$src"/homelab-*.service "$src"/homelab-*.timer /etc/systemd/system/
chmod +x /opt/homelab/_scripts/linux/*.sh
systemctl daemon-reload
for t in "$src"/homelab-*.timer; do systemctl enable --now "$(basename "$t")"; done
systemctl list-timers 'homelab-*' --no-pager
