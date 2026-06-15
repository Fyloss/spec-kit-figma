#!/usr/bin/env bash
# =============================================================================
# figma-validate-config.sh — validate figma.projects.config.json
# =============================================================================
# Usage: figma-validate-config.sh [path/to/figma.projects.config.json]
# Exit codes: 0 = valid, 1 = structural error, 2 = unresolved placeholder
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

CONFIG="${1:-$(figma_default_config)}"
figma_check_config "$CONFIG" || exit 1

MODE="$(jq -r '.mode // empty' "$CONFIG")"
case "$MODE" in
  multi-repo)
    jq -e '.submodules and (.submodules | type == "object")' "$CONFIG" >/dev/null \
      || { echo "ERROR: mode 'multi-repo' requires a 'submodules' object" >&2; exit 1; } ;;
  mono-repo|single-repo)
    jq -e '.repo and (.repo | type == "object")' "$CONFIG" >/dev/null \
      || { echo "ERROR: mode '${MODE}' requires a 'repo' object" >&2; exit 1; } ;;
  *)
    echo "ERROR: .mode must be 'single-repo', 'mono-repo' or 'multi-repo'" >&2; exit 1 ;;
esac

# Per-target structural rules, mirroring the JSON schema's definitions/target:
# 'enabled' (boolean) and 'role' (enum) are required, and every target must
# declare at least one of figmaFileId / figmaProjectId / figmaTeamId / figmaTeamIds.
# The schema (config/figma.projects.config.schema.json) stays the source of
# truth; CI validates the examples against it, this script is the portable
# curl/jq subset for runtime checks.
TARGET_ERRORS="$(jq -r --arg mode "$MODE" '
  ["design-system", "app-host", "app", "lib"] as $roles
  | (if $mode == "multi-repo"
   then (.submodules // {} | to_entries | map({name: .key, t: .value}))
   else [{name: "repo", t: (.repo // {})}]
   end)
  | .[]
  | . as $e
  | ( (select(($e.t.enabled | type) != "boolean")
       | "\($e.name): missing required boolean field \"enabled\""),
      (select(($e.t.role | type) != "string" or ($roles | index($e.t.role) == null))
       | "\($e.name): \"role\" must be one of \($roles | join("/"))"),
      (select(($e.t | has("figmaFileId") or has("figmaProjectId") or has("figmaTeamId") or has("figmaTeamIds")) | not)
       | "\($e.name): at least one of figmaFileId/figmaProjectId/figmaTeamId/figmaTeamIds is required") )
' "$CONFIG")"
if [[ -n "$TARGET_ERRORS" ]]; then
  echo "ERROR: invalid target declaration(s):" >&2
  while IFS= read -r line; do
    echo "  - ${line}" >&2
  done <<< "$TARGET_ERRORS"
  exit 1
fi

# Reject any unresolved REPLACE_WITH_* placeholder in any figma id
# (figmaFileId / figmaProjectId / figmaTeamId / each figmaTeamIds entry).
PLACEHOLDERS="$(jq -r '
  [ .. | objects | (.figmaFileId?, .figmaProjectId?, .figmaTeamId?, (.figmaTeamIds? // [] | .[])) ]
  | map(select(type == "string" and startswith("REPLACE_WITH_")))
  | .[]' "$CONFIG" || true)"
if [[ -n "$PLACEHOLDERS" ]]; then
  echo "ERROR: unresolved Figma id placeholder(s) found — replace them with real ids before running SpecKit:" >&2
  while IFS= read -r placeholder; do
    echo "  - ${placeholder}" >&2
  done <<< "$PLACEHOLDERS"
  exit 2
fi

# Credentials must come from env or ci-secret, never inline.
SRC="$(jq -r '.figma.credentials.source // empty' "$CONFIG")"
[[ "$SRC" == "env" || "$SRC" == "ci-secret" ]] \
  || { echo "ERROR: figma.credentials.source must be 'env' or 'ci-secret'" >&2; exit 1; }
# The scan is scoped to .figma.credentials: elsewhere, 'token'/'pat' are
# legitimate user-chosen keys (e.g. a Figma page named 'token' in
# pageToPackageMapping or a submodule named 'pat').
if jq -e '.figma.credentials | objects | has("token") or has("pat") or has("accessToken")' "$CONFIG" >/dev/null 2>&1; then
  echo "ERROR: a secret-looking field was found in the config. Tokens MUST live in the OS keychain (FIGMA_PAT_COMMAND), an environment variable, or a CI secret, never in this file." >&2
  exit 1
fi

# Design-context engine: 'rest' (default, portable) or 'mcp' (optional, REST fallback).
CTX="$(figma_context_source "$CONFIG")"
[[ "$CTX" == "rest" || "$CTX" == "mcp" ]] \
  || { echo "ERROR: figma.contextSource must be 'rest' or 'mcp'" >&2; exit 1; }

echo "OK: ${CONFIG} is valid (mode=${MODE}, credentials.source=${SRC}, contextSource=${CTX})."
