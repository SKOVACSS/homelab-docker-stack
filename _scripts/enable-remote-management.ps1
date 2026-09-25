#Requires -Version 5.0
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Lets a separate workstation (see workstation/README.md) manage this Docker host over SSH and Remote Desktop.

.DESCRIPTION
Turns on the two things a management laptop needs from this host, neither
of which Windows enables by default:

- OpenSSH Server, with PowerShell 7 (or Windows PowerShell if 7 isn't
  installed) as the login shell, so `ssh homelab` drops you straight into
  a prompt that can run deploy.ps1, health-check.ps1, etc. Optionally
  authorizes the workstation's public key (-PublicKey).
- Remote Desktop, with Network Level Authentication required, and the
  H.264/AVC 444 graphics mode preferred and hardware-encoded where the
  GPU supports it. That's what lets a low-power client (the 2016 MacBook
  in workstation/README.md) decode the session on its GPU instead of
  its CPU - noticeably smoother, and much less fan noise.

Neither port is published to the internet by this script or by anything
else in this repo: reach them on the LAN, or from outside through the
WireGuard server in security-stack/. Never route 3389 or 22 through Caddy
or Cloudflare Tunnel (see SECURITY.md).

Remote Desktop *hosting* needs Windows Pro/Enterprise/Education - Home
editions can connect out but can't accept connections. On Home this
script still sets up SSH and says so for RDP.

Idempotent - safe to re-run.

.PARAMETER PublicKey
An SSH public key line (e.g. the contents of ~/.ssh/id_ed25519.pub on the
workstation) to authorize for the account running this script.

.EXAMPLE
.\enable-remote-management.ps1

.EXAMPLE
.\enable-remote-management.ps1 -PublicKey "ssh-ed25519 AAAA... you@macbook"
#>

[CmdletBinding()]
param(
    [string]$PublicKey
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  Enable Remote Management (SSH + Remote Desktop)" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

# --- OpenSSH Server ---------------------------------------------------------
Write-Host "OpenSSH Server" -ForegroundColor Yellow
$sshCap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($sshCap.State -ne 'Installed') {
    Write-Host "  Installing (can take a few minutes)..."
    Add-WindowsCapability -Online -Name $sshCap.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
Write-Host "  [OK] sshd running, starts automatically" -ForegroundColor Green

$pwsh7 = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$shell = if (Test-Path $pwsh7) { $pwsh7 } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
Write-Host "  [OK] SSH login shell: $shell" -ForegroundColor Green

if ($PublicKey) {
    $PublicKey = $PublicKey.Trim()
    # sshd ignores a member of Administrators' own ~/.ssh/authorized_keys
    # and reads this shared file instead - which it also ignores unless
    # only Administrators and SYSTEM can access it. SIDs rather than names
    # so the ACL works on non-English Windows.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        $keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    } else {
        $keyFile = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
        New-Item -ItemType Directory -Force -Path (Split-Path $keyFile) | Out-Null
    }
    $existing = if (Test-Path $keyFile) { Get-Content $keyFile } else { @() }
    if ($existing -notcontains $PublicKey) {
        Add-Content -Path $keyFile -Value $PublicKey -Encoding ascii
    }
    if ($isAdmin) {
        # Set-Acl rather than icacls.exe: no dependency on System32 being on
        # PATH (on one real host it was missing from PATH entirely).
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
            $who = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, 'FullControl', 'Allow')))
        }
        Set-Acl -Path $keyFile -AclObject $acl
    }
    Write-Host "  [OK] Key authorized in $keyFile" -ForegroundColor Green
}

# --- Remote Desktop ---------------------------------------------------------
Write-Host ""
Write-Host "Remote Desktop" -ForegroundColor Yellow
$edition = (Get-CimInstance Win32_OperatingSystem).Caption
if ($edition -match 'Home') {
    Write-Host "  [SKIP] $edition can't host Remote Desktop sessions (needs Pro or higher)." -ForegroundColor Yellow
    Write-Host "         SSH above still works; for a GUI, upgrade the edition." -ForegroundColor Yellow
} else {
    $ts = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    Set-ItemProperty -Path $ts -Name fDenyTSConnections -Value 0
    Set-ItemProperty -Path "$ts\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1
    # '@FirewallAPI.dll,-28752' is the built-in "Remote Desktop" rule
    # group's resource ID - its display name is localized, this isn't.
    Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'
    Write-Host "  [OK] Enabled, Network Level Authentication required" -ForegroundColor Green

    # Same values the Group Policy editor writes for Computer Configuration >
    # Administrative Templates > Windows Components > Remote Desktop Services >
    # Remote Desktop Session Host > Remote Session Environment.
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    New-Item -Path $policy -Force | Out-Null
    foreach ($name in 'AVC444ModePreferred', 'AVCHardwareEncodePreferred', 'bEnumerateHWBeforeSW') {
        New-ItemProperty -Path $policy -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
    }
    Write-Host "  [OK] H.264/AVC 444 preferred, GPU encoding on (applies to new sessions)" -ForegroundColor Green
}

# --- Summary ----------------------------------------------------------------
$lanIp = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notmatch 'vEthernet|WSL|Docker' } |
    Select-Object -First 1 -ExpandProperty IPAddress

Write-Host ""
Write-Host "Connect from the workstation:" -ForegroundColor Cyan
Write-Host "  ssh $env:USERNAME@$lanIp"
Write-Host "  rdp-homelab $lanIp $env:USERNAME"
Write-Host ""
