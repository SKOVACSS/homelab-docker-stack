# Platform-Specific Configuration

This guide explains how to set up your Docker setup on different operating systems and how paths differ.

---

## Windows Setup

### Paths Format
Use **forward slashes** or **double backslashes** in `.env`:
```
# Both work:
MEDIA_MOVIES=D:\Media\Movies
MEDIA_MOVIES=D:/Media/Movies
```

### .env Example (Windows)
```env
DOMAIN=yourdomain.com

# Paths on Windows - see _scripts/setup-directories.ps1 for what creates these
QBIT_DOWNLOADS_PATH=D:\Media\Downloads
MEDIA_MOVIES=D:\Media\Movies
MEDIA_TV=D:\Media\TV
MEDIA_MUSIC=D:\Media\Music
MEDIA_BOOKS=D:\Media\Books
MEDIA_PHOTOS=D:\Media\Photos

# Plex
PLEX_CLAIM_TOKEN=claim-xxx
PLEX_DOMAIN=plex.yourdomain.com

# Jellyfin
JELLYFIN_DOMAIN=jellyfin.yourdomain.com
```

### Directory Structure (Windows)
```
C:\DockerApplications\           # Or any drive: D:, E:, etc.
├── caddy/
├── authentik/
├── media-stack/
├── utilities/
└── .env

D:\Media\                         # Can be different drive from Docker
├── Movies/
├── TV/
├── Music/
├── Books/
├── Photos/
└── Downloads/
```

### Special Considerations
- **Docker Desktop required** (not Docker CLI alone)
- **WSL 2 backend recommended** for best performance
- **Path length limit:** Windows has 260 character limit (unless disabled)
- **Permissions:** Docker runs as your user; ensure read/write access to paths

### Check Paths Work
```powershell
# Verify paths exist and are accessible
Test-Path D:\Media\Movies
Test-Path D:\Media\Downloads

# Show disk usage
Get-Volume | Select-Object DriveLetter, Size, SizeRemaining | Format-Table
```

---

## Linux Setup

### Paths Format
Always use **forward slashes**:
```
MEDIA_MOVIES=/mnt/media/movies
QBIT_DOWNLOADS_PATH=/mnt/downloads/qbittorrent
```

### .env Example (Linux)
```env
DOMAIN=yourdomain.com

# Paths on Linux
QBIT_DOWNLOADS_PATH=/mnt/downloads/qbittorrent
MEDIA_MOVIES=/mnt/media/movies
MEDIA_TV=/mnt/media/tv
MEDIA_MUSIC=/mnt/media/music
MEDIA_BOOKS=/mnt/media/books
MEDIA_PHOTOS=/mnt/media/photos

# Plex
PLEX_CLAIM_TOKEN=claim-xxx
PLEX_DOMAIN=plex.yourdomain.com

# Jellyfin
JELLYFIN_DOMAIN=jellyfin.yourdomain.com
```

### Directory Structure (Linux)

#### Option A: Local Directories
```
/opt/docker-apps/                # Or ~/docker-apps
├── caddy/
├── authentik/
├── media-stack/
├── utilities/
└── .env

/mnt/media/                       # NFS mount or local storage
├── movies/
├── tv/
├── music/
├── books/
├── photos/
└── qbittorrent-downloads/
```

#### Option B: NAS (Synology, QNAP)
```
/docker-apps/                     # On NAS
├── caddy/
├── authentik/
├── media-stack/
├── utilities/
└── .env

/volume1/media/                   # Synology NAS path
├── movies/
├── tv/
├── music/
├── books/
├── photos/
└── qbittorrent-downloads/

# Or mount remote NAS
/mnt/nas/media/                   # Mounted via NFS/SMB
```

### Installation Steps (Ubuntu/Debian)
```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
newgrp docker

# Create directories
sudo mkdir -p /opt/docker-apps
sudo mkdir -p /mnt/media/{movies,tv,music,books,photos,qbittorrent-downloads}

# Set permissions (if using non-root user)
sudo chown -R $USER:$USER /opt/docker-apps
sudo chown -R $USER:$USER /mnt/media

# Clone repository or set up files
cd /opt/docker-apps
```

