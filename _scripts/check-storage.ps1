<#
.SYNOPSIS
    Gotify alert when a drive is low on space or the Storage Spaces mirror
    (or one of its disks) is unhealthy.

.DESCRIPTION
    Runs every 30 minutes (scheduled task Homelab_Check_Storage). Two
    incidents went unnoticed for days before this existed:
      - 2026-09-29: a DNS loop filled C: and Docker Desktop shut down.
      - 2026-09-26: one of the D: mirror's drives dropped out (a loose
        cable) and the mirror ran on a single disk for three days.
    Repeats an alert at most every 6 hours while the problem lasts, and
    sends one "resolved" message when it clears. Uses GOTIFY_TOKEN from
    utilities\.env, posted from a short-lived container on
    notification-network (same as backup.ps1).

.PARAMETER MinFreeGB
    Alert when a fixed drive has less than this much free space.
#>
param(
    [int]$MinFreeGB = 30,
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path "$dockerBin\docker.exe") { $env:Path += ";$dockerBin" }
}

$appRoot = Split-Path -Parent $PSScriptRoot
$stateFile = Join-Path $PSScriptRoot ".storage-alert-state.json"

function Get-EnvFileValue([string]$File, [string]$Key) {
    if (-not (Test-Path $File)) { return "" }
    $line = Get-Content $File | Where-Object { $_ -match "^\s*$Key\s*=" } | Select-Object -First 1
    if (-not $line) { return "" }
    return ($line -replace "^\s*$Key\s*=\s*", "").Trim().Trim('"').Trim("'")
}

function Send-Gotify([string]$Title, [string]$Message, [int]$Priority) {
    $token = Get-EnvFileValue (Join-Path $appRoot "utilities\.env") "GOTIFY_TOKEN"
    if (-not $token -or $token -like "CHANGE_ME*") { return }
    $body = @{ title = $Title; message = $Message; priority = $Priority } | ConvertTo-Json -Compress
    $tmp = Join-Path $env:TEMP "storage-gotify.json"
    [System.IO.File]::WriteAllText($tmp, $body)
    docker run --rm --network notification-network -v "${tmp}:/body.json:ro" curlimages/curl:latest `
        -s -o /dev/null -X POST -H "Content-Type: application/json" `
        --data-binary "@/body.json" "http://gotify:80/message?token=$token" | Out-Null
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

$problems = @()

foreach ($d in Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -and $_.Root -match '^[A-Z]:\\$' }) {
    $freeGB = [math]::Round($d.Free / 1GB, 1)
    if ($freeGB -lt $MinFreeGB) { $problems += "$($d.Name): only $freeGB GB free" }
}

foreach ($v in Get-VirtualDisk -ErrorAction SilentlyContinue) {
    if ($v.HealthStatus -ne "Healthy") {
        $problems += "Storage pool '$($v.FriendlyName)' is $($v.HealthStatus) / $($v.OperationalStatus)"
    }
}
foreach ($p in Get-PhysicalDisk -ErrorAction SilentlyContinue) {
    if ($p.HealthStatus -ne "Healthy") {
        $sn = if ($p.SerialNumber) { $p.SerialNumber.Trim() } else { "" }
        $tail = if ($sn.Length -ge 4) { $sn.Substring($sn.Length - 4) } else { $sn }
        $problems += "Disk $($p.FriendlyName) (...$tail) is $($p.HealthStatus): $($p.OperationalStatus -join ', ')"
    }
}

$state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }
$now = Get-Date

if ($problems) {
    $summary = $problems -join "`n"
    $lastSent = if ($state -and $state.LastSent) { [datetime]$state.LastSent } else { [datetime]::MinValue }
    $changed = -not $state -or $state.Summary -ne $summary
    if ($changed -or ($now - $lastSent).TotalHours -ge 6) {
        Send-Gotify "Storage problem on the server" $summary 8
        @{ Summary = $summary; LastSent = $now.ToString("o") } | ConvertTo-Json | Set-Content $stateFile
    }
    if (-not $Quiet) { Write-Host $summary -ForegroundColor Yellow }
} else {
    if ($state -and $state.Summary) {
        Send-Gotify "Storage OK again" "All drives have space and the mirror is healthy." 4
    }
    if (Test-Path $stateFile) { Remove-Item $stateFile -ErrorAction SilentlyContinue }
    if (-not $Quiet) { Write-Host "Storage OK" -ForegroundColor Green }
}
