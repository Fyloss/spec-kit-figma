#!/usr/bin/env pwsh
# =============================================================================
# figma-introspect.ps1 — autonomous page/frame enumeration for a Figma file
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-introspect.sh (same contract).
# Fetches the file structure (pages and top-level frames) and writes a local
# cache snapshot the agent can reason over. Supports autonomous discovery at
# three levels of the Figma hierarchy (organization > team > project > file):
#   - a whole team    (--team)    -> enumerate every project, then every file
#   - a whole project (--project) -> enumerate every file
#   - a single file   (--file)    -> introspect pages and frames
# No per-page human confirmation is required for autonomous traversal.
#
# Usage:
#   figma-introspect.ps1 --file <fileKey> [--node <id> ...] [--depth N] [--config <path>]
#   figma-introspect.ps1 --project <projectId> [--config <path>]
#   figma-introspect.ps1 --team <teamId> [--team <teamId> ...] [--config <path>]
# --config points at a custom figma.projects.config.json (defaults to
# $FIGMA_CONFIG, then <root>/figma.projects.config.json) — same contract as the
# sibling validate/detect/resolve scripts.
# Output: writes <root>/.figma/cache/context-snapshot.json and prints an index.
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$fileKey = ''
$projectId = ''
$depth = '2'
$nodes = @()
$teams = @()

$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        '--file'    { $fileKey = [string]$args[$i + 1]; $i += 2 }
        '--project' { $projectId = [string]$args[$i + 1]; $i += 2 }
        '--team'    { $teams += [string]$args[$i + 1]; $i += 2 }
        '--node'    { $nodes += [string]$args[$i + 1]; $i += 2 }
        '--depth'   { $depth = [string]$args[$i + 1]; $i += 2 }
        '--config'  { $env:FIGMA_CONFIG = [string]$args[$i + 1]; $i += 2 }
        default     { Write-FigmaStderr "ERROR: unknown arg '$($args[$i])'"; exit 1 }
    }
}

# Crash early: validate every argument before any network call.
if (-not $fileKey -and -not $projectId -and $teams.Count -eq 0) {
    Write-FigmaStderr 'ERROR: one of --file <fileKey>, --project <projectId> or --team <teamId> is required'
    exit 1
}
if ($depth -notmatch '^[1-9][0-9]*$') {
    Write-FigmaStderr "ERROR: --depth must be a positive integer (got '$depth')"
    exit 1
}
if ($env:FIGMA_CONFIG -and -not (Test-Path -LiteralPath $env:FIGMA_CONFIG -PathType Leaf)) {
    Write-FigmaStderr "ERROR: config not found: $($env:FIGMA_CONFIG)"
    exit 1
}

$cache = Get-FigmaCachePath
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cache)

