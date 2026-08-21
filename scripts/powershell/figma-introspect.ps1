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
# Canonicalize every --node here rather than trusting the caller: an agent that
# copies the id out of a deep link hands over the URL form ('12-345'), sometimes
# with the tracking suffix still attached. The API answers such a request with an
# empty node set, which surfaces downstream (and in MCP servers) as the
# misleading "the provided node ID was not found in the file".
if ($nodes.Count -gt 0) {
    $normalizedNodes = @()
    foreach ($rawNode in $nodes) {
        $canonicalNode = ConvertTo-FigmaNodeId $rawNode
        if (-not $canonicalNode) {
            Write-FigmaStderr "ERROR: --node '$rawNode' is not a Figma node id. Expected '12:345' (the URL form 'node-id=12-345' is accepted), or 'I12:345;678:901' for a nested instance."
            exit 1
        }
        $normalizedNodes += $canonicalNode
    }
    $nodes = $normalizedNodes
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
    $sourcesJson = $null
    if ($fileKey) {
        Write-FigmaStderr "INFO: introspecting file $fileKey at depth $depth..."
        $fileJson = (Invoke-FigmaApi "/files/${fileKey}?depth=$depth") | ConvertFrom-Json

        # Optionally enrich with specific node detail (e.g. from parsed Figma links).
        if ($nodes.Count -gt 0) {
            # ';' chains the segments of a nested-instance id ('I12:345;678:901')
            # and is also a legal query sub-delimiter that some stacks still parse
            # as a second parameter separator — which would truncate the id
            # server-side and return no node for it. Downstream, a linked node
            # absent from the snapshot never satisfies the coverage check, so the
            # hook would re-introspect forever instead of ever reaching 'fresh'.
            # Percent-encode it so the id arrives whole.
            $ids = ($nodes -join ',').Replace(';', '%3B')
            $nodesJson = (Invoke-FigmaApi "/files/$fileKey/nodes?ids=$ids") | ConvertFrom-Json

            # -----------------------------------------------------------------
            # Source components. A linked node is almost always an INSTANCE, and
            # an instance is the FLATTENED rendering of a main component: its
            # overrides are applied, its variant is fixed, and the definition an
            # implementation should be written against lives elsewhere. Reading
            # the instance is how a spec ends up describing one appearance of a
            # component rather than the component.
            #
            # This is "right-click > show source", automated. Components living
            # in another library file are not fetched: that would need the
            # library's file key, which this run does not have.
            $componentIds = [System.Collections.Generic.HashSet[string]]::new()
            function Find-InstanceComponents {
                param($Node)
                if ($null -eq $Node) { return }
                if ($Node.type -eq 'INSTANCE' -and $Node.componentId) {
                    [void]$componentIds.Add([string]$Node.componentId)
                }
                foreach ($child in @($Node.children)) { Find-InstanceComponents $child }
            }
            foreach ($prop in @($nodesJson.nodes.PSObject.Properties)) {
                Find-InstanceComponents $prop.Value.document
            }
            if ($componentIds.Count -gt 0) {
                $srcIds = (@($componentIds) | Select-Object -First 50) -join ','
                $srcIds = $srcIds.Replace(';', '%3B')
                Write-FigmaStderr "INFO: resolving $($componentIds.Count) source component(s) behind the linked instance(s)..."
                # Non-fatal on purpose: a missing source degrades the context, it
                # does not invalidate it — the linked nodes are already in hand.
                try {
                    $sourcesJson = (Invoke-FigmaApi "/files/$fileKey/nodes?ids=$srcIds") | ConvertFrom-Json
                } catch {
                    Write-FigmaStderr 'WARN: could not resolve the source components; the snapshot keeps the instances only.'
                    $sourcesJson = $null
                }
            }
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
        sources       = $sourcesJson
    }
    ConvertTo-FigmaJson $snapshot | Set-Content -LiteralPath $cache -Encoding utf8
} catch {
    if ($_.Exception.Message) { Write-FigmaStderr "ERROR: $($_.Exception.Message)" }
    exit 1
}

Write-FigmaStderr "INFO: snapshot written to $cache"

# Keep a copy keyed by file so a later run for THIS file can be answered from
# cache instead of re-fetching. The current slot is a single one: without the
# store, alternating between two features that target different Figma files
# evicts the snapshot every time and the "fresh" path never hits. Copying (not
# moving) keeps the well-known path authoritative for the agent.
if ($fileKey) {
    $store = Get-FigmaSnapshotStorePath $fileKey
    if ($store) {
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $store) | Out-Null
            Copy-Item -LiteralPath $cache -Destination $store -Force
        } catch {
            Write-FigmaStderr "WARN: could not keep a per-file copy of the snapshot at $store."
        }
    }
}

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
