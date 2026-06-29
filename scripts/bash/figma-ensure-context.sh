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
# Designed as a SAFE NO-OP for generation flow: every configuration problem
# (missing config, unresolved placeholders, excluded target, failed
# introspection, ...) is reported as a skip reason with exit 0 so spec/tasks
# generation is never blocked. It is NOT silent about *why*: a failed
# introspection carries a machine-readable `code` (NETWORK|AUTH|NOT_FOUND) so the
# agent reports the real cause instead of guessing "authentication required".
# Non-zero exits are reserved for unexpected internal errors and bad CLI args.
#
# Usage:
#   figma-ensure-context.sh [<target-name>] [--config <path>]
#     [--max-age-minutes N] [--input <text> | --input -] [--dry-run]
# <target-name> defaults to "repo" (single-/mono-repo); for multi-repo it is
# auto-resolved only when exactly one enabled target exists.
# --input carries the user's raw feature input ("-" reads stdin): any direct
# Figma links it contains are parsed (figma-parse-links.sh) and become
# AUTHORITATIVE design targets — the linked file/nodes override the
# config-derived scope, and a snapshot that does not cover the linked nodes is
# treated as stale. Same contract as /speckit.figma.introspect section 0, so
# no manual introspection run is ever needed for pasted links.
# FIGMA_SNAPSHOT_MAX_AGE_MINUTES overrides the default freshness window (60).
#
# Prints a JSON status object on stdout:
#   { "ran": true|false, "reason": "...", "code": "NETWORK|AUTH|NOT_FOUND|...|null",
#     "target": "...",
#     "snapshot": "...", "links": [...], "introspectArgs": [...],
#     "mustInject": true|false,        # section is mandatory in spec/plan/tasks
#     "linkScope": "none|frame|broad", # "broad" => confirm a frame before tasks
#     "candidateFrames": [...],        # frames to confirm when linkScope=broad
#     "specSection": "...", "planSection": "...", "tasksSection": "..." }
# When mustInject=true the agent MUST paste the rendered <phase>Section file
# verbatim into the generated document, then complete the judgement fields.
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
INPUT_TEXT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) FIGMA_CONFIG="$2"; export FIGMA_CONFIG; shift 2 ;;
    --max-age-minutes) MAX_AGE_MIN="$2"; shift 2 ;;
    --input)
      [[ $# -ge 2 ]] || { echo "ERROR: --input requires a value (text or '-' for stdin)" >&2; exit 1; }
      if [[ "$2" == "-" ]]; then INPUT_TEXT="$(cat || true)"; else INPUT_TEXT="$2"; fi
      shift 2 ;;
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
LINKS_JSON="[]"
LINK_FILE=""
LINK_NODES=()
# Injection contract: filled once a usable snapshot exists (introspected|fresh).
MUST_INJECT="false"
LINK_SCOPE="none"          # none | frame | broad
CANDIDATE_FRAMES_JSON="[]" # top-level frames to confirm when LINK_SCOPE=broad
SPEC_SECTION=""
PLAN_SECTION=""
TASKS_SECTION=""
# Machine-readable failure cause from figma_api (NETWORK|AUTH|NOT_FOUND|...),
# read back via FIGMA_DIAG_FILE when introspection fails. Empty otherwise.
FAILURE_CODE=""

emit() { # $1 = ran (true|false), $2 = reason
  jq -n --argjson ran "$1" --arg reason "$2" --arg target "${TARGET:-}" --arg snapshot "$SNAPSHOT" \
    --argjson links "$LINKS_JSON" \
    --argjson mustInject "$MUST_INJECT" \
    --arg linkScope "$LINK_SCOPE" \
    --argjson candidateFrames "$CANDIDATE_FRAMES_JSON" \
    --arg code "$FAILURE_CODE" \
    --arg specSection "$SPEC_SECTION" \
    --arg planSection "$PLAN_SECTION" \
    --arg tasksSection "$TASKS_SECTION" \
    '{ran: $ran, reason: $reason,
      code: (if $code == "" then null else $code end),
      target: (if $target == "" then null else $target end),
      snapshot: $snapshot,
      links: $links,
      mustInject: $mustInject,
      linkScope: $linkScope,
      candidateFrames: $candidateFrames,
      specSection: (if $specSection == "" then null else $specSection end),
      planSection: (if $planSection == "" then null else $planSection end),
      tasksSection: (if $tasksSection == "" then null else $tasksSection end),
      introspectArgs: $ARGS.positional}' \
    --args -- ${INTROSPECT_ARGS[@]+"${INTROSPECT_ARGS[@]}"}
}

# Classify the directly-linked nodes against the snapshot and, for broad links
# (file/page level, no specific FRAME), collect the candidate top-level frames so
# the agent enumerates them for creative confirmation instead of bailing out.
compute_link_scope() {
  LINK_SCOPE="none"
  CANDIDATE_FRAMES_JSON="[]"
  [[ -z "$LINK_FILE" ]] && return 0
  [[ -f "$SNAPSHOT" ]] || { LINK_SCOPE="broad"; return 0; }
  if [[ ${#LINK_NODES[@]} -eq 0 ]]; then
    LINK_SCOPE="broad"
  else
    LINK_SCOPE="frame"
    local n
    for n in "${LINK_NODES[@]}"; do
      # The creative is NOT pinned only when a linked node is a page/canvas or
      # the document root (it covers many frames). A node-id that resolves to a
      # specific frame — top-level, nested, or any other deep-fetched element —
      # is a confirmed creative and must stay 'frame' (the original
      # `.pages[].frames[]`-only check wrongly flagged those as broad).
      # Detect "broad" two ways: the id matches an indexed page (works even when
      # the page node was not deep-fetched), OR the deep-fetched node's Figma
      # type is CANVAS/DOCUMENT (covers a document-root link not in pages[]).
      if jq -e --arg n "$n" '
            ([ .pages[]? | select(.id == $n) ] | length > 0)
            or ((.nodes.nodes[$n].document.type // "") as $t | $t == "CANVAS" or $t == "DOCUMENT")' \
            "$SNAPSHOT" >/dev/null 2>&1; then
        LINK_SCOPE="broad"; break
      fi
    done
  fi
  if [[ "$LINK_SCOPE" == "broad" ]]; then
    CANDIDATE_FRAMES_JSON="$(jq -c '[ .pages[]? as $p | ($p.frames[]? | {id, name, page: $p.name}) ]' "$SNAPSHOT" 2>/dev/null || echo '[]')"
  fi
}

# Render the ready-to-paste spec/plan/tasks sections from the fresh snapshot so
# the agent only has to paste them — the section can no longer be silently
# omitted. Render failures are non-fatal (the agent falls back to the template).
prepare_injection() {
  MUST_INJECT="true"
  # Re-render starts clean so only this run's sections survive — a per-phase
  # render failure below then leaves NO stale file for that phase.
  clear_rendered_sections
  compute_link_scope
  local phase out err
  err="$(mktemp)"
  for phase in spec plan tasks; do
    # Capture stdout (the rendered file path) separately from stderr so a render
    # failure (missing template, bad JSON, ...) is SURFACED, not silently turned
    # into a null section with no diagnostic.
    if out="$("${SCRIPT_DIR}/figma-render-section.sh" --phase "$phase" --config "$CONFIG" \
        --snapshot "$SNAPSHOT" --links "$LINKS_JSON" --candidate-frames "$CANDIDATE_FRAMES_JSON" 2>"$err")"; then
      :
    else
      echo "WARN: figma-render-section.sh failed to render the '${phase}' section: $(cat "$err")" >&2
      out=""
    fi
    case "$phase" in
      spec) SPEC_SECTION="$out" ;;
      plan) PLAN_SECTION="$out" ;;
      tasks) TASKS_SECTION="$out" ;;
    esac
  done
  rm -f "$err"
}

# True when the current snapshot already targets the linked file and contains
# every linked node — only then can a link-driven run be considered fresh.
snapshot_covers_links() {
  [[ -z "$LINK_FILE" ]] && return 0
  jq -e --arg f "$LINK_FILE" '.fileId == $f' "$SNAPSHOT" >/dev/null 2>&1 || return 1
  local node_id
  for node_id in ${LINK_NODES[@]+"${LINK_NODES[@]}"}; do
    jq -e --arg n "$node_id" '(.nodes.nodes // {}) | has($n)' "$SNAPSHOT" >/dev/null 2>&1 || return 1
  done
  return 0
}

# Stale rendered sections from a previous run must not outlive it: the verifier
# (figma-verify-section.sh) keys "Figma applied to this run" on the existence of
# .figma-section.<phase>.md. clear_rendered_sections drops them so only THIS
# run's renders remain.
#
# It is called on the paths where Figma DEFINITIVELY does not apply (no/invalid
# config, excluded target) and at the start of prepare_injection (just before a
# re-render) — but deliberately NOT on a transient introspect-failure. Wiping on
# a transient failure would erase a prior phase's still-valid render, so the
# verifier would report "not-applicable" and let a --strict CI gate silently pass
# for a run where Figma genuinely applies; leaving the prior render keeps the
# gate honest (fail-closed, consistent with verify's own --strict policy).
ROOT_DIR="$(figma_repo_root)"
clear_rendered_sections() {
  rm -f "${ROOT_DIR}/.figma-section."*.md 2>/dev/null || true
}

if [[ ! -f "$CONFIG" ]]; then
  echo "INFO: no ${CONFIG##*/} found; proceeding without Figma context." >&2
  clear_rendered_sections
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
  clear_rendered_sections
  emit false "unresolved-placeholders"
  exit 0
elif [[ "$VALIDATE_RC" -ne 0 ]]; then
  echo "WARN: ${VALIDATE_OUT}" >&2
  clear_rendered_sections
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
      clear_rendered_sections
      emit false "ambiguous-target"
      exit 0
    fi
  else
    TARGET="repo"
  fi
fi

DETECT="$("${SCRIPT_DIR}/figma-detect-target.sh" "$TARGET" "$CONFIG")"
if [[ "$(jq -r '.enabled' <<< "$DETECT")" != "true" ]]; then
  clear_rendered_sections
  emit false "target-$(jq -r '.reason' <<< "$DETECT")"
  exit 0
fi

# Direct Figma links pasted in the feature input are authoritative design
# targets (same contract as /speckit.figma.introspect section 0): the linked
# file/nodes win over the config mapping, with node-level extraction.
if [[ -n "$INPUT_TEXT" ]]; then
  PARSED_LINKS="$("${SCRIPT_DIR}/figma-parse-links.sh" <<< "$INPUT_TEXT")"
  if [[ -n "$PARSED_LINKS" ]]; then
    LINKS_JSON="$(jq -s '.' <<< "$PARSED_LINKS")"
    LINK_FILE="$(jq -r '.[0].fileId' <<< "$LINKS_JSON")"
    DISTINCT_FILES="$(jq -r '[.[].fileId] | unique | length' <<< "$LINKS_JSON")"
    if [[ "$DISTINCT_FILES" -gt 1 ]]; then
      echo "WARN: the input links reference ${DISTINCT_FILES} distinct Figma files; auto-introspecting the first ('${LINK_FILE}') — run /speckit.figma.introspect --file <id> for the others." >&2
    fi
    while IFS= read -r node_id; do
      LINK_NODES+=("$node_id")
    done < <(jq -r --arg f "$LINK_FILE" \
      '[.[] | select(.fileId == $f and .nodeId != null) | .nodeId] | unique | .[]' <<< "$LINKS_JSON")
  fi
fi

# Fresh = snapshot exists, is newer than the config, is younger than the
# max-age window (find -mmin is portable across GNU and BSD/macOS), and covers
# any directly-linked file/nodes from the input.
if [[ -f "$SNAPSHOT" && ! "$CONFIG" -nt "$SNAPSHOT" ]] \
   && [[ -n "$(find "$SNAPSHOT" -mmin "-${MAX_AGE_MIN}" 2>/dev/null)" ]] \
   && snapshot_covers_links; then
  # Figma applies and the snapshot is usable → the section is mandatory; render it.
  prepare_injection
  emit false "fresh"
  exit 0
fi

if [[ -n "$LINK_FILE" ]]; then
  # Link-driven scope: introspect the linked file and drill into each linked
  # node so the snapshot carries frame-level detail (fills, typography, layout).
  INTROSPECT_ARGS+=(--file "$LINK_FILE")
  for node_id in ${LINK_NODES[@]+"${LINK_NODES[@]}"}; do
    INTROSPECT_ARGS+=(--node "$node_id")
  done
  CONFIG_FILE_ID="$(jq -r '.figmaFileId // empty' <<< "$DETECT")"
  if [[ -n "$CONFIG_FILE_ID" && "$CONFIG_FILE_ID" != "$LINK_FILE" ]]; then
    echo "INFO: direct Figma link overrides the mapped file '${CONFIG_FILE_ID}' for this run." >&2
  fi
else
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
fi

if [[ "$DRY_RUN" == "true" ]]; then
  emit false "dry-run"
  exit 0
fi

# Introspection output (index) goes to stderr: this script's stdout is the
# machine-readable status contract. FIGMA_DIAG_FILE lets figma_api (inside the
# introspect child) record the REAL failure cause so we never hide a network
# problem behind a fabricated "authentication required".
FIGMA_DIAG_FILE="$(mktemp)"; export FIGMA_DIAG_FILE
trap 'rm -f "$FIGMA_DIAG_FILE"' EXIT
if "${SCRIPT_DIR}/figma-introspect.sh" "${INTROSPECT_ARGS[@]}" --config "$CONFIG" >&2; then
  prepare_injection
  emit true "introspected"
else
  if [[ -s "$FIGMA_DIAG_FILE" ]]; then
    FAILURE_CODE="$(jq -r '.code // empty' "$FIGMA_DIAG_FILE" 2>/dev/null || true)"
  fi
  # Fail-LOUD with the specific cause: the agent (and any weak LLM) must report
  # the truth, not the most-common-but-wrong "auth" guess.
  case "$FAILURE_CODE" in
    NETWORK)
      echo "WARN: Figma unreachable (network/proxy) for target '${TARGET}'; the script auto-retried directly. This is a connectivity problem, not a credentials one — do not report a credentials failure." >&2 ;;
    AUTH)
      echo "WARN: Figma auth/scope failure for target '${TARGET}'; check the PAT scopes and use the keychain + FIGMA_PAT_COMMAND (never a .env). See docs/CREDENTIALS.md." >&2 ;;
    NOT_FOUND)
      echo "WARN: Figma returned 404 for target '${TARGET}'; the file/project/team key is wrong or the PAT owner is not a member. See docs/CREDENTIALS.md." >&2 ;;
    *)
      echo "WARN: Figma introspection failed for target '${TARGET}'; proceeding without fresh design context (see errors above)." >&2 ;;
  esac
  emit false "introspect-failed"
fi
