#!/usr/bin/env bash
# =============================================================================
# figma-extract-values.sh — deterministic design values from a snapshot
# =============================================================================
# The extension's own promise (see figma-render-section.sh) is that the design
# section is produced deterministically "REGARDLESS of the agent model". That was
# built for the section's STRUCTURE and never for its VALUES: the snapshot is a
# raw dump of the Figma node tree — megabytes for a full-page frame — and the
# token/spacing tables were left for the model to mine out of it. Weaker models
# do not mine megabytes of JSON; they guess. Padding, alignment and typography
# that match nothing in the mockup are the result.
#
# This script closes that gap. It walks the deep-fetched nodes and emits the
# layout and typography facts as a compact JSON digest — and, with --format
# markdown, as a table the renderer pastes straight into the section, so the
# agent copies numbers instead of inventing them.
#
# UNITS ARE ALWAYS EXPLICIT. Every length is emitted as "<n>px" and never as a
# bare number. A bare number is what lets a value be re-read as something else
# downstream: a raw 70 handed to a scale-indexed helper (Tailwind's `mt-70`, or
# MUI's `theme.spacing(70)` on a theme built with `spacing: 4`) silently becomes
# 280px. The extension's job stops at "this is 70 absolute CSS px at 1x"; HOW a
# project converts that is the project's own contract, declared in the
# `.figma/figma-design-rules.custom.md` overlay — no config here could cover
# every styling stack, and a half-covered one is worse than none.
#
# Usage:
#   figma-extract-values.sh [--snapshot <path>] [--format json|markdown]
#     [--max-rows N] [--node <id> ...]
# --node restricts the digest to the given deep-fetched nodes (repeatable);
# by default every node in `.nodes.nodes` is walked. --max-rows (default 120)
# bounds the output: past it the table is truncated with an explicit note rather
# than growing back into something nobody reads.
# Exit codes: 0 = digest emitted (possibly empty), 1 = bad args / missing snapshot.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

SNAPSHOT=""
FORMAT="json"
MAX_ROWS="120"
NODES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --max-rows) MAX_ROWS="$2"; shift 2 ;;
    --node) NODES+=("$2"); shift 2 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

case "$FORMAT" in
  json|markdown) ;;
  *) echo "ERROR: --format must be json or markdown (got '${FORMAT}')" >&2; exit 1 ;;
