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
# WHAT MAKES FIGMA APPLY: a Figma link in the feature input, and nothing else.
# A valid config with a mapped, enabled target is a precondition, not a trigger:
# it says WHERE a creative would live, not WHETHER this feature has one. Without
# a link the run ends at "no-figma-link" — no introspection, no rendered section,
# mustInject=false — so a purely back-end feature never comes back with a Figma
# design section stapled to its spec. The link is pasted once, at
# /speckit.specify; it is then remembered per feature (see
# Get-FigmaFeatureLinksPath) so /speckit.plan and /speckit.tasks inherit it, and
# when that git-ignored cache is absent (fresh clone, CI, a teammate's checkout)
# it is recovered from the committed spec.md.
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
#     [--max-age-minutes N] [--input <text> | --input -] [--assume-design]
#     [--dry-run]
# <target-name> defaults to "repo" (single-/mono-repo); for multi-repo it is
# auto-resolved only when exactly one enabled target exists.
# --input carries the user's raw feature input ("-" reads stdin): any direct
# Figma links it contains are parsed (figma-parse-links.ps1) and become
# AUTHORITATIVE design targets — the linked file/nodes override the
# config-derived scope, and a snapshot that does not cover the linked nodes is
# treated as stale. Same contract as /speckit.figma.introspect section 0.
# FIGMA_SNAPSHOT_MAX_AGE_MINUTES overrides the default freshness window (60).
# Every real (non-dry) run also sweeps the cache once a day (Invoke-FigmaCacheGc):
# FIGMA_CACHE_RETENTION_DAYS overrides the 7-day window, FIGMA_CACHE_GC=off
# disables it, =force ignores the daily throttle.
#
# Prints a JSON status object on stdout:
#   { "ran": true|false, "reason": "...", "code": "NETWORK|AUTH|NOT_FOUND|...|null",
#     "dependency": null,              # always null here (no jq/curl dependency)
#     "target": "...",
#     "snapshot": "...", "links": [...], "introspectArgs": [...],
#     "mustInject": true|false,        # section is mandatory in spec/plan/tasks
#     "linkScope": "none|frame|broad", # "broad" => confirm a frame before tasks
#     "candidateFrames": [...],        # frames to confirm when linkScope=broad
#     "specSection": "...", "planSection": "...", "tasksSection": "..." }
# When mustInject=true the agent MUST paste the rendered <phase>Section file
# verbatim into the generated document, then complete the judgement fields.
# --assume-design is the agent stating "this feature has a creative" when the
# input carries no link. It grants nothing by itself: it is honoured only on a
# target whose config declares `autoIntrospect.mode: "on-request"`, so the
# authorisation stays in the committed config and an agent can never authorise
# itself. See "Autonomous introspection policy" in figma-common.ps1.
#
# Reasons: introspected | fresh | dry-run | no-figma-link | no-config |
#   invalid-config | unresolved-placeholders | ambiguous-target |
#   target-excluded | target-not-mapped | target-disabled | introspect-failed |
#   auto-declined | auto-unavailable | too-large-for-auto
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$target = ''
$maxAgeMin = if ($env:FIGMA_SNAPSHOT_MAX_AGE_MINUTES) { $env:FIGMA_SNAPSHOT_MAX_AGE_MINUTES } else { '60' }
$dryRun = $false
$assumeDesign = $false
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
        '^--assume-design$' { $assumeDesign = $true; $i += 1; continue }
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

# Housekeeping, placed BEFORE every early exit below so it runs on all kinds of
# phase — including the design-less ones, which are exactly the runs that leave
# orphaned keys behind. A dry run is a rehearsal and must leave no trace, so it
# skips the sweep; the catch keeps a housekeeping failure from ever blocking a
# hook whose contract is "never block, always answer".
if (-not $dryRun) {
    try { Invoke-FigmaCacheGc } catch { }
}

