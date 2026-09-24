# Management Workstation (Fedora on a 2016 MacBook Pro)

How to turn an old MacBook Pro into a quick, low-maintenance terminal for
managing this homelab: Remote Desktop into the Windows Docker host, SSH
for the `_scripts/*.ps1` tooling, a local editor for this repo, and
WireGuard for doing all of that away from home.

Written for the known quirks of the **13" late-2016
MacBook Pro with four Thunderbolt 3 ports** - `MacBookPro13,2`, i5-6267U,
Iris 550, 8 GB, Touch Bar + T1 chip. The same steps apply to the other
2016/2017 models (`MacBookPro13,x`/`14,x`); most other Intel Macs need
fewer of the fixes below, not different ones.

## Why Fedora KDE, and not a custom kernel

What these Macs need from Linux is a *recent* mainline kernel - the
internal keyboard/trackpad (Apple SPI, `applespi`) and several other
drivers have only matured in recent releases - not a tuned one. Fedora
tracks new kernels within weeks, on a fully supported distro. Performance
kernels (CachyOS, XanMod) make no measurable difference on a dual-core
machine whose heavy lifting happens on the server.

KDE Plasma 6 on Wayland handles the 2560x1600 Retina panel's fractional
scaling (175-200%) well, and is lighter than GNOME on 8 GB. Fedora's
default zram swap stretches that further.

## 1. Before you start

Download ahead of time:

