#Requires -Version 5.0

<#
.SYNOPSIS
Docker Deployment Helper Script

.DESCRIPTION
Automates the deployment sequence for all Docker stacks in the correct order.
Ensures caddy network is created first, then authentik, then all other stacks.

.PARAMETER Action
deploy - Deploy all stacks
start - Start existing containers
stop - Stop all containers
restart - Restart all stacks
down - Remove all containers (keep volumes)

.EXAMPLE
.\deploy.ps1 -Action deploy

#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("deploy", "start", "stop", "restart", "down", "logs", "status")]
    [string]$Action = "deploy",
    
    [string]$Stack = "",
    [switch]$Pull = $false,
    [switch]$Quiet = $false
)

$appRoot = Split-Path -Parent $PSScriptRoot
$stacks = @("caddy", "authentik", "media-stack", "privacy-stack", "security-stack", "email-stack", "monitoring-stack", "notification-stack", "utilities", "immich-app")

function Write-Status {
    param([string]$Message, [string]$Type = "info")
    
    if ($Quiet -and $Type -eq "info") { return }
    
    switch ($Type) {
        "success" { Write-Host "✅ $Message" -ForegroundColor Green }
        "error" { Write-Host "❌ $Message" -ForegroundColor Red }
        "warning" { Write-Host "⚠️  $Message" -ForegroundColor Yellow }
        "info" { Write-Host "ℹ️  $Message" -ForegroundColor Cyan }
        "step" { Write-Host "→ $Message" -ForegroundColor White }
    }
}

function Deploy-Stack {
    param([string]$StackName, [bool]$WaitForHealthy = $false)
    
    $stackPath = Join-Path $appRoot $StackName
    
    if (-not (Test-Path "$stackPath\docker-compose.yml")) {
        Write-Status "${StackName}: docker-compose.yml not found" "warning"
        return $false
    }
    
    Write-Status "Starting $StackName..." "step"
    
    $pullArg = if ($Pull) { "--pull always" } else { "" }
    $result = Invoke-Expression "docker compose -f '$stackPath\docker-compose.yml' up $pullArg -d" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Status "$StackName started" "success"
        
        if ($WaitForHealthy) {
            Write-Status "Waiting for $StackName to be healthy..." "info"
            $retries = 0
            $maxRetries = 30
            
            while ($retries -lt $maxRetries) {
                $healthy = docker compose -f "$stackPath\docker-compose.yml" ps 2>&1 | Select-String "healthy"
                if ($healthy) {
                    Write-Status "$StackName is healthy" "success"
                    return $true
                }
                Start-Sleep -Seconds 2
                $retries++
            }
            
            Write-Status "$StackName not ready after $($maxRetries * 2) seconds" "warning"
        }
        return $true
    } else {
        Write-Status "$StackName failed to start" "error"
        Write-Host $result
        return $false
    }
}

function Stop-Stack {
    param([string]$StackName)
    
    $stackPath = Join-Path $appRoot $StackName
    
    if (-not (Test-Path "$stackPath\docker-compose.yml")) {
        return
    }
    
    Write-Status "Stopping $StackName..." "step"
    docker compose -f "$stackPath\docker-compose.yml" down --remove-orphans 2>&1 | Out-Null
    Write-Status "$StackName stopped" "success"
}

function Start-Stack {
    param([string]$StackName)
    
    $stackPath = Join-Path $appRoot $StackName
    
    if (-not (Test-Path "$stackPath\docker-compose.yml")) {
        return
    }
    
    Write-Status "Starting $StackName..." "step"
    docker compose -f "$stackPath\docker-compose.yml" start 2>&1 | Out-Null
    Write-Status "$StackName started" "success"
}

function Restart-Stack {
    param([string]$StackName)
    
    $stackPath = Join-Path $appRoot $StackName
    
    if (-not (Test-Path "$stackPath\docker-compose.yml")) {
        return
    }
    
    Write-Status "Restarting $StackName..." "step"
    docker compose -f "$stackPath\docker-compose.yml" restart 2>&1 | Out-Null
    Write-Status "$StackName restarted" "success"
}

