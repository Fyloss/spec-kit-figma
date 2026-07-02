#!/usr/bin/env bash
# =============================================================================
# figma-common.sh — shared helpers for the SpecKit Figma extension
# =============================================================================
# Source this file from the other scripts:  source "$(dirname "$0")/figma-common.sh"
#
# Provides:
#   figma_repo_root            -> prints the workspace root
#   figma_load_token           -> prints the Figma PAT (env > keychain), never echoes it elsewhere
#   figma_api <PATH>           -> GET against the Figma API with 429/5xx exponential backoff
#   figma_state_dir            -> prints the per-workspace Figma state directory (.figma/)
#   figma_cache_dir            -> prints the generated/cached-artifacts directory (.figma/cache/)
#   figma_cache_path           -> prints the snapshot cache path
#   figma_section_path <phase> -> prints the rendered-section path for a phase
# Dependencies: bash 4+, curl, jq
# =============================================================================
# NOTE: This file is meant to be sourced; do not set shell options here.
# Entrypoint scripts should enable `set -euo pipefail` as needed.

figma_require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not installed." >&2; exit 1; }
}

figma_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Per-workspace Figma directory. Committed content (e.g. figma-design-rules.md)
# lives at its root; every generated/cached artifact (snapshot + rendered
# sections) lives under cache/ so a single `.figma/cache/` entry in .gitignore
# covers them all.
figma_state_dir() {
  echo "$(figma_repo_root)/.figma"
}

figma_cache_dir() {
  echo "$(figma_state_dir)/cache"
}

figma_cache_path() {
  echo "$(figma_cache_dir)/context-snapshot.json"
}

# Path of the rendered, ready-to-paste section for a phase (spec|plan|tasks).
figma_section_path() {
  echo "$(figma_cache_dir)/section.$1.md"
}

# Default config path. Precedence: FIGMA_CONFIG env override > <root>/figma.projects.config.json.
figma_default_config() {
  printf '%s' "${FIGMA_CONFIG:-$(figma_repo_root)/figma.projects.config.json}"
}

# Shared precondition: the config file exists and parses as JSON.
# Usage: figma_check_config <path>  (returns 1 with an ERROR on stderr otherwise)
figma_check_config() {
  local config="$1"
  [[ -f "$config" ]] || { echo "ERROR: config not found: $config" >&2; return 1; }
  jq empty "$config" 2>/dev/null || { echo "ERROR: $config is not valid JSON" >&2; return 1; }
}

# Generic config accessor: figma_config_get '<jq-expr>' '<default>' [config-path].
# Falls back to the default when the config is absent, jq is missing, or the
# expression yields null/empty.
figma_config_get() {
  local expr="$1" default="$2" config="${3:-$(figma_default_config)}"
  local v=""
  if [[ -f "$config" ]] && command -v jq >/dev/null 2>&1; then
    v="$(jq -r "( ${expr} ) // empty" "$config" 2>/dev/null || true)"
  fi
  printf '%s' "${v:-$default}"
}

# Base URL of the Figma REST API.
# Precedence: FIGMA_API_BASE env override > config .figma.apiBaseUrl > built-in default.
# The config is a committed, shared artifact: an apiBaseUrl pointing anywhere
# else would exfiltrate the PAT (sent as X-Figma-Token) to that host on the
# next introspection run, so config-sourced values are restricted to
# https://figma.com hosts. FIGMA_API_BASE (local, trusted env) is the escape
# hatch for enterprise proxies and test mocks.
# shellcheck disable=SC2120  # optional $1 (config path) is intentional for testability
figma_api_base() {
  if [[ -n "${FIGMA_API_BASE:-}" ]]; then
    printf '%s' "$FIGMA_API_BASE"
    return 0
  fi
  local base
  base="$(figma_config_get '.figma.apiBaseUrl' 'https://api.figma.com/v1' "${1:-}")"
  # Host = authority up to the first path/port/query/fragment delimiter;
  # userinfo (@) is rejected outright since no legitimate Figma URL uses it.
  local host="${base#https://}"
  host="${host%%[/:?#]*}"
  if [[ "$base" != https://* || "$host" == *@* \
        || ( "$host" != "figma.com" && "$host" != *.figma.com ) ]]; then
    echo "ERROR: refusing apiBaseUrl '${base}' from the config: it must be an https://*.figma.com URL. Use the FIGMA_API_BASE env var for a local override." >&2
    return 1
  fi
  printf '%s' "$base"
}