$config = Get-FigmaDefaultConfig
$snapshotPath = Get-FigmaCachePath
$introspectArgs = @()
$links = @()          # parsed link objects
$linkFile = ''
$linkNodes = @()
# True when the links were freshly resolved (this phase's input, or recovered
# from spec.md) rather than read back from the per-feature cache — only those are
# worth writing to it.
$recordLinks = $false
# Injection contract: filled once a usable snapshot exists (introspected|fresh).
$mustInject = $false
# What made this a design run: a pasted/remembered/recovered link ("link"), the
# target's autoIntrospect policy ("auto"), or nothing yet ("none").
$trigger = 'none'
# Autonomous-run policy, resolved from the target once it is known.
$autoMode = 'off'
$autoMaxFrames = 60
$confirmFrames = $true
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
        # Always null here — this port needs neither jq nor curl, so it has no
        # missing-dependency path. The key is emitted regardless to keep the
        # status schema identical to the bash twin's, as both READMEs promise.
        dependency      = $null
        target          = if ($script:target) { $script:target } else { $null }
        snapshot        = $script:snapshotPath
        links           = @($script:links)
        mustInject      = $script:mustInject
        trigger         = $script:trigger
        confirmFrames   = $script:confirmFrames
        linkScope       = $script:linkScope
        candidateFrames = @($script:candidateFrames)
        specSection     = if ($script:specSection) { $script:specSection } else { $null }
        planSection     = if ($script:planSection) { $script:planSection } else { $null }
        tasksSection    = if ($script:tasksSection) { $script:tasksSection } else { $null }
        introspectArgs  = @($script:introspectArgs | ForEach-Object { [string]$_ })
    })
}

