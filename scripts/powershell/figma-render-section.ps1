#!/usr/bin/env pwsh
# =============================================================================
# figma-render-section.ps1 — render a ready-to-paste Figma section from the snapshot
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-render-section.sh (same contract).
# Guarantees the Figma design section is integrated into spec.md / plan.md /
# tasks.md REGARDLESS of the agent model: instead of asking the model to
# synthesise a section from the template + snapshot + rules (which weaker models
# silently skip), this script renders the matching template with every
# DETERMINISTIC placeholder already filled from `.figma/cache/context-snapshot.json`.
# The agent only has to (1) paste the rendered block verbatim and (2) complete
# the JUDGEMENT placeholders — it can no longer omit the section.
#
# Usage:
#   figma-render-section.ps1 --phase spec|plan|tasks
#     [--config <path>] [--snapshot <path>]
#     [--links <json-array>] [--candidate-frames <json-array>] [--out <path>]
#
# Output: writes <root>/.figma/cache/section.<phase>.md (git-ignored) and prints its
# path on stdout. Templates are resolved from the workspace
# (<root>/.specify/templates/) first, then the extension checkout
# (<script>/../../templates/).
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$phase = ''
$snapshotPath = ''
$linksJson = '[]'
$candidateFramesJson = '[]'
$out = ''
$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        '--phase'            { $phase = [string]$args[$i + 1]; $i += 2 }
        '--config'           { $env:FIGMA_CONFIG = [string]$args[$i + 1]; $i += 2 }
        '--snapshot'         { $snapshotPath = [string]$args[$i + 1]; $i += 2 }
        '--links'            { $linksJson = [string]$args[$i + 1]; $i += 2 }
        '--candidate-frames' { $candidateFramesJson = [string]$args[$i + 1]; $i += 2 }
        '--out'              { $out = [string]$args[$i + 1]; $i += 2 }
        default              { Write-FigmaStderr "ERROR: unknown arg '$($args[$i])'"; exit 1 }
    }
}

switch ($phase) {
    'spec'  { $templateName = 'spec-figma-section.template.md' }
    'plan'  { $templateName = 'plan-figma-section.template.md' }
    'tasks' { $templateName = 'tasks-figma-section.template.md' }
    default { Write-FigmaStderr "ERROR: --phase must be one of spec|plan|tasks (got '$phase')"; exit 1 }
}

$root = Get-FigmaRepoRoot
if (-not $snapshotPath) { $snapshotPath = Get-FigmaCachePath }
if (-not $out) { $out = Get-FigmaSectionPath $phase }
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out)

if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
    Write-FigmaStderr "ERROR: snapshot not found: $snapshotPath (run figma-introspect.ps1 first)"
    exit 1
}
# -NoEnumerate keeps a JSON array an array: without it, a single-element array
# would be unwrapped to a scalar object and wrongly rejected here.
try {
    $links = ConvertFrom-Json $linksJson -NoEnumerate
    if ($links -isnot [System.Array] -and $links -isnot [System.Collections.IList]) { throw 'not an array' }
} catch {
    Write-FigmaStderr 'ERROR: --links must be a JSON array'
    exit 1
}
try {
    $candidateFrames = ConvertFrom-Json $candidateFramesJson -NoEnumerate
    if ($candidateFrames -isnot [System.Array] -and $candidateFrames -isnot [System.Collections.IList]) { throw 'not an array' }
} catch {
    Write-FigmaStderr 'ERROR: --candidate-frames must be a JSON array'
    exit 1
}
$links = @($links)
$candidateFrames = @($candidateFrames)

# Resolve the template: workspace install first, then the extension checkout.
$template = ''
foreach ($cand in @(
        (Join-Path $root '.specify/templates' $templateName),
        (Join-Path $PSScriptRoot '../../templates' $templateName))) {
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $template = $cand; break }
}
if (-not $template) {
    Write-FigmaStderr "ERROR: template '$templateName' not found in .specify/templates/ or the extension checkout."
    exit 1
}

# -----------------------------------------------------------------------------
# Deterministic scalars from the snapshot.
# -----------------------------------------------------------------------------
$snapshot = Read-FigmaJsonFile $snapshotPath
$fileId = [string](Get-JsonValue $snapshot @('fileId') 'n/a')
$projectId = [string](Get-JsonValue $snapshot @('projectId') 'n/a')
$generatedAt = [string](Get-JsonValue $snapshot @('generatedAt') 'unknown')
$lastModified = [string](Get-JsonValue $snapshot @('lastModified') 'unknown')
$contextSource = [string](Get-JsonValue $snapshot @('contextSource') 'rest')
$mode = [string](Get-FigmaConfigValue @('mode') 'single-repo')

# Substitute the scalar placeholders the templates share. Judgement placeholders
# (placement, justification, token mapping) are intentionally left untouched.
# The engine placeholder ({{rest | mcp}}) is deterministic (the snapshot's
# contextSource), so it is filled here rather than left for the agent.
# String.Replace is literal, so no escaping is needed (unlike the bash/sed port).
$rendered = (Get-Content -LiteralPath $template -Raw).
    Replace('{{FIGMA_FILE_ID}}', $fileId).
    Replace('{{FIGMA_PROJECT_ID | n/a}}', $projectId).
    Replace('{{GENERATED_AT}}', $generatedAt).
    Replace('{{LAST_MODIFIED}}', $lastModified).
    Replace('{{single-repo | mono-repo | multi-repo}}', $mode).
    Replace('{{multi-repo | mono-repo}}', $mode).
    Replace('{{rest | mcp}}', $contextSource)

