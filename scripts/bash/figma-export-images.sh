#!/usr/bin/env bash
# =============================================================================
# figma-export-images.sh — render Figma nodes to image files
# =============================================================================
# Two needs share the /images endpoint and nothing else. They are separate MODES
# here because their lifecycles are opposite, and one flag doing both would put
# throwaway files under version control (or leave deliverables in a git-ignored
# cache).
#
#   --mode preview  (default)
#     A picture of each candidate frame, so the developer CONFIRMS the creative
#     by looking at it instead of reading a list of node ids (design rule 5).
#     Written next to the spec it documents — specs/<feature>/assets/ — and
#     COMMITTED: .figma/cache/ is git-ignored, so a preview written there is
#     invisible to a reviewer on GitHub and spec.md renders a broken image. A few
#     tens of KB in the repository costs less than a broken image in a reviewed
#     spec.
#
#   --mode asset
#     A real asset the implementation ships: a logo as .svg, a gallery mock as
#     .png. Written where --out says (the design system, or the app), committed
#     as a deliverable, and recorded in a manifest so a re-run neither
#     re-downloads an unchanged node nor silently overwrites a hand-edited file.
#
# THE ENDPOINT RENDERS ASYNCHRONOUSLY. GET /v1/images/:key returns a JSON map of
# node id -> a temporary URL, and each URL must then be downloaded. Two steps,
# not one. Ids are requested in batches (--batch-size) because a large request
# times out server-side on a big file.
#
# Usage:
#   figma-export-images.sh --file <fileKey> --node <id> [--node <id> ...]
#     [--mode preview|asset] [--format png|jpg|svg|pdf] [--scale N]
#     [--out <dir>] [--batch-size N] [--force] [--config <path>]
#
# Prints a JSON report on stdout:
#   { "mode": "...", "fileId": "...", "outDir": "...", "format": "...",
#     "scale": N, "exported": [ {nodeId, path, bytes, status} ], "failed": [...],
#     "manifest": "..." | null }
# status is "written" | "unchanged" | "skipped-modified".
# Exit codes: 0 = report emitted (even with per-node failures), 1 = bad args or
# a hard failure before any export.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq
figma_require curl

FILE_KEY=""
MODE="preview"
FORMAT=""
SCALE="2"
OUT=""
BATCH_SIZE="10"
FORCE="false"
NODES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE_KEY="$2"; shift 2 ;;
    --node) NODES+=("$2"); shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --force) FORCE="true"; shift ;;
    --config) FIGMA_CONFIG="$2"; export FIGMA_CONFIG; shift 2 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

case "$MODE" in
  preview) [[ -n "$FORMAT" ]] || FORMAT="png" ;;
  asset)   [[ -n "$FORMAT" ]] || FORMAT="svg" ;;
  *) echo "ERROR: --mode must be preview or asset (got '${MODE}')" >&2; exit 1 ;;
esac
case "$FORMAT" in
  png|jpg|svg|pdf) ;;
  *) echo "ERROR: --format must be png, jpg, svg or pdf (got '${FORMAT}')" >&2; exit 1 ;;
esac
# Figma rejects scale on vector formats; sending it anyway is a 400 for a
# parameter that could never have meant anything.
if [[ "$FORMAT" == "svg" || "$FORMAT" == "pdf" ]]; then
  SCALE=""
