#!/usr/bin/env bash
# =============================================================================
# figma-detect-target.sh — decide whether Figma integration applies to a target
# =============================================================================
# Usage: figma-detect-target.sh <target-name> [path/to/figma.projects.config.json]
# Prints a JSON object on stdout:
#   { "enabled": true|false, "reason": "...", "role": "...", "figmaFileId": "...",
#     "figmaProjectId": "...", "figmaTeamId": "...", "figmaTeamIds": [...],
#     "submodulePath": "...", "node": { ...full target... } }
# Exit code: 0 with JSON for every mapping outcome (enabled, excluded,
# not-mapped, disabled); non-zero only for structural errors (bad config/args).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

TARGET="${1:?Usage: figma-detect-target.sh <target-name> [config]}"
CONFIG="${2:-$(figma_default_config)}"
figma_check_config "$CONFIG" || exit 1

MODE="$(jq -r '.mode // empty' "$CONFIG")"
case "$MODE" in
  single-repo|mono-repo|multi-repo) ;;
  *) echo "ERROR: unknown or missing mode '$MODE' in $CONFIG" >&2; exit 1 ;;
esac

emit_disabled() {
  jq -n --arg t "$TARGET" --arg reason "$1" '{enabled:false, reason:$reason, target:$t, role:null, figmaFileId:null, figmaProjectId:null, figmaTeamId:null, figmaTeamIds:null, submodulePath:null, node:null}'
}

# Excluded list wins and is silent.
if jq -e --arg t "$TARGET" '(.excluded // []) | index($t) != null' "$CONFIG" >/dev/null; then
  emit_disabled "excluded"
  exit 0
fi

if [[ "$MODE" == "multi-repo" ]]; then
  NODE="$(jq -c --arg t "$TARGET" '.submodules[$t] // empty' "$CONFIG")"
elif [[ "$MODE" == "single-repo" ]]; then
  # single-repo: there is exactly one front-end target → always the repo.
  NODE="$(jq -c '.repo // empty' "$CONFIG")"
else
  # mono-repo: the target may be the repo itself or one of its apps/libs.
  NODE="$(jq -c --arg t "$TARGET" '
    if (.repo.monorepo.apps // []) + (.repo.monorepo.libs // []) | index($t) != null
    then .repo
    elif ($t == "repo" or $t == (.repo.submodulePath // ""))
    then .repo
    else empty end' "$CONFIG")"
fi

if [[ -z "$NODE" ]]; then
  emit_disabled "not-mapped"
  exit 0
fi

echo "$NODE" | jq --arg t "$TARGET" '{
  enabled: (.enabled == true),
  reason: (if .enabled == true then "mapped" else "disabled" end),
  target: $t,
  role: .role,
  figmaFileId: (.figmaFileId // null),
  figmaProjectId: (.figmaProjectId // null),
  figmaTeamId: (.figmaTeamId // null),
  figmaTeamIds: (.figmaTeamIds // null),
  submodulePath: (.submodulePath // null),
  node: .
}'
