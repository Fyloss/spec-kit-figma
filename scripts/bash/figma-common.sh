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
#   figma_cache_path           -> prints the current-run snapshot path
#   figma_snapshot_store_path <fileId> -> prints the per-file snapshot cache path
#   figma_section_path <phase> -> prints the rendered-section path for a phase
#   figma_feature_key          -> prints the current feature's identity (filename-safe)
#   figma_feature_links_path   -> prints where this feature's design links are remembered
#   figma_gc_cache             -> collects cache entries whose feature/file is gone
#   figma_resolve_phase_doc <phase> [identified-only] -> prints specs/<feature>/<phase>.md, or fails
#   figma_normalize_node_id <id> -> prints the canonical node id ('12:345'), or fails
# Dependencies: bash 4+, curl, jq
# =============================================================================
# NOTE: This file is meant to be sourced; do not set shell options here.
# Entrypoint scripts should enable `set -euo pipefail` as needed.

# Install guidance for the external tools the bash helpers depend on. A bare
# "jq is required" is a dead end on a locked-down machine (no sudo, Homebrew's
# Cellar not writable) — and a dead end is what pushes an agent to abandon the
# scripts and improvise, e.g. by calling a Figma MCP server with a node id it
# re-derived from the URL. Every hint therefore includes an admin-free path.
# shellcheck disable=SC2016  # the hints are literal shell snippets for the user
figma_install_hint() {
  case "${1:-}" in
    jq)
      printf '%s\n' \
        '  brew install jq             # macOS, when Homebrew is writable' \
        '  sudo apt-get install -y jq  # Debian/Ubuntu' \
        '' \
        '  Neither available (no sudo, Homebrew Cellar not writable)? The static' \
        '  binary needs no admin rights:' \
        '    mkdir -p ~/.local/bin' \
        '    curl -fsSL -o ~/.local/bin/jq https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64' \
        '    chmod +x ~/.local/bin/jq' \
        '    export PATH="$HOME/.local/bin:$PATH"   # add this to your shell profile' \
        '  (swap jq-macos-arm64 for jq-macos-amd64, jq-linux-amd64 or jq-linux-arm64)' \
        '' \
        '  Or skip the bash helpers entirely: the PowerShell 7+ ports under' \
        '  .specify/scripts/powershell/ use built-in JSON and need no jq.'
      ;;
    curl)
      printf '%s\n' \
        '  brew install curl            # macOS' \
        '  sudo apt-get install -y curl # Debian/Ubuntu' \
        '  Or run the PowerShell 7+ ports, which use built-in HTTP.'
      ;;
  esac
}

figma_require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "ERROR: '$1' is required but not installed." >&2
  figma_install_hint "$1" >&2
  exit 1
}

figma_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Per-workspace Figma directory. Committed content (the design-rules base
# figma-design-rules.md and the user overlay figma-design-rules.custom.md) lives at
# its root; every generated/cached artifact (snapshot + rendered
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

# Per-file snapshot store. figma_cache_path above is a single slot: the snapshot
# of the CURRENT run, and the well-known path every command prompt hands to the
# agent. One slot is enough to PUBLISH a snapshot but not to CACHE one — two
# features pointing at different Figma files evict each other, so the "fresh"
# path never hits and every phase re-pays a full file + nodes fetch. Keyed by
# file, snapshots survive that alternation; the current slot is a copy of
# whichever one this run resolved.
# Prints the store path, or returns 1 when the key cannot name a file.
figma_snapshot_store_path() {
  local key="${1:-}"
  [[ -n "$key" ]] || return 1
  # Figma file keys are [A-Za-z0-9_-], but the value reaches us from a URL or a
  # config field: squeeze anything else so it can never escape the directory.
  key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-100)"
  [[ "$key" =~ ^\.+$ ]] && return 1
  echo "$(figma_cache_dir)/snapshots/${key}.json"
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
figma_section_path() {
  echo "$(figma_cache_dir)/sections/$(figma_feature_key)/$1.md"
}

# Identity of the feature being worked on, used to scope the remembered design
# links. Precedence mirrors SpecKit's own resolution (core_pack/scripts/bash/
# common.sh): SPECIFY_FEATURE, then .specify/feature.json's feature_directory,
# then the git branch. Prints "default" when nothing identifies a feature.
#
# Scoping is the whole point: the links are remembered so /speckit.plan and
# /speckit.tasks inherit what /speckit.specify detected, and a single shared file
# would make the NEXT feature inherit them too — reinstating the very problem
# (a design section forced onto a feature that has no mockup) the link
# requirement exists to prevent.
figma_feature_key() {
  local key="${SPECIFY_FEATURE:-}"
  if [[ -z "$key" ]]; then
    local fj; fj="$(figma_repo_root)/.specify/feature.json"
    if [[ -f "$fj" ]] && command -v jq >/dev/null 2>&1; then
      key="$(jq -r '.feature_directory // empty' "$fj" 2>/dev/null || true)"
      key="${key%/}"; key="${key##*/}"
    fi
  fi
  [[ -n "$key" ]] || key="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$key" && "$key" != "HEAD" ]] || key="default"
  # Squeeze to a safe, bounded filename: the value reaches us from an env var, a
  # JSON field or a branch name, any of which may carry '/' or '..'. Mapping
  # every other byte to '-' makes traversal impossible; a key left as only dots
  # ('.', '..') would still name a directory entry we must not write, so it
  # falls back to "default".
  key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-100)"
  [[ "$key" =~ ^\.+$ ]] && key="default"
  printf '%s' "${key:-default}"
}