function Remove-Stack {
    param([string]$StackName)
    
    $stackPath = Join-Path $appRoot $StackName
    
    if (-not (Test-Path "$stackPath\docker-compose.yml")) {
        return
    }
    
    Write-Status "Removing $StackName (keeping volumes)..." "step"
    docker compose -f "$stackPath\docker-compose.yml" down --remove-orphans 2>&1 | Out-Null
    Write-Status "$StackName removed" "success"
}

function Show-Logs {
    param([string]$StackName)
    
    $stackPath = Join-Path $appRoot $StackName
    
    if (-not (Test-Path "$stackPath\docker-compose.yml")) {
        Write-Status "$StackName not found" "error"
        return
    }
    
    docker compose -f "$stackPath\docker-compose.yml" logs -f
}

function Show-Status {
    param([string]$StackName = "")
    
    if ([string]::IsNullOrEmpty($StackName)) {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  Docker Stack Status" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        
        foreach ($s in $stacks) {
            $stackPath = Join-Path $appRoot $s
            if (Test-Path "$stackPath\docker-compose.yml") {
                $ps = docker compose -f "$stackPath\docker-compose.yml" ps 2>&1
                $running = $ps | Select-String "Up" | Measure-Object | Select-Object -ExpandProperty Count
                $total = $ps | Select-String "^\w" | Measure-Object | Select-Object -ExpandProperty Count
                
                if ($running -eq $total -and $total -gt 0) {
                    Write-Host "  ✅ $s ($running/$total)" -ForegroundColor Green
                } elseif ($running -gt 0) {
                    Write-Host "  ⚠️  $s ($running/$total)" -ForegroundColor Yellow
                } else {
                    Write-Host "  ❌ $s ($running/$total)" -ForegroundColor Red
                }
            }
        }
        
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
    } else {
        $stackPath = Join-Path $appRoot $StackName
        if (Test-Path "$stackPath\docker-compose.yml") {
            docker compose -f "$stackPath\docker-compose.yml" ps
        }
    }
}

# Main execution
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Docker Deployment Helper" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

switch ($Action) {
    "deploy" {
        Write-Status "Starting deployment sequence..." "step"
        Write-Status "CRITICAL: Deploy in this exact order!" "warning"
        Write-Host ""
        
        # 1. Caddy (creates network)
        if (-not (Deploy-Stack "caddy" $true)) {
            Write-Status "Caddy deployment failed. Aborting." "error"
            exit 1
        }
        Start-Sleep -Seconds 5
        
        # 2. Authentik
        if (-not (Deploy-Stack "authentik" $true)) {
            Write-Status "Authentik deployment failed. Aborting." "error"
            exit 1
        }
        Start-Sleep -Seconds 5
        
        # 3. All others
        foreach ($s in $stacks | Where-Object {$_ -ne "caddy" -and $_ -ne "authentik"}) {
            Deploy-Stack $s $false
            Start-Sleep -Seconds 3
        }
        
        Write-Host ""
        Write-Status "Deployment complete!" "success"
        Write-Status "Run: .\deploy.ps1 -Action status" "info"
    }
    
    "start" {
        if ([string]::IsNullOrEmpty($Stack)) {
            foreach ($s in $stacks) {
                Start-Stack $s
            }
        } else {
            Start-Stack $Stack
        }
    }
    
    "stop" {
        if ([string]::IsNullOrEmpty($Stack)) {
            foreach ($s in $stacks) {
                Stop-Stack $s
            }
        } else {
            Stop-Stack $Stack
        }
    }
    
    "restart" {
        if ([string]::IsNullOrEmpty($Stack)) {
            foreach ($s in $stacks) {
                Restart-Stack $s
            }
        } else {
            Restart-Stack $Stack
        }
    }
    
    "down" {
        $confirm = Read-Host "Remove all containers (keep volumes)? (y/N)"
        if ($confirm -eq "y") {
            foreach ($s in $stacks) {
                Remove-Stack $s
            }
            Write-Status "All stacks removed" "success"
        }
    }
    
    "logs" {
        if ([string]::IsNullOrEmpty($Stack)) {
            Write-Status "Specify stack name: -Stack <stackname>" "error"
        } else {
            Show-Logs $Stack
        }
    }
    
    "status" {
        Show-Status $Stack
    }
}

Write-Host ""
