#!/usr/bin/env pwsh
# =============================================================================
# figma-ensure-context.ps1 — guarantee a fresh Figma snapshot (automatic hook)
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-ensure-context.sh (same contract).
# Invoked automatically at the start of /speckit.specify and /speckit.tasks so
# the developer never has to run /speckit.figma.introspect by hand. It decides
# whether Figma applies to the run and re-introspects only when the snapshot
# is missing or stale.
#
# Designed as a SAFE NO-OP for generation flow: every configuration problem
# (missing config, unresolved placeholders, excluded target, failed
# introspection, ...) is reported as a skip reason with exit 0 so spec/tasks
# generation is never blocked. It is NOT silent about *why*: a failed
# introspection carries a machine-readable `code` (NETWORK|AUTH|NOT_FOUND) so the
# agent reports the real cause instead of guessing "authentication required".
# Non-zero exits are reserved for unexpected internal errors and bad CLI args.
#
# Usage:
#   figma-ensure-context.ps1 [<target-name>] [--config <path>]
#     [--max-age-minutes N] [--input <text> | --input -] [--dry-run]
# <target-name> defaults to "repo" (single-/mono-repo); for multi-repo it is
# auto-resolved only when exactly one enabled target exists.
# --input carries the user's raw feature input ("-" reads stdin): any direct
# Figma links it contains are parsed (figma-parse-links.ps1) and become
# AUTHORITATIVE design targets — the linked file/nodes override the
# config-derived scope, and a snapshot that does not cover the linked nodes is
# treated as stale. Same contract as /speckit.figma.introspect section 0.
# FIGMA_SNAPSHOT_MAX_AGE_MINUTES overrides the default freshness window (60).
#
# Prints a JSON status object on stdout:
#   { "ran": true|false, "reason": "...", "code": "NETWORK|AUTH|NOT_FOUND|...|null",
#     "target": "...",
#     "snapshot": "...", "links": [...], "introspectArgs": [...],
#     "mustInject": true|false,        # section is mandatory in spec/plan/tasks
#     "linkScope": "none|frame|broad", # "broad" => confirm a frame before tasks
#     "candidateFrames": [...],        # frames to confirm when linkScope=broad
#     "specSection": "...", "planSection": "...", "tasksSection": "..." }
# When mustInject=true the agent MUST paste the rendered <phase>Section file
# verbatim into the generated document, then complete the judgement fields.
# Reasons: introspected | fresh | dry-run | no-config | invalid-config |
#   unresolved-placeholders | ambiguous-target | target-excluded |
#   target-not-mapped | target-disabled | introspect-failed
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$target = ''
$maxAgeMin = if ($env:FIGMA_SNAPSHOT_MAX_AGE_MINUTES) { $env:FIGMA_SNAPSHOT_MAX_AGE_MINUTES } else { '60' }
$dryRun = $false
$inputText = ''
$i = 0
while ($i -lt $args.Count) {
    switch -Regex ($args[$i]) {
        '^--config$' { $env:FIGMA_CONFIG = [string]$args[$i + 1]; $i += 2; continue }
        '^--max-age-minutes$' { $maxAgeMin = [string]$args[$i + 1]; $i += 2; continue }
        '^--input$' {
            if ($i + 1 -ge $args.Count) {
                Write-FigmaStderr "ERROR: --input requires a value (text or '-' for stdin)"
                exit 1
            }
            if ($args[$i + 1] -eq '-') {
                $inputText = [Console]::In.ReadToEnd()
            } else {
                $inputText = [string]$args[$i + 1]
            }
            $i += 2; continue
        }
        '^--dry-run$' { $dryRun = $true; $i += 1; continue }
        '^--' { Write-FigmaStderr "ERROR: unknown arg '$($args[$i])'"; exit 1 }
        default {
            if ($target) { Write-FigmaStderr "ERROR: unexpected extra argument '$($args[$i])'"; exit 1 }
            $target = [string]$args[$i]; $i += 1
        }
    }
}
if ($maxAgeMin -notmatch '^[1-9][0-9]*$') {
    Write-FigmaStderr "ERROR: --max-age-minutes must be a positive integer (got '$maxAgeMin')"
    exit 1
}
$maxAgeMin = [int]$maxAgeMin