# Resolve the env var name declared in figma.projects.config.json (defaults to FIGMA_PAT).
# In ci-secret mode, envVar names the variable the CI injects the secret into;
# secretName (the secret-store key) is only a fallback when envVar is unset.
figma_env_var_name() {
  figma_config_get '
    if .figma.credentials.source == "ci-secret" then
      (.figma.credentials.envVar // .figma.credentials.secretName)
    else
      .figma.credentials.envVar
    end' 'FIGMA_PAT' "${1:-}"
}

# -----------------------------------------------------------------------------
# Design-context engine selection (REST default, optional MCP with REST fallback)
# -----------------------------------------------------------------------------

# Requested engine declared in the config: "rest" (default) or "mcp".
figma_context_source() {
  figma_config_get '.figma.contextSource' 'rest' "${1:-}"
}

# MCP server endpoint (defaults to the local Figma Dev Mode MCP server).
figma_mcp_url() {
  figma_config_get '.figma.mcp.url' 'http://127.0.0.1:3845/mcp' "${1:-}"
}

# Whether an unreachable MCP server should silently fall back to REST (default: yes).
# The jq expression maps the tristate (absent/true/false) to a string so the
# `//`-treats-false-as-empty pitfall cannot reintroduce a wrong default.
figma_mcp_fallback_enabled() {
  local v
  v="$(figma_config_get 'if .figma.mcp.fallbackToRest == false then "false" else "true" end' 'true' "${1:-}")"
  [[ "$v" == "true" ]]
}

# Probe the MCP server. Returns 0 when reachable. Any HTTP response (even 4xx)
# means the server is up; a transport failure (curl error or code 000) is absent.
figma_mcp_available() {
  command -v curl >/dev/null 2>&1 || return 1
  local url; url="$(figma_mcp_url "${1:-}")"
  local code
  if code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "${FIGMA_MCP_PROBE_TIMEOUT:-3}" "$url" 2>/dev/null)"; then
    [[ -n "$code" && "$code" != "000" ]]
  else
    return 1
  fi
}

# Single decision table for the MCP -> REST fallback policy, shared by
# figma_resolve_context_source and figma-resolve-source.sh (which probes once
# itself to avoid a second timeout / flapping disagreement).
# Usage: figma_decide_context_source <requested> <reachable:true|false> <fallback:true|false> <mcp-url>
# Prints the effective engine ("rest"/"mcp"); diagnostics go to stderr.
# Exit code: 0 on success, 1 when MCP is required (fallback disabled) but absent.
figma_decide_context_source() {
  local requested="$1" reachable="$2" fallback="$3" mcp_url="${4:-}"
  case "$requested" in
    rest)
      echo "rest" ;;
    mcp)
      if [[ "$reachable" == "true" ]]; then
        echo "mcp"
      elif [[ "$fallback" == "true" ]]; then
        echo "WARN: MCP server unreachable at ${mcp_url}; falling back to the portable REST engine." >&2
        echo "rest"
      else
        echo "ERROR: contextSource='mcp' but the MCP server is unreachable and mcp.fallbackToRest=false." >&2
        return 1
      fi ;;
    *)
      echo "WARN: unknown contextSource '${requested}'; defaulting to the REST engine." >&2
      echo "rest" ;;
  esac
}

# Resolve the EFFECTIVE engine, applying the MCP -> REST fallback policy.
# Prints "rest" or "mcp" on stdout; diagnostics go to stderr.
# Exit code: 0 on success, 1 when MCP is required (fallback disabled) but absent.
figma_resolve_context_source() {
  local config="${1:-$(figma_default_config)}"
  local requested; requested="$(figma_context_source "$config")"
  local reachable="false"
  if [[ "$requested" == "mcp" ]] && figma_mcp_available "$config"; then
    reachable="true"
  fi
  local fallback="false"
  figma_mcp_fallback_enabled "$config" && fallback="true"
  figma_decide_context_source "$requested" "$reachable" "$fallback" "$(figma_mcp_url "$config")"
}

