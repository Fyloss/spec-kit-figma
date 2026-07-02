#!/usr/bin/env pwsh
# =============================================================================
# figma-validate-config.ps1 — validate figma.projects.config.json
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-validate-config.sh (same contract).
# Usage: figma-validate-config.ps1 [path/to/figma.projects.config.json]
# Exit codes: 0 = valid, 1 = structural error, 2 = unresolved placeholder
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$config = if ($args.Count -ge 1 -and $args[0]) { [string]$args[0] } else { Get-FigmaDefaultConfig }
if (-not (Test-FigmaConfig $config)) { exit 1 }

$cfg = Read-FigmaJsonFile $config
$mode = [string](Get-JsonValue $cfg @('mode') '')
switch ($mode) {
    'multi-repo' {
        $submodules = Get-JsonValue $cfg @('submodules')
        if ($null -eq $submodules -or $submodules -isnot [PSCustomObject]) {
            Write-FigmaStderr "ERROR: mode 'multi-repo' requires a 'submodules' object"
            exit 1
        }
    }
    { $_ -in 'mono-repo', 'single-repo' } {
        $repo = Get-JsonValue $cfg @('repo')
        if ($null -eq $repo -or $repo -isnot [PSCustomObject]) {
            Write-FigmaStderr "ERROR: mode '$mode' requires a 'repo' object"
            exit 1
        }
    }
    default {
        Write-FigmaStderr "ERROR: .mode must be 'single-repo', 'mono-repo' or 'multi-repo'"
        exit 1
    }
}

# Per-target structural rules, mirroring the JSON schema's definitions/target:
# 'enabled' (boolean) and 'role' (enum) are required, and every target must
# declare at least one of figmaFileId / figmaProjectId / figmaTeamId / figmaTeamIds.
# The schema (config/figma.projects.config.schema.json) stays the source of
# truth; CI validates the examples against it, this script is the portable
# runtime subset.
$roles = @('design-system', 'app-host', 'app', 'lib')
$entries = @()
if ($mode -eq 'multi-repo') {
    $submodules = Get-JsonValue $cfg @('submodules')
    if ($null -ne $submodules) {
        foreach ($p in $submodules.PSObject.Properties) {
            $entries += [pscustomobject]@{ name = $p.Name; t = $p.Value }
        }
    }
} else {
    $entries += [pscustomobject]@{ name = 'repo'; t = (Get-JsonValue $cfg @('repo') ([pscustomobject]@{})) }
}

$targetErrors = @()
foreach ($e in $entries) {
    $t = $e.t
    $enabledProp = if ($null -ne $t) { $t.PSObject.Properties['enabled'] } else { $null }
    if ($null -eq $enabledProp -or $enabledProp.Value -isnot [bool]) {
        $targetErrors += "$($e.name): missing required boolean field `"enabled`""
    }
    $role = Get-JsonValue $t @('role')
    if ($role -isnot [string] -or $roles -notcontains $role) {
        $targetErrors += "$($e.name): `"role`" must be one of $($roles -join '/')"
    }
    $hasAnyId = $false
    foreach ($idKey in @('figmaFileId', 'figmaProjectId', 'figmaTeamId', 'figmaTeamIds')) {
        if ($null -ne $t -and $null -ne $t.PSObject.Properties[$idKey]) { $hasAnyId = $true; break }
    }
    if (-not $hasAnyId) {
        $targetErrors += "$($e.name): at least one of figmaFileId/figmaProjectId/figmaTeamId/figmaTeamIds is required"
    }
}
if ($targetErrors.Count -gt 0) {
    Write-FigmaStderr 'ERROR: invalid target declaration(s):'
    foreach ($line in $targetErrors) { Write-FigmaStderr "  - $line" }
    exit 1
}

# Reject any unresolved REPLACE_WITH_* placeholder in any figma id
# (figmaFileId / figmaProjectId / figmaTeamId / each figmaTeamIds entry),
# anywhere in the document — same recursive scan as the jq `..` walk.
function Find-FigmaPlaceholders {
    param($Object)
    $found = @()
    if ($null -eq $Object) { return $found }
    if ($Object -is [PSCustomObject]) {
        foreach ($idKey in @('figmaFileId', 'figmaProjectId', 'figmaTeamId')) {
            $v = Get-JsonValue $Object @($idKey)
            if ($v -is [string] -and $v.StartsWith('REPLACE_WITH_')) { $found += $v }
        }
        foreach ($v in @(Get-JsonValue $Object @('figmaTeamIds') @())) {
            if ($v -is [string] -and $v.StartsWith('REPLACE_WITH_')) { $found += $v }
        }
        foreach ($p in $Object.PSObject.Properties) {
            $found += Find-FigmaPlaceholders $p.Value
        }
    } elseif ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        foreach ($item in $Object) { $found += Find-FigmaPlaceholders $item }
    }
    return $found
}

$placeholders = @(Find-FigmaPlaceholders $cfg)
if ($placeholders.Count -gt 0) {
    Write-FigmaStderr 'ERROR: unresolved Figma id placeholder(s) found — replace them with real ids before running SpecKit:'
    foreach ($ph in $placeholders) { Write-FigmaStderr "  - $ph" }
    exit 2
}

# Credentials must come from env or ci-secret, never inline.
$src = [string](Get-JsonValue $cfg @('figma', 'credentials', 'source') '')
if ($src -notin @('env', 'ci-secret')) {
    Write-FigmaStderr "ERROR: figma.credentials.source must be 'env' or 'ci-secret'"
    exit 1
}
# The scan is scoped to .figma.credentials: elsewhere, 'token'/'pat' are
# legitimate user-chosen keys (e.g. a Figma page named 'token' in
# pageToPackageMapping or a submodule named 'pat').
$credentials = Get-JsonValue $cfg @('figma', 'credentials')
if ($null -ne $credentials -and $credentials -is [PSCustomObject]) {
    foreach ($secretKey in @('token', 'pat', 'accessToken')) {
        if ($null -ne $credentials.PSObject.Properties[$secretKey]) {
            Write-FigmaStderr 'ERROR: a secret-looking field was found in the config. Tokens MUST live in the OS credential store (FIGMA_PAT_COMMAND), an environment variable, or a CI secret, never in this file.'
            exit 1
        }
    }
}

# Design-context engine: 'rest' (default, portable) or 'mcp' (optional, REST fallback).
$ctx = [string](Get-FigmaContextSource $config)
if ($ctx -notin @('rest', 'mcp')) {
    Write-FigmaStderr "ERROR: figma.contextSource must be 'rest' or 'mcp'"
    exit 1
}

Write-Output "OK: $config is valid (mode=$mode, credentials.source=$src, contextSource=$ctx)."
exit 0
