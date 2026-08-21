#!/usr/bin/env pwsh
# =============================================================================
# figma-check-drift.ps1 — has the mockup moved since the spec was written?
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-check-drift.sh (same contract).
# Invoked automatically after /speckit.analyze (the after_analyze hook). Analyze
# cross-checks spec/plan/tasks for consistency, and this is the one Figma fact
# that consistency check cannot see on its own: the documents may agree perfectly
# with each other and all three be faithful to a creative the designer has since
# changed.
#
# The comparison is between two recorded facts, never a re-render:
#   - the Figma `lastModified` captured in the document when it was generated,
#     read back from the section marker
#     (<!-- speckit-figma:section phase=spec file=<key> lastModified=<ts> -->);
#   - the `lastModified` of the CURRENT snapshot, refreshed by before_analyze.
#
# Usage:
#   figma-check-drift.ps1 [--phase spec|plan|tasks] [--doc <path>]
#     [--snapshot <path>] [--config <path>] [--strict]
#
# Prints a JSON status object on stdout:
#   { "drifted": true|false, "applicable": true|false,
#     "reason": "ok|drifted|not-applicable|doc-not-found|no-marker|no-snapshot|unknown-timestamp",
#     "phase": "...", "doc": "...", "fileId": "...",
#     "documentLastModified": "...", "figmaLastModified": "...",
#     "remedy": "..." }
#
# SAFE NO-OP by default: an absent document, a missing marker or an unusable
# snapshot all exit 0. --strict (or `figma.verifyStrict`) turns a REAL drift —
# and only that — into a non-zero exit. Being unable to check is never a failure;
# checking and finding drift is.
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$phase = 'spec'
$doc = ''
$snapshot = ''
$strict = $false
$i = 0
while ($i -lt $args.Count) {
    switch -Regex ($args[$i]) {
        '^--phase$'    { $phase = [string]$args[$i + 1]; $i += 2; continue }
        '^--doc$'      { $doc = [string]$args[$i + 1]; $i += 2; continue }
        '^--snapshot$' { $snapshot = [string]$args[$i + 1]; $i += 2; continue }
        '^--config$'   { $env:FIGMA_CONFIG = [string]$args[$i + 1]; $i += 2; continue }
        '^--strict$'   { $strict = $true; $i += 1; continue }
        '^--'          { Write-FigmaStderr "ERROR: unknown arg '$($args[$i])'"; exit 1 }
        default        { Write-FigmaStderr "ERROR: unexpected argument '$($args[$i])'"; exit 1 }
    }
}

if ($phase -notin @('spec', 'plan', 'tasks')) {
    Write-FigmaStderr "ERROR: --phase must be one of spec|plan|tasks (got '$phase')"
    exit 1
}

# Same escape hatch as figma-verify-section, so one config key gates the whole
# post-generation family instead of each script inventing its own.
if (-not $strict) {
    $strictCfg = Get-FigmaConfigValue @('figma', 'verifyStrict') $null
    if ($strictCfg -is [bool] -and $strictCfg) { $strict = $true }
}

if (-not $snapshot) { $snapshot = Get-FigmaCachePath }

$docTs = ''
$figmaTs = ''
$fileId = ''

function Emit-Status {
    param([bool]$Drifted, [bool]$Applicable, [string]$Reason, [string]$Remedy)
    ConvertTo-FigmaJson ([ordered]@{
        drifted              = $Drifted
        applicable           = $Applicable
        reason               = $Reason
        phase                = $phase
        doc                  = if ($doc) { $doc } else { $null }
        fileId               = if ($fileId) { $fileId } else { $null }
        documentLastModified = if ($docTs) { $docTs } else { $null }
        figmaLastModified    = if ($figmaTs) { $figmaTs } else { $null }
        remedy               = if ($Remedy) { $Remedy } else { $null }
    })
}

if (-not $doc) { $doc = Get-FigmaPhaseDoc $phase }
if (-not $doc -or -not (Test-Path -LiteralPath $doc -PathType Leaf)) {
    Write-FigmaStderr "INFO: no $phase.md located; nothing to compare."
    $doc = ''
    Emit-Status $false $false 'doc-not-found' ''
    exit 0
}

# The marker line, and the two facts it carries. A document generated before the
# marker gained them yields empty values — reported as "unknown-timestamp", not
# as drift: an old document is not evidence the design moved.
$markerPrefix = "speckit-figma:section phase=$phase"
$markerLine = (Get-Content -LiteralPath $doc -ErrorAction SilentlyContinue |
    Where-Object { $_.Contains($markerPrefix) } | Select-Object -First 1)
if (-not $markerLine) {
    Write-FigmaStderr "INFO: $(Split-Path -Leaf $doc) carries no Figma section; drift does not apply to this feature."
    Emit-Status $false $false 'no-marker' ''
    exit 0
}

$m = [regex]::Match($markerLine, '\slastModified=(?<v>[^\s>]+)')
if ($m.Success) { $docTs = $m.Groups['v'].Value }
$m = [regex]::Match($markerLine, '\sfile=(?<v>[^\s>]+)')
if ($m.Success) { $fileId = $m.Groups['v'].Value }

if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf)) {
    Write-FigmaStderr "INFO: no snapshot at $snapshot; run /speckit.figma.ensure first."
    Emit-Status $false $false 'no-snapshot' 'Re-run the before_analyze hook (/speckit.figma.ensure) so a current snapshot exists.'
    exit 0
}
$snap = Read-FigmaJsonFile $snapshot
$figmaTs = [string](Get-JsonValue $snap @('lastModified'))
$snapshotFile = [string](Get-JsonValue $snap @('fileId'))

if (-not $docTs -or $docTs -eq 'unknown' -or -not $figmaTs) {
    $d = if ($docTs) { $docTs } else { 'none' }
    $f = if ($figmaTs) { $figmaTs } else { 'none' }
    Write-FigmaStderr "INFO: not enough recorded timestamps to compare (document='$d', snapshot='$f'); regenerate the section to start tracking drift."
    Emit-Status $false $true 'unknown-timestamp' 'Re-run the phase so the section marker records the Figma lastModified.'
    exit 0
}

# Comparing two different files' timestamps would be meaningless — and worse,
# alarming: a feature whose creative legitimately moved to another file would
# report permanent drift.
if ($snapshotFile -and $fileId -and $fileId -ne 'unknown' -and $snapshotFile -ne $fileId) {
    Write-FigmaStderr "INFO: the snapshot targets file '$snapshotFile' but $(Split-Path -Leaf $doc) was generated from '$fileId'; skipping the drift comparison."
    Emit-Status $false $false 'not-applicable' ''
    exit 0
}

# Figma returns ISO-8601 UTC ('2026-08-14T09:12:33Z'), which sorts
# lexicographically in chronological order — no date parsing, so no dependency on
# the host's culture or timezone, and identical semantics to the bash port.
if ([string]::CompareOrdinal($figmaTs, $docTs) -gt 0) {
    $leaf = Split-Path -Leaf $doc
    $remedy = "The Figma file changed after $leaf was generated. Re-run /speckit.specify (or /speckit.figma.ensure) to refresh the design section, and re-check the affected tasks before implementing."
    Write-FigmaStderr "WARN: design drift — $leaf records $docTs, Figma now reports $figmaTs. $remedy"
    Emit-Status $true $true 'drifted' $remedy
    if ($strict) { exit 1 }
    exit 0
}

Emit-Status $false $true 'ok' ''