# -----------------------------------------------------------------------------
# Auto-filled facts appendix — the deterministic, model-proof part. Lists the
# real introspected pages/frames, components, context engine and input links so
# the agent CANNOT claim "no creative was indicated": the candidates are here.
# -----------------------------------------------------------------------------
# esc: keep free-text (page/frame names, link URLs) from corrupting the markdown
# tables that get pasted verbatim — a literal "|" would inject spurious columns,
# a newline would split the row. Escape the pipe and flatten any line breaks.
function Format-CellValue {
    param($Value)
    $s = if ($null -eq $Value -or "$Value" -eq '') { '—' } else { [string]$Value }
    $s = $s -replace '\|', '\|'
    $s = $s -replace '[\r\n]+', ' '
    return $s
}

$pages = @(Get-JsonValue $snapshot @('pages') @())
if ($pages.Count -eq 0) {
    $pagesTable = '_No mapped page introspected in the snapshot._'
} else {
    $rows = foreach ($p in $pages) {
        "| $(Format-CellValue (Get-JsonValue $p @('name'))) | $(@(Get-JsonValue $p @('frames') @()).Count) |"
    }
    $pagesTable = "| Page | Frames |`n|------|--------|`n" + ($rows -join "`n")
}

$frameRows = @()
foreach ($p in $pages) {
    foreach ($f in @(Get-JsonValue $p @('frames') @())) {
        $frameRows += "| $(Format-CellValue (Get-JsonValue $p @('name'))) | $(Format-CellValue (Get-JsonValue $f @('name'))) | ``$(Get-JsonValue $f @('id'))`` |"
    }
}
if ($frameRows.Count -eq 0) {
    $framesTable = '_No top-level frame indexed._'
} else {
    $framesTable = "| Page | Frame | Node id |`n|------|-------|---------|`n" + ($frameRows -join "`n")
}

$components = Get-JsonValue $snapshot @('components')
$componentCount = if ($null -eq $components) { 0 } else { @($components.PSObject.Properties).Count }
$styles = Get-JsonValue $snapshot @('styles')
$styleCount = if ($null -eq $styles) { 0 } else { @($styles.PSObject.Properties).Count }

if ($links.Count -eq 0) {
    $linksTable = '_None — context derived from the page mapping._'
} else {
    $rows = foreach ($l in $links) {
        $node = Get-JsonValue $l @('nodeId')
        $nodeCell = if ($null -eq $node -or "$node" -eq '') { '—' } else { $node }
        "| $(Format-CellValue (Get-JsonValue $l @('url'))) | ``$(Get-JsonValue $l @('fileId'))`` | ``$nodeCell`` |"
    }
    $linksTable = "| URL | File | Node |`n|-----|------|------|`n" + ($rows -join "`n")
}

if ($candidateFrames.Count -eq 0) {
    $candidateTable = ''
} else {
    $rows = @()
    for ($k = 0; $k -lt $candidateFrames.Count; $k++) {
        $c = $candidateFrames[$k]
        $rows += "| $($k + 1) | $(Format-CellValue (Get-JsonValue $c @('page'))) | $(Format-CellValue (Get-JsonValue $c @('name'))) | ``$(Get-JsonValue $c @('id'))`` |"
    }
    $candidateTable = "`n> ⚠️ A broad Figma link (file/page, no specific frame) was provided. " +
        'Confirm which of these frames the feature targets BEFORE generating tasks ' +
        "(creative-confirmation checkpoint — do not silently skip):`n`n" +
        "| # | Page | Frame | Node id |`n|---|------|-------|---------|`n" + ($rows -join "`n")
}

# Stable, phase-specific machine marker so figma-verify-section.ps1 can confirm
# integration without coupling to the (translatable) heading text, and can tell
# a wrong-phase section apart. Keep this line when pasting the block.
$content = "<!-- speckit-figma:section phase=$phase -->`n" +
    $rendered +
    "`n`n<!-- ===== AUTO-FILLED FROM .figma/cache/context-snapshot.json — do not delete; complete the judgement fields above ===== -->`n" +
    "`n### Snapshot facts (auto-filled, deterministic)`n`n" +
    "- **File**: ``$fileId``  ·  **Project**: ``$projectId``  ·  **Engine**: $contextSource`n" +
    "- **Generated**: $generatedAt  ·  **Figma lastModified**: $lastModified`n" +
    "- **Indexed**: $componentCount component(s), $styleCount style(s)`n`n" +
    "**Direct links provided in input**`n`n$linksTable`n`n" +
    "**Introspected pages**`n`n$pagesTable`n`n" +
    "**Top-level frames (candidate creatives)**`n`n$framesTable`n" +
    "$candidateTable`n"

Set-Content -LiteralPath $out -Value $content -NoNewline -Encoding utf8

Write-Output $out
exit 0