# Node ids to deep-fetch for $linkFile, from whichever source filled $links.
# A prototype link contributes two: the frame that was being viewed and the
# flow's starting point (startNodeId) — both are creatives, and both ride the
# same batched /nodes request, so there is nothing to save by dropping one.
function Get-LinkNodes {
    @($script:links |
        Where-Object { $_.fileId -eq $script:linkFile } |
        ForEach-Object { $_.nodeId; $_.startNodeId } |
        Where-Object { $null -ne $_ -and '' -ne $_ } |
        ForEach-Object { [string]$_ } |
        Sort-Object -Unique)
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
# .figma/cache/sections/<feature>/<phase>.md. Clear-RenderedSections drops them so only THIS
# run's renders remain.
#
# It is called on the paths where Figma DEFINITIVELY does not apply (no/invalid
# config, excluded target) and at the start of Prepare-Injection (just before a
# re-render) — but deliberately NOT on a transient introspect-failure. Wiping on
# a transient failure would erase a prior phase's still-valid render, so the
# verifier would report "not-applicable" and let a --strict CI gate silently pass
# for a run where Figma genuinely applies; leaving the prior render keeps the
# gate honest (fail-closed, consistent with verify's own --strict policy).
# Scoped to THIS feature: wiping every feature's renders would erase a design
# feature's evidence whenever a design-less one runs (see Get-FigmaSectionPath).
function Clear-RenderedSections {
    $dir = Split-Path -Parent (Get-FigmaSectionPath 'spec')
    Remove-Item -Path (Join-Path $dir '*.md') -Force -ErrorAction SilentlyContinue
}

# Terminal path for every run that reaches a usable snapshot. It exists so the
# autonomous frame budget is enforced at ALL THREE of them — the fresh slot, the
# restored per-file copy, and a just-completed introspection — instead of only at
# the one that happens to perform the network call.
#
# The budget is checked here, AFTER the snapshot exists, because the frame count
# is not knowable before it: /files/<key>?depth=2 is the call that produces the
# page/frame index. The fetch is therefore paid once, and the snapshot is kept
# (it is valid, cached, and a later /speckit.figma.introspect will reuse it) —
# what the budget refuses is REASONING over a file that wide without a pinned
# node. Link-driven runs are exempt: their node id already pins the creative.
function Complete-WithSnapshot { # $Ran (bool), $Reason
    param([bool]$Ran, [string]$Reason)
    if ($script:trigger -eq 'auto') {
        $frames = 0
        try {
            $snap = Read-FigmaJsonFile $script:snapshotPath
            $pages = @(Get-JsonValue $snap @('pages'))
            foreach ($page in $pages) {
                $frames += @(Get-JsonValue $page @('frames')).Count
            }
        } catch { $frames = 0 }
        if ($frames -gt $script:autoMaxFrames) {
            Write-FigmaStderr "WARN: file '$($script:linkFile)' holds $frames top-level frames, over this target's autoIntrospect.maxFrames=$($script:autoMaxFrames). Context that wide is too diluted to implement faithfully: open the frame in Figma, copy its link (right-click > Copy link to selection) and paste it into the feature input to pin the creative."
            Clear-RenderedSections
            Emit-Status $false 'too-large-for-auto'
            exit 0
        }
    }
    Prepare-Injection
    Emit-Status $Ran $Reason
    exit 0
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

# True when the given snapshot already targets the linked file and contains
# every linked node — only then can a link-driven run be considered fresh.
function Test-SnapshotCoversLinks {
    param([string]$Path)
    if (-not $script:linkFile) { return $true }
    $snap = $null
    try { $snap = Read-FigmaJsonFile $Path } catch { return $false }
    if ((Get-JsonValue $snap @('fileId')) -ne $script:linkFile) { return $false }
    foreach ($n in $script:linkNodes) {
        $nodesObj = Get-JsonValue $snap @('nodes', 'nodes')
        if ($null -eq $nodesObj -or $null -eq $nodesObj.PSObject.Properties[$n]) { return $false }
    }
    return $true
}

# Age-and-config half of the freshness test: the snapshot exists, is not older
# than the config that shaped it, and is younger than the max-age window.
function Test-SnapshotIsCurrent {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $configTime = (Get-Item -LiteralPath $script:config).LastWriteTimeUtc
    $snapshotTime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
    $ageMinutes = ((Get-Date).ToUniversalTime() - $snapshotTime).TotalMinutes
    return ($configTime -le $snapshotTime -and $ageMinutes -lt $script:maxAgeMin)
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
        $linkNodes = Get-LinkNodes
        $recordLinks = $true
    }
}

# A Figma link in the feature input is what makes a run a design run. Without
# one, the extension has nothing to ground itself in and MUST stay out of the
# way: a valid config and a mapped target used to be enough to introspect and
# force the design section into spec.md, so a feature like "add a Redis cache on
# the billing endpoint" came back carrying a Figma section it had no business
# carrying. The mapping describes WHERE a creative would live, not WHETHER this
# feature has one; only the link answers that.
#
# The developer pastes the link once, at /speckit.specify. /speckit.plan and
# /speckit.tasks receive a different input that no longer carries it, so the
# links are remembered per feature and inherited by the later phases — otherwise
# spec.md would carry the design section and plan.md would not.
if (-not $linkFile) {
    $linksFile = Get-FigmaFeatureLinksPath
    if (Test-Path -LiteralPath $linksFile -PathType Leaf) {
        # The contract is the JSON ROOT TYPE, not merely "does it parse": a
        # hand-edited file holding a single object instead of a one-element array
        # would otherwise feed a non-list value to the rest of the pipeline. It
        # has to be read off the TEXT, because ConvertFrom-Json unrolls '[{...}]'
        # into a bare object — the deserialized shape cannot tell the two apart.
        # Mirrors the bash port's `jq 'select(type == "array" and length > 0)'`.
        try {
            $rawLinks = Get-Content -LiteralPath $linksFile -Raw
            $remembered = if ($rawLinks -match '^\s*\[') { @($rawLinks | ConvertFrom-Json) } else { @() }
        } catch { $remembered = @() }
        if ($remembered.Count -gt 0) {
            $linkFile = [string](Get-JsonValue $remembered[0] @('fileId') '')
        }
        # A truncated or hand-edited file must degrade to "no remembered links"
        # rather than put a malformed entry in the status object's `links`.
        if ($linkFile) {
            $links = $remembered
            $linkNodes = Get-LinkNodes
            Write-FigmaStderr "INFO: no Figma link in this phase's input; reusing the link(s) recorded for feature '$(Get-FigmaFeatureKey)'."
        }
    }
}

# Last source: the spec.md an earlier phase already produced. The per-feature
# cache above lives under .figma/cache/, which is git-ignored, so it does NOT
# travel with the branch — a teammate who pulls it, a fresh clone or a CI job
# reaches /speckit.plan with the spec but no cache. Falling through to
# "no-figma-link" there is worse than doing nothing: the agent is instructed to
# say NOTHING about Figma, so plan.md silently loses the design section spec.md
# carries. The committed document is the durable record of the link.
#
# Two guards keep this from re-creating the regression it protects against.
# -IdentifiedOnly: the document must be one the CURRENT feature owns — with
# nothing identifying the feature, "the only spec around" belongs to another one,
# and inheriting its creative is exactly the bug. The machine marker: a
# figma.com URL merely mentioned in the prose of a spec is not a design section,
# and must not become a trigger.
if (-not $linkFile) {
    $specDoc = Get-FigmaPhaseDoc 'spec' -IdentifiedOnly
    if ($specDoc -and (Select-String -LiteralPath $specDoc -SimpleMatch -Pattern 'speckit-figma:section phase=spec' -Quiet)) {
        $recoveredLines = @(& "$PSScriptRoot/figma-parse-links.ps1" (Get-Content -LiteralPath $specDoc -Raw))
        if ($recoveredLines.Count -gt 0) {
            $links = @($recoveredLines | ForEach-Object { $_ | ConvertFrom-Json })
            $linkFile = [string](Get-JsonValue $links[0] @('fileId') '')
            $linkNodes = Get-LinkNodes
            # Re-warm the cache: recovered links are as authoritative as pasted ones.
            $recordLinks = $true
            Write-FigmaStderr "INFO: no Figma link in this phase's input and none cached for feature '$(Get-FigmaFeatureKey)'; recovered it from $(Split-Path -Leaf $specDoc)."
        }
    }
}

# A link resolved from any of the three sources above pins the creative. That is
# the default trigger, and the safe one: the developer named the frame.
if ($linkFile) { $trigger = 'link' }

# No link anywhere. The 2.0.0 contract ends the run here — and still does, unless
# THIS target opted into autonomous introspection (`autoIntrospect` in the config;
# see "Autonomous introspection policy" in figma-common.ps1). The opt-in
# deliberately lives in the committed config: authorising the extension to work
# without a link is a team decision, reviewable in a PR, and an agent must never
# be able to grant it to itself.
if (-not $linkFile) {
    $autoMode = Get-FigmaAutoIntrospectMode $detect
    $autoMaxFrames = Get-FigmaAutoIntrospectMaxFrames $detect
    $confirmFrames = Test-FigmaAutoIntrospectConfirm $detect

    switch ($autoMode) {
        'on-request' {
            # The config unlocks the door, the agent opens it: --assume-design is
            # the agent stating that this feature has a creative. Without it the
            # run is a deliberate decline — a distinct outcome from "this target
            # may not", which is why it does not collapse into no-figma-link.
            if (-not $assumeDesign) {
                Write-FigmaStderr "INFO: target '$target' allows autonomous introspection on request, but this run claimed no design intent. Re-run with --assume-design when the feature has a creative, or paste the Figma link to pin it exactly."
                Clear-RenderedSections
                Emit-Status $false 'auto-declined'
                exit 0
            }
        }
        'always' { }  # any run on a mapped, enabled target introspects
        default {
            # mode=off (the default): --assume-design must not look like it worked.
            if ($assumeDesign) {
                Write-FigmaStderr "WARN: --assume-design was passed but target '$target' declares autoIntrospect.mode='off' (the default); the flag grants nothing. Set it to 'on-request' in $(Split-Path -Leaf $config) to allow autonomous introspection."
            }
            # Actionable on purpose. The document stays silent, so this line is the
            # only place a forgotten link can still be caught — and it only works if
            # it says what to do. Nothing downstream distinguishes a front-end
            # feature whose author forgot the link from a back-end one that
            # legitimately has none.
            Write-FigmaStderr 'INFO: no Figma link in the feature input; proceeding without Figma context. If this feature does have a mockup, paste the Figma link into /speckit.specify and re-run — nothing further will flag the omission.'
            Clear-RenderedSections
            Emit-Status $false 'no-figma-link'
            exit 0
        }
    }

    # Authorised — but the autonomous path introspects the MAPPED FILE and nothing
    # wider. A team/project id walks every file of an organisation, which is
    # /speckit.figma.introspect's job and never a hook's: an automatic
    # pre-generation step must not turn one feature into an org-wide crawl.
    $autoFileId = [string](Get-JsonValue $detect @('figmaFileId') '')
    if (-not $autoFileId) {
        Write-FigmaStderr "WARN: target '$target' enables autoIntrospect but declares no figmaFileId (only a project/team id). An autonomous run needs exactly one file: pin figmaFileId in $(Split-Path -Leaf $config), or run /speckit.figma.introspect --project/--team by hand."
        Clear-RenderedSections
        Emit-Status $false 'auto-unavailable'
        exit 0
    }

    # From here the run is deliberately indistinguishable from a link-driven one
    # whose link carried no node id: $linkFile drives freshness, the per-file
    # snapshot store and the introspection scope, while $links stays empty so the
    # rendered section reports "context derived from page mapping" instead of
    # inventing a link the developer never pasted. $linkNodes stays empty too —
    # which is exactly what makes Compute-LinkScope classify the run as "broad",
    # so the creative-confirmation checkpoint (design rule 5) fires by
    # construction rather than by a new code path of its own.
    $linkFile = $autoFileId
    $trigger = 'auto'
    Write-FigmaStderr "INFO: no Figma link; autonomously introspecting the mapped file '$linkFile' for target '$target' (autoIntrospect.mode=$autoMode)."
}

# Remember this phase's links for the next one. A dry run is a rehearsal: it must
# not leave state behind that changes what a later real run decides.
if ($recordLinks -and -not $dryRun) {
    $linksFile = Get-FigmaFeatureLinksPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $linksFile) | Out-Null
    ConvertTo-FigmaJson @($links) | Set-Content -LiteralPath $linksFile -Encoding utf8
}