try {
    # ---------------------------------------------------------------------------
    # Level 1 — Teams: enumerate every project of every team, then every file.
    # Builds a nested teams[] -> projects[] -> files[] index
    # (organization > team > project > file).
    # ---------------------------------------------------------------------------
    $teamsIndex = $null
    if ($teams.Count -gt 0) {
        Write-FigmaStderr "INFO: enumerating projects/files for $($teams.Count) team(s)..."
        $teamsIndex = @()
        foreach ($team in $teams) {
            Write-FigmaStderr "INFO:   team $team -> listing projects..."
            $teamProjects = (Invoke-FigmaApi "/teams/$team/projects") | ConvertFrom-Json
            $teamName = Get-JsonValue $teamProjects @('name')
            $projectsIndex = @()
            foreach ($proj in @(Get-JsonValue $teamProjects @('projects') @())) {
                # ($pid is a read-only PowerShell automatic variable, hence projId.)
                $projId = [string](Get-JsonValue $proj @('id') '')
                $pname = Get-JsonValue $proj @('name')
                if (-not $projId) { continue }
                Write-FigmaStderr "INFO:     project $projId ($pname) -> listing files..."
                $projectFiles = (Invoke-FigmaApi "/projects/$projId/files") | ConvertFrom-Json
                $files = @()
                foreach ($f in @(Get-JsonValue $projectFiles @('files') @())) {
                    $files += [ordered]@{
                        key          = Get-JsonValue $f @('key')
                        name         = Get-JsonValue $f @('name')
                        lastModified = Get-JsonValue $f @('last_modified')
                    }
                }
                $projectsIndex += [ordered]@{ id = $projId; name = $pname; files = $files }
            }
            $teamsIndex += [ordered]@{
                id = $team
                name = if ("$teamName" -eq '') { $null } else { $teamName }
                projects = $projectsIndex
            }
        }
        # Default to the first discovered file when none was explicitly given.
        if (-not $fileKey -and -not $projectId) {
            foreach ($t in $teamsIndex) {
                foreach ($p in $t.projects) {
                    foreach ($f in $p.files) {
                        if (-not $fileKey -and $f.key) { $fileKey = [string]$f.key }
                    }
                }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Level 2 — Project: enumerate all files of a single Figma project.
    # ---------------------------------------------------------------------------
    if ($projectId) {
        Write-FigmaStderr "INFO: enumerating files for project $projectId..."
        $singleProjectFiles = (Invoke-FigmaApi "/projects/$projectId/files") | ConvertFrom-Json
        foreach ($f in @(Get-JsonValue $singleProjectFiles @('files') @())) {
            Write-Output "$(Get-JsonValue $f @('key'))`t$(Get-JsonValue $f @('name'))"
        }
        if (-not $fileKey) {
            # Default to the first file when none was explicitly given.
            $first = @(Get-JsonValue $singleProjectFiles @('files') @()) | Select-Object -First 1
            if ($null -ne $first) { $fileKey = [string](Get-JsonValue $first @('key') '') }
        }
    }

    # Resolve the effective design-context engine (REST by default; MCP when
    # reachable, otherwise transparent REST fallback). This script IS the portable
    # REST engine, so it always produces a REST snapshot — but it records the
    # effective engine so the agent knows whether richer MCP context is
    # additionally available for this run. When contextSource='mcp' is required
    # but the server is unreachable and mcp.fallbackToRest=false,
    # Resolve-FigmaContextSource throws: propagate that hard error instead of
    # silently degrading to REST.
    $contextSource = Resolve-FigmaContextSource
    Write-FigmaStderr "INFO: design-context engine = $contextSource"

    # ---------------------------------------------------------------------------
    # Level 3 — File: introspect pages and top-level frames of the resolved file.
    # When a team/project was enumerated but yielded no file, the snapshot still
    # carries the team/project index so the agent can pick a file to drill into.
    # ---------------------------------------------------------------------------
    $fileJson = $null
    $nodesJson = $null
    if ($fileKey) {
        Write-FigmaStderr "INFO: introspecting file $fileKey at depth $depth..."
        $fileJson = (Invoke-FigmaApi "/files/${fileKey}?depth=$depth") | ConvertFrom-Json

        # Optionally enrich with specific node detail (e.g. from parsed Figma links).
        if ($nodes.Count -gt 0) {
            $ids = $nodes -join ','
            $nodesJson = (Invoke-FigmaApi "/files/$fileKey/nodes?ids=$ids") | ConvertFrom-Json
        }
    } else {
        Write-FigmaStderr 'WARN: no file resolved from the team/project enumeration; snapshot will contain the project index only.'
    }

    $pages = @()
    if ($null -ne $fileJson) {
        foreach ($page in @(Get-JsonValue $fileJson @('document', 'children') @())) {
            $frames = @()
            foreach ($child in @(Get-JsonValue $page @('children') @())) {
                if ((Get-JsonValue $child @('type')) -eq 'FRAME') {
                    $frames += [ordered]@{
                        id   = Get-JsonValue $child @('id')
                        name = Get-JsonValue $child @('name')
                        type = Get-JsonValue $child @('type')
                    }
                }
            }
            $pages += [ordered]@{
                id     = Get-JsonValue $page @('id')
                name   = Get-JsonValue $page @('name')
                frames = $frames
            }
        }
    }

    $snapshot = [ordered]@{
        fileId        = if ($fileKey) { $fileKey } else { $null }
        projectId     = if ($projectId) { $projectId } else { $null }
        teams         = $teamsIndex
        contextSource = $contextSource
        generatedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        lastModified  = Get-JsonValue $fileJson @('lastModified')
        version       = Get-JsonValue $fileJson @('version')
        pages         = $pages
        components    = Get-JsonValue $fileJson @('components')
        componentSets = Get-JsonValue $fileJson @('componentSets')
        styles        = Get-JsonValue $fileJson @('styles')
        nodes         = $nodesJson
    }
    ConvertTo-FigmaJson $snapshot | Set-Content -LiteralPath $cache -Encoding utf8
} catch {
    if ($_.Exception.Message) { Write-FigmaStderr "ERROR: $($_.Exception.Message)" }
    exit 1
}

Write-FigmaStderr "INFO: snapshot written to $cache"

if ($teams.Count -gt 0) {
    Write-Output '----- TEAM / PROJECT / FILE INDEX -----'
    foreach ($t in @($teamsIndex)) {
        $suffix = if ($t.name) { "($($t.name))" } else { '' }
        Write-Output ("team $($t.id) $suffix".TrimEnd())
        foreach ($p in @($t.projects)) {
            Write-Output "  project $($p.id) ($($p.name)) — $(@($p.files).Count) file(s)"
            foreach ($f in @($p.files)) {
                Write-Output "    $($f.key)`t$($f.name)"
            }
        }
    }
}

if ($fileKey) {
    Write-Output '----- PAGE INDEX -----'
    foreach ($p in @($pages)) {
        Write-Output "$($p.id)`t$($p.name)`t($(@($p.frames).Count) frames)"
    }
}
exit 0
