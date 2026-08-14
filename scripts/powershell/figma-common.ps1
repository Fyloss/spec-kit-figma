#!/usr/bin/env pwsh
# =============================================================================
# figma-common.ps1 — shared helpers for the SpecKit Figma extension (Windows/PowerShell)
# =============================================================================
# Dot-source this file from the other scripts:  . "$PSScriptRoot/figma-common.ps1"
#
# PowerShell 7+ port of scripts/bash/figma-common.sh with the SAME contracts:
# same env vars, same JSON shapes, same diagnostics text, same exit semantics.
# curl is replaced by Invoke-WebRequest and jq by ConvertFrom-Json/ConvertTo-Json,
# so Windows only needs PowerShell 7+ and git — no extra tooling.
#
# Provides (bash-name -> PowerShell-name):
#   figma_repo_root            -> Get-FigmaRepoRoot
#   figma_load_token           -> Get-FigmaToken (returns the PAT; never echo it elsewhere)
#   figma_api <PATH>           -> Invoke-FigmaApi (GET with 429/5xx exponential backoff)
#   figma_state_dir            -> Get-FigmaStateDir (.figma/)
#   figma_cache_dir            -> Get-FigmaCacheDir (.figma/cache/)
#   figma_cache_path           -> Get-FigmaCachePath (snapshot cache path)
#   figma_section_path <phase> -> Get-FigmaSectionPath (rendered-section path)
#   figma_gc_cache             -> Invoke-FigmaCacheGc (collects orphaned cache entries)
# Dependencies: PowerShell 7+, git
# =============================================================================
# NOTE: This file is meant to be dot-sourced; do not change global preferences here.

# --- stderr helpers: diagnostics NEVER pollute the machine-readable stdout ----
function Write-FigmaStderr {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

# Safe property navigation on ConvertFrom-Json output: returns $Default when any
# path segment is absent or $null (the PowerShell analogue of jq's `// default`).
# ConvertFrom-Json eagerly converts ISO-8601 strings to [datetime]; jq never
# does, so re-normalize datetimes back to the ISO-8601 string the JSON carried
# (Figma timestamps are always UTC "…Z") to keep byte-for-byte output parity.
function Get-JsonValue {
    param($Object, [string[]]$Path, $Default = $null)
    $cur = $Object
    foreach ($key in $Path) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$key]
        if ($null -eq $prop) { return $Default }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return $Default }
    if ($cur -is [datetime]) {
        if ($cur.Kind -eq [System.DateTimeKind]::Utc) {
            return $cur.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
        }
        return $cur.ToString("yyyy-MM-dd'T'HH:mm:ss", [cultureinfo]::InvariantCulture)
    }
    return $cur
}

# Stable JSON emission for the stdout contracts. -InputObject keeps arrays from
# being unwrapped by the pipeline; -Depth 100 keeps deep snapshots intact.
function ConvertTo-FigmaJson {
    param($Object, [switch]$Compress)
    ConvertTo-Json -InputObject $Object -Depth 100 -Compress:$Compress
}

function Read-FigmaJsonFile {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-FigmaRepoRoot {
    $root = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $root) { return ($root | Select-Object -First 1) }
    return (Get-Location).Path
}

# Per-workspace Figma directory. Committed content (the design-rules base
# figma-design-rules.md and the user overlay figma-design-rules.custom.md) lives at
# its root; every generated/cached artifact (snapshot + rendered sections) lives
# under cache/ so a single `.figma/cache/` entry in .gitignore covers them all.
function Get-FigmaStateDir { Join-Path (Get-FigmaRepoRoot) '.figma' }

function Get-FigmaCacheDir { Join-Path (Get-FigmaStateDir) 'cache' }

function Get-FigmaCachePath { Join-Path (Get-FigmaCacheDir) 'context-snapshot.json' }

# Per-file snapshot store. Get-FigmaCachePath above is a single slot: the
# snapshot of the CURRENT run, and the well-known path every command prompt hands
# to the agent. One slot is enough to PUBLISH a snapshot but not to CACHE one —
# two features pointing at different Figma files evict each other, so the "fresh"
# path never hits and every phase re-pays a full file + nodes fetch. Keyed by
# file, snapshots survive that alternation; the current slot is a copy of
# whichever one this run resolved. Returns $null when the key cannot name a file.
function Get-FigmaSnapshotStorePath {
    param([string]$FileId)
    if (-not $FileId) { return $null }
    # Figma file keys are [A-Za-z0-9_-], but the value reaches us from a URL or a
    # config field: squeeze anything else so it can never escape the directory.
    $key = ($FileId -replace '[^A-Za-z0-9._-]', '-')
    if ($key.Length -gt 100) { $key = $key.Substring(0, 100) }
    if (-not $key -or $key -match '^\.+$') { return $null }
    return Join-Path (Join-Path (Get-FigmaCacheDir) 'snapshots') "$key.json"
}

