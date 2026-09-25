#Requires -RunAsAdministrator
#Requires -Version 5.0

<#
.SYNOPSIS
Installs Scrutiny's drive-health collector on this Windows host.

.DESCRIPTION
Scrutiny (utilities stack, scrutiny.DOMAIN) shows SMART health for every
physical drive, but Docker Desktop's VM can't see the real disks - the
collector has to run on Windows itself, as Administrator (reading SMART
data needs raw disk access).

This script:
  1. Installs smartmontools (smartctl) with winget, if missing.
  2. Downloads Scrutiny's Windows collector (same version as the server,
     from the project's GitHub releases) to C:\ProgramData\scrutiny.
  3. Writes collector.yaml pointing at the server's localhost-only port
     (127.0.0.1:8089, see utilities/docker-compose.yml).
  4. Registers a scheduled task "Scrutiny collector" that runs as SYSTEM
     at startup and every 6 hours, then runs it once now.

Re-running is safe (it updates the files and the task in place).
Uninstall: Unregister-ScheduledTask "Scrutiny collector" and delete
C:\ProgramData\scrutiny.

.EXAMPLE
# From an elevated PowerShell:
.\install-scrutiny-collector.ps1
#>

param(
    [string]$Version = "v0.9.4",
    [string]$ApiEndpoint = "http://127.0.0.1:8089",
    [string]$InstallDir = "C:\ProgramData\scrutiny"
)

$ErrorActionPreference = "Stop"

# 1. smartmontools
$smartctl = "C:\Program Files\smartmontools\bin\smartctl.exe"
if (-not (Test-Path $smartctl)) {
    Write-Host "Installing smartmontools..." -ForegroundColor Cyan
    winget install --id smartmontools.smartmontools -e --silent --accept-package-agreements --accept-source-agreements
    if (-not (Test-Path $smartctl)) { throw "smartctl not found at $smartctl after install" }
}
Write-Host "smartctl: $smartctl" -ForegroundColor Green

# 2. Collector binary
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$exe = Join-Path $InstallDir "scrutiny-collector-metrics.exe"
$url = "https://github.com/AnalogJ/scrutiny/releases/download/$Version/scrutiny-collector-metrics-windows-amd64.exe"
Write-Host "Downloading collector $Version..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing

# 3. Config
$config = @"
version: 1
host:
  id: "$env:COMPUTERNAME"
api:
  endpoint: "$ApiEndpoint"
log:
  file: "$($InstallDir -replace '\\','/')/collector.log"
  level: INFO
commands:
  metrics_smartctl_bin: "$($smartctl -replace '\\','/')"
"@
$configPath = Join-Path $InstallDir "collector.yaml"
[System.IO.File]::WriteAllText($configPath, $config)

# 4. Scheduled task (SYSTEM: needs raw disk access, no user logged in)
$action = New-ScheduledTaskAction -Execute $exe -Argument "run --config `"$configPath`"" -WorkingDirectory $InstallDir
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 6))
)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable
Register-ScheduledTask -TaskName "Scrutiny collector" -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Scheduled task 'Scrutiny collector' registered (startup + every 6h)." -ForegroundColor Green

Write-Host "Running a first collection..." -ForegroundColor Cyan
& $exe run --config $configPath
if ($LASTEXITCODE -eq 0) {
    Write-Host "Done - drives should now appear at scrutiny.<your domain>." -ForegroundColor Green
} else {
    Write-Host "Collector exited with $LASTEXITCODE - see $InstallDir\collector.log" -ForegroundColor Yellow
}
