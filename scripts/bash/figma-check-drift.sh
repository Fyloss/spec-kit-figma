#!/usr/bin/env bash
# =============================================================================
# figma-check-drift.sh — has the mockup moved since the spec was written?
# =============================================================================
# Invoked automatically after /speckit.analyze (the after_analyze hook). Analyze
# cross-checks spec/plan/tasks for consistency, and this is the one Figma fact
# that consistency check cannot see on its own: the documents may agree perfectly
# with each other and all three be faithful to a creative the designer has since
# changed. On a PR that sits for two weeks that is the drift that produces an
# implementation faithful to an obsolete design.
#
# The comparison is between two recorded facts, never a re-render:
#   - the Figma `lastModified` captured in the document when it was generated,
#     read back from the section marker
#     (<!-- speckit-figma:section phase=spec file=<key> lastModified=<ts> -->);
#   - the `lastModified` of the CURRENT snapshot, refreshed by the before_analyze
#     hook moments earlier.
# The marker is the source because parsing the rendered prose would break the
# first time a heading is reworded or translated.
#
# Usage:
#   figma-check-drift.sh [--phase spec|plan|tasks] [--doc <path>]
#     [--snapshot <path>] [--config <path>] [--strict]
# --phase defaults to spec: it is the document that records the creative, and the
# one /speckit.figma.ensure recovers links from. --doc overrides the SpecKit
# layout resolution (specs/<feature>/<phase>.md).
#
# Prints a JSON status object on stdout:
#   { "drifted": true|false, "applicable": true|false,
#     "reason": "ok|drifted|not-applicable|doc-not-found|no-marker|no-snapshot|unknown-timestamp",
#     "phase": "...", "doc": "...", "fileId": "...",
#     "documentLastModified": "...", "figmaLastModified": "...",
#     "remedy": "..." }
#
# SAFE NO-OP by default, like every other hook in this extension: an absent
# document, a missing marker or an unusable snapshot all exit 0. --strict (or
# `figma.verifyStrict` in the config) turns a REAL drift — and only that — into a
# non-zero exit so CI can gate on it. Being unable to check is never a failure;
# checking and finding drift is.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

PHASE="spec"
DOC=""
SNAPSHOT=""
STRICT="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --doc) DOC="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --config) FIGMA_CONFIG="$2"; export FIGMA_CONFIG; shift 2 ;;
    --strict) STRICT="true"; shift ;;
    --*) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
    *) echo "ERROR: unexpected argument '$1'" >&2; exit 1 ;;
  esac
done

case "$PHASE" in
  spec|plan|tasks) ;;
  *) echo "ERROR: --phase must be one of spec|plan|tasks (got '${PHASE}')" >&2; exit 1 ;;
esac

# Same escape hatch as figma-verify-section.sh, so one config key gates the whole
# post-generation family instead of each script inventing its own.
if [[ "$STRICT" != "true" ]] \
   && [[ "$(figma_config_get 'if .figma.verifyStrict == true then "true" else "false" end' 'false')" == "true" ]]; then
  STRICT="true"
fi

[[ -n "$SNAPSHOT" ]] || SNAPSHOT="$(figma_cache_path)"

DOC_TS=""
FIGMA_TS=""
FILE_ID=""

emit() { # $1 drifted(bool)  $2 applicable(bool)  $3 reason  $4 remedy
  jq -n --argjson drifted "$1" --argjson applicable "$2" \
    --arg reason "$3" --arg remedy "$4" --arg phase "$PHASE" \
    --arg doc "${DOC:-}" --arg file "$FILE_ID" \
    --arg docTs "$DOC_TS" --arg figmaTs "$FIGMA_TS" \
    '{drifted: $drifted, applicable: $applicable, reason: $reason, phase: $phase,
      doc: (if $doc == "" then null else $doc end),
      fileId: (if $file == "" then null else $file end),
      documentLastModified: (if $docTs == "" then null else $docTs end),
      figmaLastModified: (if $figmaTs == "" then null else $figmaTs end),
      remedy: (if $remedy == "" then null else $remedy end)}'
}

