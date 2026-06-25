#!/usr/bin/env bash
# =============================================================================
# figma-render-section.sh — render a ready-to-paste Figma section from the snapshot
# =============================================================================
# Guarantees the Figma design section is integrated into spec.md / plan.md /
# tasks.md REGARDLESS of the agent model: instead of asking the model to
# synthesise a section from the template + snapshot + rules (which weaker models
# silently skip), this script renders the matching template with every
# DETERMINISTIC placeholder already filled from `.figma-context-snapshot.json`
# (file id, project id, generated/lastModified timestamps, context engine, the
# introspected page/frame index, component/style counts, and any direct input
# links). The agent only has to (1) paste the rendered block verbatim and
# (2) complete the JUDGEMENT placeholders (placement reuse/create, justification,
# token mapping) — it can no longer omit the section.
#
# Usage:
#   figma-render-section.sh --phase spec|plan|tasks
#     [--config <path>] [--snapshot <path>]
#     [--links <json-array>] [--candidate-frames <json-array>] [--out <path>]
#
# Output: writes <root>/.figma-section.<phase>.md (git-ignored) and prints its
# path on stdout. Templates are resolved from the workspace
# (<root>/.specify/templates/) first, then the extension checkout
# (<script>/../../templates/).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

PHASE=""
SNAPSHOT=""
LINKS_JSON="[]"
CANDIDATE_FRAMES_JSON="[]"
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --config) FIGMA_CONFIG="$2"; export FIGMA_CONFIG; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --links) LINKS_JSON="$2"; shift 2 ;;
    --candidate-frames) CANDIDATE_FRAMES_JSON="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

case "$PHASE" in
  spec)  TEMPLATE_NAME="spec-figma-section.template.md" ;;
  plan)  TEMPLATE_NAME="plan-figma-section.template.md" ;;
  tasks) TEMPLATE_NAME="tasks-figma-section.template.md" ;;
  *) echo "ERROR: --phase must be one of spec|plan|tasks (got '${PHASE}')" >&2; exit 1 ;;
esac

ROOT="$(figma_repo_root)"
[[ -n "$SNAPSHOT" ]] || SNAPSHOT="$(figma_cache_path)"
[[ -n "$OUT" ]] || OUT="${ROOT}/.figma-section.${PHASE}.md"

if [[ ! -f "$SNAPSHOT" ]]; then
  echo "ERROR: snapshot not found: ${SNAPSHOT} (run figma-introspect.sh first)" >&2
  exit 1
fi
if ! echo "$LINKS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "ERROR: --links must be a JSON array" >&2; exit 1
fi

# Resolve the template: workspace install first, then the extension checkout.
TEMPLATE=""
for cand in "${ROOT}/.specify/templates/${TEMPLATE_NAME}" "${SCRIPT_DIR}/../../templates/${TEMPLATE_NAME}"; do
  if [[ -f "$cand" ]]; then TEMPLATE="$cand"; break; fi
done
if [[ -z "$TEMPLATE" ]]; then
  echo "ERROR: template '${TEMPLATE_NAME}' not found in .specify/templates/ or the extension checkout." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Deterministic scalars from the snapshot.
# -----------------------------------------------------------------------------
FILE_ID="$(jq -r '.fileId // "n/a"' "$SNAPSHOT")"
PROJECT_ID="$(jq -r '.projectId // "n/a"' "$SNAPSHOT")"
GENERATED_AT="$(jq -r '.generatedAt // "unknown"' "$SNAPSHOT")"
LAST_MODIFIED="$(jq -r '.lastModified // "unknown"' "$SNAPSHOT")"
CONTEXT_SOURCE="$(jq -r '.contextSource // "rest"' "$SNAPSHOT")"
MODE="$(figma_config_get '.mode' 'single-repo')"

# Escape a value for safe use as a sed REPLACEMENT with the '@' delimiter: a
# backslash, '&' (expands to the whole match) and '@' (the delimiter) would
# otherwise corrupt the command or the output. Values come from the snapshot /
# config and are not guaranteed free of these characters.
sed_repl() { printf '%s' "$1" | sed -e 's/[\\&@]/\\&/g'; }

FILE_ID_E="$(sed_repl "$FILE_ID")"
PROJECT_ID_E="$(sed_repl "$PROJECT_ID")"
GENERATED_AT_E="$(sed_repl "$GENERATED_AT")"
LAST_MODIFIED_E="$(sed_repl "$LAST_MODIFIED")"
MODE_E="$(sed_repl "$MODE")"

