#!/usr/bin/env pwsh
# =============================================================================
# figma-detect-target.ps1 — decide whether Figma integration applies to a target
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-detect-target.sh (same contract).
# Usage: figma-detect-target.ps1 <target-name> [path/to/figma.projects.config.json]
# Prints a JSON object on stdout:
#   { "enabled": true|false, "reason": "...", "role": "...", "figmaFileId": "...",
#     "figmaProjectId": "...", "figmaTeamId": "...", "figmaTeamIds": [...],
#     "submodulePath": "...", "node": { ...full target... } }
# Exit code: 0 with JSON for every mapping outcome (enabled, excluded,
# not-mapped, disabled); non-zero only for structural errors (bad config/args).
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

if (-not $args -or -not $args[0]) {
    Write-FigmaStderr 'Usage: figma-detect-target.ps1 <target-name> [config]'
    exit 1
}
$target = [string]$args[0]
$config = if ($args.Count -ge 2 -and $args[1]) { [string]$args[1] } else { Get-FigmaDefaultConfig }
if (-not (Test-FigmaConfig $config)) { exit 1 }

$cfg = Read-FigmaJsonFile $config
$mode = [string](Get-JsonValue $cfg @('mode') '')
if ($mode -notin @('single-repo', 'mono-repo', 'multi-repo')) {
    Write-FigmaStderr "ERROR: unknown or missing mode '$mode' in $config"
    exit 1
}

function Emit-Disabled {
    param([string]$Reason)
    ConvertTo-FigmaJson ([ordered]@{
        enabled = $false; reason = $Reason; target = $target; role = $null
        figmaFileId = $null; figmaProjectId = $null; figmaTeamId = $null
        figmaTeamIds = $null; submodulePath = $null; node = $null
    })
}

# Excluded list wins and is silent.
$excluded = Get-JsonValue $cfg @('excluded') @()
if (@($excluded) -contains $target) {
    Emit-Disabled 'excluded'
    exit 0
}

$node = $null
if ($mode -eq 'multi-repo') {
    $node = Get-JsonValue $cfg @('submodules', $target)
} elseif ($mode -eq 'single-repo') {
    # single-repo: there is exactly one front-end target -> always the repo.
    $node = Get-JsonValue $cfg @('repo')
} else {
    # mono-repo: the target may be the repo itself or one of its apps/libs.
    $apps = @(Get-JsonValue $cfg @('repo', 'monorepo', 'apps') @())
    $libs = @(Get-JsonValue $cfg @('repo', 'monorepo', 'libs') @())
    $repoSubmodulePath = [string](Get-JsonValue $cfg @('repo', 'submodulePath') '')
    if (($apps + $libs) -contains $target -or $target -eq 'repo' -or $target -eq $repoSubmodulePath) {
        $node = Get-JsonValue $cfg @('repo')
    }
}

if ($null -eq $node) {
    Emit-Disabled 'not-mapped'
    exit 0
}

$enabled = (Get-JsonValue $node @('enabled')) -eq $true
ConvertTo-FigmaJson ([ordered]@{
    enabled        = $enabled
    reason         = if ($enabled) { 'mapped' } else { 'disabled' }
    target         = $target
    role           = Get-JsonValue $node @('role')
    figmaFileId    = Get-JsonValue $node @('figmaFileId')
    figmaProjectId = Get-JsonValue $node @('figmaProjectId')
    figmaTeamId    = Get-JsonValue $node @('figmaTeamId')
    figmaTeamIds   = Get-JsonValue $node @('figmaTeamIds')
    submodulePath  = Get-JsonValue $node @('submodulePath')
    node           = $node
})
exit 0
