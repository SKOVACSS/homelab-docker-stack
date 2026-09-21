#Requires -Version 5.0

<#
.SYNOPSIS
Lists the pinned image version for every service across all stacks.

.DESCRIPTION
Walks every stack directory (any folder with a docker-compose.yml) and
extracts each service's image reference, splitting it into registry,
repository, and tag so the values can be fed into a version-drift check
against upstream registries. This first pass only inventories what is
currently pinned - it does not call out to any registry yet.

.PARAMETER JSON
Output the inventory as JSON instead of a console table.

.EXAMPLE
.\check-versions.ps1

.EXAMPLE
.\check-versions.ps1 -JSON
#>

param(
    [switch]$JSON
)

function ConvertTo-ImageInfo {
    param([Parameter(Mandatory=$true)][string]$Image)

    $digest = $null
    if ($Image -match '^(?<base>.+)@(?<digest>sha256:[0-9a-f]{64})$') {
        $Image = $Matches.base
        $digest = $Matches.digest
    }

    # A ${VAR:-default} substitution can contain its own ':', which would
    # otherwise be mistaken for the tag separator below - mask it out
    # first so the colon/slash split only ever sees real separators.
    $varMatch = [regex]::Match($Image, '\$\{[^}]*\}$')
    $placeholder = $null
    if ($varMatch.Success) {
        $placeholder = $varMatch.Value
        $Image = $Image.Substring(0, $varMatch.Index) + '@@VAR@@'
    }

    # A tag never contains '/', so the image has a tag only if the last
    # ':' comes after the last '/'. This also keeps registry:port hosts
    # (colon before the last '/') from being misread as a tag.
    $lastColon = $Image.LastIndexOf(':')
    $lastSlash = $Image.LastIndexOf('/')
    if ($lastColon -gt $lastSlash) {
        $tag = $Image.Substring($lastColon + 1)
        $repoPart = $Image.Substring(0, $lastColon)
    } else {
        $tag = 'latest'
        $repoPart = $Image
    }

    if ($tag -eq '@@VAR@@') { $tag = $placeholder }

    # A registry host is distinguished from a Docker Hub namespace by
    # containing a '.' or ':' (e.g. ghcr.io, lscr.io, registry.local:5000).
    $firstSlash = $repoPart.IndexOf('/')
    $firstSegment = if ($firstSlash -ge 0) { $repoPart.Substring(0, $firstSlash) } else { $repoPart }
    if ($firstSlash -ge 0 -and $firstSegment -match '[.:]') {
        $registry = $firstSegment
        $repository = $repoPart.Substring($firstSlash + 1)
    } else {
        $registry = 'docker.io'
        $repository = if ($repoPart -match '/') { $repoPart } else { "library/$repoPart" }
    }

    $isVariable = $false
    $variableName = $null
    $resolvedTag = $tag
    if ($tag -match '^\$\{(?<name>[A-Za-z_][A-Za-z0-9_]*):-(?<default>.+)\}$') {
        $isVariable = $true
        $variableName = $Matches.name
        $resolvedTag = $Matches.default
    }

    [PSCustomObject]@{
        Registry     = $registry
        Repository   = $repository
        Tag          = $tag
        ResolvedTag  = $resolvedTag
        IsVariable   = $isVariable
        VariableName = $variableName
        Digest       = $digest
    }
}

function Get-ImageInventory {
    $appRoot = Split-Path -Parent $PSScriptRoot
    $stackDirs = Get-ChildItem $appRoot -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'docker-compose.yml') }

    $inventory = @()
    foreach ($dir in $stackDirs) {
        $composePath = Join-Path $dir.FullName 'docker-compose.yml'
        $currentService = $null
        foreach ($line in Get-Content $composePath) {
            if ($line -match '^\s{2}(?<svc>[A-Za-z0-9_.-]+):\s*$') {
                $currentService = $Matches.svc
            } elseif ($line -match '^\s*image:\s*(?<img>\S+)\s*$') {
                $info = ConvertTo-ImageInfo -Image $Matches.img
                $inventory += [PSCustomObject]@{
                    Stack        = $dir.Name
                    Service      = $currentService
                    RawImage     = $Matches.img
                    Registry     = $info.Registry
                    Repository   = $info.Repository
                    Tag          = $info.Tag
                    ResolvedTag  = $info.ResolvedTag
                    IsVariable   = $info.IsVariable
                    VariableName = $info.VariableName
                    Digest       = $info.Digest
                }
            }
        }
    }
    return $inventory
}

# Main execution
$inventory = Get-ImageInventory

if ($JSON) {
    $inventory | ConvertTo-Json -Depth 5
    return
}

Write-Host ""
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host "  Pinned Image Inventory" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host ""

$inventory | Sort-Object Stack, Service | ForEach-Object {
    $tagDisplay = $_.Tag
    if ($_.IsVariable) {
        $tagDisplay = "$($_.Tag) (resolves to '$($_.ResolvedTag)')"
    }
    Write-Host ("  {0,-20} {1,-22} {2}/{3}:{4}" -f $_.Stack, $_.Service, $_.Registry, $_.Repository, $tagDisplay) -ForegroundColor White
}

Write-Host ""
Write-Host "Total images: $($inventory.Count)" -ForegroundColor Cyan
Write-Host ""
