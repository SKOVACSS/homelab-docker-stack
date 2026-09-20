#Requires -Version 5.0

<#
.SYNOPSIS
Health Check Script for Docker Home Lab

.DESCRIPTION
Validates all Docker containers and services are running with proper health status.

.EXAMPLE
.\health-check.ps1

#>

param(
    [switch]$Detailed = $false,
    [switch]$JSON = $false
)

# Configuration
$stacks = @("authentik", "caddy", "media-stack", "privacy-stack", "security-stack", "email-stack", "monitoring-stack", "notification-stack", "utilities", "immich-app")
$results = @{
    Healthy = @()
    Unhealthy = @()
    NotRunning = @()
    Total = 0
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Docker Home Lab - Health Check" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Get all running containers
$containers = docker ps --no-trunc --format "table {{.Names}}\t{{.Status}}\t{{.State}}"

if (-not $containers) {
    Write-Host "⚠️  No containers running" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To start services, run:" -ForegroundColor Cyan
    Write-Host "  docker compose -f caddy/docker-compose.yml up -d" -ForegroundColor White
    exit 1
}

foreach ($stack in $stacks) {
    Write-Host "Checking $stack..." -ForegroundColor White
    
    try {
        $stackPath = Split-Path -Parent $PSScriptRoot
        $stackPath = Join-Path $stackPath $stack
        
        if (-not (Test-Path "$stackPath\docker-compose.yml")) {
            continue
        }
        
        # Get containers for this stack
        $stackContainers = docker compose -f "$stackPath\docker-compose.yml" ps --no-trunc 2>$null
        
        if ($stackContainers) {
            foreach ($line in $stackContainers) {
                if ($line -match '^\S+\s+') {
                    $parts = $line -split '\s+' | Where-Object {$_}
                    $name = $parts[0]
                    $status = $parts[-2]
                    $state = $parts[-1]
                    
                    if ($status -match "Up.*healthy") {
                        Write-Host "  ✅ $name - Healthy" -ForegroundColor Green
                        $results.Healthy += @{Stack=$stack; Container=$name; Status=$status}
                    } elseif ($status -match "Up") {
                        Write-Host "  ⚠️  $name - Running (no healthcheck)" -ForegroundColor Yellow
                        $results.Healthy += @{Stack=$stack; Container=$name; Status=$status}
                    } elseif ($status -match "Up.*unhealthy") {
                        Write-Host "  ❌ $name - Unhealthy" -ForegroundColor Red
                        $results.Unhealthy += @{Stack=$stack; Container=$name; Status=$status}
                    } else {
                        Write-Host "  ⏸️  $name - Not Running" -ForegroundColor Yellow
                        $results.NotRunning += @{Stack=$stack; Container=$name; Status=$status}
                    }
                    $results.Total++
                }
            }
        }
    }
    catch {
        Write-Host "  ⚠️  Error checking stack" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "✅ Healthy:     $($results.Healthy.Count)" -ForegroundColor Green
Write-Host "⚠️  Unhealthy:   $($results.Unhealthy.Count)" -ForegroundColor Yellow
Write-Host "❌ Not Running:  $($results.NotRunning.Count)" -ForegroundColor Red
Write-Host "📊 Total:       $($results.Total)" -ForegroundColor Cyan
Write-Host ""

# Overall status
$healthPercentage = if ($results.Total -gt 0) {
    [math]::Round(($results.Healthy.Count / $results.Total) * 100)
} else {
    0
}

if ($results.Unhealthy.Count -eq 0 -and $results.NotRunning.Count -eq 0) {
    Write-Host "✅ System Status: HEALTHY ($healthPercentage%)" -ForegroundColor Green
} elseif ($results.Unhealthy.Count -gt 0) {
    Write-Host "❌ System Status: ISSUES DETECTED" -ForegroundColor Red
} else {
    Write-Host "⚠️  System Status: DEGRADED" -ForegroundColor Yellow
}

Write-Host ""

# Detailed diagnostics
if ($Detailed) {
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Detailed Diagnostics" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Networks:" -ForegroundColor White
    docker network ls --filter "name=caddy" --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}" | ForEach-Object {Write-Host "  $_"}
    
    Write-Host ""
    Write-Host "Volumes:" -ForegroundColor White
    docker volume ls --format "table {{.Name}}\t{{.Driver}}" | Select-Object -First 15 | ForEach-Object {Write-Host "  $_"}
    
    Write-Host ""
    Write-Host "Disk Usage:" -ForegroundColor White
    docker system df | ForEach-Object {Write-Host "  $_"}
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Exit code
if ($results.Unhealthy.Count -eq 0 -and $results.NotRunning.Count -eq 0) {
    exit 0
} else {
    exit 1
}