- **Fedora KDE Plasma Desktop ISO** (x86_64) -
  [fedoraproject.org/kde/download](https://fedoraproject.org/kde/download/).
  Verify its SHA256 against the `CHECKSUM` file next to it.
- **Fedora Media Writer** (or Rufus, in *DD Image* mode) to write it.

Have on hand:

- A **USB-C** stick (or a USB-A stick + adapter) - 4 GB or more.
- A **USB keyboard/mouse**, just in case the internal ones misbehave in
  the live session or at an encryption prompt.
- **A way online that isn't the built-in Wi-Fi**: a USB-C Ethernet
  adapter, or USB tethering from your phone. On the Touch Bar models the
  Wi-Fi often won't connect until it's fixed (see "Wi-Fi" below), and the
  fix needs the internet.
- Your **Wi-Fi password**, and a **WireGuard peer config** from the server
  (`security-stack/wireguard/config/peerN/peerN.conf`) on a second stick
  or somewhere you can download it from after install. Use a peer no other
  device already uses.
- A backup of anything you want from macOS - installing wipes the disk.

Nothing else needs pre-downloading: every package and driver in step 3
comes from Fedora, RPM Fusion, Microsoft or GitHub during setup.

## 2. Install

1. Plug in the stick, power on holding **Option (⌥)**, pick **EFI Boot**.
2. In the live session, check keyboard, trackpad and display before
   committing, and try Wi-Fi (see "Wi-Fi" below if it won't connect).
   No sound, a blank Touch Bar and no webcam are all expected.
   - The Fedora menu's **"Test this media"** entry may print
     `grub_efidisk_open: invalid buffer alignment` and/or report the
     result as **NA** - neither means the stick is bad. Recent Fedora
     ISOs don't embed the checksum that test reads; the SHA256 you
     checked on download is the real verification.
3. **Install to Hard Drive** -> erase the whole disk. OpenCore Legacy
   Patcher and macOS go with it; nothing on this Mac needs them. Its
   firmware is already final (Monterey was the last supported macOS), and
   there's no T2 chip or Secure Boot to deal with.
4. **Disk encryption (LUKS)** is worth enabling on a laptop that holds SSH
   keys to your server. If you do, keep the USB keyboard plugged in for
   the first boot: until step 3's script adds the SPI keyboard drivers to
   the initramfs, the built-in keyboard may not work at the passphrase
   prompt.

## 3. Post-install script

```bash
git clone https://github.com/SKOVACSS/homelab-docker-stack.git
cd homelab-docker-stack/workstation
./fedora-macbook-setup.sh --server 192.168.1.50 --user YourWindowsUser \
                          --wg-conf ~/Downloads/peer2.conf
```

(`--server`/`--user`/`--wg-conf` are optional - see `--help`.) Then
**reboot and run it once more**: the speaker driver has to be built
against the kernel you're actually running, and the first run's update
usually installs a newer one.

What it does:

| Step | Why |
|---|---|
| `dnf upgrade`, base tools, Remmina + FreeRDP, WireGuard tools | The client side of everything below. |
| `thermald` | Intel thermal management - keeps clocks and fans sane. |
| RPM Fusion, full `ffmpeg`, `intel-media-driver` | Hardware H.264 decode on the Iris 550, so RDP's AVC444 mode runs on the GPU instead of the CPU. |
| VS Code, PowerShell 7 | Edit this repo locally or over Remote-SSH; lint/dry-run the `.ps1` scripts. |
| SPI keyboard drivers into the initramfs | Built-in keyboard works at the LUKS prompt. |
| udev rule: Apple NVMe `d3cold_allowed=0` | These Macs otherwise fail to resume from suspend (SSD drops off the bus). |
| `brcmfmac feature_disable=0x82000` (BCM43602 only) | Touch Bar models' Wi-Fi firmware fails WPA logins without it. |
| Wi-Fi power saving off | The BCM43602's driver stalls/drops with it on. |
| Caps Lock -> Esc | The Touch Bar's Esc isn't dependable on Linux (see below). |
| `snd_hda_macbookpro` | Mainline's CS8409 codec driver only knows Dell's wiring; without this the speakers are silent. Not confirmed upstream on the 13" Touch Bar (`MacBookPro13,2`) - may still be silent there. |
| SSH key, `Host homelab`, `rdp-homelab` | One-word connections to the server. |
| WireGuard import (off by default) | Toggle it from the tray when away from home. |

Setting the display scale (System Settings -> Display) is left to you -
175% or 200% are the usual picks for this panel.

## 4. Windows side

On the Docker host, from an **elevated** PowerShell in `_scripts\`:

```powershell
.\enable-remote-management.ps1 -PublicKey "ssh-ed25519 AAAA... you@macbook"
```

(Paste the key the setup script printed.) This installs and starts
OpenSSH Server with PowerShell as its login shell, authorizes the key,
and enables Remote Desktop with NLA plus the H.264/AVC444 + GPU-encode
policies. RDP hosting needs Windows **Pro** or higher - on Home the
script sets up SSH only and says so.

Then from the laptop:

```bash
ssh homelab                 # run deploy.ps1 / health-check.ps1 there
rdp-homelab                 # full desktop; Remmina works too
# VS Code: install the "Remote - SSH" extension, then Connect to Host -> homelab
```

Web UIs (Portainer, Grafana, Uptime Kuma, Homepage) just work in Firefox.

**Away from home**, turn on the WireGuard connection first. Never publish
3389 or 22 through Caddy/Cloudflare Tunnel - see [SECURITY.md](../SECURITY.md).
The stock peer configs send *all* traffic through home
(`ALLOWEDIPS=0.0.0.0/0` in `security-stack/docker-compose.yml`); to route
only the LAN through it, change `AllowedIPs` in the imported connection
to your LAN's subnet (e.g. `192.168.1.0/24, 10.13.13.0/24`).

## Known gaps on this model

- **Wi-Fi (Touch Bar models)** - the BCM43602's firmware misdetects the
  country, so only 2.4 GHz networks show up and connecting often fails
  (`...was not in the scan list`, or an endless password prompt). In
  order, until one works:
  1. Connect to a **2.4 GHz** network from a terminal, which also avoids
     the scan-list race:
     `nmcli device wifi rescan; nmcli --ask device wifi connect "SSID"`
  2. Disable the firmware's WPA offload (the setup script makes this
     permanent; this applies it right now, live session included):
     ```bash
     echo 'options brcmfmac feature_disable=0x82000' | sudo tee /etc/modprobe.d/brcmfmac.conf
     sudo modprobe -r brcmfmac_wcc; sudo modprobe -r brcmfmac; sudo modprobe brcmfmac
     ```
  3. Set the router (or a guest network) to **WPA2**, not WPA3/mixed.
  4. Still failing: a board NVRAM file (`brcmfmac43602-pcie.txt`) that
     fixes the country detection exists, but reported results vary
     between boards - see
     [Dunedan/mbp-2016-linux](https://github.com/Dunedan/mbp-2016-linux#wi-fi).
     Use Ethernet/tethering in the meantime.
- **Speakers (13" Touch Bar, `MacBookPro13,2`)** - listed as not working
  upstream, even with the `snd_hda_macbookpro` driver the script builds.
  Plan on USB/Bluetooth audio or headphones.

- **Touch Bar** - the T1-era Touch Bar has no mainline driver; it may be
  blank or only partly working. The out-of-tree
  [macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver)
  (`apple-ib-tb`) can show F-keys. Caps Lock -> Esc covers the one key
  that matters most.
- **Webcam** - needs the out-of-tree `facetimehd` driver (available as a
  COPR); skipped since a management terminal rarely needs it.
- **Touch ID** - not supported.
- **Battery** - after nine-plus years, check it with
  `upower -i $(upower -e | grep BAT)` before trusting it away from a
  charger.

The community notes at
[Dunedan/mbp-2016-linux](https://github.com/Dunedan/mbp-2016-linux) track
the current state of every component on these models.
