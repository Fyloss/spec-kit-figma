#!/usr/bin/env pwsh
# =============================================================================
# install.ps1 — install the SpecKit Figma extension into a target workspace
# =============================================================================
# PowerShell 7+ port of install.sh for Windows users (same behaviour, same
# output vocabulary: ADDED / SKIP / UPDATED / CLEANED / GITIGNORE / INFO / WARN).
# Usage:
#   ./install.ps1 [--target <workspace-root>] [--mode single-repo|mono-repo|multi-repo]
#                 [--prompt-hooks | --no-hooks] [--no-readme]
# (PowerShell-style -Target/-Mode/-PromptHooks/-NoHooks/-NoReadme are accepted too.)
# What it does (idempotent):
#   - copies the figma.projects.config example to <root>/figma.projects.config.json
#   - copies the helper scripts to <root>/.specify/scripts/bash/ AND
#     <root>/.specify/scripts/powershell/ (both families, so mixed macOS/Linux/
#     Windows teams share one committed workspace)
#   - ensures the .figma/cache/ directory (generated/cached artifacts) is git-ignored
#   - installs the design-rules constitution base into .figma/ (committed;
#     extension-owned, always refreshed) and creates the user overlay
#     .figma/figma-design-rules.custom.md once (skip-if-exists)
#   - copies the user guides (CREDENTIALS / INSTALL / MONOREPO) to .figma/docs/
#   - appends/refreshes a managed "Figma design context" section in the
#     workspace README.md (created if missing); --no-readme skips it entirely
#   - by default LEAVES the /speckit.specify, /speckit.plan and /speckit.tasks
#     prompts untouched and removes any auto-context block a previous version
#     injected. --prompt-hooks opts back into prompt injection; --no-hooks
#     touches nothing (not even cleanup).
#   - prints the next steps (it does NOT replace placeholders or write tokens)
# =============================================================================
$ErrorActionPreference = 'Stop'
$extDir = $PSScriptRoot

# Extract the first numeric `version:` value from a YAML file. Accepts the value
# bare, single- or double-quoted. `schema_version:` / `speckit_version:` do not
# match a line-initial `version:`, so the first hit is the extension's own version.
function Get-YamlVersion {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return '' }
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match "^\s*version:\s*['`"]?([0-9][0-9.]*)['`"]?") { return $Matches[1] }
    }
    return ''
}

# Strip a managed block (markers included) from a file, collapsing the trailing
# blank lines so repeated runs do not accumulate whitespace. Returns $false when
# the block is unterminated (BEGIN without END — e.g. a manually-edited file):
# stripping to EOF would clobber user content, so the caller warns and leaves
# the file untouched instead.
function Remove-ManagedBlock {
    param([string]$File, [string]$Begin, [string]$End)
    $raw = Get-Content -LiteralPath $File -Raw
    if ($raw.Contains($Begin) -and -not $raw.Contains($End)) { return $false }
    $out = @()
    $skip = $false
    foreach ($line in (Get-Content -LiteralPath $File)) {
        if ($line.Contains($Begin)) { $skip = $true; continue }
        if ($line.Contains($End)) { $skip = $false; continue }
        if (-not $skip) { $out += $line }
    }
    $text = (($out -join "`n").TrimEnd("`n")) + "`n"
    Set-Content -LiteralPath $File -Value $text -NoNewline -Encoding utf8
    return $true
}

function Write-Stderr { param([string]$Message) [Console]::Error.WriteLine($Message) }