# Path of the rendered, ready-to-paste section for a phase (spec|plan|tasks),
# scoped to the current feature.
#
# The scoping is load-bearing, not tidiness. figma-verify-section decides
# "Figma applied to this run" from the EXISTENCE of this file, while resolving a
# per-feature document — so while every feature shared one slot, a design-less
# feature erased the renders of a design one, and that feature's after-hook then
# reported not-applicable. A --strict CI gate passed for a document genuinely
# missing its design section: fail-open, which is exactly what the gate exists to
# prevent.
function Get-FigmaSectionPath {
    param([string]$Phase)
    Join-Path (Join-Path (Join-Path (Get-FigmaCacheDir) 'sections') (Get-FigmaFeatureKey)) "$Phase.md"
}

# Identity of the feature being worked on, used to scope the remembered design
# links. Precedence mirrors SpecKit's own resolution: SPECIFY_FEATURE, then
# .specify/feature.json's feature_directory, then the git branch. Returns
# 'default' when nothing identifies a feature.
#
# Scoping is the whole point: the links are remembered so /speckit.plan and
# /speckit.tasks inherit what /speckit.specify detected, and a single shared file
# would make the NEXT feature inherit them too — reinstating the very problem
# (a design section forced onto a feature that has no mockup) the link
# requirement exists to prevent.
function Get-FigmaFeatureKey {
    $key = $env:SPECIFY_FEATURE
    if (-not $key) {
        $featureJson = Join-Path (Get-FigmaRepoRoot) '.specify/feature.json'
        if (Test-Path -LiteralPath $featureJson -PathType Leaf) {
            try {
                $key = [string](Read-FigmaJsonFile $featureJson).feature_directory
                $key = ($key.TrimEnd('/', '\') -split '[/\\]')[-1]
            } catch { $key = '' }
        }
    }
    if (-not $key) {
        $branch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $branch -and $branch -ne 'HEAD') {
            $key = ($branch | Select-Object -First 1)
        }
    }
    if (-not $key) { return 'default' }
    # Squeeze to a safe, bounded filename: the value reaches us from an env var,
    # a JSON field or a branch name, any of which may carry '/' or '..'. Mapping
    # every other character to '-' makes traversal impossible; a key left as only
    # dots ('.', '..') would still name a directory entry we must not write.
    $key = ($key -replace '[^A-Za-z0-9._-]', '-')
    if ($key.Length -gt 100) { $key = $key.Substring(0, 100) }
    if (-not $key -or $key -match '^\.+$') { return 'default' }
    return $key
}

# Where the Figma links detected in the feature input are remembered, per
# feature, so later phases inherit them without the developer re-pasting.
function Get-FigmaFeatureLinksPath {
    Join-Path (Join-Path (Get-FigmaCacheDir) 'links') "$(Get-FigmaFeatureKey).json"
}

# True when a cache key still names something: the feature this very run is
# working on, or a SpecKit feature directory. specs/<key>/ is committed and
# outlives the branch that produced it, which is what makes it the durable
# ownership signal — a merged feature keeps its entry, an ad-hoc branch that
# never became a feature does not.
function Test-FigmaGcKeyIsLive {
    param([string]$Key, [string]$CurrentKey, [string]$RepoRoot)
    if ($Key -eq $CurrentKey) { return $true }
    return (Test-Path -LiteralPath (Join-Path (Join-Path $RepoRoot 'specs') $Key) -PathType Container)
}

# Reclaim cache entries whose owner is gone. .figma/cache/ only ever grew: every
# branch that ran a phase left a links/<key>.json and a sections/<key>/, and every
# Figma file ever linked left a snapshots/<file>.json. Disk is not the problem (a
# links file is a few hundred bytes) — key REUSE is. A key derives from a branch
# name, so a new feature on a recycled name inherits the previous one's remembered
# links, which is precisely the "design section forced onto a feature that has no
# mockup" regression the link requirement exists to prevent.
#
# The policy is ownership first, age second: an entry is collected only when BOTH
# say it is garbage.
#   * Ownership — a key with a specs/<key>/ directory is a real feature and is
#     kept indefinitely. Collecting a live feature's sections/<key>/ would be
#     unsafe on top of wasteful: figma-verify-section reads "Figma applied to this
#     run" from the existence of those files, so deleting them turns a --strict CI
#     gate fail-open (the very failure Get-FigmaSectionPath's scoping fixed). What
#     has no such directory is the garbage: ad-hoc branches, and the 'default' key
#     of a detached HEAD.
#   * Age — nothing is collected before FIGMA_CACHE_RETENTION_DAYS (7) of
#     inactivity, so a feature whose specs/ directory does not exist YET — the
#     /speckit.specify run that is about to create it — is never collected
#     mid-flight.
# The CURRENT feature is exempt from both: a run must never collect the state it
# is itself about to read.
#
# Snapshots are keyed by Figma file, not by feature, so they have no owner to
# check: they are pure caches of remote data and go on age alone. Their window is
# never shorter than the freshness window, so a snapshot that a run could still
# restore is never taken from under it.
#
# Throttled to once a day through .gc-stamp, since this runs inside a hook on
# every phase. FIGMA_CACHE_GC=off disables it entirely, =force ignores the
# throttle. Best-effort by design: nothing here is allowed to be the reason a
# hook blocks generation, so every failure is swallowed.
function Invoke-FigmaCacheGc {
    $mode = if ($env:FIGMA_CACHE_GC) { $env:FIGMA_CACHE_GC } else { 'auto' }
    if ($mode -eq 'off') { return }
    $cache = Get-FigmaCacheDir
    if (-not (Test-Path -LiteralPath $cache -PathType Container)) { return }

    $days = 7
    if ($env:FIGMA_CACHE_RETENTION_DAYS -match '^[1-9][0-9]*$') {
        $days = [int]$env:FIGMA_CACHE_RETENTION_DAYS
    }
    $now = Get-Date
    $cutoff = $now.AddDays(-$days)

    # -Force throughout: a dot-prefixed name is a HIDDEN file, and both Get-Item
    # and Set-Content skip hidden files without it — silently, which would leave
    # the throttle permanently un-armed and sweep on every single phase.
    $stamp = Join-Path $cache '.gc-stamp'
    if ($mode -ne 'force' -and (Test-Path -LiteralPath $stamp -PathType Leaf)) {
        $last = (Get-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue).LastWriteTime
        if ($last -and $last -gt $now.AddDays(-1)) { return }
    }
    # Stamped BEFORE the sweep: a sweep that dies halfway must not make every
    # subsequent run retry it.
    try { Set-Content -LiteralPath $stamp -Value '' -NoNewline -Force -ErrorAction Stop } catch { }

    $root = Get-FigmaRepoRoot
    $current = Get-FigmaFeatureKey
    $removed = 0

    foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $cache 'links') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if (Test-FigmaGcKeyIsLive $entry.BaseName $current $root) { continue }
        if ($entry.LastWriteTime -ge $cutoff) { continue }
        try { Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop; $removed++ } catch { }
    }

    foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $cache 'sections') -Directory -ErrorAction SilentlyContinue)) {
        if (Test-FigmaGcKeyIsLive $entry.Name $current $root) { continue }
        # A directory's own mtime only moves when an entry is added or removed, so
        # the renders decide: any one of them touched inside the window keeps the
        # whole directory.
        $renders = @(Get-ChildItem -LiteralPath $entry.FullName -Filter '*.md' -File -ErrorAction SilentlyContinue)
        if ($renders | Where-Object { $_.LastWriteTime -ge $cutoff }) { continue }
        # The renders, then the directory once it is empty — never a recursive
        # delete of a path assembled from a key, and never a file this extension
        # did not write.
        foreach ($render in $renders) {
            Remove-Item -LiteralPath $render.FullName -Force -ErrorAction SilentlyContinue
        }
        try {
            if (-not @(Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
                $removed++
            }
        } catch { }
    }

    # Past the freshness window a stored snapshot is dead weight: Test-SnapshotIsCurrent
    # would reject it anyway. It is still kept for the whole retention window (the
    # window is a floor, not the policy), and never dropped below a caller's own —
    # possibly much longer — freshness window.
    $snapCutoff = $cutoff
    if ($env:FIGMA_SNAPSHOT_MAX_AGE_MINUTES -match '^[1-9][0-9]*$') {
        $byWindow = $now.AddMinutes(-[int]$env:FIGMA_SNAPSHOT_MAX_AGE_MINUTES)
        if ($byWindow -lt $snapCutoff) { $snapCutoff = $byWindow }
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $cache 'snapshots') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($entry.LastWriteTime -ge $snapCutoff) { continue }
        try { Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop; $removed++ } catch { }
    }

    if ($removed -gt 0) {
        $noun = if ($removed -eq 1) { 'entry' } else { 'entries' }
        Write-FigmaStderr "INFO: cache housekeeping reclaimed $removed stale $noun under .figma/cache/ (features with no specs/ directory, unused snapshots). Set FIGMA_CACHE_RETENTION_DAYS to change the $days-day window, FIGMA_CACHE_GC=off to disable."
    }
}

