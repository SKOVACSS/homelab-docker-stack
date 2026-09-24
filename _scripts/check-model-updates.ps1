#Requires -Version 5.0

<#
.SYNOPSIS
Weekly check for newer chat models that should fit this server's GPU, sent to Gotify as a suggestion.

.DESCRIPTION
Never changes the running model - swapping one is a manual, tested step
(see ai-stack/docker-compose.yml's command). A model has to fit the GPU's
VRAM next to vLLM's own overhead and work on vLLM's Intel XPU backend,
and the current one was sized by trial. This only narrows the field:

  - official publishers only ($Authors) - no re-uploads or fine-tunes
  - AWQ-quantized text models (the format proven on this vLLM build);
    vision/audio variants are skipped
  - not gated (no Hugging Face login needed to download)
  - weights <= $MaxWeightGB (the current 7B AWQ is ~5.2GB and fits a
    12GB card with an 8192-token context; a 14B's ~9.4GB did not)
  - at least $MinSizeRatio x the current model's size (no downgrades)
  - published after the model currently served

Each suggestion is sent once - remembered in ai-stack/model-check-state.json
(per server, gitignored). -DryRun prints instead of notifying.

.EXAMPLE
.\check-model-updates.ps1 -DryRun
#>

param(
    [string[]]$Authors = @('Qwen', 'meta-llama', 'mistralai', 'google', 'microsoft', 'ibm-granite', 'deepseek-ai'),
    [double]$MaxWeightGB = 6.5,
    # Skip anything much smaller than the current model - a newer 3-4B is
    # still a downgrade from a 7B for general chat.
    [double]$MinSizeRatio = 0.8,
    [int]$MaxSuggestions = 3,
    [switch]$DryRun
)

$appRoot = Split-Path -Parent $PSScriptRoot
$statePath = "$appRoot\ai-stack\model-check-state.json"
$api = 'https://huggingface.co/api/models'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
    if (Test-Path "$dockerBin\docker.exe") { $env:Path += ";$dockerBin" }
}

# ---------- Current model (from the vllm container, asleep or not) ----------
$cmd = docker inspect vllm --format '{{json .Config.Cmd}}' 2>$null | ConvertFrom-Json
$current = $cmd | Where-Object { $_ -match '^[\w.-]+/[\w.-]+$' } | Select-Object -First 1
if (-not $current) { Write-Host "❌ Couldn't find the served model in the vllm container's command" -ForegroundColor Red; exit 1 }
$currentInfo = Invoke-RestMethod "$api/$current" -TimeoutSec 30
$currentDate = [datetime]$currentInfo.createdAt
$currentBytes = ((Invoke-RestMethod "$api/$current`?blobs=true" -TimeoutSec 30).siblings | Where-Object { $_.rfilename -like "*.safetensors" } | Measure-Object size -Sum).Sum
Write-Host "Current model: $current (published $($currentDate.ToString('yyyy-MM-dd')))"

$state = @{ suggested = @() }
if (Test-Path $statePath) { $state = Get-Content $statePath -Raw | ConvertFrom-Json }
$alreadySuggested = @($state.suggested)

# ---------- Candidates ----------
$candidates = @()
foreach ($author in $Authors) {
    try {
        $models = Invoke-RestMethod "$api`?author=$author&search=AWQ&sort=createdAt&direction=-1&limit=30&full=true" -TimeoutSec 30
    } catch { Write-Host "⚠️  $author`: $($_.Exception.Message)" -ForegroundColor Yellow; continue }
    foreach ($m in $models) {
        $tags = @($m.tags)
        if ($m.id -eq $current -or $alreadySuggested -contains $m.id) { continue }
        if ($m.gated -and "$($m.gated)" -ne 'False') { continue }
        if ($tags -notcontains 'text-generation') { continue }
        if ($m.id -match '(?i)-(VL|Omni|Vision|Audio)-') { continue }
        if ([datetime]$m.createdAt -le $currentDate) { continue }
        $detail = Invoke-RestMethod "$api/$($m.id)?blobs=true" -TimeoutSec 30
        $bytes = ($detail.siblings | Where-Object { $_.rfilename -like '*.safetensors' } | Measure-Object size -Sum).Sum
        $gb = [math]::Round($bytes / 1GB, 1)
        if (-not $bytes -or $gb -gt $MaxWeightGB -or $bytes -lt $currentBytes * $MinSizeRatio) { continue }
        $candidates += [PSCustomObject]@{ Id = $m.id; Published = ([datetime]$m.createdAt).ToString('yyyy-MM-dd'); WeightsGB = $gb }
    }
}
$candidates = @($candidates | Sort-Object Published -Descending | Select-Object -First $MaxSuggestions)

if ($candidates.Count -eq 0) { Write-Host "✅ No newer models that fit - nothing to suggest"; exit 0 }

$lines = $candidates | ForEach-Object { "- $($_.Id) ($($_.WeightsGB) GB, published $($_.Published))" }
$message = "Newer models that should fit the GPU (current: $current):`n$($lines -join "`n")`n`nNot applied - ask Claude to test one before switching."
Write-Host $message

if ($DryRun) { Write-Host "(dry run - no notification sent, nothing remembered)"; exit 0 }

# ---------- Notify (Gotify, reached from a container on caddy-network) ----------
$tokenLine = Get-Content "$appRoot\utilities\.env" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^GOTIFY_TOKEN=.+' } | Select-Object -First 1
if (-not $tokenLine) { Write-Host "⚠️  GOTIFY_TOKEN not set in utilities\.env - not notifying" -ForegroundColor Yellow; exit 0 }
$token = $tokenLine -replace '^GOTIFY_TOKEN=', ''
$body = @{ title = 'Chat model update available'; message = $message; priority = 4 } | ConvertTo-Json -Compress
# Body over stdin: Windows PowerShell 5.1 strips quotes from native args.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
$null = $body | docker exec -i uptime-kuma curl -s -X POST "http://gotify:80/message?token=$token" -H 'Content-Type: application/json' --data-binary '@-'
if ($LASTEXITCODE -ne 0) { Write-Host "❌ Gotify notification failed" -ForegroundColor Red; exit 1 }

$state = @{ suggested = @($alreadySuggested + $candidates.Id | Select-Object -Unique) }
$state | ConvertTo-Json | Set-Content $statePath -Encoding UTF8
Write-Host "✅ Sent to Gotify"
