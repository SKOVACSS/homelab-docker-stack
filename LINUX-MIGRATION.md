# Moving the server from Windows 11 to Linux

Status: **plan - nothing has been changed yet.** Written 2026-10-02.

## Why now

One of the two 20 TB drives has to be taken out, wiped and re-added anyway
(Storage Spaces marked it failed after a loose-cable episode and will not
take it back). A wiped 20 TB drive is exactly what a migration needs as its
staging disk, so the two jobs are combined.

What goes away on Linux: Docker Desktop and its WSL2 VM (the engine
stopping, a 250 GB virtual disk on C:, 6-8 GB of RAM lost to the VM), the
NAT that hides every LAN device behind one address (the cause of the
Pi-hole rate-limit and DNS-loop incidents), and Storage Spaces (ran degraded
for days without telling anyone).

## Target

| | Now | After |
|---|---|---|
| OS | Windows 11 Pro + Docker Desktop (WSL2) | Ubuntu Server 26.04 LTS + Docker Engine |
| Boot disk | 500 GB NVMe | the spare 256 GB SATA SSD first (Windows NVMe kept as a fallback), NVMe later |
| Bulk storage | Storage Spaces two-way mirror, NTFS | ZFS mirror (`tank`), checksummed, snapshots |
| Docker data | `docker_data.vhdx` on C: | `/var/lib/docker` on the SSD |
| Scheduling | Task Scheduler | systemd timers |
| Off-site backup | Restic repo synced by the Proton Drive app | Restic repo uploaded with the Proton Drive CLI |
| Admin access | Claude desktop app on the server | SSH + Claude Code CLI |

## Hardware compatibility

Inventory taken from the running server on 2026-10-02.

| Part | Linux driver | Verdict |
|---|---|---|
| Ryzen 7 9700X | in kernel | Fine. |
| MSI MAG X870 Tomahawk WiFi, BIOS 1.A10 (Aug 2024) | - | Works. **Update the BIOS first** - this is the launch BIOS; later ones carry AGESA fixes for Ryzen 9000 and DDR5 stability (the RAM runs at 4800 with XMP off because of earlier crashes). |
| Intel Arc B580 (8086:e20b) | `xe`, kernel 6.12+ | Supported natively - no more WSL `/dev/dxg` passthrough. Video encode via VA-API/QSV (Jellyfin, Plex, Tdarr); compute via Level Zero/OpenCL (vLLM, Immich ML). **The one item to prove in advance** - see the check below. |
| AMD integrated graphics (1002:13c0) | `amdgpu` | Fine; gives a console even if the Arc driver misbehaves. |
| Realtek RTL8126 5 GbE (10ec:8126) - the port in use | `r8169`, kernel 6.9+ | Fine on 26.04. |
| Intel I350 quad gigabit (8086:1521) | `igb` | Rock solid; a fallback NIC if the Realtek port gives trouble. |
| Qualcomm FastConnect 7800 Wi-Fi 7 / Bluetooth | `ath12k`, `btusb` | Supported; unused on a wired server. |
| ASMedia ASM1064 SATA (both 20 TB drives) | `ahci` | Fine. |
| AMD chipset SATA (1022:43f6) | `ahci` | Fine; a second controller to move the suspect drive to. |
| WD SN850X NVMe | `nvme` | Fine. |
| ASMedia USB4 | `thunderbolt`/`xhci` | Fine. |
| Fan and temperature sensors (Nuvoton NCT6687D on MSI) | `nct6683` (read-only) or out-of-tree `nct6687d` | CPU temperature works out of the box. **Fan speeds need the `nct6687d` module** (DKMS). Worth doing given the case-fan history. |
| Seagate IronWolf Pro 20 TB x2 | SMART via `smartctl` | Fine; Scrutiny reads them directly from its container. |

### Proving it before committing: `_scripts/linux/hw-check.sh`

Boot the server from an Ubuntu 26.04 live USB, choose **Try Ubuntu**
(nothing is installed, no disk is written), plug in the network cable and
run:

```bash
sudo bash hw-check.sh | tee hw-check-report.txt
```

It reports PASS/WARN/FAIL for: kernel version, the driver bound to every
device above, Arc hardware encode and compute, NIC link, SMART health and
cable-error counts for each drive, sensors, and UEFI boot. **No FAIL lines
is the go/no-go for the migration.** It is also the cleanest test of the
suspect drive's cable: run it twice a few minutes apart and compare the
cable-CRC-errors count.

## The sequence

Each phase ends in a state you can stop at. Windows stays bootable until
phase 6.

**0. Preparation (no downtime)**
- Update the motherboard BIOS.
- Run `hw-check.sh` from a live USB.
- Finish the script port (below) and merge it.
- Make sure last night's backup and off-site copy succeeded; note the
  Restic password somewhere outside the server.
- Copy anything irreplaceable that lives only on D: and is not in the
  backup to a third disk (the 6 TB BarraCuda).