elif [[ ! "$SCALE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$(echo "$SCALE < 0.01 || $SCALE > 4" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
  echo "ERROR: --scale must be a number between 0.01 and 4 (got '${SCALE}')" >&2
  exit 1
fi
if [[ ! "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --batch-size must be a positive integer (got '${BATCH_SIZE}')" >&2
  exit 1
fi
if [[ -z "$FILE_KEY" ]]; then
  echo "ERROR: --file <fileKey> is required" >&2; exit 1
fi
if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "ERROR: at least one --node <id> is required" >&2; exit 1
fi

# Canonicalize here rather than trusting the caller: an agent that copies the id
# out of a deep link hands over the URL form ('12-345'), which the API answers
# with an empty image map.
NORMALIZED=()
for RAW in "${NODES[@]}"; do
  if CANON="$(figma_normalize_node_id "$RAW")"; then
    NORMALIZED+=("$CANON")
  else
    echo "ERROR: --node '${RAW}' is not a Figma node id. Expected '12:345' (the URL form 'node-id=12-345' is accepted)." >&2
    exit 1
  fi
done
NODES=("${NORMALIZED[@]}")

ROOT="$(figma_repo_root)"
if [[ -z "$OUT" ]]; then
  if [[ "$MODE" == "preview" ]]; then
    # Beside the spec it documents, and committed with it.
    OUT="${ROOT}/specs/$(figma_feature_key)/assets"
  else
    echo "ERROR: --out <dir> is required in asset mode: where a shipped asset belongs is a project decision (design system vs app), never a default this script may pick." >&2
    exit 1
  fi
fi
mkdir -p "$OUT"

MANIFEST=""
MANIFEST_JSON="{}"
if [[ "$MODE" == "asset" ]]; then
  # The manifest is what makes a re-run safe: it records what this script wrote
  # and what the file looked like when it did, so an asset a human has since
  # edited is never silently overwritten.
  MANIFEST="${OUT}/.figma-assets.json"
  [[ -f "$MANIFEST" ]] && MANIFEST_JSON="$(jq -c '.' "$MANIFEST" 2>/dev/null || echo '{}')"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A node id is not a filename: ':' is a path separator on Windows and ';' appears
# in nested-instance ids.
safe_name() { printf '%s' "$1" | tr ':;' '__'; }

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else printf 'nosha'; fi
}

EXPORTED="[]"
FAILED="[]"

# ---- step 1: ask Figma to render, in batches ---------------------------------
URL_MAP="{}"
BATCH=()
flush_batch() {
  [[ ${#BATCH[@]} -eq 0 ]] && return 0
  local ids; ids="$(IFS=, ; echo "${BATCH[*]}")"
  ids="${ids//;/%3B}"
  local query="/images/${FILE_KEY}?ids=${ids}&format=${FORMAT}"
  [[ -n "$SCALE" ]] && query="${query}&scale=${SCALE}"
  local resp
  if ! resp="$(figma_api "$query")"; then
    echo "WARN: Figma refused to render a batch of ${#BATCH[@]} node(s); they are reported as failed." >&2
    local n
    for n in "${BATCH[@]}"; do
      FAILED="$(jq -c --arg n "$n" --arg r "render-request-failed" '. + [{nodeId:$n, reason:$r}]' <<< "$FAILED")"
    done
    BATCH=()
    return 0
  fi
  # `err` is Figma's own field; a non-null one describes the whole batch.
  local api_err; api_err="$(jq -r '.err // empty' <<< "$resp")"
  if [[ -n "$api_err" ]]; then
    echo "WARN: Figma returned an error for this batch: ${api_err}" >&2
  fi
  URL_MAP="$(jq -c --argjson add "$(jq -c '.images // {}' <<< "$resp")" '. * $add' <<< "$URL_MAP")"
  BATCH=()
}

for NODE in "${NODES[@]}"; do
  BATCH+=("$NODE")
  [[ ${#BATCH[@]} -ge "$BATCH_SIZE" ]] && flush_batch
done
flush_batch

# ---- step 2: download each rendered URL --------------------------------------
for NODE in "${NODES[@]}"; do
  IMG_URL="$(jq -r --arg n "$NODE" '.[$n] // empty' <<< "$URL_MAP")"
  if [[ -z "$IMG_URL" || "$IMG_URL" == "null" ]]; then
    # Already reported above when the whole batch failed; a null here means Figma
    # rendered nothing for this specific node (unknown id, or an empty node).
    if ! jq -e --arg n "$NODE" 'any(.[]; .nodeId == $n)' <<< "$FAILED" >/dev/null 2>&1; then
      FAILED="$(jq -c --arg n "$NODE" --arg r "no-image-returned" '. + [{nodeId:$n, reason:$r}]' <<< "$FAILED")"
    fi
    continue
  fi

  DEST="${OUT}/$(safe_name "$NODE").${FORMAT}"
  TMP="${WORK}/$(safe_name "$NODE").${FORMAT}"
  # The rendered URL is a plain signed URL on Figma's CDN and must NOT carry the
  # PAT: figma_curl_get would attach it, so this is a bare download.
  if ! curl -fsSL --max-time "${FIGMA_IMAGE_TIMEOUT:-60}" -o "$TMP" "$IMG_URL" 2>/dev/null; then
    FAILED="$(jq -c --arg n "$NODE" --arg r "download-failed" '. + [{nodeId:$n, reason:$r}]' <<< "$FAILED")"
    continue
  fi

  NEW_SHA="$(sha_of "$TMP")"
  STATUS="written"
  if [[ -f "$DEST" ]]; then
    OLD_SHA="$(sha_of "$DEST")"
    RECORDED_SHA="$(jq -r --arg n "$NODE" '.[$n].sha256 // empty' <<< "$MANIFEST_JSON")"
    if [[ "$OLD_SHA" == "$NEW_SHA" ]]; then
      STATUS="unchanged"
    elif [[ "$MODE" == "asset" && "$FORCE" != "true" && -n "$RECORDED_SHA" && "$RECORDED_SHA" != "$OLD_SHA" ]]; then
      # The file on disk is not what this script last wrote: a human changed it.
      # Overwriting would destroy work with no trace. Report and move on.
      STATUS="skipped-modified"
      echo "WARN: ${DEST#"$ROOT"/} was modified after its last export; keeping it. Pass --force to overwrite." >&2
    fi
  fi

  if [[ "$STATUS" == "written" || "$STATUS" == "unchanged" ]]; then
    [[ "$STATUS" == "written" ]] && mv "$TMP" "$DEST"
  fi

  BYTES="$(wc -c < "$DEST" 2>/dev/null | tr -d ' ' || echo 0)"
  EXPORTED="$(jq -c --arg n "$NODE" --arg p "${DEST#"$ROOT"/}" --argjson b "${BYTES:-0}" --arg s "$STATUS" \
    '. + [{nodeId:$n, path:$p, bytes:$b, status:$s}]' <<< "$EXPORTED")"

  if [[ "$MODE" == "asset" && "$STATUS" != "skipped-modified" ]]; then
    MANIFEST_JSON="$(jq -c --arg n "$NODE" --arg sha "$NEW_SHA" --arg p "${DEST#"$ROOT"/}" \
      --arg f "$FORMAT" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.[$n] = {sha256:$sha, path:$p, format:$f, exportedAt:$at}' <<< "$MANIFEST_JSON")"
  fi
done

if [[ -n "$MANIFEST" ]]; then
  printf '%s\n' "$(jq '.' <<< "$MANIFEST_JSON")" > "$MANIFEST"
fi

jq -n --arg mode "$MODE" --arg file "$FILE_KEY" --arg out "${OUT#"$ROOT"/}" \
  --arg format "$FORMAT" --arg scale "$SCALE" \
  --argjson exported "$EXPORTED" --argjson failed "$FAILED" \
  --arg manifest "${MANIFEST:+${MANIFEST#"$ROOT"/}}" \
  '{mode:$mode, fileId:$file, outDir:$out, format:$format,
    scale: (if $scale == "" then null else ($scale | tonumber) end),
    exported:$exported, failed:$failed,
    manifest: (if $manifest == "" then null else $manifest end)}'