# -----------------------------------------------------------------------------
# Claude Code / official Figma plugin advisory
# -----------------------------------------------------------------------------
# Inside Claude Code, the most reliable way to obtain rich MCP design context is
# the official Figma plugin (`claude plugin install figma@claude-plugins-official`):
# it wires Figma's *hosted* MCP server (https://mcp.figma.com/mcp) in as a native
# Claude Code tool, so the agent reads structured node data directly — no local
# Dev Mode server, no curl probe. These helpers detect that situation and nudge
# the user toward the plugin; they are advisory only and never change behaviour.

# True when running inside Claude Code. The CLI exports CLAUDECODE=1 for every
# command it spawns (AI_AGENT=claude-code... is a secondary signal).
figma_is_claude_code() {
  [[ "${CLAUDECODE:-}" == "1" ]] && return 0
  [[ "${AI_AGENT:-}" == claude-code* ]]
}

# Path to Claude Code's installed-plugins registry. Honours CLAUDE_CONFIG_DIR
# (which relocates ~/.claude), so the probe follows a customised config home.
figma_claude_plugins_file() {
  echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
}

# True when ANY Figma plugin is installed in Claude Code (the official one or a
# fork from another marketplace), matched on the `figma@<marketplace>` key the
# CLI writes to installed_plugins.json. Returns non-zero — i.e. "not installed",
# so the advice fires — when jq is missing or the registry is absent/unreadable.
figma_claude_figma_plugin_installed() {
  local file; file="$(figma_claude_plugins_file)"
  [[ -f "$file" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e 'any((.plugins // {}) | keys[]; startswith("figma@"))' "$file" >/dev/null 2>&1
}

# Print a recommendation to stderr when running in Claude Code WITHOUT a Figma
# plugin. No-op for other agents, when a plugin is already present, or when
# FIGMA_NO_PLUGIN_ADVICE=1 silences it. Always returns 0 so callers can chain it
# without `set -e` aborting on the "no advice needed" path.
figma_claude_plugin_advice() {
  [[ "${FIGMA_NO_PLUGIN_ADVICE:-}" == "1" ]] && return 0
  figma_is_claude_code || return 0
  figma_claude_figma_plugin_installed && return 0
  cat >&2 <<'EOF'
TIP: Claude Code detected without the official Figma plugin. For the richest,
     most faithful design context, install it:
         claude plugin install figma@claude-plugins-official
     It connects Claude Code to Figma's hosted MCP server
     (https://mcp.figma.com/mcp) as a native tool — no local Dev Mode server
     required — then set "figma.contextSource": "mcp" in
     figma.projects.config.json. (Silence with FIGMA_NO_PLUGIN_ADVICE=1.)
EOF
  return 0
}

# Load the token: environment variable first, then FIGMA_PAT_COMMAND (a secret
# manager such as the macOS keychain). There is deliberately NO plaintext .env
# fallback — locally the token MUST be stored in the OS keychain and fetched via
# FIGMA_PAT_COMMAND, never written to a file in the workspace.
#
# FIGMA_PAT_COMMAND is a trusted LOCAL env var (same trust model as
# FIGMA_API_BASE — never read from the committed config, which could smuggle a
# command in via a PR): it keeps the token in the OS keychain instead of any
# file on disk, e.g. in ~/.zshrc:
#   export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"
# It is executed WITHOUT a shell (tokenized exec), so pipes/substitutions in
# the value are inert arguments, not shell syntax.
# shellcheck disable=SC2120  # optional $1 (config path) is intentional for testability
figma_load_token() {
  local config="${1:-$(figma_default_config)}"
  local var; var="$(figma_env_var_name "$config")"
  if [[ -n "${!var:-}" ]]; then
    printf '%s' "${!var}"
    return 0
  fi
  if [[ -n "${FIGMA_PAT_COMMAND:-}" ]]; then
    local -a pat_cmd
    read -r -a pat_cmd <<< "$FIGMA_PAT_COMMAND"
    local pat_out
    if pat_out="$("${pat_cmd[@]}" 2>/dev/null)" && [[ -n "$pat_out" ]]; then
      printf '%s' "$pat_out"
      return 0
    fi
    echo "WARN: FIGMA_PAT_COMMAND failed or returned an empty token." >&2
  fi
  echo "ERROR: ${var} not found. Store the PAT in your OS keychain and export FIGMA_PAT_COMMAND locally (e.g. 'security find-generic-password -s figma-pat -w'), or inject ${var} as a CI secret. Do NOT 'export ${var}=...' by hand and do NOT create a .env file — the token must never be written to disk in the workspace (see docs/CREDENTIALS.md)." >&2
  return 1
}

# Map a 403/404 API path to the most likely cause, so org-level setups fail with
# an actionable hint. Team/project enumeration needs the `projects:read` scope AND
# team membership; a file read needs `file_content:read`. Prints to stdout (the
# caller redirects to stderr); always exits 0.
figma_scope_hint() {
  local path="$1"
  case "$path" in
    /teams/*|/projects/*)
      echo "HINT: listing team projects or project files requires a PAT with the 'projects:read' scope, and the token owner must be a member of that team. See docs/CREDENTIALS.md." ;;
    /files/*)
      echo "HINT: reading a file requires a PAT with the 'file_content:read' scope (and 'file_metadata:read' for metadata), and access to the file. See docs/CREDENTIALS.md." ;;
  esac
}

# Classify a Figma HTTP status into a stable machine code the caller can switch
# on and surface verbatim. Transport failures reach here as code 000. Pure
# function: no network, no globals. Prints exactly one of:
#   OK | NETWORK | AUTH | NOT_FOUND | RATE_LIMIT | SERVER | UNKNOWN
figma_classify_status() {
  case "$1" in
    200|201|204)     echo "OK" ;;
    000)             echo "NETWORK" ;;
    401|403)         echo "AUTH" ;;
    404)             echo "NOT_FOUND" ;;
    429)             echo "RATE_LIMIT" ;;
    500|502|503|504) echo "SERVER" ;;
    *)               echo "UNKNOWN" ;;
  esac
}

# Build the cause-specific diagnostic for a failed Figma call. The text IS the
# instruction a weak LLM will copy verbatim, so each cause names its real remedy
# and the NETWORK case explicitly forbids the "authentication" misdiagnosis.
# Usage: figma_error_message <class> <path> <httpStatus>
figma_error_message() {
  local class="$1" path="$2" code="$3"
  case "$class" in
    NETWORK)
      printf 'NETWORK/PROXY error: cannot reach api.figma.com (HTTP %s). A broken or unreachable proxy is the usual cause — the script already auto-retried directly without the proxy. This is a connectivity problem, NOT a credentials problem. HTTP 000 / curl exit 5 = proxy. If it persists, check network/proxy connectivity to api.figma.com.' "$code" ;;
    AUTH)
      printf 'AUTH/SCOPE error: Figma returned HTTP %s for %s. The PAT is missing, invalid, or lacks the required read-only scopes (team/project enumeration also needs projects:read). Store the PAT in the OS keychain and export FIGMA_PAT_COMMAND; do NOT export the token by hand and do NOT create a .env (see docs/CREDENTIALS.md). %s' "$code" "$path" "$(figma_scope_hint "$path")" ;;
    NOT_FOUND)
      printf 'NOT FOUND: Figma returned 404 for %s. Either the file/project/team key is wrong, or the PAT owner is not a member of that team/project. Verify the id and team membership (see docs/CREDENTIALS.md).' "$path" ;;
    RATE_LIMIT)
      printf 'RATE LIMIT: Figma returned HTTP %s for %s after retries; wait and retry later.' "$code" "$path" ;;
    SERVER)
      printf 'SERVER error: Figma returned HTTP %s for %s after retries; this is a Figma-side outage, retry later.' "$code" "$path" ;;
    *)
      printf 'Figma API error HTTP %s for %s.' "$code" "$path" ;;
  esac
}

# Record a machine-readable failure cause for the calling process to read back
# (set FIGMA_DIAG_FILE to a writable path). No-op when unset. Never contains the
# token — only the class, the HTTP status and the request path.
figma_record_diag() {
  [[ -n "${FIGMA_DIAG_FILE:-}" ]] || return 0
  jq -n --arg code "$1" --arg httpStatus "$2" --arg path "$3" \
    '{code: $code, httpStatus: $httpStatus, path: $path}' > "$FIGMA_DIAG_FILE" 2>/dev/null || true
}

# Single Figma GET. Writes the body to $1 and prints the HTTP status to stdout
# (transport failures print 000). The Figma REST API is a PUBLIC
# endpoint, so on a proxy-connection failure — curl exit 5 ("couldn't resolve
# proxy"), exit 6 ("couldn't resolve host") with a proxy configured, or a 000
# transport failure with a proxy configured — it retries ONCE with every proxy
# variable stripped. This self-heals BOTH a broken corporate proxy (direct works)
# and is harmless where the proxy is the only egress (the first attempt succeeds
# so the strip never runs). The token stays an X-Figma-Token header on both tries.
figma_curl_get() {
  local out="$1" url="$2" token="$3"
  local code rc proxy_set=""
  [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-}" ]] && proxy_set="yes"
  # `|| rc=$?` keeps the captured code intact under set -e and records curl's exit.
  code="$(curl -sS -o "$out" -w '%{http_code}' \
    -H "X-Figma-Token: ${token}" \
    -H "Accept: application/json" \
    "$url" 2>/dev/null)" && rc=0 || rc=$?
  [[ -n "$code" ]] || code="000"
  if [[ "$rc" -eq 5 || ( -n "$proxy_set" && ( "$rc" -eq 6 || "$code" == "000" ) ) ]]; then
    echo "WARN: cannot reach Figma via the configured proxy (curl exit ${rc}); retrying directly without the proxy..." >&2
    code="$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy "no_proxy=*" "NO_PROXY=*" \
      curl -sS -o "$out" -w '%{http_code}' \
      -H "X-Figma-Token: ${token}" \
      -H "Accept: application/json" \
      "$url" 2>/dev/null)" && rc=0 || rc=$?
    [[ -n "$code" ]] || code="000"
  fi
  printf '%s' "$code"
}

# GET helper with retry. Usage: figma_api "/files/<key>?depth=1" [config-path]
# Retries 429/5xx AND transport failures (code 000) with exponential backoff;
# each attempt self-heals a broken/mandatory proxy via figma_curl_get. On a
# terminal failure it records a cause-specific diagnostic (NETWORK/AUTH/...) so
# the caller reports the truth instead of guessing "authentication required".
# FIGMA_API_MAX_ATTEMPTS / FIGMA_API_RETRY_DELAY override the retry policy (tests).
figma_api() {
  figma_require curl
  local path="$1"
  local config="${2:-$(figma_default_config)}"
  # Validate the base URL BEFORE touching the token: a rejected apiBaseUrl
  # must never get anywhere near the credential.
  local base; base="$(figma_api_base "$config")" || return 1
  # A missing/empty token is a credentials problem: record it as AUTH so the
  # caller reports the truth (figma_load_token already printed the keychain hint).
  local token; token="$(figma_load_token "$config")" || { figma_record_diag AUTH "" "$path"; return 1; }
  local url="${base}${path}"
  local attempt=0 max_attempts="${FIGMA_API_MAX_ATTEMPTS:-5}" delay="${FIGMA_API_RETRY_DELAY:-2}"
  local last_code="000"
  while (( attempt < max_attempts )); do
    local tmp; tmp="$(mktemp)"
    local code; code="$(figma_curl_get "$tmp" "$url" "$token")"
    last_code="$code"
    case "$code" in
      200|201|204)
        # 2xx success (201/204 carry an empty body); stay consistent with
        # figma_classify_status, which already classes these as OK.
        cat "$tmp"; rm -f "$tmp"; return 0 ;;
      000|429|500|502|503|504)
        rm -f "$tmp"
        echo "WARN: Figma API ${code} (attempt $((attempt+1))/${max_attempts}); backing off ${delay}s..." >&2
        sleep "$delay"; delay=$(( delay * 2 )); attempt=$(( attempt + 1 )) ;;
      401|403|404|*)
        local class; class="$(figma_classify_status "$code")"
        figma_record_diag "$class" "$code" "$path"
        echo "ERROR: $(figma_error_message "$class" "$path" "$code")" >&2
        cat "$tmp" >&2; rm -f "$tmp"; return 1 ;;
    esac
  done
  # Retries exhausted: classify by the LAST status so a network outage (000)
  # never gets mislabelled as an auth failure.
  local class; class="$(figma_classify_status "$last_code")"
  figma_record_diag "$class" "$last_code" "$path"
  echo "ERROR: $(figma_error_message "$class" "$path" "$last_code")" >&2
  return 1
}