$config = Get-FigmaDefaultConfig
$snapshotPath = Get-FigmaCachePath
$introspectArgs = @()
$links = @()          # parsed link objects
$linkFile = ''
$linkNodes = @()
# Injection contract: filled once a usable snapshot exists (introspected|fresh).
$mustInject = $false
$linkScope = 'none'          # none | frame | broad
$candidateFrames = @()       # top-level frames to confirm when linkScope=broad
$specSection = ''
$planSection = ''
$tasksSection = ''
# Machine-readable failure cause from Invoke-FigmaApi (NETWORK|AUTH|NOT_FOUND|...),
# read back via FIGMA_DIAG_FILE when introspection fails. Empty otherwise.
$failureCode = ''

function Emit-Status { # $Ran (bool), $Reason
    param([bool]$Ran, [string]$Reason)
    ConvertTo-FigmaJson ([ordered]@{
        ran             = $Ran
        reason          = $Reason
        code            = if ($script:failureCode) { $script:failureCode } else { $null }
        target          = if ($script:target) { $script:target } else { $null }
        snapshot        = $script:snapshotPath
        links           = @($script:links)
        mustInject      = $script:mustInject
        linkScope       = $script:linkScope
        candidateFrames = @($script:candidateFrames)
        specSection     = if ($script:specSection) { $script:specSection } else { $null }
        planSection     = if ($script:planSection) { $script:planSection } else { $null }
        tasksSection    = if ($script:tasksSection) { $script:tasksSection } else { $null }
        introspectArgs  = @($script:introspectArgs | ForEach-Object { [string]$_ })
    })
}

# Classify the directly-linked nodes against the snapshot and, for broad links
# (file/page level, no specific FRAME), collect the candidate top-level frames so
# the agent enumerates them for creative confirmation instead of bailing out.
function Compute-LinkScope {
    $script:linkScope = 'none'
    $script:candidateFrames = @()
    if (-not $script:linkFile) { return }
    if (-not (Test-Path -LiteralPath $script:snapshotPath -PathType Leaf)) {
        $script:linkScope = 'broad'
        return
    }
    $snap = $null
    try { $snap = Read-FigmaJsonFile $script:snapshotPath } catch { }
    if ($script:linkNodes.Count -eq 0) {
        $script:linkScope = 'broad'
    } else {
        $script:linkScope = 'frame'
        foreach ($n in $script:linkNodes) {
            # The creative is NOT pinned only when a linked node is a page/canvas or
            # the document root (it covers many frames). A node-id that resolves to a
            # specific frame — top-level, nested, or any other deep-fetched element —
            # is a confirmed creative and must stay 'frame'.
            # Detect "broad" two ways: the id matches an indexed page (works even when
            # the page node was not deep-fetched), OR the deep-fetched node's Figma
            # type is CANVAS/DOCUMENT (covers a document-root link not in pages[]).
            $isPage = $false
            foreach ($p in @(Get-JsonValue $snap @('pages') @())) {
                if ((Get-JsonValue $p @('id')) -eq $n) { $isPage = $true; break }
            }
            $nodeType = [string](Get-JsonValue $snap @('nodes', 'nodes', $n, 'document', 'type') '')
            if ($isPage -or $nodeType -in @('CANVAS', 'DOCUMENT')) {
                $script:linkScope = 'broad'
                break
            }
        }
    }
    if ($script:linkScope -eq 'broad') {
        $frames = @()
        foreach ($p in @(Get-JsonValue $snap @('pages') @())) {
            foreach ($f in @(Get-JsonValue $p @('frames') @())) {
                $frames += [ordered]@{
                    id   = Get-JsonValue $f @('id')
                    name = Get-JsonValue $f @('name')
                    page = Get-JsonValue $p @('name')
                }
            }
        }
        $script:candidateFrames = $frames
    }
}

