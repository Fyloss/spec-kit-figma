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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"

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
      # Take the whole node-id value (up to the next parameter or fragment) and
      # let figma_normalize_node_id canonicalize it: the tracking suffix Figma
      # appends (&t=…) must not leak into the id, and nested-instance ids carry
      # several separators. The '&' separator is matched through any number of
      # 'amp;' escapes: input pasted from a rich-text source (Jira, Confluence,
      # an HTML email) arrives as '&amp;node-id=…', and requiring a bare '&'
      # would silently downgrade a pinned frame to a broad link.
      # An unrecognized value yields null — the caller then treats the link as
      # broad and asks which frame, which is safer than forwarding an id the
      # API/MCP server will reject.
      raw_node="$(printf '%s' "$url" | grep -oE '[?&](amp;)*node-id=[^&#[:space:]]+' | head -n1 | sed -E 's/^[?&](amp;)*node-id=//' || true)"
      node="$(figma_normalize_node_id "$raw_node" || true)"
      jq -n --arg f "$key" --arg n "${node:-}" --arg k "$kind" --arg u "$url" \
        '{fileId:$f, nodeId:(if $n=="" then null else $n end), kind:$k, url:$u}'
    done