if [[ -z "$DOC" ]]; then
  DOC="$(figma_resolve_phase_doc "$PHASE" || true)"
fi
if [[ -z "$DOC" || ! -f "$DOC" ]]; then
  echo "INFO: no ${PHASE}.md located; nothing to compare." >&2
  DOC=""
  emit false false "doc-not-found" ""
  exit 0
fi

# The marker line, and the two facts it carries. A document generated before the
# marker gained them yields empty values — reported as "unknown-timestamp", not
# as drift: an old document is not evidence the design moved.
MARKER_LINE="$(grep -m1 -F "speckit-figma:section phase=${PHASE}" "$DOC" || true)"
if [[ -z "$MARKER_LINE" ]]; then
  echo "INFO: ${DOC##*/} carries no Figma section; drift does not apply to this feature." >&2
  emit false false "no-marker" ""
  exit 0
fi

DOC_TS="$(sed -nE 's/.*[[:space:]]lastModified=([^[:space:]>]+).*/\1/p' <<< "$MARKER_LINE" | head -n1)"
FILE_ID="$(sed -nE 's/.*[[:space:]]file=([^[:space:]>]+).*/\1/p' <<< "$MARKER_LINE" | head -n1)"

if [[ ! -f "$SNAPSHOT" ]]; then
  echo "INFO: no snapshot at ${SNAPSHOT}; run /speckit.figma.ensure first." >&2
  emit false false "no-snapshot" "Re-run the before_analyze hook (/speckit.figma.ensure) so a current snapshot exists."
  exit 0
fi
FIGMA_TS="$(jq -r '.lastModified // empty' "$SNAPSHOT" 2>/dev/null || true)"
SNAPSHOT_FILE="$(jq -r '.fileId // empty' "$SNAPSHOT" 2>/dev/null || true)"

if [[ -z "$DOC_TS" || "$DOC_TS" == "unknown" || -z "$FIGMA_TS" ]]; then
  echo "INFO: not enough recorded timestamps to compare (document='${DOC_TS:-none}', snapshot='${FIGMA_TS:-none}'); regenerate the section to start tracking drift." >&2
  emit false true "unknown-timestamp" "Re-run the phase so the section marker records the Figma lastModified."
  exit 0
fi

# Comparing two different files' timestamps would be meaningless — and worse,
# alarming: a feature whose creative legitimately moved to another file would
# report permanent drift. Report it as not-applicable and say which is which.
if [[ -n "$SNAPSHOT_FILE" && -n "$FILE_ID" && "$FILE_ID" != "unknown" && "$SNAPSHOT_FILE" != "$FILE_ID" ]]; then
  echo "INFO: the snapshot targets file '${SNAPSHOT_FILE}' but ${DOC##*/} was generated from '${FILE_ID}'; skipping the drift comparison." >&2
  emit false false "not-applicable" ""
  exit 0
fi

# Figma returns ISO-8601 UTC ('2026-08-14T09:12:33Z'), which sorts
# lexicographically in chronological order — no date parsing, so no dependency on
# GNU vs BSD `date`, and nothing to get wrong across the two script families.
if [[ "$FIGMA_TS" > "$DOC_TS" ]]; then
  REMEDY="The Figma file changed after ${DOC##*/} was generated. Re-run /speckit.specify (or /speckit.figma.ensure) to refresh the design section, and re-check the affected tasks before implementing."
  echo "WARN: design drift — ${DOC##*/} records ${DOC_TS}, Figma now reports ${FIGMA_TS}. ${REMEDY}" >&2
  emit true true "drifted" "$REMEDY"
  [[ "$STRICT" == "true" ]] && exit 1
  exit 0
fi

emit false true "ok" ""