# Stale rendered sections from a previous run must not outlive it: the verifier
# (figma-verify-section.ps1) keys "Figma applied to this run" on the existence of
# .figma/cache/section.<phase>.md. Clear-RenderedSections drops them so only THIS
# run's renders remain.
#
# It is called on the paths where Figma DEFINITIVELY does not apply (no/invalid
# config, excluded target) and at the start of Prepare-Injection (just before a
# re-render) — but deliberately NOT on a transient introspect-failure. Wiping on
# a transient failure would erase a prior phase's still-valid render, so the
# verifier would report "not-applicable" and let a --strict CI gate silently pass
# for a run where Figma genuinely applies; leaving the prior render keeps the
# gate honest (fail-closed, consistent with verify's own --strict policy).
function Clear-RenderedSections {
    Remove-Item -Path (Join-Path (Get-FigmaCacheDir) 'section.*.md') -Force -ErrorAction SilentlyContinue
}

# Render the ready-to-paste spec/plan/tasks sections from the fresh snapshot so
# the agent only has to paste them — the section can no longer be silently
# omitted. Render failures are non-fatal (the agent falls back to the template).
function Prepare-Injection {
    $script:mustInject = $true
    # Re-render starts clean so only this run's sections survive — a per-phase
    # render failure below then leaves NO stale file for that phase.
    Clear-RenderedSections
    Compute-LinkScope
    $linksJson = ConvertTo-FigmaJson @($script:links) -Compress
    $candidatesJson = ConvertTo-FigmaJson @($script:candidateFrames) -Compress
    foreach ($phase in @('spec', 'plan', 'tasks')) {
        # Capture stdout (the rendered file path) separately from stderr so a render
        # failure (missing template, bad JSON, ...) is SURFACED, not silently turned
        # into a null section with no diagnostic.
        $out = ''
        $errFile = New-TemporaryFile
        try {
            $out = & "$PSScriptRoot/figma-render-section.ps1" --phase $phase --config $script:config `
                --snapshot $script:snapshotPath --links $linksJson --candidate-frames $candidatesJson `
                2>$errFile.FullName
            if ($LASTEXITCODE -ne 0) {
                Write-FigmaStderr "WARN: figma-render-section.ps1 failed to render the '$phase' section: $(Get-Content -LiteralPath $errFile.FullName -Raw)"
                $out = ''
            } else {
                $out = ([string]($out | Select-Object -Last 1)).Trim()
            }
        } catch {
            Write-FigmaStderr "WARN: figma-render-section.ps1 failed to render the '$phase' section: $($_.Exception.Message)"
            $out = ''
        } finally {
            Remove-Item -LiteralPath $errFile.FullName -Force -ErrorAction SilentlyContinue
        }
        switch ($phase) {
            'spec'  { $script:specSection = $out }
            'plan'  { $script:planSection = $out }
            'tasks' { $script:tasksSection = $out }
        }
    }
}

# True when the current snapshot already targets the linked file and contains
# every linked node — only then can a link-driven run be considered fresh.
function Test-SnapshotCoversLinks {
    if (-not $script:linkFile) { return $true }
    $snap = $null
    try { $snap = Read-FigmaJsonFile $script:snapshotPath } catch { return $false }
    if ((Get-JsonValue $snap @('fileId')) -ne $script:linkFile) { return $false }
    foreach ($n in $script:linkNodes) {
        $nodesObj = Get-JsonValue $snap @('nodes', 'nodes')
        if ($null -eq $nodesObj -or $null -eq $nodesObj.PSObject.Properties[$n]) { return $false }
    }
    return $true
}

if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    Write-FigmaStderr "INFO: no $(Split-Path -Leaf $config) found; proceeding without Figma context."
    Clear-RenderedSections
    Emit-Status $false 'no-config'
    exit 0
}