# Where the Figma links detected in the feature input are remembered, per
# feature, so later phases inherit them without the developer re-pasting.
figma_feature_links_path() {
  echo "$(figma_cache_dir)/links/$(figma_feature_key).json"
}

# True when a cache key still names something: the feature this very run is
# working on, or a SpecKit feature directory. specs/<key>/ is committed and
# outlives the branch that produced it, which is what makes it the durable
# ownership signal — a merged feature keeps its entry, an ad-hoc branch that
# never became a feature does not.
figma_gc_key_is_live() { # $1 = key, $2 = current key, $3 = repo root
  [[ "$1" == "$2" ]] && return 0
  [[ -d "$3/specs/$1" ]] && return 0
  return 1
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
#     gate fail-open (the very failure figma_section_path's scoping fixed). What
#     has no such directory is the garbage: ad-hoc branches, and the "default" key
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
figma_gc_cache() {
  local mode="${FIGMA_CACHE_GC:-auto}"
  [[ "$mode" == "off" ]] && return 0
  local cache; cache="$(figma_cache_dir)"
  [[ -d "$cache" ]] || return 0

  local days="${FIGMA_CACHE_RETENTION_DAYS:-7}"
  [[ "$days" =~ ^[1-9][0-9]*$ ]] || days=7
  local retain_min=$(( days * 1440 ))

  local stamp="${cache}/.gc-stamp"
  if [[ "$mode" != "force" && -f "$stamp" ]]; then
    # `find -mmin +1440` prints the stamp only once it is over a day old; no
    # output means the last sweep is recent enough and this run skips it.
    [[ -n "$(find "$stamp" -mmin +1440 2>/dev/null)" ]] || return 0
  fi
  # Stamped BEFORE the sweep: a sweep that dies halfway must not make every
  # subsequent run retry it.
  touch "$stamp" 2>/dev/null || true

  local root current entry key removed=0
  root="$(figma_repo_root)"
  current="$(figma_feature_key)"

  for entry in "${cache}"/links/*.json; do
    [[ -f "$entry" ]] || continue
    key="${entry##*/}"; key="${key%.json}"
    figma_gc_key_is_live "$key" "$current" "$root" && continue
    [[ -n "$(find "$entry" -mmin "+${retain_min}" 2>/dev/null)" ]] || continue
    rm -f "$entry" 2>/dev/null && removed=$(( removed + 1 ))
  done

  for entry in "${cache}"/sections/*/; do
    [[ -d "$entry" ]] || continue
    key="${entry%/}"; key="${key##*/}"
    figma_gc_key_is_live "$key" "$current" "$root" && continue
    # A directory's own mtime only moves when an entry is added or removed, so
    # the renders decide: any one of them touched inside the window keeps the
    # whole directory.
    [[ -z "$(find "$entry" -maxdepth 1 -name '*.md' -mmin "-${retain_min}" 2>/dev/null)" ]] || continue
    # The renders, then the directory once it is empty — never a recursive delete
    # of a path assembled from a key, and never a file this extension did not write.
    rm -f "${entry}"*.md 2>/dev/null || true
    rmdir "$entry" 2>/dev/null && removed=$(( removed + 1 ))
  done

  # Past the freshness window a stored snapshot is dead weight: snapshot_is_current
  # would reject it anyway. It is still kept for the whole retention window (the
  # window is a floor, not the policy), and never dropped below a caller's own —
  # possibly much longer — freshness window.
  local snap_min="$retain_min" max_age="${FIGMA_SNAPSHOT_MAX_AGE_MINUTES:-60}"
  [[ "$max_age" =~ ^[1-9][0-9]*$ ]] && (( max_age > snap_min )) && snap_min="$max_age"
  for entry in "${cache}"/snapshots/*.json; do
    [[ -f "$entry" ]] || continue
    [[ -n "$(find "$entry" -mmin "+${snap_min}" 2>/dev/null)" ]] || continue
    rm -f "$entry" 2>/dev/null && removed=$(( removed + 1 ))
  done

  if (( removed > 0 )); then
    local noun="entries"
    if (( removed == 1 )); then noun="entry"; fi
    echo "INFO: cache housekeeping reclaimed ${removed} stale ${noun} under .figma/cache/ (features with no specs/ directory, unused snapshots). Set FIGMA_CACHE_RETENTION_DAYS to change the ${days}-day window, FIGMA_CACHE_GC=off to disable." >&2
  fi
  return 0
}

# Locate the SpecKit document of a phase (spec|plan|tasks) in the standard
# layout. Precedence: specs/<feature-key>/<phase>.md (honours SPECIFY_FEATURE and
# .specify/feature.json, not just the branch), then specs/<branch>/<phase>.md,
# then the single specs/*/<phase>.md when there is exactly one.
#
# With SEVERAL candidates and no feature identity the target is genuinely
# ambiguous, so this returns 1 rather than picking the most recent: callers
# verify (and gate CI on) or read design links from the document, and both are
# wrong on the wrong feature's file. Prints the path on success.
#
# Usage: figma_resolve_phase_doc <phase> [identified-only]
# "identified-only" drops BOTH guesses — the branch and the last-resort single
# candidate — so ONLY a document the current feature positively owns is
# returned. A caller that READS design context out of the document needs that:
# "the branch's spec" and "the only spec around" both belong to some OTHER
# feature whenever they differ from the feature key, and inheriting their
# creative re-creates the regression the link requirement exists to prevent. A
# caller that merely verifies a document generated by this very run can afford
# the looser rule (its failure mode is a warning, not a silent injection).
figma_resolve_phase_doc() {
  local phase="$1" mode="${2:-}" root doc branch
  root="$(figma_repo_root)"
  doc="${root}/specs/$(figma_feature_key)/${phase}.md"
  [[ -f "$doc" ]] && { printf '%s' "$doc"; return 0; }
  # Everything below is a guess, so it is gated. The branch is already the LAST
  # resort inside figma_feature_key: it can only disagree with the key resolved
  # above when SPECIFY_FEATURE or .specify/feature.json named another feature —
  # which makes specs/<branch>/ that other feature's directory, not ours.
  [[ "$mode" == "identified-only" ]] && return 1
  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -n "$branch" && -f "${root}/specs/${branch}/${phase}.md" ]]; then
    printf '%s' "${root}/specs/${branch}/${phase}.md"; return 0
  fi
  local matches=() f
  # SpecKit feature dirs are `NNN-slug` (alphanumeric); the glob is safe here.
  for f in "${root}"/specs/*/"${phase}.md"; do
    [[ -f "$f" ]] && matches+=("$f")
  done
  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s' "${matches[0]}"; return 0
  elif [[ ${#matches[@]} -gt 1 ]]; then
    echo "WARN: ${#matches[@]} candidate specs/*/${phase}.md documents and no feature identity resolves one of them; name the document explicitly." >&2
  fi
  return 1
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

# Canonical form of a Figma node id, as expected by the REST API and by every
# Figma MCP server: '12:345', or 'I12:345;678:901' for a nested instance.
# Deep links carry the same id in URL form — '12-345', '%3A'-encoded, and
# '%3B'-chained — so a half-normalized value ('12-345' forwarded as-is, or only
# the first separator converted) reaches the server as an unknown node and comes
# back as "the provided node ID was not found in the file". Normalizing at a
# single chokepoint keeps that failure impossible whatever the agent pasted.
# Prints the canonical id on success; prints nothing and returns 1 when the value
# is not a node id (callers then treat the link as broad rather than guessing).
figma_normalize_node_id() {
  local raw="${1:-}" id
  local pattern='^I?[0-9]+:[0-9A-Za-z]+(;[0-9]+:[0-9A-Za-z]+)*$'
  [[ -n "$raw" ]] || return 1
  id="$(printf '%s' "$raw" | sed -E 's/%3A/:/Ig; s/%3B/;/Ig; s/-/:/g')"
  [[ "$id" =~ $pattern ]] || return 1
  printf '%s' "$id"
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
