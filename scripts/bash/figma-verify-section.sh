#!/usr/bin/env bash
# =============================================================================
# figma-verify-section.sh — verify the Figma section made it into the document
# =============================================================================
# Closes the loop after generation: the before-hook renders a ready-to-paste
# section and guarantees the FILE exists, but it cannot guarantee the agent
# actually PASTED it into the generated spec.md / plan.md / tasks.md. This
# verification runs AFTER generation and checks that — when a Figma mockup was
# detected for the run (i.e. the rendered `.figma/cache/section.<phase>.md` exists) —
# the corresponding document really contains the Figma section marker.
#
# Designed as a SAFE NO-OP by default: when Figma does not apply, the document
# cannot be located, or the section is present, it exits 0. With --strict (or
# `figma.verifyStrict: true` in the config) a missing section — the real defect —
# exits non-zero so a CI pipeline can gate on it.
#
# Usage:
#   figma-verify-section.sh --phase spec|plan|tasks
#     [--doc <path>] [--config <path>] [--strict]
# When --doc is omitted, the document is resolved from the SpecKit layout:
# specs/<current-branch>/<phase>.md; otherwise it is used ONLY when exactly one
# specs/*/<phase>.md exists. With several candidates the target is ambiguous, so
# verification refuses (reason "doc-not-found") and asks for --doc rather than
# risk verifying — and, under --strict, gating CI on — the wrong feature's doc.
#
# Prints a JSON status object on stdout:
#   { "verified": true|false, "phase": "...", "applicable": true|false,
#     "reason": "ok|not-applicable|section-missing|doc-not-found",
#     "doc": "...", "expectedMarker": "...", "renderedSection": "...",
#     "remedy": "..." }
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

PHASE=""
DOC=""
STRICT="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --doc) DOC="$2"; shift 2 ;;
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

# Strict can also be enabled from the config (CI gate without changing the call).
if [[ "$STRICT" != "true" ]] \
   && [[ "$(figma_config_get 'if .figma.verifyStrict == true then "true" else "false" end' 'false')" == "true" ]]; then
  STRICT="true"
fi

ROOT="$(figma_repo_root)"
RENDERED="$(figma_section_path "$PHASE")"
# Phase-specific machine marker emitted by figma-render-section.sh: decoupled
# from the (translatable) heading text and able to detect a wrong-phase section.
MARKER="speckit-figma:section phase=${PHASE}"
# Legacy/heading fallback so a section pasted without the machine comment (or
# rendered by an older version) is still recognized. It MUST stay phase-specific:
# the previous phase-agnostic "(extension: figma)" suffix is present in EVERY
# template heading, so it matched a section pasted for the WRONG phase and made
# the verifier report "ok" for a missing/misplaced section — silently defeating
# the wrong-phase detection the machine marker above exists for (and --strict).
case "$PHASE" in
  spec)  LEGACY_MARKER="## Figma Design Context" ;;
  plan)  LEGACY_MARKER="## Figma Design Plan" ;;
  tasks) LEGACY_MARKER="## Figma-derived tasks" ;;
esac

emit() { # $1 verified(bool)  $2 applicable(bool)  $3 reason  $4 remedy
  jq -n --argjson verified "$1" --argjson applicable "$2" \
    --arg phase "$PHASE" --arg reason "$3" --arg doc "${DOC:-}" \
    --arg marker "$MARKER" --arg rendered "$RENDERED" --arg remedy "$4" \
    '{verified: $verified, phase: $phase, applicable: $applicable,
      reason: $reason,
      doc: (if $doc == "" then null else $doc end),
      expectedMarker: $marker, renderedSection: $rendered,
      remedy: (if $remedy == "" then null else $remedy end)}'
}

# Resolve the SpecKit document for this phase when not given explicitly.
resolve_doc() {
  [[ -n "$DOC" ]] && return 0
  local branch; branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -n "$branch" && -f "${ROOT}/specs/${branch}/${PHASE}.md" ]]; then
    DOC="${ROOT}/specs/${branch}/${PHASE}.md"; return 0
  fi
  # No branch-named feature dir: fall back ONLY when the choice is unambiguous —
  # a single specs/*/<phase>.md. With several candidates, picking the most-recent
  # one could verify (and, under --strict, gate CI on) the WRONG feature's doc,
  # so refuse and ask for --doc instead.
  local matches=()
  local f
  # SpecKit feature dirs are `NNN-slug` (alphanumeric); the glob is safe here.
  for f in "${ROOT}"/specs/*/"${PHASE}.md"; do
    [[ -f "$f" ]] && matches+=("$f")
  done
  if [[ ${#matches[@]} -eq 1 ]]; then
    DOC="${matches[0]}"; return 0
  elif [[ ${#matches[@]} -gt 1 ]]; then
    echo "WARN: ${#matches[@]} candidate specs/*/${PHASE}.md documents and branch '${branch}' has no specs/${branch}/${PHASE}.md; pass --doc to disambiguate." >&2
  fi
  return 1
}

# Not applicable: no rendered section => Figma did not apply to this run.
if [[ ! -f "$RENDERED" ]]; then
  echo "INFO: no ${RENDERED##*/} — Figma did not apply to this run; nothing to verify." >&2
  emit true false "not-applicable" ""
  exit 0
fi

if ! resolve_doc; then
  echo "WARN: could not locate the ${PHASE}.md document (pass --doc); skipping verification." >&2
  emit true true "doc-not-found" "Pass --doc <path-to-${PHASE}.md> so the section can be verified."
  [[ "$STRICT" == "true" ]] && exit 1
  exit 0
fi

if grep -qF "$MARKER" "$DOC" || grep -qF "$LEGACY_MARKER" "$DOC"; then
  emit true true "ok" ""
  exit 0
fi

# Applicable, document found, section absent — the real defect.
REMEDY="Insert the rendered Figma section from ${RENDERED} into ${DOC} (it was detected but not integrated)."
echo "WARN: ${DOC} is missing the Figma section '${MARKER}'. ${REMEDY}" >&2
emit false true "section-missing" "$REMEDY"
[[ "$STRICT" == "true" ]] && exit 1
exit 0
