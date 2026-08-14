#!/usr/bin/env pwsh
# =============================================================================
# figma-verify-section.ps1 — verify the Figma section made it into the document
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-verify-section.sh (same contract).
# Closes the loop after generation: the before-hook renders a ready-to-paste
# section and guarantees the FILE exists, but it cannot guarantee the agent
# actually PASTED it into the generated spec.md / plan.md / tasks.md. This
# verification runs AFTER generation and checks that — when a Figma mockup was
# detected for the run (i.e. the rendered `.figma/cache/sections/<feature>/<phase>.md` exists) —
# the corresponding document really contains the Figma section marker.
#
# Designed as a SAFE NO-OP by default: when Figma does not apply, the document
# cannot be located, or the section is present, it exits 0. With --strict (or
# `figma.verifyStrict: true` in the config) a missing section — the real defect —
# exits non-zero so a CI pipeline can gate on it.
#
# Usage:
#   figma-verify-section.ps1 --phase spec|plan|tasks
#     [--doc <path>] [--config <path>] [--strict]
#
# Prints a JSON status object on stdout:
#   { "verified": true|false, "phase": "...", "applicable": true|false,
#     "reason": "ok|not-applicable|section-missing|doc-not-found",
#     "doc": "...", "expectedMarker": "...", "renderedSection": "...",
#     "remedy": "..." }
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$phase = ''
$doc = ''
$strict = $false
$i = 0
while ($i -lt $args.Count) {
    switch -Regex ($args[$i]) {
        '^--phase$'  { $phase = [string]$args[$i + 1]; $i += 2; continue }
        '^--doc$'    { $doc = [string]$args[$i + 1]; $i += 2; continue }
        '^--config$' { $env:FIGMA_CONFIG = [string]$args[$i + 1]; $i += 2; continue }
        '^--strict$' { $strict = $true; $i += 1; continue }
        '^--'        { Write-FigmaStderr "ERROR: unknown arg '$($args[$i])'"; exit 1 }
        default      { Write-FigmaStderr "ERROR: unexpected argument '$($args[$i])'"; exit 1 }
    }
}

if ($phase -notin @('spec', 'plan', 'tasks')) {
    Write-FigmaStderr "ERROR: --phase must be one of spec|plan|tasks (got '$phase')"
    exit 1
}

# Strict can also be enabled from the config (CI gate without changing the call).
if (-not $strict) {
    $strictCfg = Get-FigmaConfigValue @('figma', 'verifyStrict') $null
    if ($strictCfg -is [bool] -and $strictCfg) { $strict = $true }
}

$rendered = Get-FigmaSectionPath $phase
# Phase-specific machine marker emitted by figma-render-section.ps1: decoupled
# from the (translatable) heading text and able to detect a wrong-phase section.
$marker = "speckit-figma:section phase=$phase"
# Legacy/heading fallback so a section pasted without the machine comment (or
# rendered by an older version) is still recognized. It MUST stay phase-specific:
# a phase-agnostic marker would match a section pasted for the WRONG phase and
# silently defeat the wrong-phase detection (and --strict).
switch ($phase) {
    'spec'  { $legacyMarker = '## Figma Design Context' }
    'plan'  { $legacyMarker = '## Figma Design Plan' }
    'tasks' { $legacyMarker = '## Figma-derived tasks' }
}

function Emit-Status {
    param([bool]$Verified, [bool]$Applicable, [string]$Reason, [string]$Remedy)
    ConvertTo-FigmaJson ([ordered]@{
        verified        = $Verified
        phase           = $phase
        applicable      = $Applicable
        reason          = $Reason
        doc             = if ($doc) { $doc } else { $null }
        expectedMarker  = $marker
        renderedSection = $rendered
        remedy          = if ($Remedy) { $Remedy } else { $null }
    })
}

# Resolve the SpecKit document for this phase when not given explicitly. The
# layout rules (and the refusal to guess between several candidates, which under
# --strict would gate CI on the WRONG feature's doc) live in Get-FigmaPhaseDoc.
# Returns $true when $doc is set.
function Resolve-Doc {
    if ($script:doc) { return $true }
    $script:doc = Get-FigmaPhaseDoc $phase
    return [bool]$script:doc
}

# Not applicable: no rendered section => Figma did not apply to this run.
if (-not (Test-Path -LiteralPath $rendered -PathType Leaf)) {
    Write-FigmaStderr "INFO: no $(Split-Path -Leaf $rendered) — Figma did not apply to this run; nothing to verify."
    Emit-Status $true $false 'not-applicable' ''
    exit 0
}

if (-not (Resolve-Doc)) {
    Write-FigmaStderr "WARN: could not locate the $phase.md document (pass --doc); skipping verification."
    Emit-Status $true $true 'doc-not-found' "Pass --doc <path-to-$phase.md> so the section can be verified."
    if ($strict) { exit 1 }
    exit 0
}

$docContent = Get-Content -LiteralPath $doc -Raw
if ($docContent.Contains($marker) -or $docContent.Contains($legacyMarker)) {
    Emit-Status $true $true 'ok' ''
    exit 0
}

# Applicable, document found, section absent — the real defect.
$remedy = "Insert the rendered Figma section from $rendered into $doc (it was detected but not integrated)."
Write-FigmaStderr "WARN: $doc is missing the Figma section '$marker'. $remedy"
Emit-Status $false $true 'section-missing' $remedy
if ($strict) { exit 1 }
exit 0