# Reuse the canonical validator instead of re-encoding its rules (exit 2 =
# unresolved placeholders, 1 = structural error).
$validateOut = & "$PSScriptRoot/figma-validate-config.ps1" $config 2>&1 | Out-String
$validateRc = $LASTEXITCODE
if ($validateRc -eq 2) {
    Write-FigmaStderr "WARN: $($validateOut.Trim())"
    Clear-RenderedSections
    Emit-Status $false 'unresolved-placeholders'
    exit 0
} elseif ($validateRc -ne 0) {
    Write-FigmaStderr "WARN: $($validateOut.Trim())"
    Clear-RenderedSections
    Emit-Status $false 'invalid-config'
    exit 0
}

if (-not $target) {
    $cfg = Read-FigmaJsonFile $config
    $mode = [string](Get-JsonValue $cfg @('mode') '')
    if ($mode -eq 'multi-repo') {
        # Only auto-resolve when the choice is unambiguous.
        $enabled = @()
        $submodules = Get-JsonValue $cfg @('submodules')
        if ($null -ne $submodules) {
            foreach ($p in $submodules.PSObject.Properties) {
                if ((Get-JsonValue $p.Value @('enabled')) -eq $true) { $enabled += $p.Name }
            }
        }
        if ($enabled.Count -eq 1) {
            $target = $enabled[0]
        } else {
            Write-FigmaStderr "WARN: multi-repo config with $($enabled.Count) enabled targets ($($enabled -join ' ')); pass the target name explicitly."
            Clear-RenderedSections
            Emit-Status $false 'ambiguous-target'
            exit 0
        }
    } else {
        $target = 'repo'
    }
}

$detectOut = & "$PSScriptRoot/figma-detect-target.ps1" $target $config
if ($LASTEXITCODE -ne 0) {
    Write-FigmaStderr 'ERROR: figma-detect-target.ps1 failed.'
    exit 1
}
$detect = ($detectOut | Out-String) | ConvertFrom-Json
if ((Get-JsonValue $detect @('enabled')) -ne $true) {
    Clear-RenderedSections
    Emit-Status $false "target-$(Get-JsonValue $detect @('reason'))"
    exit 0
}

# Direct Figma links pasted in the feature input are authoritative design
# targets (same contract as /speckit.figma.introspect section 0): the linked
# file/nodes win over the config mapping, with node-level extraction.
if ($inputText) {
    $parsedLines = @(& "$PSScriptRoot/figma-parse-links.ps1" $inputText)
    if ($parsedLines.Count -gt 0) {
        $links = @($parsedLines | ForEach-Object { $_ | ConvertFrom-Json })
        $linkFile = [string](Get-JsonValue $links[0] @('fileId') '')
        $distinctFiles = @($links | ForEach-Object { $_.fileId } | Sort-Object -Unique).Count
        if ($distinctFiles -gt 1) {
            Write-FigmaStderr "WARN: the input links reference $distinctFiles distinct Figma files; auto-introspecting the first ('$linkFile') — run /speckit.figma.introspect --file <id> for the others."
        }
        $linkNodes = @($links |
            Where-Object { $_.fileId -eq $linkFile -and $null -ne $_.nodeId } |
            ForEach-Object { [string]$_.nodeId } |
            Sort-Object -Unique)
    }
}

# Fresh = snapshot exists, is newer than the config, is younger than the
# max-age window, and covers any directly-linked file/nodes from the input.
if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
    $configTime = (Get-Item -LiteralPath $config).LastWriteTimeUtc
    $snapshotTime = (Get-Item -LiteralPath $snapshotPath).LastWriteTimeUtc
    $ageMinutes = ((Get-Date).ToUniversalTime() - $snapshotTime).TotalMinutes
    if ($configTime -le $snapshotTime -and $ageMinutes -lt $maxAgeMin -and (Test-SnapshotCoversLinks)) {
        # Figma applies and the snapshot is usable -> the section is mandatory; render it.
        Prepare-Injection
        Emit-Status $false 'fresh'
        exit 0
    }
}