# Fresh = snapshot exists, is newer than the config, is younger than the
# max-age window, and covers any directly-linked file/nodes from the input.
if ((Test-SnapshotIsCurrent $snapshotPath) -and (Test-SnapshotCoversLinks $snapshotPath)) {
    # Figma applies and the snapshot is usable -> the section is mandatory; render it.
    Complete-WithSnapshot $false 'fresh'
}

# The current slot holds another file's snapshot -- but the per-file store may
# already hold a usable one for THIS link. Without this lookup, alternating
# between two features that target different Figma files re-introspects on every
# single phase, because each run evicts the other's snapshot from the one slot.
$storedSnapshot = Get-FigmaSnapshotStorePath $linkFile
if ($storedSnapshot -and $storedSnapshot -ne $snapshotPath `
    -and (Test-SnapshotIsCurrent $storedSnapshot) -and (Test-SnapshotCoversLinks $storedSnapshot)) {
    # Publish it as the current one: every command prompt hands the agent the
    # well-known path, so restoring has to happen there and not only in memory.
    try {
        Copy-Item -LiteralPath $storedSnapshot -Destination $snapshotPath -Force
        Write-FigmaStderr "INFO: reused the cached snapshot of file '$linkFile'; no re-introspection needed."
        Complete-WithSnapshot $false 'fresh'
    } catch {
        Write-FigmaStderr "WARN: could not restore the cached snapshot of '$linkFile'; re-introspecting."
    }
}

# File-level scope: introspect the resolved file and drill into each linked node
# so the snapshot carries frame-level detail (fills, typography, layout).
# Reaching here means $linkFile is set, from one of exactly two triggers — a link
# ($trigger = link), or the target's autoIntrospect policy resolving the mapped
# figmaFileId ($trigger = auto). An autonomous run contributes no --node, so the
# snapshot stays file-wide and the frame budget in Complete-WithSnapshot decides
# whether it is usable at all. Team/project scopes are never derived here:
# /speckit.figma.introspect remains the way to walk a mapped team or project.
$introspectArgs += @('--file', $linkFile)
foreach ($nodeId in $linkNodes) {
    $introspectArgs += @('--node', $nodeId)
}
$configFileId = [string](Get-JsonValue $detect @('figmaFileId') '')
if ($configFileId -and $configFileId -ne $linkFile) {
    Write-FigmaStderr "INFO: direct Figma link overrides the mapped file '$configFileId' for this run."
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
        Complete-WithSnapshot $true 'introspected'
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