**1. Free the staging drive (Windows running)**
- Power off, pull the retired drive (serial ending 9L01), `diskpart clean`
  it on another PC, refit it on a **different SATA cable and port** (the
  AMD controller rather than the ASMedia one).

**2. First copy (Windows running, apps up) - about a day**
- Format it as plain NTFS (`E:`), then
  `robocopy D:\ E:\ /MIR /COPY:DAT /DCOPY:T /R:1 /W:1 /MT:8 /XD "System Volume Information" "$RECYCLE.BIN"`.
- This is also the load test for that drive and cable. **Any I/O error or
  dropout here stops the migration** - fix the hardware first.
- Stop the stacks, run robocopy once more to catch changes, then leave the
  apps stopped.

**3. Install Linux - about an hour**
- Fit the 256 GB SATA SSD; unplug nothing else. Install Ubuntu Server
  26.04 LTS on it (OpenSSH on, no LVM encryption needed).
- Docker Engine + Compose plugin, PowerShell 7, ZFS, Intel GPU runtime
  (`intel-media-va-driver-non-free`, `intel-opencl-icd`, Level Zero),
  smartmontools, Tailscale, Claude Code.
- Free port 53 for Pi-hole: `DNSStubListener=no` in systemd-resolved.

**4. New storage - about a day**
- Create the pool on the *other* 20 TB drive (the healthy one, now free):
  `zpool create -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa tank <disk-by-id>`.
- Mount the NTFS staging drive read-only and `rsync -aHAX --info=progress2`
  everything into `tank` datasets (`tank/media`, `tank/backups`,
  `tank/apps`, `tank/sites`).
- **This is the exposed step:** for about a day the only complete copy is
  on the staging drive. Media can be re-downloaded and configs, databases
  and photos are in the off-site backup, but nothing else is.

**5. Bring the apps up - about half a day**
- Check out the repo to `/opt/homelab`, copy each stack's `.env` from the
  backup's `config\` folder and rewrite the paths (`D:\Media\...` ->
  `/tank/media/...`).
- Restore every Docker volume from the newest nightly backup
  (`volumes/<name>/data.tar.gz`) and the databases from their dumps -
  the restore test already proves these are usable.
- `docker compose up -d` stack by stack: caddy, authentik, dns, then the rest.
- Install the systemd timers.

**6. Complete the mirror - about a day, apps running**
- Once everything has been verified for a few days: wipe the staging
  drive and `zpool attach tank <healthy-disk> <staging-disk>`. ZFS
  resilvers and checksums every block; a bad cable shows up as checksum
  errors in `zpool status` instead of a silent dropout.
- Only now is the Windows NVMe free to be reused.

**Rollback** at any point up to step 4: boot the NVMe; Windows and the
degraded Storage Spaces mirror are untouched. After step 4 the healthy
drive has been reformatted, so rollback means restoring from the staging
drive.

## What has to be ported

| Item | Windows-specific today | On Linux |
|---|---|---|
| `backup.ps1`, `test-restore.ps1`, `check-model-updates.ps1`, `configure-qbittorrent.ps1` | backslash paths, `$env:TEMP`, `D:\` defaults | Same scripts under PowerShell 7 once the paths are made portable. |
| `check-storage.ps1` | `Get-PhysicalDisk`, `Get-VirtualDisk` | `df` + `zpool status -x` + `smartctl`. |
| Off-site upload | Proton Drive desktop app watching a folder | Proton Drive CLI: upload new Restic files after each backup, then verify. |
| Scheduled tasks (backup 02:00, restore test 4-weekly, storage check 30 min, qBittorrent hourly, model check weekly) | Task Scheduler | systemd timers (`_scripts/linux/systemd/`). |
| `heal-network-dependents.ps1` | works around Docker Desktop recreating networks | Probably unnecessary; keep disabled, re-enable if needed. |
| `compact-wsl-disks.ps1`, autologon + lock task, `.wslconfig` | WSL/Windows only | Dropped. |
| GPU passthrough in `ai-stack` and `immich-app` | `/dev/dxg` + `/usr/lib/wsl` | `/dev/dri` devices and the `render` group. vLLM and Immich ML need their compose device sections switched. |
| Scrutiny collector | separate Windows task feeding the container | The container reads the drives itself (`--device`, `SYS_RAWIO`). |
| Pi-hole | all clients appear as 172.20.0.1 | Real client addresses: per-client stats work and the rate limit can go back on. |
| Media/app paths in every `.env` | `D:\...` | `/tank/...` |

## Open decisions

1. **Distro:** Ubuntu Server 26.04 LTS is assumed (ZFS in the stock
   kernel, long support, kernel new enough for the B580). Debian 13 with
   backports is the alternative.
2. **Boot disk:** start on the 256 GB SATA SSD (keeps Windows as a
   fallback) and move to the NVMe later, or wipe the NVMe straight away.
3. **Third 20 TB drive** (broken connector): if repaired first, step 4's
   exposed day disappears - it can hold a second copy.
