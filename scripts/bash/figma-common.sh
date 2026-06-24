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
#   figma_cache_path           -> prints the snapshot cache path
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

figma_cache_path() {
  echo "$(figma_repo_root)/.figma-context-snapshot.json"
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
  echo "ERROR: ${var} not found. Set it in your environment (CI secret) or store the PAT in your OS keychain and export FIGMA_PAT_COMMAND locally (see docs/CREDENTIALS.md)." >&2
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

# GET helper with retry. Usage: figma_api "/files/<key>?depth=1" [config-path]
# Retries 429/5xx AND transport failures (code 000) with exponential backoff.
# FIGMA_API_MAX_ATTEMPTS / FIGMA_API_RETRY_DELAY override the retry policy (tests).
figma_api() {
  figma_require curl
  local path="$1"
  local config="${2:-$(figma_default_config)}"
  # Validate the base URL BEFORE touching the token: a rejected apiBaseUrl
  # must never get anywhere near the credential.
  local base; base="$(figma_api_base "$config")" || return 1
  local token; token="$(figma_load_token "$config")" || return 1
  local url="${base}${path}"
  local attempt=0 max_attempts="${FIGMA_API_MAX_ATTEMPTS:-5}" delay="${FIGMA_API_RETRY_DELAY:-2}"
  while (( attempt < max_attempts )); do
    local tmp; tmp="$(mktemp)"
    local code
    # On a transport failure curl itself emits '000' via -w before exiting
    # non-zero; the fallback assignment must REPLACE the captured output, not
    # append to it (appending used to garble the code into '000000').
    code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "X-Figma-Token: ${token}" \
      -H "Accept: application/json" \
      "$url" 2>/dev/null)" || code="000"
    case "$code" in
      200)
        cat "$tmp"; rm -f "$tmp"; return 0 ;;
      000|429|500|502|503|504)
        rm -f "$tmp"
        echo "WARN: Figma API ${code} (attempt $((attempt+1))/${max_attempts}); backing off ${delay}s..." >&2
        sleep "$delay"; delay=$(( delay * 2 )); attempt=$(( attempt + 1 )) ;;
      403|404)
        echo "ERROR: Figma API ${code} for ${path}" >&2
        figma_scope_hint "$path" >&2
        cat "$tmp" >&2; rm -f "$tmp"; return 1 ;;
      *)
        echo "ERROR: Figma API ${code} for ${path}" >&2
        cat "$tmp" >&2; rm -f "$tmp"; return 1 ;;
    esac
  done
  echo "ERROR: Figma API retries exhausted for ${path}" >&2
  return 1
}