### NAS-Specific (Synology)
```bash
# SSH into Synology
ssh admin@synology-ip

# Create directories
mkdir -p /volume1/docker-apps
mkdir -p /volume1/media/{movies,tv,music,books,photos}

# Set permissions
sudo chown -R 1000:1000 /volume1/media

# Install Docker (via Package Manager or direct install)
# Then follow Linux steps above
```

### Check Paths Work (Linux)
```bash
# Verify paths exist
ls -la /mnt/media/movies
ls -la /mnt/media/qbittorrent-downloads

# Show disk usage
df -h /mnt/media/
du -sh /mnt/media/*

# Check permissions
ls -la /opt/docker-apps
```

---

## macOS Setup

### Paths Format
Use **forward slashes**:
```
MEDIA_MOVIES=/Users/username/media/movies
QBIT_DOWNLOADS_PATH=/Users/username/downloads/qbittorrent
```

### .env Example (macOS)
```env
DOMAIN=yourdomain.com

# Paths on macOS
QBIT_DOWNLOADS_PATH=/Users/username/downloads/qbittorrent
MEDIA_MOVIES=/Users/username/media/movies
MEDIA_TV=/Users/username/media/tv
MEDIA_MUSIC=/Users/username/media/music
MEDIA_BOOKS=/Users/username/media/books
MEDIA_PHOTOS=/Users/username/media/photos

# Or use external drive
MEDIA_MOVIES=/Volumes/external-drive/media/movies
MEDIA_TV=/Volumes/external-drive/media/tv

# Plex
PLEX_CLAIM_TOKEN=claim-xxx
PLEX_DOMAIN=plex.yourdomain.com

# Jellyfin
JELLYFIN_DOMAIN=jellyfin.yourdomain.com
```

### Directory Structure (macOS)

#### Option A: User Home Directory
```
~/docker-apps/                    # or /Users/username/docker-apps
├── caddy/
├── authentik/
├── media-stack/
├── utilities/
└── .env

~/media/                          # or /Users/username/media
├── movies/
├── tv/
├── music/
├── books/
├── photos/
└── qbittorrent-downloads/
```

#### Option B: External Drive
```
/Volumes/external-drive/
├── docker-apps/
│   ├── caddy/
│   ├── authentik/
│   ├── media-stack/
│   ├── utilities/
│   └── .env
└── media/
    ├── movies/
    ├── tv/
    ├── music/
    ├── books/
    ├── photos/
    └── qbittorrent-downloads/
```

### Installation Steps (macOS)

#### Option A: Docker Desktop (Easiest)
```bash
# Download from: https://www.docker.com/products/docker-desktop
# Or use Homebrew
brew install --cask docker

# Start Docker Desktop (from Applications)
# Then verify
docker --version
```

#### Option B: Homebrew + Colima
```bash
# Lightweight alternative to Docker Desktop
brew install colima docker

# Start Colima
colima start

# Verify
docker --version
```

### Check Paths Work (macOS)
```bash
# Verify paths exist
ls -la ~/media/movies
ls -la /Volumes/external-drive/media/

# Show disk usage
du -sh ~/media/*
df -h /Volumes/external-drive

# Check permissions
ls -la ~/docker-apps
```

### M1/M2 Apple Silicon Notes
- Most Docker images work, but some older images may not
- Use `arm64` compatible images (most modern ones are)
- If you see platform errors, try adding to compose:
```yaml
services:
  sonarr:
    image: ghcr.io/hotio/sonarr:latest
    platform: linux/arm64
```

---

## Path Migration Between Platforms

If moving from Windows to Linux (or vice versa):

### Step 1: Export Current Setup
```powershell
# On Windows
cd _scripts
.\backup.ps1 -Action backup -Full
```

### Step 2: Update Paths in .env
**Windows paths:**
```
MEDIA_MOVIES=D:\Media\Movies
MEDIA_TV=D:\Media\TV
```

**To Linux paths:**
```
MEDIA_MOVIES=/mnt/media/movies
MEDIA_TV=/mnt/media/tv
```

