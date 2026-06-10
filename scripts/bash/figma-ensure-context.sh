#!/usr/bin/env bash
# =============================================================================
# figma-ensure-context.sh — guarantee a fresh Figma snapshot (automatic hook)
# =============================================================================
# Invoked automatically at the start of /speckit.specify and /speckit.tasks
# (via the managed block install.sh appends to those command prompts), so the
# developer never has to run /speckit.figma.introspect by hand. It decides
# whether Figma applies to the run and re-introspects only when the snapshot
# is missing or stale.
#
# Designed as a SAFE NO-OP: every configuration problem (missing config,
# unresolved placeholders, excluded target, failed introspection, ...) is
# reported as a skip reason with exit 0 so spec/tasks generation is never
# blocked — the agent surfaces the reason instead. Non-zero exits are reserved
# for unexpected internal errors and bad CLI arguments.
#
# Usage:
#   figma-ensure-context.sh [<target-name>] [--config <path>]
#     [--max-age-minutes N] [--dry-run]
# <target-name> defaults to "repo" (single-/mono-repo); for multi-repo it is
# auto-resolved only when exactly one enabled target exists.
# FIGMA_SNAPSHOT_MAX_AGE_MINUTES overrides the default freshness window (60).
#
# Prints a JSON status object on stdout:
#   { "ran": true|false, "reason": "...", "target": "...",
#     "snapshot": "...", "introspectArgs": [...] }
# Reasons: introspected | fresh | dry-run | no-config | invalid-config |
#   unresolved-placeholders | ambiguous-target | target-excluded |
#   target-not-mapped | target-disabled | introspect-failed
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

TARGET=""
MAX_AGE_MIN="${FIGMA_SNAPSHOT_MAX_AGE_MINUTES:-60}"
DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) FIGMA_CONFIG="$2"; export FIGMA_CONFIG; shift 2 ;;
    --max-age-minutes) MAX_AGE_MIN="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --*) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
    *)
      [[ -z "$TARGET" ]] || { echo "ERROR: unexpected extra argument '$1'" >&2; exit 1; }
      TARGET="$1"; shift ;;
  esac
done
if [[ ! "$MAX_AGE_MIN" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --max-age-minutes must be a positive integer (got '${MAX_AGE_MIN}')" >&2
  exit 1
fi

CONFIG="$(figma_default_config)"
SNAPSHOT="$(figma_cache_path)"
INTROSPECT_ARGS=()

emit() { # $1 = ran (true|false), $2 = reason
  jq -n --argjson ran "$1" --arg reason "$2" --arg target "${TARGET:-}" --arg snapshot "$SNAPSHOT" \
    '{ran: $ran, reason: $reason,
      target: (if $target == "" then null else $target end),
      snapshot: $snapshot,
      introspectArgs: $ARGS.positional}' \
    --args -- ${INTROSPECT_ARGS[@]+"${INTROSPECT_ARGS[@]}"}
}

if [[ ! -f "$CONFIG" ]]; then
  echo "INFO: no ${CONFIG##*/} found; proceeding without Figma context." >&2
  emit false "no-config"
  exit 0
fi

# Reuse the canonical validator instead of re-encoding its rules (exit 2 =
# unresolved placeholders, 1 = structural error).
set +e
VALIDATE_OUT="$("${SCRIPT_DIR}/figma-validate-config.sh" "$CONFIG" 2>&1)"
VALIDATE_RC=$?
set -e
if [[ "$VALIDATE_RC" -eq 2 ]]; then
  echo "WARN: ${VALIDATE_OUT}" >&2
  emit false "unresolved-placeholders"
  exit 0
elif [[ "$VALIDATE_RC" -ne 0 ]]; then
  echo "WARN: ${VALIDATE_OUT}" >&2
  emit false "invalid-config"
  exit 0
fi

if [[ -z "$TARGET" ]]; then
  MODE="$(jq -r '.mode // empty' "$CONFIG")"
  if [[ "$MODE" == "multi-repo" ]]; then
    # Only auto-resolve when the choice is unambiguous.
    ENABLED_LIST="$(jq -r '[.submodules // {} | to_entries[] | select(.value.enabled == true) | .key] | join(" ")' "$CONFIG")"
    read -r -a ENABLED <<< "$ENABLED_LIST"
    if [[ ${#ENABLED[@]} -eq 1 ]]; then
      TARGET="${ENABLED[0]}"
    else
      echo "WARN: multi-repo config with ${#ENABLED[@]} enabled targets (${ENABLED_LIST}); pass the target name explicitly." >&2
      emit false "ambiguous-target"
      exit 0
    fi
  else
    TARGET="repo"
  fi
fi

DETECT="$("${SCRIPT_DIR}/figma-detect-target.sh" "$TARGET" "$CONFIG")"
if [[ "$(jq -r '.enabled' <<< "$DETECT")" != "true" ]]; then
  emit false "target-$(jq -r '.reason' <<< "$DETECT")"
  exit 0
fi

# Fresh = snapshot exists, is newer than the config, and is younger than the
# max-age window (find -mmin is portable across GNU and BSD/macOS).
if [[ -f "$SNAPSHOT" && ! "$CONFIG" -nt "$SNAPSHOT" ]] \
   && [[ -n "$(find "$SNAPSHOT" -mmin "-${MAX_AGE_MIN}" 2>/dev/null)" ]]; then
  emit false "fresh"
  exit 0
fi

# Derive the introspection scope from the detected target (team > project >
# file, same precedence as /speckit.figma.introspect).
while IFS= read -r team_id; do
  INTROSPECT_ARGS+=(--team "$team_id")
done < <(jq -r '(.figmaTeamIds // [])[]' <<< "$DETECT")
TEAM_ID="$(jq -r '.figmaTeamId // empty' <<< "$DETECT")"
if [[ -n "$TEAM_ID" ]]; then INTROSPECT_ARGS+=(--team "$TEAM_ID"); fi
PROJECT_ID="$(jq -r '.figmaProjectId // empty' <<< "$DETECT")"
if [[ -n "$PROJECT_ID" ]]; then INTROSPECT_ARGS+=(--project "$PROJECT_ID"); fi
FILE_ID="$(jq -r '.figmaFileId // empty' <<< "$DETECT")"
if [[ -n "$FILE_ID" ]]; then INTROSPECT_ARGS+=(--file "$FILE_ID"); fi

if [[ "$DRY_RUN" == "true" ]]; then
  emit false "dry-run"
  exit 0
fi

# Introspection output (index) goes to stderr: this script's stdout is the
# machine-readable status contract.
if "${SCRIPT_DIR}/figma-introspect.sh" "${INTROSPECT_ARGS[@]}" --config "$CONFIG" >&2; then
  emit true "introspected"
else
  echo "WARN: Figma introspection failed for target '${TARGET}'; proceeding without fresh design context (see errors above)." >&2
  emit false "introspect-failed"
fi