# Shared caller-side message for the Remove-ManagedBlock refusal above.
function Warn-Unterminated {
    param([string]$File)
    $rel = $File
    if ($rel.StartsWith("$target/") -or $rel.StartsWith("$target\")) { $rel = $rel.Substring($target.Length + 1) }
    Write-Stderr "WARN: unterminated SPECKIT-FIGMA block in $rel (BEGIN without END marker) — left untouched; restore the END marker and re-run install.ps1."
}

function Get-RelativeToTarget {
    param([string]$File)
    if ($File.StartsWith("$target/") -or $File.StartsWith("$target\")) { return $File.Substring($target.Length + 1) }
    return $File
}

# Extension id and version, read from the extension's own manifest. The id drives
# the SpecKit paths we inspect later, so we derive it rather than hardcoding it.
$extVersion = Get-YamlVersion (Join-Path $extDir 'extension.yml')
if (-not $extVersion) { $extVersion = 'unknown' }
$extId = ''
foreach ($line in Get-Content -LiteralPath (Join-Path $extDir 'extension.yml')) {
    if ($line -match "^\s*id:\s*['`"]?([A-Za-z0-9._-]+)['`"]?") { $extId = $Matches[1]; break }
}
if (-not $extId) { $extId = 'figma' }

# Per-agent command locations created by `specify init` (markdown-based agents).
# Single source of truth: both the hook-injection loop and the command-drift
# loop iterate this, so a newly supported agent format is added in one place.
$agentCmdDirs = @('.claude/commands', '.github/prompts', '.cursor/commands', '.windsurf/workflows', '.opencode/command')

# Default to the workspace the installer is invoked from (its git root, else $PWD),
# NOT the extension's own repo. --target still overrides this.
$target = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $target) { $target = (Get-Location).Path }
$mode = 'single-repo'
$hooks = 'clean'
$readmeBlock = 'on'
$i = 0
while ($i -lt $args.Count) {
    switch -Regex ($args[$i]) {
        '^(--target|-Target)$' { $target = [string]$args[$i + 1]; $i += 2; continue }
        '^(--mode|-Mode)$' { $mode = [string]$args[$i + 1]; $i += 2; continue }
        '^(--prompt-hooks|-PromptHooks)$' { $hooks = 'inject'; $i += 1; continue }
        '^(--no-hooks|-NoHooks)$' { $hooks = 'off'; $i += 1; continue }
        '^(--no-readme|-NoReadme)$' { $readmeBlock = 'off'; $i += 1; continue }
        default { Write-Stderr "ERROR: unknown arg '$($args[$i])'"; exit 1 }
    }
}

# Canonical target path, resolved once. Used to tell apart "installing into a
# project" from "running inside the extension checkout itself".
$targetReal = $target
try { $targetReal = (Resolve-Path -LiteralPath $target).Path } catch { }
$isSelf = ($targetReal -eq $extDir)

if ($mode -notin @('single-repo', 'mono-repo', 'multi-repo')) {
    Write-Stderr 'ERROR: --mode must be single-repo|mono-repo|multi-repo'
    exit 1
}

$exampleSuffix = switch ($mode) {
    'single-repo' { 'singlerepo' }
    'mono-repo'   { 'monorepo' }
    'multi-repo'  { 'multirepo' }
}
$example = Join-Path $extDir 'config' "figma.projects.config.$exampleSuffix.example.json"
$configDest = Join-Path $target 'figma.projects.config.json'

if (Test-Path -LiteralPath $configDest -PathType Leaf) {
    Write-Output "SKIP: $configDest already exists (not overwritten)."
} else {
    Copy-Item -LiteralPath $example -Destination $configDest
    Write-Output "ADDED: $configDest (from $mode example) — edit it and replace REPLACE_WITH_* ids."
}

# The docs and slash-commands run ./.specify/scripts/bash/*.sh (or the
# ./.specify/scripts/powershell/*.ps1 ports on Windows) from the workspace root,
# so the helper scripts must live in the workspace, not only in this checkout.
# BOTH families are installed regardless of the platform the installer runs on:
# the workspace is committed and shared across a mixed team.
# Always refreshed: they are extension-owned code, not user-edited files.
if ($isSelf) {
    Write-Output 'SKIP: .specify/scripts/ (target is the extension checkout itself; scripts already at scripts/).'
} else {
    $bashDest = Join-Path $target '.specify/scripts/bash'
    $null = New-Item -ItemType Directory -Force -Path $bashDest
    Copy-Item -Path (Join-Path $extDir 'scripts/bash/*.sh') -Destination $bashDest
    Write-Output 'ADDED: .specify/scripts/bash/ (figma-*.sh helpers)'
    $psDest = Join-Path $target '.specify/scripts/powershell'
    $null = New-Item -ItemType Directory -Force -Path $psDest
    $psScripts = Get-ChildItem -Path (Join-Path $extDir 'scripts/powershell') -Filter '*.ps1' -ErrorAction SilentlyContinue
    if ($psScripts) {
        $psScripts | Copy-Item -Destination $psDest
        Write-Output 'ADDED: .specify/scripts/powershell/ (figma-*.ps1 helpers for Windows / PowerShell 7+)'
    } else {
        Write-Stderr "WARN: no figma-*.ps1 found in $extDir/scripts/powershell/ — Windows teammates will lack the PowerShell helpers."
    }
}

$gi = Join-Path $target '.gitignore'
if (-not (Test-Path -LiteralPath $gi)) { $null = New-Item -ItemType File -Path $gi }
# All generated/cached Figma artifacts live under .figma/cache/ — a single entry
# covers the snapshot and every rendered section, while committed content
# (figma-design-rules.md) stays visible at the .figma/ root.
$giLines = @(Get-Content -LiteralPath $gi)
if ($giLines -cnotcontains '.figma/cache/') {
    Add-Content -LiteralPath $gi -Value '.figma/cache/'
    Write-Output 'GITIGNORE: added .figma/cache/'
    $giLines = @(Get-Content -LiteralPath $gi)
}
# Drop legacy entries/files from earlier versions so nothing lingers. `.figma/`
# must go too: it would hide the now-committed .figma/figma-design-rules.md.
foreach ($legacyEntry in @('.figma/', '.figma-context-snapshot.json', '.figma-section.*.md')) {
    if ($giLines -ccontains $legacyEntry) {
        $giLines = @($giLines | Where-Object { $_ -cne $legacyEntry })
        Set-Content -LiteralPath $gi -Value ($giLines -join "`n") -Encoding utf8
        Write-Output "GITIGNORE: removed legacy $legacyEntry"
    }
}
Remove-Item -Path (Join-Path $target '.figma-context-snapshot.json') -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $target '.figma-section.*.md') -Force -ErrorAction SilentlyContinue
# Cached artifacts written by earlier versions at the .figma/ root are dropped;
# they will be regenerated under .figma/cache/ on the next introspect run.
Remove-Item -Path (Join-Path $target '.figma/context-snapshot.json') -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $target '.figma/section.*.md') -Force -ErrorAction SilentlyContinue

# The introspect command mandates loading this constitution file, so it must
# always be installed — into .figma/ (committed), not the git-ignored cache/.
$null = New-Item -ItemType Directory -Force -Path (Join-Path $target '.figma')
Copy-Item -LiteralPath (Join-Path $extDir '.figma/figma-design-rules.md') -Destination (Join-Path $target '.figma/figma-design-rules.md')
Write-Output 'ADDED: .figma/figma-design-rules.md'
# Earlier versions installed it under .specify/memory/; drop that copy so a
# single canonical file remains.
Remove-Item -Path (Join-Path $target '.specify/memory/figma-design-rules.md') -Force -ErrorAction SilentlyContinue

# The user overlay is created ONCE and NEVER overwritten: it holds project-specific
# customizations that must survive every update. On conflict with the base above,
# the overlay wins (see "Layering & precedence" in the base file). Without an
# overlay the base rules apply unchanged. Skipped when the target IS the extension
# checkout, so its own repo is not polluted with an untracked overlay.
if (-not $isSelf) {
    $customDest = Join-Path $target '.figma/figma-design-rules.custom.md'
    if (Test-Path -LiteralPath $customDest -PathType Leaf) {
        Write-Output 'SKIP: .figma/figma-design-rules.custom.md already exists (user overlay, not overwritten).'
    } else {
        Copy-Item -LiteralPath (Join-Path $extDir 'config/figma-design-rules.custom.example.md') -Destination $customDest
        Write-Output 'ADDED: .figma/figma-design-rules.custom.md (user overlay — customize freely; preserved across updates).'
    }
}

# The section templates MUST be installed so figma-render-section can produce
# the ready-to-paste spec/plan/tasks blocks in the workspace (not only from the
# extension checkout). Extension-owned, always refreshed.
if (-not $isSelf) {
    $tplDest = Join-Path $target '.specify/templates'
    $null = New-Item -ItemType Directory -Force -Path $tplDest
    $tpls = Get-ChildItem -Path (Join-Path $extDir 'templates') -Filter '*figma-section.template.md' -ErrorAction SilentlyContinue
    if ($tpls) {
        $tpls | Copy-Item -Destination $tplDest
        Write-Output 'ADDED: .specify/templates/ (spec/plan/tasks figma-section templates)'
    } else {
        Write-Stderr "WARN: no *figma-section.template.md found in $extDir/templates/ — section rendering will fall back to the extension checkout."
    }
}

# The user guides ship with the workspace so the README section below can link
# to LOCAL copies that match the installed version. Extension-owned, always
# refreshed — like the design-rules base.
if (-not $isSelf) {
    $docsDest = Join-Path $target '.figma/docs'
    $null = New-Item -ItemType Directory -Force -Path $docsDest
    $guides = Get-ChildItem -Path (Join-Path $extDir 'docs') -Filter '*.md' -ErrorAction SilentlyContinue
    if ($guides) {
        $guides | Copy-Item -Destination $docsDest
        Write-Output 'ADDED: .figma/docs/ (CREDENTIALS / INSTALL / MONOREPO guides, synced to this version)'
    } else {
        Write-Stderr "WARN: no guides found in $extDir/docs/ — the README links to .figma/docs/ will dangle."
    }
}

# -----------------------------------------------------------------------------
# Workspace README section. Same marker mechanism as the prompt auto-context
# hook; created if the README does not exist; refreshed in place on re-runs;
# the rest of the file is never touched. --no-readme skips all of it.
# -----------------------------------------------------------------------------
$readmeMarkerBegin = 'BEGIN SPECKIT-FIGMA README'
$readmeMarkerEnd = 'END SPECKIT-FIGMA README'
$readmeTemplate = Join-Path $extDir 'templates/figma-readme-block.template.md'

if ($readmeBlock -eq 'on' -and -not $isSelf) {
    if (-not (Test-Path -LiteralPath $readmeTemplate -PathType Leaf)) {
        Write-Stderr "WARN: templates/figma-readme-block.template.md missing from $extDir — README section not installed."
    } else {
        # The block advertises the layout mode. An existing config is the source of
        # truth — an update run usually omits --mode, which must not silently
        # relabel a mono-/multi-repo workspace as single-repo. Fall back to --mode.
        $configMode = ''
        if (Test-Path -LiteralPath $configDest -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $configDest) {
                if ($line -match '^\s*"mode"\s*:\s*"([a-z-]+)"') { $configMode = $Matches[1]; break }
            }
        }
        $readmeMode = if ($configMode) { $configMode } else { $mode }
        $extRepoUrl = ''
        foreach ($line in Get-Content -LiteralPath (Join-Path $extDir 'extension.yml')) {
            if ($line -match "^\s*repository:\s*['`"]?([^'`"\s]+)['`"]?") { $extRepoUrl = $Matches[1]; break }
        }
        if (-not $extRepoUrl) { $extRepoUrl = 'https://github.com/Fyloss/spec-kit-figma' }

        # Respect an existing README whatever its case; create README.md otherwise.
        $readmeDest = ''
        foreach ($readmeName in @('README.md', 'Readme.md', 'readme.md')) {
            $cand = Join-Path $target $readmeName
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $readmeDest = $cand; break }
        }
        $readmeAction = 'ADDED'
        if (-not $readmeDest) {
            $readmeDest = Join-Path $target 'README.md'
            Set-Content -LiteralPath $readmeDest -Value "# $(Split-Path -Leaf $targetReal)`n" -NoNewline -Encoding utf8
            Write-Output 'ADDED: README.md (workspace had none — created with a title and the figma section)'
        } elseif ((Get-Content -LiteralPath $readmeDest -Raw).Contains($readmeMarkerBegin)) {
            # An unterminated block is refused by Remove-ManagedBlock: warn, keep the
            # file byte-for-byte intact and skip the append (no second BEGIN marker).
            if (Remove-ManagedBlock $readmeDest $readmeMarkerBegin $readmeMarkerEnd) {
                $readmeAction = 'UPDATED'
            } else {
                Warn-Unterminated $readmeDest
                $readmeAction = 'skip'
            }
        }
        if ($readmeAction -ne 'skip') {
            $block = (Get-Content -LiteralPath $readmeTemplate -Raw).
                Replace('{{EXTENSION_VERSION}}', $extVersion).
                Replace('{{MODE}}', $readmeMode).
                Replace('{{REPOSITORY_URL}}', $extRepoUrl)
            Add-Content -LiteralPath $readmeDest -Value ("`n" + $block) -NoNewline -Encoding utf8
            $rel = Get-RelativeToTarget $readmeDest
            if ($readmeAction -eq 'UPDATED') {
                Write-Output "UPDATED: figma section in $rel (refreshed to v$extVersion)"
            } else {
                Write-Output "ADDED: figma section in $rel (PAT setup + local guide links; --no-readme to opt out)"
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Version coherence. SpecKit records the *registered* extension — and thus the
# version whose slash-commands are wired — written by `specify extension add`.
# We keep NO parallel stamp: we read SpecKit's own record and compare it to the
# version these ASSETS come from, so a half-applied update is surfaced instead
# of silently diverging. Skipped when the target IS the extension checkout.
# -----------------------------------------------------------------------------
if (-not $isSelf) {
    $manifest = Join-Path $target ".specify/extensions/$extId/extension.yml"
    $registeredVersion = Get-YamlVersion $manifest

    # Registered? The manifest existing is proof on its own; otherwise look for the
    # id as an `installed:` list item in either registry name (extensions.yml on
    # some SpecKit versions, extension.yml on others). The scan is scoped to the
    # installed: block so a `- <id>` under another key (hooks, disabled, ...)
    # cannot raise a false positive.
    $figmaRegistered = Test-Path -LiteralPath $manifest -PathType Leaf
    foreach ($reg in @((Join-Path $target '.specify/extensions.yml'), (Join-Path $target '.specify/extension.yml'))) {
        if (-not (Test-Path -LiteralPath $reg -PathType Leaf)) { continue }
        $inInstalled = $false
        foreach ($line in Get-Content -LiteralPath $reg) {
            if ($line -match '^[A-Za-z_][A-Za-z0-9_-]*:') {
                $inInstalled = $line -match '^installed:'
                continue
            }
            if ($inInstalled -and $line -match "^\s*-\s+$([regex]::Escape($extId))\s*$") {
                $figmaRegistered = $true
            }
        }
    }

    if ($registeredVersion) {
        if ($registeredVersion -eq $extVersion) {
            Write-Output "INFO: $extId extension in sync at $extVersion (assets and registered commands match)."
        } else {
            Write-Stderr "WARN: $extId version mismatch — assets just synced to $extVersion but SpecKit has commands registered at $registeredVersion. Run 'specify extension add $extId --from <source>' to align the commands."
        }
    } elseif ($figmaRegistered) {
        Write-Output "INFO: $extId registered with SpecKit but its installed version could not be read from this layout; assets synced at $extVersion. Re-run 'specify extension add $extId' if commands misbehave."
    } else {
        Write-Output "INFO: $extId assets synced at $extVersion; extension not yet registered with SpecKit — run 'specify extension add $extId' to register its commands."
    }
}

# -----------------------------------------------------------------------------
# Prompt auto-context block. DEFAULT ("clean"): the prompts are NOT modified —
# automatic Figma context is provided by the extension.yml hooks — and any block
# a previous extension version injected is removed. "--prompt-hooks" ("inject")
# appends/refreshes the managed block for agents without SpecKit extension-hook
# support. "--no-hooks" ("off") touches nothing.
# -----------------------------------------------------------------------------
$hookMarkerBegin = 'BEGIN SPECKIT-FIGMA AUTO-CONTEXT'
$hookMarkerEnd = 'END SPECKIT-FIGMA AUTO-CONTEXT'

$hookBlock = @'

<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed by spec-kit-figma; re-running install.sh refreshes this block) -->
## Figma design context (automatic)

Before generating, refresh the Figma design context:

1. From the workspace root, run `./.specify/scripts/bash/figma-ensure-context.sh`
   (or, on Windows, the PowerShell 7+ port
   `./.specify/scripts/powershell/figma-ensure-context.ps1` — same flags, same
   output), piping the user's RAW feature input (description, arguments, any
   pasted links — verbatim) via `--input -` (pass the target package name as
   the first argument in mono-/multi-repo workspaces):

   ```bash
   ./.specify/scripts/bash/figma-ensure-context.sh --input - <<'SPECKIT_FIGMA_INPUT'
   <the user's verbatim feature input>
   SPECKIT_FIGMA_INPUT
   ```

   ```powershell
   @'
   <the user's verbatim feature input>
   '@ | ./.specify/scripts/powershell/figma-ensure-context.ps1 --input -
   ```

   Any direct Figma link in the input is detected and introspected
   automatically — the linked file/frames become the authoritative design
   targets (node-level detail included), so no manual
   /speckit.figma.introspect run is needed. The script is a safe no-op when
   the extension is not configured, the target is excluded, or
   `.figma/cache/context-snapshot.json` is already fresh and covers the linked
   nodes.
2. When it prints `"ran": true` or `"reason": "fresh"` with `"mustInject": true`,
   the Figma design section is MANDATORY in this document — never omit it,
   whatever the agent model. The script renders a ready-to-paste section to the
   path reported in `specSection` / `planSection` / `tasksSection` (the one
   matching this command): insert that rendered block VERBATIM into the
   generated document, then load `.figma/cache/context-snapshot.json` and complete the
   judgement placeholders by applying the rules of `/speckit.figma.introspect`
   (sections 3-7: frame confirmation, component placement, token gaps, tests +
   Storybook sub-tasks). Treat any `links` reported in the status JSON as
   authoritative design targets for the affected components.
3. For any other skip reason, proceed without Figma context and add a short
   note mentioning the reason.
<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->
'@

function Remove-Hook {
    param([string]$File)
    if (-not (Get-Content -LiteralPath $File -Raw).Contains($hookMarkerBegin)) { return }
    if (-not (Remove-ManagedBlock $File $hookMarkerBegin $hookMarkerEnd)) { Warn-Unterminated $File; return }
    Write-Output "CLEANED: $(Get-RelativeToTarget $File) (auto-context now runs via the extension hooks; use --prompt-hooks to reinstate prompt injection)"
}

function Add-Hook {
    param([string]$File)
    $action = 'HOOKED'
    if ((Get-Content -LiteralPath $File -Raw).Contains($hookMarkerBegin)) {
        # Managed block: strip the previous copy and re-append the current one,
        # so re-running install.ps1 upgrades existing workspaces.
        if (-not (Remove-ManagedBlock $File $hookMarkerBegin $hookMarkerEnd)) { Warn-Unterminated $File; return }
        $action = 'UPDATED'
    }
    Add-Content -LiteralPath $File -Value ($hookBlock + "`n") -NoNewline -Encoding utf8
    Write-Output "${action}: $(Get-RelativeToTarget $File)"
}

if ($hooks -ne 'off') {
    $hookedAny = $false
    foreach ($dir in $agentCmdDirs) {
        foreach ($stem in @('specify', 'plan', 'tasks')) {
            foreach ($f in @(
                    (Join-Path $target $dir "speckit.$stem.md"),
                    (Join-Path $target $dir "speckit.$stem.prompt.md"))) {
                if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
                if ($hooks -eq 'inject') { Add-Hook $f } else { Remove-Hook $f }
                $hookedAny = $true
            }
        }
    }
    if ($hooks -eq 'inject' -and -not $hookedAny) {
        Write-Output "NOTE: no /speckit.specify, /speckit.plan or /speckit.tasks command files found — run 'specify init' first, then re-run install.ps1 --prompt-hooks to enable prompt injection."
    }
    if ($hooks -eq 'clean') {
        Write-Output 'INFO: speckit command prompts left untouched — automatic Figma context runs via the extension hooks (before_specify/before_plan/before_tasks -> /speckit.figma.ensure, after_specify/after_plan/after_tasks -> /speckit.figma.verify). Use --prompt-hooks if your agent does not support SpecKit extension hooks.'
    }
}

# -----------------------------------------------------------------------------
# Command-drift detection. install.ps1 copies the workspace ASSETS but does NOT
# register the slash-commands — that is `specify extension add`'s job. We detect
# the gap and tell the user exactly what to run. The command stems are derived
# from the extension's own commands/ directory so new commands are covered for free.
# -----------------------------------------------------------------------------
$extStems = @()
foreach ($cmdFile in Get-ChildItem -Path (Join-Path $extDir 'commands') -Filter "speckit.$extId.*.md" -ErrorAction SilentlyContinue) {
    $stem = $cmdFile.Name -replace "^speckit\.$([regex]::Escape($extId))\.", '' -replace '\.md$', ''
    $extStems += $stem
}

if ($extStems.Count -gt 0) {
    foreach ($dir in $agentCmdDirs) {
        $dirPath = Join-Path $target $dir
        if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) { continue }
        # Only a dir that already holds a speckit command counts as a configured
        # agent — otherwise an empty/unrelated dir would trigger a false warning.
        if (-not (Get-ChildItem -Path $dirPath -Filter 'speckit.*' -ErrorAction SilentlyContinue)) { continue }
        $missing = @()
        foreach ($stem in $extStems) {
            if ((Test-Path -LiteralPath (Join-Path $dirPath "speckit.$extId.$stem.md") -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $dirPath "speckit.$extId.$stem.prompt.md") -PathType Leaf)) { continue }
            $missing += $stem
        }
        if ($missing.Count -gt 0) {
            Write-Stderr "WARN: $extId command(s) not registered for ${dir}: $($missing -join ' ') — run 'specify extension add $extId' to (re)register them for this agent."
        }
    }
}

Write-Output @"

Next steps:
  1. Edit figma.projects.config.json — list targets, fill excluded[], replace REPLACE_WITH_* ids.
  2. Local dev: store your READ-ONLY Figma PAT in the OS credential store and export
     FIGMA_PAT_COMMAND in your shell profile (full guide: .figma/docs/CREDENTIALS.md,
     also linked from the figma section of your README).
     Windows (PowerShell 7+ SecretManagement), in your PowerShell profile:
       Set-Secret -Name figma-pat -Secret 'figd_xxxxxxxx'
       `$env:FIGMA_PAT_COMMAND = 'Get-Secret figma-pat -AsPlainText'
     macOS (keychain), e.g. in ~/.zshrc:
       security add-generic-password -s figma-pat -a "`$USER" -w 'figd_xxxxxxxx'
       echo 'export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"' >> ~/.zshrc
     CI / Cloud Agent: set credentials.source = "ci-secret" and inject a platform secret.
  3. Validate (from the workspace root):
       Windows:      pwsh -File ./.specify/scripts/powershell/figma-validate-config.ps1
       macOS/Linux:  ./.specify/scripts/bash/figma-validate-config.sh
  4. Register the extension commands (commands/speckit.figma.*.md)
     with your SpecKit agent of choice — or install natively with
     'specify extension add' (see extension.yml / docs/INSTALL.md), which registers
     /speckit.figma.setup, /speckit.figma.update, /speckit.figma.ensure,
     /speckit.figma.introspect and /speckit.figma.verify for you.
"@
exit 0
