<#
.SYNOPSIS
Detects usable GPU hardware acceleration for Immich, Plex, and Jellyfin,
and writes the right *_HWACCEL / ML_IMAGE_SUFFIX values into each stack's
.env file - vendor-agnostic (NVIDIA/AMD/Intel) and safe with no GPU at all.

.DESCRIPTION
Run automatically by deploy.ps1 before every deploy, so this needs no
manual step and stays correct if hardware changes later. Also safe to run
standalone for troubleshooting (-WhatIf shows what it would write without
touching any .env file).

Why this exists rather than one hardcoded device mapping: hardware
transcoding/ML acceleration in Docker needs a genuinely different
device/runtime setup per GPU vendor (NVIDIA's --gpus/nvidia-container-
toolkit vs AMD/Intel's /dev/dri render node vs, on Docker Desktop's WSL2
backend specifically, /dev/dxg instead of /dev/dri at all), and what's
actually *usable* can differ from what's merely *present* - confirmed
live on one real host (Windows 11 + Docker Desktop WSL2 + Intel Arc B580):
/dev/dri does not exist there even with an up-to-date driver and a modern
WSL2 kernel, while /dev/dxg does, and only some workloads (OpenVINO
compute, not ffmpeg's VAAPI) can actually use /dev/dxg alone. So detection
happens against the Docker Compose:v2 spec's `extends:` mechanism - see
immich-app/hwaccel.ml.yml, immich-app/hwaccel.transcoding.yml, and
media-stack/hwaccel.transcoding.yml for what each profile name below
actually maps to.

.PARAMETER WhatIf
Show what would be detected and written, without modifying any .env file.

.EXAMPLE
.\detect-gpu.ps1
.EXAMPLE
.\detect-gpu.ps1 -WhatIf
#>
param(
    [switch]$WhatIf,
    [switch]$Quiet
)

$appRoot = Split-Path -Parent $PSScriptRoot

function Write-Info {
    param([string]$Message)
    if (-not $Quiet) { Write-Host $Message }
}

# Runs a command, swallowing all output, returning $true only on a clean
# exit. Used throughout for "does this even exist / work" probes where we
# don't care about the output, only whether it succeeded.
function Test-CommandSucceeds {
    param([string]$Executable, [string[]]$CommandArgs)
    try {
        $null = & $Executable @CommandArgs 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Tests whether a given absolute device path exists ON THE DOCKER ENGINE
# (not this machine - relevant when Docker runs inside a VM/WSL2 distro
# distinct from the host PowerShell is running on). Actually mounting it
# into a throwaway container is the only reliable way to know: Docker
# itself errors immediately if the host-side path doesn't exist, which is
# a cleaner signal than trying to reason about it from outside.
function Test-DockerDevice {
    param([string]$DevicePath)
    & docker run --rm --device "${DevicePath}:${DevicePath}" alpine:3.22 true *>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-HostGpuVendors {
    # Returns a subset of @('nvidia','amd','intel') - a host can have more
    # than one (e.g. an Intel iGPU alongside a discrete AMD/NVIDIA card).
    $vendors = @()
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        try {
            $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
            foreach ($c in $controllers) {
                if ($c.Name -match 'NVIDIA') { $vendors += 'nvidia' }
                elseif ($c.Name -match 'AMD|Radeon') { $vendors += 'amd' }
                elseif ($c.Name -match 'Intel') { $vendors += 'intel' }
            }
        } catch {
            Write-Info "  (couldn't query Win32_VideoController: $_)"
        }
    } else {
        # Linux/Synology: read PCI vendor IDs directly from sysfs rather
        # than depending on lspci being installed. 0x10de=NVIDIA,
        # 0x1002=AMD/ATI, 0x8086=Intel - see pci.ids.
        try {
            $drmDevices = Get-ChildItem -Path /sys/class/drm -Filter 'card*' -ErrorAction Stop |
                Where-Object { $_.Name -notmatch '-' }
            foreach ($d in $drmDevices) {
                $vendorFile = Join-Path $d.FullName 'device/vendor'
                if (Test-Path $vendorFile) {
                    $vendorId = (Get-Content $vendorFile -ErrorAction SilentlyContinue).Trim()
                    switch ($vendorId) {
                        '0x10de' { $vendors += 'nvidia' }
                        '0x1002' { $vendors += 'amd' }
                        '0x8086' { $vendors += 'intel' }
                    }
                }
            }
        } catch {
            Write-Info "  (couldn't read /sys/class/drm: $_)"
        }
    }
    return ($vendors | Select-Object -Unique)
}

function Set-EnvValue {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
    )
    if (-not (Test-Path $Path)) {
        Write-Info "  ! $Path doesn't exist yet - skipping (run this again after the .env files are generated)"
        return
    }
    $lines = Get-Content $Path
    $pattern = "^$([regex]::Escape($Key))="
    $newLine = "$Key=$Value"
    $existing = $lines | Where-Object { $_ -match $pattern }

    if ($existing -and $existing -eq $newLine) {
        return # already correct, nothing to do
    }

    if ($WhatIf) {
        $action = if ($existing) { "would update" } else { "would add" }
        Write-Info "  [WhatIf] $action $Key=$Value in $Path"
        return
    }

    if ($existing) {
        $lines = $lines | ForEach-Object { if ($_ -match $pattern) { $newLine } else { $_ } }
    } else {
        $lines += $newLine
    }
    $lines | Out-File $Path -Encoding UTF8 -Force
    Write-Info "  -> $Key=$Value ($Path)"
}

# ---------------------------------------------------------------------------

Write-Info "Detecting GPU hardware acceleration..."

if (-not (Test-CommandSucceeds -Executable 'docker' -CommandArgs @('info'))) {
    Write-Info "  Docker isn't reachable - skipping GPU detection (everything defaults to cpu, which is always safe)."
    return
}

$vendors = Get-HostGpuVendors
if ($vendors.Count -eq 0) {
    Write-Info "  No GPU vendor detected on this host - using cpu (software) everywhere."
} else {
    Write-Info "  Host GPU vendor(s): $($vendors -join ', ')"
}

# --- NVIDIA: checked first regardless of platform - the nvidia-container-
# toolkit / WSL2 CUDA path is well-supported and self-contained (its own
# --gpus flag, not a raw device path), so it's worth a real Docker-level
# test whenever an NVIDIA card is present at all.
$nvidiaUsable = $false
if ($vendors -contains 'nvidia') {
    $nvidiaUsable = Test-CommandSucceeds -Executable 'docker' -CommandArgs @('run', '--rm', '--gpus', 'all', 'alpine:3.22', 'true')
    Write-Info "  NVIDIA GPU + Docker --gpus: $(if ($nvidiaUsable) { 'usable' } else { 'present but not usable (driver/toolkit not set up for containers yet)' })"
}

# --- /dev/dri and /dev/dxg: the two device paths every other backend
# below depends on. Testing both unconditionally (cheap - alpine is tiny
# and already cached almost everywhere) rather than guessing from
# platform/vendor alone, since WSL2's dxg-only-vs-dxg+dri split doesn't
# correlate cleanly with vendor or even Windows version.
$hasDri = Test-DockerDevice -DevicePath '/dev/dri'
$hasDxg = Test-DockerDevice -DevicePath '/dev/dxg'
Write-Info "  /dev/dri: $(if ($hasDri) { 'present' } else { 'not present' })   /dev/dxg: $(if ($hasDxg) { 'present' } else { 'not present' })"

$hasKfd = $false
if ($vendors -contains 'amd' -and $hasDri) {
    $hasKfd = Test-DockerDevice -DevicePath '/dev/kfd'
}

# --- Decide transcode profile (Immich video transcoding, Plex, Jellyfin -
# same decision for all three, they share media-stack/hwaccel.transcoding.yml
# and immich-app/hwaccel.transcoding.yml, which use identical profile names).
$transcodeProfile = 'cpu'
if ($nvidiaUsable) {
    $transcodeProfile = 'nvenc'
} elseif ($hasDri -and $hasDxg) {
    $transcodeProfile = 'vaapi-wsl'
} elseif ($hasDri) {
    $transcodeProfile = 'vaapi' # covers Intel and AMD alike via mesa on native Linux
}
# dxg-only (no dri): no working transcode path exists today for any
# vendor - ffmpeg's VAAPI backend requires a DRM render node regardless of
# LIBVA_DRIVER_NAME=d3d12 (confirmed live) - so this intentionally falls
# through to the 'cpu' default above rather than guessing.

# --- Decide Immich ML profile + image suffix. OpenVINO's GPU plugin is
# Intel-only (Level-Zero/compute-runtime); ROCm needs /dev/kfd, not just
# /dev/dri; CUDA is NVIDIA-only. Each needs its own image build, hence the
# suffix on top of the device profile.
$mlProfile = 'cpu'
$mlImageSuffix = ''
if ($nvidiaUsable) {
    $mlProfile = 'cuda'; $mlImageSuffix = '-cuda'
} elseif ($vendors -contains 'amd' -and $hasKfd) {
    $mlProfile = 'rocm'; $mlImageSuffix = '-rocm'
} elseif ($vendors -contains 'intel' -and $hasDri -and $hasDxg) {
    $mlProfile = 'openvino-wsl'; $mlImageSuffix = '-openvino'
} elseif ($vendors -contains 'intel' -and $hasDri) {
    $mlProfile = 'openvino'; $mlImageSuffix = '-openvino'
} elseif ($vendors -contains 'intel' -and $hasDxg) {
    # This repo's own addition, not upstream Immich - see the comment on
    # openvino-wsl-dxgonly in immich-app/hwaccel.ml.yml. Confirmed working
    # live via a real onnxruntime OpenVINOExecutionProvider GPU session
    # using only /dev/dxg.
    $mlProfile = 'openvino-wsl-dxgonly'; $mlImageSuffix = '-openvino'
}

Write-Info "  Transcoding (Immich/Plex/Jellyfin): $transcodeProfile"
Write-Info "  Immich machine learning: $mlProfile (image suffix: '$mlImageSuffix')"

# --- Write results. Every value defaults to cpu/'' in the compose files
# themselves too (${TRANSCODE_HWACCEL:-cpu} etc.), so a stack whose .env
# doesn't exist yet, or a var that's never been written, is always safe.
Set-EnvValue -Path "$appRoot\immich-app\.env" -Key 'TRANSCODE_HWACCEL' -Value $transcodeProfile
Set-EnvValue -Path "$appRoot\immich-app\.env" -Key 'ML_HWACCEL' -Value $mlProfile
Set-EnvValue -Path "$appRoot\immich-app\.env" -Key 'ML_IMAGE_SUFFIX' -Value $mlImageSuffix
Set-EnvValue -Path "$appRoot\media-stack\.env" -Key 'PLEX_HWACCEL' -Value $transcodeProfile
Set-EnvValue -Path "$appRoot\media-stack\.env" -Key 'JELLYFIN_HWACCEL' -Value $transcodeProfile

if ($transcodeProfile -ne 'cpu') {
    Write-Info ""
    Write-Info "  Note: device access alone doesn't turn hardware transcoding on inside"
    Write-Info "  each app - Plex and Jellyfin also need it enabled in their own admin UI"
    Write-Info "  (Jellyfin: Dashboard > Playback; Plex: Settings > Transcoder, needs a"
    Write-Info "  Plex Pass subscription), and Immich needs Admin > Settings > Video"
    Write-Info "  Transcoding > Hardware Acceleration set to match ($transcodeProfile)."
}