# Substitute the scalar placeholders the templates share. Judgement placeholders
# (placement, justification, token mapping) are intentionally left untouched.
# Delimiter '@' — the placeholders themselves contain '|', so it cannot be the
# sed delimiter; replacement values are escaped above.
substitute() {
  sed \
    -e "s@{{FIGMA_FILE_ID}}@${FILE_ID_E}@g" \
    -e "s@{{FIGMA_PROJECT_ID | n/a}}@${PROJECT_ID_E}@g" \
    -e "s@{{GENERATED_AT}}@${GENERATED_AT_E}@g" \
    -e "s@{{LAST_MODIFIED}}@${LAST_MODIFIED_E}@g" \
    -e "s@{{multi-repo | mono-repo}}@${MODE_E}@g" \
    "$1"
}

# -----------------------------------------------------------------------------
# Auto-filled facts appendix — the deterministic, model-proof part. Lists the
# real introspected pages/frames, components, context engine and input links so
# the agent CANNOT claim "no creative was indicated": the candidates are here.
# -----------------------------------------------------------------------------
PAGES_TABLE="$(jq -r '
  (.pages // []) as $p
  | if ($p | length) == 0 then "_No mapped page introspected in the snapshot._"
    else ( "| Page | Frames |\n|------|--------|\n"
           + ( [ $p[] | "| \(.name) | \((.frames // []) | length) |" ] | join("\n") ) )
    end' "$SNAPSHOT")"

FRAMES_TABLE="$(jq -r '
  [ (.pages // [])[] as $pg | ($pg.frames // [])[] | "| \($pg.name) | \(.name) | `\(.id)` |" ] as $rows
  | if ($rows | length) == 0 then "_No top-level frame indexed._"
    else "| Page | Frame | Node id |\n|------|-------|---------|\n" + ($rows | join("\n"))
    end' "$SNAPSHOT")"

COMPONENT_COUNT="$(jq -r '(.components // {} | length)' "$SNAPSHOT")"
STYLE_COUNT="$(jq -r '(.styles // {} | length)' "$SNAPSHOT")"

LINKS_TABLE="$(echo "$LINKS_JSON" | jq -r '
  if (length == 0) then "_None — context derived from the page mapping._"
  else "| URL | File | Node |\n|-----|------|------|\n"
       + ( [ .[] | "| \(.url) | `\(.fileId)` | `\(.nodeId // "—")` |" ] | join("\n") )
  end')"

CANDIDATE_TABLE="$(echo "$CANDIDATE_FRAMES_JSON" | jq -r '
  if (length == 0) then ""
  else "\n> ⚠️ A broad Figma link (file/page, no specific frame) was provided. "
       + "Confirm which of these frames the feature targets BEFORE generating tasks "
       + "(creative-confirmation checkpoint — do not silently skip):\n\n"
       + "| # | Frame | Node id |\n|---|-------|---------|\n"
       + ( [ to_entries[] | "| \(.key + 1) | \(.value.name) | `\(.value.id)` |" ] | join("\n") )
  end')"

{
  # Stable, phase-specific machine marker so figma-verify-section.sh can confirm
  # integration without coupling to the (translatable) heading text, and can tell
  # a wrong-phase section apart. Keep this line when pasting the block.
  printf '<!-- speckit-figma:section phase=%s -->\n' "$PHASE"
  substitute "$TEMPLATE"
  printf '\n\n<!-- ===== AUTO-FILLED FROM .figma-context-snapshot.json — do not delete; complete the judgement fields above ===== -->\n'
  printf '\n### Snapshot facts (auto-filled, deterministic)\n\n'
  # Backticks below are literal markdown; %s is expanded by printf, not the shell.
  # shellcheck disable=SC2016
  printf -- '- **File**: `%s`  ·  **Project**: `%s`  ·  **Engine**: %s\n' "$FILE_ID" "$PROJECT_ID" "$CONTEXT_SOURCE"
  printf -- '- **Generated**: %s  ·  **Figma lastModified**: %s\n' "$GENERATED_AT" "$LAST_MODIFIED"
  printf -- '- **Indexed**: %s component(s), %s style(s)\n\n' "$COMPONENT_COUNT" "$STYLE_COUNT"
  printf '**Direct links provided in input**\n\n%s\n\n' "$LINKS_TABLE"
  printf '**Introspected pages**\n\n%s\n\n' "$PAGES_TABLE"
  printf '**Top-level frames (candidate creatives)**\n\n%s\n' "$FRAMES_TABLE"
  printf '%s\n' "$CANDIDATE_TABLE"
} > "$OUT"

echo "$OUT"
