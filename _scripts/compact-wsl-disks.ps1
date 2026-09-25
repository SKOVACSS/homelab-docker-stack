#Requires -Version 5.0
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Shrinks Docker's and WSL's virtual disks so space freed inside them goes
back to C:. Stops every container for a few minutes - run at a quiet time.

.DESCRIPTION
WSL virtual disks (.vhdx) grow as Linux writes data but never shrink by
themselves: pruning images or deleting files inside Docker frees space in
the VM, not on C:. This:
  1. Runs fstrim inside the VM so the freed blocks are marked unused.
  2. Stops Docker Desktop and shuts WSL down.
  3. Compacts each disk offline with diskpart ("compact vdisk"), the
     supported, safe way. (WSL's "sparse" mode would do this live, but
     WSL gates it behind --allow-unsafe because of a corruption bug.)
  4. Starts Docker Desktop again; containers come back on their own.

Needs an elevated PowerShell (diskpart). Typical run: 5-15 minutes.

.EXAMPLE
.\compact-wsl-disks.ps1
#>

param(
    [string[]]$Disks = @(
        "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"
    ) + @(Get-ChildItem "$env:LOCALAPPDATA\wsl" -Recurse -Filter ext4.vhdx -ErrorAction SilentlyContinue | ForEach-Object FullName)
)

$ErrorActionPreference = 'Stop'
$wsl = "$env:SystemRoot\System32\wsl.exe"
$diskpart = "$env:SystemRoot\System32\diskpart.exe"
$dockerDesktop = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
$docker = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"

function Get-FreeGB { [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 1) }
$startFree = Get-FreeGB
Write-Host "C: free before: $startFree GB"
$Disks = $Disks | Where-Object { Test-Path -LiteralPath $_ }
foreach ($d in $Disks) { Write-Host ("  {0,7:N1} GB  {1}" -f ((Get-Item -LiteralPath $d).Length / 1GB), $d) }

# 1. Mark freed blocks as unused while the VM is still running.
Write-Host "Trimming free space inside WSL..."
& $wsl -d docker-desktop -u root -e fstrim -av 2>&1 | Write-Host
& $wsl -d Ubuntu -u root -e fstrim -av 2>&1 | Write-Host

# 2. Stop Docker Desktop, then WSL (releases the .vhdx files).
Write-Host "Stopping Docker Desktop and WSL..."
Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue | Stop-Process -Force
& $wsl --shutdown
Start-Sleep -Seconds 10

# 3. Compact each disk offline.
foreach ($d in $Disks) {
    Write-Host "Compacting $d ..."
    $script = @"
select vdisk file="$d"
attach vdisk readonly
compact vdisk
detach vdisk
"@
    $tmp = New-TemporaryFile
    try {
        Set-Content -LiteralPath $tmp.FullName -Value $script -Encoding ASCII
        & $diskpart /s $tmp.FullName | Select-String -Pattern 'percent|success|error' | ForEach-Object { Write-Host "    $($_.Line.Trim())" }
    } finally {
        Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("    now {0:N1} GB" -f ((Get-Item -LiteralPath $d).Length / 1GB))
}

# 4. Bring Docker back.
Write-Host "Starting Docker Desktop..."
Start-Process $dockerDesktop
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 5
    $running = & $docker info --format '{{.ContainersRunning}}' 2>$null
    if ($running -match '^\d+$') { Write-Host "Docker is up ($running containers running)."; break }
}

$endFree = Get-FreeGB
Write-Host "C: free after: $endFree GB (recovered $([math]::Round($endFree - $startFree, 1)) GB)"
