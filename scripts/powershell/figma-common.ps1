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

# Path of the rendered, ready-to-paste section for a phase (spec|plan|tasks).
function Get-FigmaSectionPath {
    param([string]$Phase)
    Join-Path (Get-FigmaCacheDir) "section.$Phase.md"
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
        try {
            $out = & $exe @cmdArgs 2>$null
            $out = ($out | Out-String).TrimEnd("`r", "`n")
            if ($out) { return $out }
        } catch { }
        Write-FigmaStderr 'WARN: FIGMA_PAT_COMMAND failed or returned an empty token.'
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