# Locate the SpecKit document of a phase (spec|plan|tasks) in the standard
# layout. Precedence: specs/<feature-key>/<phase>.md (honours SPECIFY_FEATURE and
# .specify/feature.json, not just the branch), then specs/<branch>/<phase>.md,
# then the single specs/*/<phase>.md when there is exactly one.
#
# With SEVERAL candidates and no feature identity the target is genuinely
# ambiguous, so this returns $null rather than picking the most recent: callers
# verify (and gate CI on) or read design links from the document, and both are
# wrong on the wrong feature's file.
#
# -IdentifiedOnly drops BOTH guesses — the branch and the last-resort single
# candidate — so ONLY a document the current feature positively owns is returned.
# A caller that READS design context out of the document needs that: "the
# branch's spec" and "the only spec around" both belong to some OTHER feature
# whenever they differ from the feature key, and inheriting their creative
# re-creates the regression the link requirement exists to prevent. A caller that
# merely verifies a document generated by this very run can afford the looser
# rule (its failure mode is a warning, not a silent injection).
function Get-FigmaPhaseDoc {
    param([Parameter(Mandatory)][string]$Phase, [switch]$IdentifiedOnly)
    $root = Get-FigmaRepoRoot
    $candidate = Join-Path $root 'specs' (Get-FigmaFeatureKey) "$Phase.md"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    # Everything below is a guess, so it is gated. The branch is already the LAST
    # resort inside Get-FigmaFeatureKey: it can only disagree with the key
    # resolved above when SPECIFY_FEATURE or .specify/feature.json named another
    # feature — which makes specs/<branch>/ that other feature's directory.
    if ($IdentifiedOnly) { return $null }
    $branch = ''
    try {
        $branch = git -C $root rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { $branch = '' }
    } catch { $branch = '' }
    if ($branch) {
        $candidate = Join-Path $root 'specs' $branch "$Phase.md"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $specsDir = Join-Path $root 'specs'
    $matched = @()
    if (Test-Path -LiteralPath $specsDir -PathType Container) {
        $matched = @(Get-ChildItem -LiteralPath $specsDir -Directory |
            ForEach-Object { Join-Path $_.FullName "$Phase.md" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    }
    if ($matched.Count -eq 1) { return $matched[0] }
    if ($matched.Count -gt 1) {
        Write-FigmaStderr "WARN: $($matched.Count) candidate specs/*/$Phase.md documents and no feature identity resolves one of them; name the document explicitly."
    }
    return $null
}

# Canonical form of a Figma node id, as expected by the REST API and by every
# Figma MCP server: '12:345', or 'I12:345;678:901' for a nested instance.
# Deep links carry the same id in URL form — '12-345', '%3A'-encoded, and
# '%3B'-chained — so a half-normalized value reaches the server as an unknown
# node and comes back as "the provided node ID was not found in the file".
# Returns the canonical id, or $null when the value is not a node id.
function ConvertTo-FigmaNodeId {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $id = $Raw -replace '(?i)%3A', ':' -replace '(?i)%3B', ';' -replace '-', ':'
    if ($id -notmatch '^I?[0-9]+:[0-9A-Za-z]+(;[0-9]+:[0-9A-Za-z]+)*$') { return $null }
    return $id
}

# Default config path. Precedence: FIGMA_CONFIG env override > <root>/figma.projects.config.json.
function Get-FigmaDefaultConfig {
    if ($env:FIGMA_CONFIG) { return $env:FIGMA_CONFIG }
    Join-Path (Get-FigmaRepoRoot) 'figma.projects.config.json'
}

# Shared precondition: the config file exists and parses as JSON.
# Returns $true, or $false with an ERROR on stderr otherwise.
function Test-FigmaConfig {
    param([string]$Config)
    if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
        Write-FigmaStderr "ERROR: config not found: $Config"
        return $false
    }
    try { $null = Read-FigmaJsonFile $Config } catch {
        Write-FigmaStderr "ERROR: $Config is not valid JSON"
        return $false
    }
    return $true
}

# Generic config accessor. Falls back to the default when the config is absent,
# unreadable, or the path yields null/empty.
function Get-FigmaConfigValue {
    param([string[]]$Path, $Default, [string]$Config = (Get-FigmaDefaultConfig))
    if (Test-Path -LiteralPath $Config -PathType Leaf) {
        try {
            $obj = Read-FigmaJsonFile $Config
            $v = Get-JsonValue $obj $Path
            if ($null -ne $v -and "$v" -ne '') { return $v }
        } catch { }
    }
    return $Default
}

# Base URL of the Figma REST API.
# Precedence: FIGMA_API_BASE env override > config .figma.apiBaseUrl > built-in default.
# The config is a committed, shared artifact: an apiBaseUrl pointing anywhere
# else would exfiltrate the PAT (sent as X-Figma-Token) to that host on the
# next introspection run, so config-sourced values are restricted to
# https://figma.com hosts. FIGMA_API_BASE (local, trusted env) is the escape
# hatch for enterprise proxies and test mocks.
# Throws on a rejected apiBaseUrl (the bash `return 1` analogue).
function Get-FigmaApiBase {
    param([string]$Config = (Get-FigmaDefaultConfig))
    if ($env:FIGMA_API_BASE) { return $env:FIGMA_API_BASE }
    $base = [string](Get-FigmaConfigValue @('figma', 'apiBaseUrl') 'https://api.figma.com/v1' $Config)
    # Host = authority up to the first path/port/query/fragment delimiter;
    # userinfo (@) is rejected outright since no legitimate Figma URL uses it.
    $hostPart = $base -replace '^https://', ''
    $hostPart = ($hostPart -split '[/:?#]', 2)[0]
    if ($base -notmatch '^https://' -or $hostPart -match '@' -or
        ($hostPart -ne 'figma.com' -and $hostPart -notmatch '\.figma\.com$')) {
        Write-FigmaStderr "ERROR: refusing apiBaseUrl '$base' from the config: it must be an https://*.figma.com URL. Use the FIGMA_API_BASE env var for a local override."
        throw "invalid apiBaseUrl"
    }
    return $base
}

# Resolve the env var name declared in figma.projects.config.json (defaults to FIGMA_PAT).
# In ci-secret mode, envVar names the variable the CI injects the secret into;
# secretName (the secret-store key) is only a fallback when envVar is unset.
function Get-FigmaEnvVarName {
    param([string]$Config = (Get-FigmaDefaultConfig))
    $source = Get-FigmaConfigValue @('figma', 'credentials', 'source') '' $Config
    if ($source -eq 'ci-secret') {
        $v = Get-FigmaConfigValue @('figma', 'credentials', 'envVar') '' $Config
        if ("$v" -ne '') { return $v }
        $v = Get-FigmaConfigValue @('figma', 'credentials', 'secretName') '' $Config
        if ("$v" -ne '') { return $v }
        return 'FIGMA_PAT'
    }
    return (Get-FigmaConfigValue @('figma', 'credentials', 'envVar') 'FIGMA_PAT' $Config)
}

# -----------------------------------------------------------------------------
# Design-context engine selection (REST default, optional MCP with REST fallback)
# -----------------------------------------------------------------------------

# Requested engine declared in the config: "rest" (default) or "mcp".
function Get-FigmaContextSource {
    param([string]$Config = (Get-FigmaDefaultConfig))
    Get-FigmaConfigValue @('figma', 'contextSource') 'rest' $Config
}

# MCP server endpoint (defaults to the local Figma Dev Mode MCP server).
function Get-FigmaMcpUrl {
    param([string]$Config = (Get-FigmaDefaultConfig))
    Get-FigmaConfigValue @('figma', 'mcp', 'url') 'http://127.0.0.1:3845/mcp' $Config
}

# Whether an unreachable MCP server should silently fall back to REST (default: yes).
# The tristate (absent/true/false) maps explicitly so a false value cannot be
# swallowed by a truthiness default.
function Test-FigmaMcpFallbackEnabled {
    param([string]$Config = (Get-FigmaDefaultConfig))
    $v = Get-FigmaConfigValue @('figma', 'mcp', 'fallbackToRest') $null $Config
    return -not ($v -is [bool] -and $v -eq $false)
}

# Probe the MCP server. Returns $true when reachable. Any HTTP response (even
# 4xx) means the server is up; a transport failure is absent.
function Test-FigmaMcpAvailable {
    param([string]$Config = (Get-FigmaDefaultConfig))
    $url = Get-FigmaMcpUrl $Config
    $timeout = 3
    if ($env:FIGMA_MCP_PROBE_TIMEOUT) { $timeout = [int]$env:FIGMA_MCP_PROBE_TIMEOUT }
    try {
        $null = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $timeout -SkipHttpErrorCheck -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Single decision table for the MCP -> REST fallback policy, shared by
# Resolve-FigmaContextSource and figma-resolve-source.ps1 (which probes once
# itself to avoid a second timeout / flapping disagreement).
# Returns the effective engine ("rest"/"mcp"); diagnostics go to stderr.
# Throws when MCP is required (fallback disabled) but absent.
function Resolve-FigmaContextSourceDecision {
    param([string]$Requested, [bool]$Reachable, [bool]$Fallback, [string]$McpUrl = '')
    switch ($Requested) {
        'rest' { return 'rest' }
        'mcp' {
            if ($Reachable) { return 'mcp' }
            if ($Fallback) {
                Write-FigmaStderr "WARN: MCP server unreachable at $McpUrl; falling back to the portable REST engine."
                return 'rest'
            }
            Write-FigmaStderr "ERROR: contextSource='mcp' but the MCP server is unreachable and mcp.fallbackToRest=false."
            throw "mcp required but unreachable"
        }
        default {
            Write-FigmaStderr "WARN: unknown contextSource '$Requested'; defaulting to the REST engine."
            return 'rest'
        }
    }
}

# Resolve the EFFECTIVE engine, applying the MCP -> REST fallback policy.
# Returns "rest" or "mcp"; diagnostics go to stderr.
# Throws when MCP is required (fallback disabled) but absent.
function Resolve-FigmaContextSource {
    param([string]$Config = (Get-FigmaDefaultConfig))
    $requested = Get-FigmaContextSource $Config
    $reachable = $false
    if ($requested -eq 'mcp' -and (Test-FigmaMcpAvailable $Config)) { $reachable = $true }
    $fallback = Test-FigmaMcpFallbackEnabled $Config
    Resolve-FigmaContextSourceDecision $requested $reachable $fallback (Get-FigmaMcpUrl $Config)
}

# -----------------------------------------------------------------------------
# Claude Code / official Figma plugin advisory
# -----------------------------------------------------------------------------
# Inside Claude Code, the most reliable way to obtain rich MCP design context is
# the official Figma plugin (`claude plugin install figma@claude-plugins-official`):
# it wires Figma's *hosted* MCP server (https://mcp.figma.com/mcp) in as a native
# Claude Code tool, so the agent reads structured node data directly — no local
# Dev Mode server, no probe. These helpers detect that situation and nudge the
# user toward the plugin; they are advisory only and never change behaviour.

# True when running inside Claude Code. The CLI exports CLAUDECODE=1 for every
# command it spawns (AI_AGENT=claude-code... is a secondary signal).
function Test-FigmaIsClaudeCode {
    if ($env:CLAUDECODE -eq '1') { return $true }
    return [bool]($env:AI_AGENT -and $env:AI_AGENT.StartsWith('claude-code'))
}

# Path to Claude Code's installed-plugins registry. Honours CLAUDE_CONFIG_DIR
# (which relocates ~/.claude), so the probe follows a customised config home.
function Get-FigmaClaudePluginsFile {
    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    Join-Path $configDir 'plugins/installed_plugins.json'
}

# True when ANY Figma plugin is installed in Claude Code (the official one or a
# fork from another marketplace), matched on the `figma@<marketplace>` key the
# CLI writes to installed_plugins.json. Returns $false — i.e. "not installed",
# so the advice fires — when the registry is absent/unreadable.
function Test-FigmaClaudeFigmaPluginInstalled {
    $file = Get-FigmaClaudePluginsFile
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    try {
        $obj = Read-FigmaJsonFile $file
        $plugins = Get-JsonValue $obj @('plugins')
        if ($null -eq $plugins) { return $false }
        foreach ($p in $plugins.PSObject.Properties) {
            if ($p.Name.StartsWith('figma@')) { return $true }
        }
    } catch { }
    return $false
}

# Print a recommendation to stderr when running in Claude Code WITHOUT a Figma
# plugin. No-op for other agents, when a plugin is already present, or when
# FIGMA_NO_PLUGIN_ADVICE=1 silences it.
function Write-FigmaClaudePluginAdvice {
    if ($env:FIGMA_NO_PLUGIN_ADVICE -eq '1') { return }
    if (-not (Test-FigmaIsClaudeCode)) { return }
    if (Test-FigmaClaudeFigmaPluginInstalled) { return }
    Write-FigmaStderr @'
TIP: Claude Code detected without the official Figma plugin. For the richest,
     most faithful design context, install it:
         claude plugin install figma@claude-plugins-official
     It connects Claude Code to Figma's hosted MCP server
     (https://mcp.figma.com/mcp) as a native tool — no local Dev Mode server
     required — then set "figma.contextSource": "mcp" in
     figma.projects.config.json. (Silence with FIGMA_NO_PLUGIN_ADVICE=1.)
'@
}

# Load the token: environment variable first, then FIGMA_PAT_COMMAND (a secret
# manager such as the Windows Credential Manager via SecretManagement, or the
# macOS keychain). There is deliberately NO plaintext .env fallback — locally
# the token MUST be stored in the OS credential store and fetched via
# FIGMA_PAT_COMMAND, never written to a file in the workspace.
#
# FIGMA_PAT_COMMAND is a trusted LOCAL env var (same trust model as
# FIGMA_API_BASE — never read from the committed config, which could smuggle a
# command in via a PR). On Windows, with the SecretManagement + SecretStore
# modules installed, set for example:
#   $env:FIGMA_PAT_COMMAND = 'Get-Secret figma-pat -AsPlainText'
# It is executed WITHOUT a shell (tokenized invocation via the call operator),
# so pipes/substitutions in the value are inert arguments, not shell syntax.
# Read the local SecretStore vault's authentication settings, so a failed
# lookup can be diagnosed against what the vault actually does. Reading the
# configuration never unlocks anything, so it cannot itself prompt. Returns
# empty strings when the command is not a SecretStore lookup or the module is
# absent — the one impure part of the diagnostic, kept out of the hint text so
# that stays a pure function.
function Get-FigmaSecretStoreState {
    param([string]$Command)
    $state = @{ Authentication = ''; Interaction = '' }
    if ($Command -notmatch 'Get-Secret') { return $state }
    try {
        $cfg = Get-SecretStoreConfiguration -ErrorAction Stop
        $state.Authentication = [string]$cfg.Authentication
        $state.Interaction = [string]$cfg.Interaction
    } catch { }
    return $state
}

# The Windows failure mode: a SecretStore vault created with the defaults
# requires an interactive password unlock, which an agent hook can never answer,
# so every non-interactive `Get-Secret` fails for a reason that has nothing to
# do with the PAT — and the raw error never names the remedy. $Authentication /
# $Interaction are the observed vault settings ('' when unknown). Returns ''
# when the command is not a SecretStore lookup, or when the vault is already in
# no-password mode and this diagnosis would therefore be a wrong lead.
function Get-FigmaSecretStoreHint {
    param([string]$Command, [string]$Authentication = '', [string]$Interaction = '')
    if ($Command -notmatch 'Get-Secret') { return '' }
    if ($Authentication -eq 'None' -and $Interaction -eq 'None') { return '' }
    $observed = ''
    if ($Authentication -or $Interaction) {
        $observed = " Vault config: Authentication=$Authentication, Interaction=$Interaction."
    }
    return @"
HINT: 'Get-Secret' failed — this can happen with a correctly stored PAT.$observed
      A SecretStore vault created with the defaults requires an interactive
      password unlock, which an agent hook can never answer, so every
      non-interactive lookup fails. Switch the vault to no-password mode — the
      secrets stay encrypted at rest under your Windows user profile (DPAPI),
      the setting recommended for a local dev machine driving automated tooling:
          Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:`$false
      Verify: Get-SecretStoreConfiguration | Select-Object Authentication, Interaction
"@
}

# Throws when no token can be resolved (the bash `return 1` analogue).
function Get-FigmaToken {
    param([string]$Config = (Get-FigmaDefaultConfig))
    $var = Get-FigmaEnvVarName $Config
    $fromEnv = [Environment]::GetEnvironmentVariable($var)
    if ($fromEnv) { return $fromEnv }
    if ($env:FIGMA_PAT_COMMAND) {
        $tokens = -split $env:FIGMA_PAT_COMMAND
        $exe = $tokens[0]
        $cmdArgs = @()
        if ($tokens.Count -gt 1) { $cmdArgs = $tokens[1..($tokens.Count - 1)] }
        # Keep the command's own error instead of discarding it: a locked vault,
        # a missing cmdlet and a revoked entry all failed the same silent way
        # before, and "PAT not found" then sends the user back to re-storing a
        # token that is already stored. Error records are filtered OUT of the
        # token so a chatty-but-successful lookup still resolves.
        $why = ''
        try {
            $raw = & $exe @cmdArgs 2>&1
            $failures = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            $out = (@($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String).TrimEnd("`r", "`n")
            if ($out) { return $out }
            if ($failures.Count -gt 0) { $why = ($failures | ForEach-Object { $_.ToString() }) -join ' ' }
        } catch {
            $why = $_.Exception.Message
        }
        $why = ($why -replace '\s*\r?\n\s*', ' ').Trim()
        $detail = if ($why) { " ($why)" } else { '' }
        Write-FigmaStderr "WARN: FIGMA_PAT_COMMAND failed or returned an empty token.$detail"
        $state = Get-FigmaSecretStoreState $env:FIGMA_PAT_COMMAND
        $hint = Get-FigmaSecretStoreHint $env:FIGMA_PAT_COMMAND $state.Authentication $state.Interaction
        if ($hint) { Write-FigmaStderr $hint }
    }
    Write-FigmaStderr "ERROR: $var not found. Store the PAT in your OS credential store and export FIGMA_PAT_COMMAND locally (e.g. 'Get-Secret figma-pat -AsPlainText' with the SecretManagement module, or 'security find-generic-password -s figma-pat -w' on macOS), or inject $var as a CI secret. Do NOT set ${var}=... by hand and do NOT create a .env file — the token must never be written to disk in the workspace (see docs/CREDENTIALS.md)."
    throw "missing Figma token"
}

# Map a 403/404 API path to the most likely cause, so org-level setups fail with
# an actionable hint. Team/project enumeration needs the `projects:read` scope AND
# team membership; a file read needs `file_content:read`. Returns '' when no hint applies.
function Get-FigmaScopeHint {
    param([string]$Path)
    if ($Path -match '^/(teams|projects)/') {
        return "HINT: listing team projects or project files requires a PAT with the 'projects:read' scope, and the token owner must be a member of that team. See docs/CREDENTIALS.md."
    }
    if ($Path -match '^/files/') {
        return "HINT: reading a file requires a PAT with the 'file_content:read' scope (and 'file_metadata:read' for metadata), and access to the file. See docs/CREDENTIALS.md."
    }
    return ''
}

# Classify a Figma HTTP status into a stable machine code the caller can switch
# on and surface verbatim. Transport failures reach here as code 000. Pure
# function: no network, no globals. Returns exactly one of:
#   OK | NETWORK | AUTH | NOT_FOUND | RATE_LIMIT | SERVER | UNKNOWN
function Get-FigmaStatusClass {
    param([string]$Code)
    switch ($Code) {
        { $_ -in '200', '201', '204' } { return 'OK' }
        '000' { return 'NETWORK' }
        { $_ -in '401', '403' } { return 'AUTH' }
        '404' { return 'NOT_FOUND' }
        '429' { return 'RATE_LIMIT' }
        { $_ -in '500', '502', '503', '504' } { return 'SERVER' }
        default { return 'UNKNOWN' }
    }
}

# Build the cause-specific diagnostic for a failed Figma call. The text IS the
# instruction a weak LLM will copy verbatim, so each cause names its real remedy
# and the NETWORK case explicitly forbids the "authentication" misdiagnosis.
function Get-FigmaErrorMessage {
    param([string]$Class, [string]$Path, [string]$Code)
    switch ($Class) {
        'NETWORK' {
            return "NETWORK/PROXY error: cannot reach api.figma.com (HTTP $Code). A broken or unreachable proxy is the usual cause — the script already auto-retried directly without the proxy. This is a connectivity problem, NOT a credentials problem. HTTP 000 / a transport failure = proxy. If it persists, check network/proxy connectivity to api.figma.com."
        }
        'AUTH' {
            return "AUTH/SCOPE error: Figma returned HTTP $Code for $Path. The PAT is missing, invalid, or lacks the required read-only scopes (team/project enumeration also needs projects:read). Store the PAT in the OS credential store and export FIGMA_PAT_COMMAND; do NOT export the token by hand and do NOT create a .env (see docs/CREDENTIALS.md). $(Get-FigmaScopeHint $Path)"
        }
        'NOT_FOUND' {
            return "NOT FOUND: Figma returned 404 for $Path. Either the file/project/team key is wrong, or the PAT owner is not a member of that team/project. Verify the id and team membership (see docs/CREDENTIALS.md)."
        }
        'RATE_LIMIT' {
            return "RATE LIMIT: Figma returned HTTP $Code for $Path after retries; wait and retry later."
        }
        'SERVER' {
            return "SERVER error: Figma returned HTTP $Code for $Path after retries; this is a Figma-side outage, retry later."
        }
        default {
            return "Figma API error HTTP $Code for $Path."
        }
    }
}

# Record a machine-readable failure cause for the calling process to read back
# (set FIGMA_DIAG_FILE to a writable path). No-op when unset. Never contains the
# token — only the class, the HTTP status and the request path.
function Write-FigmaDiag {
    param([string]$Code, [string]$HttpStatus, [string]$Path)
    if (-not $env:FIGMA_DIAG_FILE) { return }
    try {
        ConvertTo-FigmaJson ([ordered]@{ code = $Code; httpStatus = $HttpStatus; path = $Path }) |
            Set-Content -LiteralPath $env:FIGMA_DIAG_FILE -Encoding utf8
    } catch { }
}

# Single Figma GET. Returns @{ Code = '<http-status>'; Body = '<string>' }
# (transport failures return code 000). The Figma REST API is a PUBLIC endpoint,
# so on a transport failure with a proxy configured it retries ONCE with the
# proxy bypassed (-NoProxy). This self-heals a broken corporate proxy (direct
# works) and is harmless where the proxy is the only egress (the first attempt
# succeeds so the bypass never runs). The token stays an X-Figma-Token header
# on both tries.
function Invoke-FigmaHttpGet {
    param([string]$Url, [string]$Token)
    $headers = @{ 'X-Figma-Token' = $Token; 'Accept' = 'application/json' }
    $proxySet = [bool]($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:http_proxy -or $env:https_proxy)
    $code = '000'; $body = ''
    try {
        $resp = Invoke-WebRequest -Uri $Url -Headers $headers -SkipHttpErrorCheck -ErrorAction Stop
        $code = [string][int]$resp.StatusCode
        $body = [string]$resp.Content
    } catch {
        $code = '000'
    }
    if ($code -eq '000' -and $proxySet) {
        Write-FigmaStderr 'WARN: cannot reach Figma via the configured proxy; retrying directly without the proxy...'
        try {
            $resp = Invoke-WebRequest -Uri $Url -Headers $headers -SkipHttpErrorCheck -NoProxy -ErrorAction Stop
            $code = [string][int]$resp.StatusCode
            $body = [string]$resp.Content
        } catch {
            $code = '000'
        }
    }
    return @{ Code = $code; Body = $body }
}

# GET helper with retry. Usage: Invoke-FigmaApi "/files/<key>?depth=1" [config-path]
# Returns the response body string. Retries 429/5xx AND transport failures
# (code 000) with exponential backoff; each attempt self-heals a broken/mandatory
# proxy via Invoke-FigmaHttpGet. On a terminal failure it records a
# cause-specific diagnostic (NETWORK/AUTH/...) and THROWS so the caller reports
# the truth instead of guessing "authentication required".
# FIGMA_API_MAX_ATTEMPTS / FIGMA_API_RETRY_DELAY override the retry policy (tests).
function Invoke-FigmaApi {
    param([string]$Path, [string]$Config = (Get-FigmaDefaultConfig))
    # Validate the base URL BEFORE touching the token: a rejected apiBaseUrl
    # must never get anywhere near the credential.
    $base = Get-FigmaApiBase $Config
    # A missing/empty token is a credentials problem: record it as AUTH so the
    # caller reports the truth (Get-FigmaToken already printed the store hint).
    try {
        $token = Get-FigmaToken $Config
    } catch {
        Write-FigmaDiag 'AUTH' '' $Path
        throw
    }
    $url = "$base$Path"
    $maxAttempts = 5
    if ($env:FIGMA_API_MAX_ATTEMPTS) { $maxAttempts = [int]$env:FIGMA_API_MAX_ATTEMPTS }
    $delay = 2
    if ($env:FIGMA_API_RETRY_DELAY) { $delay = [double]$env:FIGMA_API_RETRY_DELAY }
    $attempt = 0
    $lastCode = '000'
    while ($attempt -lt $maxAttempts) {
        $result = Invoke-FigmaHttpGet $url $token
        $code = $result.Code
        $lastCode = $code
        switch -Regex ($code) {
            '^(200|201|204)$' {
                # 2xx success (201/204 carry an empty body).
                return $result.Body
            }
            '^(000|429|500|502|503|504)$' {
                Write-FigmaStderr "WARN: Figma API $code (attempt $($attempt + 1)/$maxAttempts); backing off ${delay}s..."
                Start-Sleep -Seconds $delay
                $delay = $delay * 2
                $attempt = $attempt + 1
            }
            default {
                $class = Get-FigmaStatusClass $code
                Write-FigmaDiag $class $code $Path
                Write-FigmaStderr "ERROR: $(Get-FigmaErrorMessage $class $Path $code)"
                if ($result.Body) { Write-FigmaStderr $result.Body }
                throw "Figma API error HTTP $code for $Path"
            }
        }
    }
    # Retries exhausted: classify by the LAST status so a network outage (000)
    # never gets mislabelled as an auth failure.
    $class = Get-FigmaStatusClass $lastCode
    Write-FigmaDiag $class $lastCode $Path
    Write-FigmaStderr "ERROR: $(Get-FigmaErrorMessage $class $Path $lastCode)"
    throw "Figma API error HTTP $lastCode for $Path (retries exhausted)"
}
