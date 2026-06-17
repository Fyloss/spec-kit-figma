#!/usr/bin/env bash
# =============================================================================
# figma-parse-links.sh — extract Figma file/node references from free-form input
# =============================================================================
# Handles the case where the spec-generation input contains direct Figma links.
# Usage:
#   figma-parse-links.sh "https://www.figma.com/design/AbC123/Flow?node-id=12-345 ..."
#   echo "$INPUT" | figma-parse-links.sh
# Output: one JSON object per detected link:
#   {"fileId":"AbC123","nodeId":"12:345","kind":"design","url":"..."}
# =============================================================================
set -euo pipefail

INPUT="${*:-}"
if [[ -z "$INPUT" ]]; then
  INPUT="$(cat || true)"
fi

# Match figma.com/file/<key> and figma.com/design/<key>, with optional node-id query.
# Collect matches first so a no-match grep (exit 1) does not abort under pipefail.
LINKS="$(printf '%s' "$INPUT" \
  | grep -oE 'https?://(www\.)?figma\.com/(file|design|proto)/[A-Za-z0-9_-]+[^[:space:])"<]*' || true)"
[[ -z "$LINKS" ]] && exit 0

printf '%s\n' "$LINKS" \
  | while IFS= read -r url; do
      [[ -z "$url" ]] && continue
      kind="$(printf '%s' "$url" | sed -E 's#.*figma\.com/(file|design|proto)/.*#\1#')"
      key="$(printf '%s' "$url" | sed -E 's#.*figma\.com/(file|design|proto)/([A-Za-z0-9_-]+).*#\2#')"
      node="$(printf '%s' "$url" | grep -oE 'node-id=[0-9]+[-:%][0-9A-Za-z]+' | head -n1 | sed -E 's/node-id=//; s/%3A/:/I; s/-/:/' || true)"
      jq -n --arg f "$key" --arg n "${node:-}" --arg k "$kind" --arg u "$url" \
        '{fileId:$f, nodeId:(if $n=="" then null else $n end), kind:$k, url:$u}'
    done