if ($linkFile) {
    # Link-driven scope: introspect the linked file and drill into each linked
    # node so the snapshot carries frame-level detail (fills, typography, layout).
    $introspectArgs += @('--file', $linkFile)
    foreach ($nodeId in $linkNodes) {
        $introspectArgs += @('--node', $nodeId)
    }
    $configFileId = [string](Get-JsonValue $detect @('figmaFileId') '')
    if ($configFileId -and $configFileId -ne $linkFile) {
        Write-FigmaStderr "INFO: direct Figma link overrides the mapped file '$configFileId' for this run."
    }
} else {
    # Derive the introspection scope from the detected target (team > project >
    # file, same precedence as /speckit.figma.introspect).
    foreach ($teamId in @(Get-JsonValue $detect @('figmaTeamIds') @())) {
        $introspectArgs += @('--team', [string]$teamId)
    }
    $teamId = [string](Get-JsonValue $detect @('figmaTeamId') '')
    if ($teamId) { $introspectArgs += @('--team', $teamId) }
    $projectId = [string](Get-JsonValue $detect @('figmaProjectId') '')
    if ($projectId) { $introspectArgs += @('--project', $projectId) }
    $fileId = [string](Get-JsonValue $detect @('figmaFileId') '')
    if ($fileId) { $introspectArgs += @('--file', $fileId) }
}

if ($dryRun) {
    Emit-Status $false 'dry-run'
    exit 0
}

# Introspection output (index) goes to stderr: this script's stdout is the
# machine-readable status contract. FIGMA_DIAG_FILE lets Invoke-FigmaApi (inside
# the introspect child) record the REAL failure cause so we never hide a network
# problem behind a fabricated "authentication required".
$diagFile = New-TemporaryFile
$env:FIGMA_DIAG_FILE = $diagFile.FullName
try {
    & "$PSScriptRoot/figma-introspect.ps1" @introspectArgs --config $config |
        ForEach-Object { Write-FigmaStderr $_ }
    $introspectRc = $LASTEXITCODE
    if ($introspectRc -eq 0) {
        Prepare-Injection
        Emit-Status $true 'introspected'
    } else {
        if ((Test-Path -LiteralPath $diagFile.FullName) -and (Get-Item -LiteralPath $diagFile.FullName).Length -gt 0) {
            try {
                $diag = Read-FigmaJsonFile $diagFile.FullName
                $failureCode = [string](Get-JsonValue $diag @('code') '')
            } catch { }
        }
        # Fail-LOUD with the specific cause: the agent (and any weak LLM) must report
        # the truth, not the most-common-but-wrong "auth" guess.
        switch ($failureCode) {
            'NETWORK' {
                Write-FigmaStderr "WARN: Figma unreachable (network/proxy) for target '$target'; the script auto-retried directly. This is a connectivity problem, not a credentials one — do not report a credentials failure."
            }
            'AUTH' {
                Write-FigmaStderr "WARN: Figma auth/scope failure for target '$target'; check the PAT scopes and use the OS credential store + FIGMA_PAT_COMMAND (never a .env). See docs/CREDENTIALS.md."
            }
            'NOT_FOUND' {
                Write-FigmaStderr "WARN: Figma returned 404 for target '$target'; the file/project/team key is wrong or the PAT owner is not a member. See docs/CREDENTIALS.md."
            }
            default {
                Write-FigmaStderr "WARN: Figma introspection failed for target '$target'; proceeding without fresh design context (see errors above)."
            }
        }
        Emit-Status $false 'introspect-failed'
    }
} finally {
    Remove-Item -LiteralPath $diagFile.FullName -Force -ErrorAction SilentlyContinue
    Remove-Item Env:FIGMA_DIAG_FILE -ErrorAction SilentlyContinue
}
exit 0