esac
if [[ ! "$MAX_ROWS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --max-rows must be a positive integer (got '${MAX_ROWS}')" >&2
  exit 1
fi

[[ -n "$SNAPSHOT" ]] || SNAPSHOT="$(figma_cache_path)"
if [[ ! -f "$SNAPSHOT" ]]; then
  echo "ERROR: snapshot not found: ${SNAPSHOT} (run figma-introspect.sh first)" >&2
  exit 1
fi

NODE_FILTER="[]"
if [[ ${#NODES[@]} -gt 0 ]]; then
  NODE_FILTER="$(printf '%s\n' "${NODES[@]}" | jq -R . | jq -s -c .)"
fi

# The digest. Everything below is a pure function of the snapshot, which is what
# makes the output reproducible and diffable across runs.
#
# `px` renders a length with its unit, and only when the value is a real number:
# Figma omits paddings that are zero on some node types, and a fabricated "0px"
# reads as a deliberate design decision the mockup never made.
DIGEST="$(jq -c \
  --argjson want "$NODE_FILTER" \
  --argjson maxRows "$MAX_ROWS" '
  def px: if (type == "number") then "\(. | if . == floor then floor else . end)px" else null end;
  def nonempty: with_entries(select(.value != null));

  # A node contributes a row only if it carries at least one fact worth copying.
  # Structural containers with no layout and no text would otherwise bury the
  # handful of rows that matter under hundreds of empty ones.
  def facts:
    {
      layoutMode: (.layoutMode // null),
      paddingTop: (.paddingTop | px),
      paddingRight: (.paddingRight | px),
      paddingBottom: (.paddingBottom | px),
      paddingLeft: (.paddingLeft | px),
      itemSpacing: (.itemSpacing | px),
      primaryAxisAlignItems: (.primaryAxisAlignItems // null),
      counterAxisAlignItems: (.counterAxisAlignItems // null),
      cornerRadius: (.cornerRadius | px),
      width: (.absoluteBoundingBox.width | px),
      height: (.absoluteBoundingBox.height | px),
      fontFamily: (.style.fontFamily // null),
      fontWeight: (.style.fontWeight // null),
      fontSize: (.style.fontSize | px),
      lineHeightPx: (.style.lineHeightPx | px),
      letterSpacing: (.style.letterSpacing | px),
      textAlignHorizontal: (.style.textAlignHorizontal // null),
      textAlignVertical: (.style.textAlignVertical // null),
      # Style ids are the bridge to the Design System: a node bound to a shared
      # style must map to the matching token, not to the raw value it renders.
      styles: (if (.styles // {}) == {} then null else .styles end),
      componentId: (.componentId // null)
    } | nonempty;

  def walk_node($depth; $origin):
    . as $n
    | [ { id: $n.id, name: $n.name, type: $n.type, depth: $depth,
          origin: $origin, facts: ($n | facts) } ]
      + ( ($n.children // []) | map(walk_node($depth + 1; $origin)) | add // [] );

  # Two origins, kept apart on purpose. A linked node is usually an INSTANCE —
  # the flattened rendering of a main component, with its overrides applied and
  # its variant fixed. The DEFINITION is what an implementation should be written
  # against, so introspection resolves it into `.sources` and its rows are tagged
  # "source". Merging the two would hide which numbers describe the component and
  # which describe one particular appearance of it.
  ( ( (.nodes.nodes // {}) | to_entries
      | map(select(($want | length) == 0 or (.key as $k | $want | index($k))))
      | map(.value.document // empty)
      | map(walk_node(0; "instance")) | add // [] )
    + ( (.sources.nodes // {}) | to_entries
      | map(.value.document // empty)
      | map(walk_node(0; "source")) | add // [] ) ) as $all
  | ( $all | map(select((.facts | length) > 0)) ) as $rows
  | {
      snapshotFile: (.fileId // null),
      lastModified: (.lastModified // null),
      totalNodes: ($all | length),
      rowCount: ($rows | length),
      sourceComponents: [ (.sources.externalFiles // {}) as $external
                        | (.sources.nodes // {}) | to_entries[]
                          | { id: .key, name: (.value.document.name // null),
                              type: (.value.document.type // null),
                              fileKey: ($external[.key] // null) } ],
      truncated: (($rows | length) > $maxRows),
      nodes: ($rows[:$maxRows])
    }' "$SNAPSHOT")"

if [[ "$FORMAT" == "json" ]]; then
  printf '%s\n' "$DIGEST"
  exit 0
fi

# Markdown: two tables, because layout facts and typography facts are read by
# different parts of the implementation and interleaving them makes both unusable.
printf '%s' "$DIGEST" | jq -r '
  def esc: (. // "—") | tostring | gsub("[|]"; "\\|") | gsub("[\n\r]+"; " ");
  def cell: if . == null then "—" else (. | esc) end;
  def indent($d): ("· " * (if $d > 6 then 6 else $d end));

  (.sourceComponents // []) as $sources
  | (.nodes | map(select(.facts.layoutMode or .facts.paddingTop or .facts.paddingLeft
                       or .facts.itemSpacing or .facts.width or .facts.cornerRadius))) as $layout
  | (.nodes | map(select(.facts.fontSize or .facts.textAlignHorizontal))) as $text
  | (
      ( if ($sources | length) == 0 then ""
        else
          "**Source components behind the linked instances**\n\n"
          + "| Component | Node id | File |\n|-----------|---------|------|\n"
          + ( [ $sources[] | "| \(.name | cell) | `\(.id)` | \(if .fileKey then "`\(.fileKey)` (external)" else "same file" end) |" ] | join("\n") )
          + "\n\n> Implement against the **source component**, not the instance: an instance is that component with its overrides applied and its variant fixed. Rows tagged `source` below come from the definition. A component flagged **external** was resolved from another Figma file (e.g. a Design System library) via its published component key, not from the linked file.\n\n"
        end )
      + "**Layout values (auto-filled, absolute CSS px at 1x)**\n\n"
      + ( if ($layout | length) == 0 then "_No layout value extracted — the snapshot holds no deep-fetched node._"
          else
            "| Node | Origin | Type | Direction | Padding T/R/B/L | Gap | Align (main/cross) | Radius | Size |\n"
            + "|------|--------|------|-----------|-----------------|-----|--------------------|--------|------|\n"
            + ( [ $layout[] |
                  "| \(indent(.depth))\(.name | esc) `\(.id)` | \(.origin | cell) | \(.type | cell) | \(.facts.layoutMode | cell) "
                  + "| \(.facts.paddingTop | cell) / \(.facts.paddingRight | cell) / \(.facts.paddingBottom | cell) / \(.facts.paddingLeft | cell) "
                  + "| \(.facts.itemSpacing | cell) | \(.facts.primaryAxisAlignItems | cell) / \(.facts.counterAxisAlignItems | cell) "
                  + "| \(.facts.cornerRadius | cell) | \(.facts.width | cell) × \(.facts.height | cell) |"
                ] | join("\n") )
          end )
      + "\n\n**Typography values (auto-filled, absolute CSS px at 1x)**\n\n"
      + ( if ($text | length) == 0 then "_No text node extracted._"
          else
            "| Node | Family | Weight | Size | Line height | Letter spacing | Align (h/v) |\n"
            + "|------|--------|--------|------|-------------|----------------|-------------|\n"
            + ( [ $text[] |
                  "| \(indent(.depth))\(.name | esc) `\(.id)` | \(.facts.fontFamily | cell) | \(.facts.fontWeight | cell) "
                  + "| \(.facts.fontSize | cell) | \(.facts.lineHeightPx | cell) | \(.facts.letterSpacing | cell) "
                  + "| \(.facts.textAlignHorizontal | cell) / \(.facts.textAlignVertical | cell) |"
                ] | join("\n") )
          end )
      + ( if .truncated then "\n\n> ⚠️ Truncated to \(.nodes | length) of \(.rowCount) nodes carrying values. Pin a narrower frame with a Figma node link to get the full digest."
          else "" end )
      + "\n\n> Values are **absolute CSS px at 1x**. Convert them through this project'"'"'s declared contract (`.figma/figma-design-rules.custom.md`); never pass a raw px number to a scale-indexed helper."
    )'