### Step 3: Copy Data
```bash
# Copy media files to new location
rsync -av /old/media/ /new/media/

# Or use Synology (if target)
# Via SMB/NFS mount on old machine
```

### Step 4: Restore Setup
On the new machine, copy the repo + your `.env` files, adjust paths per
this guide, then:
```powershell
cd _scripts
.\deploy.ps1 -Action deploy
```

---

## Synology NAS Specific (Popular Home Lab Choice)

### Why Synology?
- Always on, low power
- Built-in backup (Hyper Backup)
- NAS RAID protection
- Can stream 4K to multiple users
- Much cheaper than server hardware

### Setup on Synology

#### 1. Enable Docker
```
Control Panel → File Services → enable NFS (for Linux mounts)
Package Center → Install Docker
```

#### 2. Create Share for Docker
```
Control Panel → Shared Folder → Create
Name: docker-apps
Location: volume1
Permissions: your-user (Read/Write)
```

#### 3. Create Share for Media
```
Control Panel → Shared Folder → Create
Name: media
Location: volume1
Permissions: your-user (Read/Write)
```

#### 4. SSH Setup
```bash
# SSH into Synology (enable SSH first in Control Panel)
ssh admin@synology-ip

# Navigate to docker folder
cd /volume1/docker-apps

# Follow Linux setup steps
```

#### 5. .env on Synology
```
DOMAIN=yourdomain.com
QBIT_DOWNLOADS_PATH=/volume1/media/qbittorrent-downloads
MEDIA_MOVIES=/volume1/media/movies
MEDIA_TV=/volume1/media/tv
MEDIA_MUSIC=/volume1/media/music
MEDIA_BOOKS=/volume1/media/books
MEDIA_PHOTOS=/volume1/media/photos
```

#### 6. Start Services
```bash
cd /volume1/docker-apps
docker compose up -d
```

#### 7. Backup Strategy
- Use Synology Hyper Backup for full NAS backup
- Also backup Docker volumes separately
- Test restore monthly

---

## Performance Tips by Platform

### Windows
- Use WSL 2 backend (not Hyper-V if possible)
- Store `DockerApplications` on SSD (C: drive)
- Store media on fast drive (SSD > HDD)
- Allocate sufficient RAM in Docker Desktop (≥4GB)

### Linux
- Store on fast storage (SSD or NVMe)
- Use NAS with NFS mount for media (faster than SMB)
- Enable Docker BuildKit: `export DOCKER_BUILDKIT=1`

### macOS
- Use external SSD for media (internal storage limited)
- M1/M2 faster than Intel
- Allocate sufficient RAM in Docker Desktop (≥4GB)

### Synology
- Use volume1 (usually fastest RAID)
- Don't mix OS caches with media
- Use dedicated drive pool for media if possible

---

## Troubleshooting Paths

### "Permission Denied" Error
```
Windows: Run Docker Desktop as Administrator
Linux: sudo chown -R 1000:1000 /path/to/media
macOS: Check file permissions: ls -la /path/to/media
```

### "Path Not Found"
```
Check path exists: ls /path/to/media
Check .env syntax: no spaces around =
Check drive mounted (external drives): df -h
```

### "Too Many Open Files" (Linux)
```
Increase limit: ulimit -n 65536
Permanent: edit /etc/security/limits.conf
```

---

## Summary Table

| OS | Best For | Media Path | Docker Path | Pros | Cons |
|-----|----------|-----------|-----------|------|------|
| Windows | Personal PC | `D:\Media` | `C:\DockerApplications` | Familiar UI | Limited CLI tools |
| Linux | Server/NAS | `/mnt/media` | `/opt/docker-apps` | Lightweight | CLI-heavy |
| macOS | Developer | `/Volumes/external` | `~/docker-apps` | Unix-like | Expensive hardware |
| Synology | Always-on NAS | `/volume1/media` | `/volume1/docker-apps` | Low power | Limited CPU |

---

**For your setup:** Windows PC works well. Consider Synology NAS as a future upgrade for always-on resilience.
