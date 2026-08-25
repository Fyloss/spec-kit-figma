#!/usr/bin/env bash
# =============================================================================
# figma-introspect.sh — autonomous page/frame enumeration for a Figma file
# =============================================================================
# Fetches the file structure (pages and top-level frames) and writes a local
# cache snapshot the agent can reason over. Supports autonomous discovery at
# three levels of the Figma hierarchy (organization > team > project > file):
#   - a whole team    (--team)    -> enumerate every project, then every file
#   - a whole project (--project) -> enumerate every file
#   - a single file   (--file)    -> introspect pages and frames
# No per-page human confirmation is required for autonomous traversal.
#
# Usage:
#   figma-introspect.sh --file <fileKey> [--node <id> ...] [--depth N] [--config <path>]
#   figma-introspect.sh --project <projectId> [--config <path>]
#   figma-introspect.sh --team <teamId> [--team <teamId> ...] [--config <path>]
# --config points at a custom figma.projects.config.json (defaults to
# $FIGMA_CONFIG, then <root>/figma.projects.config.json) — same contract as the
# sibling validate/detect/resolve scripts.
# Output: writes <root>/.figma/cache/context-snapshot.json and prints an index.
#
# API responses are staged in temp files and handed to jq via --slurpfile:
# real Figma files easily exceed the kernel's per-argument size limit, so they
# must never be passed as --argjson argv strings.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

FILE_KEY=""
PROJECT_ID=""
DEPTH="2"
NODES=()
TEAMS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE_KEY="$2"; shift 2 ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --team) TEAMS+=("$2"); shift 2 ;;
    --node) NODES+=("$2"); shift 2 ;;
    --depth) DEPTH="$2"; shift 2 ;;
    --config) FIGMA_CONFIG="$2"; export FIGMA_CONFIG; shift 2 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

# Crash early: validate every argument before any network call.
if [[ -z "$FILE_KEY" && -z "$PROJECT_ID" && ${#TEAMS[@]} -eq 0 ]]; then
  echo "ERROR: one of --file <fileKey>, --project <projectId> or --team <teamId> is required" >&2
  exit 1
fi
if [[ ! "$DEPTH" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --depth must be a positive integer (got '${DEPTH}')" >&2
  exit 1
fi
if [[ -n "${FIGMA_CONFIG:-}" && ! -f "$FIGMA_CONFIG" ]]; then
  echo "ERROR: config not found: $FIGMA_CONFIG" >&2
  exit 1
fi
# Canonicalize every --node here rather than trusting the caller: an agent that
# copies the id out of a deep link hands over the URL form ('12-345'), sometimes
# with the tracking suffix still attached. The API answers such a request with an
# empty node set, which surfaces downstream (and in MCP servers) as the
# misleading "the provided node ID was not found in the file".
if [[ ${#NODES[@]} -gt 0 ]]; then
  NORMALIZED_NODES=()
  for RAW_NODE in "${NODES[@]}"; do
    if CANONICAL_NODE="$(figma_normalize_node_id "$RAW_NODE")"; then
      NORMALIZED_NODES+=("$CANONICAL_NODE")
    else
      echo "ERROR: --node '${RAW_NODE}' is not a Figma node id. Expected '12:345' (the URL form 'node-id=12-345' is accepted), or 'I12:345;678:901' for a nested instance." >&2
      exit 1
    fi
  done
  NODES=("${NORMALIZED_NODES[@]}")
fi

CACHE="$(figma_cache_path)"
mkdir -p "$(dirname "$CACHE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
# Level 1 — Teams: enumerate every project of every team, then every file.
# Builds a nested teams[] -> projects[] -> files[] index
# (organization > team > project > file).
# -----------------------------------------------------------------------------
TEAMS_FILE="$WORK/teams.json"
printf 'null' > "$TEAMS_FILE"
if [[ ${#TEAMS[@]} -gt 0 ]]; then
  echo "INFO: enumerating projects/files for ${#TEAMS[@]} team(s)..." >&2
  : > "$WORK/teams.ndjson"
  for TEAM in "${TEAMS[@]}"; do
    echo "INFO:   team ${TEAM} -> listing projects..." >&2
    figma_api "/teams/${TEAM}/projects" > "$WORK/team-projects.json"
    TEAM_NAME="$(jq -r '.name // empty' "$WORK/team-projects.json")"
    : > "$WORK/projects.ndjson"
    while IFS=$'\t' read -r PID PNAME; do
      [[ -n "$PID" ]] || continue
      echo "INFO:     project ${PID} (${PNAME}) -> listing files..." >&2
      figma_api "/projects/${PID}/files" > "$WORK/project-files.json"
      jq -c --arg id "$PID" --arg name "$PNAME" \
        '{id: $id, name: $name, files: [ .files[]? | {key, name, lastModified: .last_modified} ]}' \
        "$WORK/project-files.json" >> "$WORK/projects.ndjson"
    done < <(jq -r '.projects[]? | "\(.id)\t\(.name)"' "$WORK/team-projects.json")
    jq -c -s --arg id "$TEAM" --arg name "$TEAM_NAME" \
      '{id: $id, name: (if $name == "" then null else $name end), projects: .}' \
      "$WORK/projects.ndjson" >> "$WORK/teams.ndjson"
  done
  jq -s '.' "$WORK/teams.ndjson" > "$TEAMS_FILE"
  # Default to the first discovered file when none was explicitly given.
  if [[ -z "$FILE_KEY" && -z "$PROJECT_ID" ]]; then
    FILE_KEY="$(jq -r '[ .[].projects[].files[].key ] | .[0] // empty' "$TEAMS_FILE")"
  fi
fi

# -----------------------------------------------------------------------------
# Level 2 — Project: enumerate all files of a single Figma project.
# -----------------------------------------------------------------------------
if [[ -n "$PROJECT_ID" ]]; then
  echo "INFO: enumerating files for project ${PROJECT_ID}..." >&2
  figma_api "/projects/${PROJECT_ID}/files" > "$WORK/single-project-files.json"
  jq -r '.files[] | "\(.key)\t\(.name)"' "$WORK/single-project-files.json"
  if [[ -z "$FILE_KEY" ]]; then
    # Default to the first file when none was explicitly given.
    FILE_KEY="$(jq -r '.files[0].key // empty' "$WORK/single-project-files.json")"
  fi
fi

# Resolve the effective design-context engine (REST by default; MCP when reachable,
# otherwise transparent REST fallback). This script IS the portable REST engine, so
# it always produces a REST snapshot — but it records the effective engine so the
# agent knows whether richer MCP context is additionally available for this run.
# When contextSource='mcp' is required but the server is unreachable and
# mcp.fallbackToRest=false, figma_resolve_context_source exits non-zero: propagate
# that hard error instead of silently degrading to REST.
CONTEXT_SOURCE="$(figma_resolve_context_source)"
echo "INFO: design-context engine = ${CONTEXT_SOURCE}" >&2

# -----------------------------------------------------------------------------
# Level 3 — File: introspect pages and top-level frames of the resolved file.
# When a team/project was enumerated but yielded no file, the snapshot still
# carries the team/project index so the agent can pick a file to drill into.
# -----------------------------------------------------------------------------
FILE_FILE="$WORK/file.json"
NODES_FILE="$WORK/nodes.json"
SOURCES_FILE="$WORK/sources.json"
printf 'null' > "$FILE_FILE"
printf 'null' > "$NODES_FILE"
printf 'null' > "$SOURCES_FILE"
if [[ -n "$FILE_KEY" ]]; then
  echo "INFO: introspecting file ${FILE_KEY} at depth ${DEPTH}..." >&2
  figma_api "/files/${FILE_KEY}?depth=${DEPTH}" > "$FILE_FILE"

  # Optionally enrich with specific node detail (e.g. from parsed Figma links).
  if [[ ${#NODES[@]} -gt 0 ]]; then
    IDS="$(IFS=, ; echo "${NODES[*]}")"
    # ';' chains the segments of a nested-instance id ('I12:345;678:901') and is
    # also a legal query sub-delimiter that some stacks still parse as a second
    # parameter separator — which would truncate the id server-side and return no
    # node for it. Downstream, a linked node absent from the snapshot never
    # satisfies snapshot_covers_links, so the hook would re-introspect forever
    # instead of ever reaching 'fresh'. Percent-encode it so the id arrives whole.
    IDS="${IDS//;/%3B}"
    figma_api "/files/${FILE_KEY}/nodes?ids=${IDS}" > "$NODES_FILE"

    # -------------------------------------------------------------------------
    # Source components. A linked node is almost always an INSTANCE, and an
    # instance is the FLATTENED rendering of a main component: its overrides are
    # applied, its variant is fixed, and the definition an implementation should
    # be written against lives elsewhere in the file (or in a library). Reading
    # the instance is how a spec ends up describing one particular appearance of
    # a component rather than the component.
    #
    # This is the "right-click > show source" step, automated: collect the
    # componentId of every INSTANCE in the fetched subtrees and deep-fetch those
    # definitions too, into a separate `sources` slot so the agent can tell a
    # definition from a rendering.
    COMPONENT_IDS_FILE="$WORK/component-ids.txt"
    jq -r '
      def collect: [ .. | objects | select(.type? == "INSTANCE") | .componentId? | select(. != null) ];
      [ (.nodes // {}) | .[] | .document | collect ] | flatten | unique | .[]
    ' "$NODES_FILE" 2>/dev/null | head -n 50 > "$COMPONENT_IDS_FILE" || true

    if [[ -s "$COMPONENT_IDS_FILE" ]]; then
      SRC_IDS="$(paste -sd, "$COMPONENT_IDS_FILE")"
      SRC_IDS="${SRC_IDS//;/%3B}"
      echo "INFO: resolving $(wc -l < "$COMPONENT_IDS_FILE" | tr -d ' ') source component(s) behind the linked instance(s)..." >&2
      # Non-fatal on purpose: a missing source degrades the context, it does not
      # invalidate it, and the linked nodes are already in hand.
      if ! figma_api "/files/${FILE_KEY}/nodes?ids=${SRC_IDS}" > "$SOURCES_FILE" 2>/dev/null; then
        echo "WARN: could not resolve the source components; the snapshot keeps the instances only." >&2
        printf 'null' > "$SOURCES_FILE"
      fi

      # -----------------------------------------------------------------------
      # Cross-file resolution. A componentId still missing from the response
      # above is almost always a component published from ANOTHER file — a
      # Design System library, another project, another team. Node ids are
      # file-scoped, so the same-file lookup can never find it. Figma's own
      # component registry can, regardless of where that file actually is:
      # every component this file references carries a published `key`
      # (already captured in `$f.components`), and `GET /v1/components/{key}`
      # answers with the file that owns it — no config has to name that file
      # up front, and the same lookup works whether the source is the Design
      # System or anything else.
      MISSING_IDS_FILE="$WORK/missing-component-ids.txt"
      jq -r --rawfile ids "$COMPONENT_IDS_FILE" '
        ($ids | rtrimstr("\n") | split("\n") | map(select(length > 0))) as $all
        | ((.nodes // {}) | with_entries(select(.value != null)) | keys) as $found
        | ($all - $found)[]
      ' "$SOURCES_FILE" > "$MISSING_IDS_FILE" 2>/dev/null || true

      if [[ -s "$MISSING_IDS_FILE" ]]; then
        echo "INFO: $(wc -l < "$MISSING_IDS_FILE" | tr -d ' ') source component(s) not in this file; checking the Figma component registry for their owning file..." >&2
        : > "$WORK/external-sources.ndjson"
        while IFS= read -r CID; do
          [[ -n "$CID" ]] || continue
          KEY="$(jq -r --arg id "$CID" '(.components[$id].key // empty)' "$FILE_FILE" 2>/dev/null)"
          if [[ -z "$KEY" ]]; then
            echo "WARN: no published key for component ${CID}; cannot locate its owning file." >&2
            continue
          fi
          META_FILE="$WORK/component-meta.json"
          if ! figma_api "/components/${KEY}" > "$META_FILE" 2>/dev/null; then
            echo "WARN: could not resolve the owning file of component ${CID} (key ${KEY})." >&2
            continue
          fi
          EXT_FILE_KEY="$(jq -r '.meta.file_key // empty' "$META_FILE" 2>/dev/null)"
          EXT_NODE_ID="$(jq -r '.meta.node_id // empty' "$META_FILE" 2>/dev/null)"
          if [[ -z "$EXT_FILE_KEY" || -z "$EXT_NODE_ID" ]]; then
            echo "WARN: component ${CID} (key ${KEY}) has no resolvable owning file." >&2
            continue
          fi
          EXT_NODE_ID_ENC="${EXT_NODE_ID//;/%3B}"
          EXT_NODE_FILE="$WORK/external-node.json"
          if ! figma_api "/files/${EXT_FILE_KEY}/nodes?ids=${EXT_NODE_ID_ENC}" > "$EXT_NODE_FILE" 2>/dev/null; then
            echo "WARN: could not fetch component ${CID} from its owning file ${EXT_FILE_KEY}." >&2
            continue
          fi
          jq -c --arg cid "$CID" --arg file "$EXT_FILE_KEY" --arg node "$EXT_NODE_ID" '
            (.nodes[$node] // null) as $doc
            | if $doc == null then empty else { id: $cid, fileKey: $file, node: $doc } end
          ' "$EXT_NODE_FILE" >> "$WORK/external-sources.ndjson" 2>/dev/null || true
        done < "$MISSING_IDS_FILE"

        # Merge the cross-file finds into SOURCES_FILE's .nodes, keyed by the
        # ORIGINAL componentId — so figma-extract-values.sh keeps matching
        # instance.componentId -> sources.nodes[componentId] unchanged — and
        # record which file each came from in a sibling `externalFiles` map.
        if [[ -s "$WORK/external-sources.ndjson" ]]; then
          jq -s '.' "$WORK/external-sources.ndjson" > "$WORK/external-sources.json"
          jq -s '
            (.[0] // {}) as $base
            | (.[1]) as $extra
            | $base + {
                nodes: ( ($base.nodes // {}) + ( $extra | map({(.id): .node}) | add // {} ) ),
                externalFiles: ( ($base.externalFiles // {}) + ( $extra | map({(.id): .fileKey}) | add // {} ) )
              }
          ' "$SOURCES_FILE" "$WORK/external-sources.json" > "$WORK/sources-merged.json"
          mv "$WORK/sources-merged.json" "$SOURCES_FILE"
        fi
      fi
    fi
  fi
else
  echo "WARN: no file resolved from the team/project enumeration; snapshot will contain the project index only." >&2
fi

jq -n \
  --arg file "${FILE_KEY:-}" \
  --arg project "${PROJECT_ID:-}" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg context_source "$CONTEXT_SOURCE" \
  --slurpfile file_json "$FILE_FILE" \
  --slurpfile nodes_json "$NODES_FILE" \
  --slurpfile sources_json "$SOURCES_FILE" \
  --slurpfile teams_json "$TEAMS_FILE" \
  '$file_json[0] as $f
   | {
     fileId: (if $file == "" then null else $file end),
     projectId: (if $project == "" then null else $project end),
     teams: $teams_json[0],
     contextSource: $context_source,
     generatedAt: $generated,
     lastModified: ($f.lastModified // null),
     version: ($f.version // null),
     pages: (if $f == null then [] else [ $f.document.children[]? | { id, name, frames: [ (.children[]? | select(.type == "FRAME") | {id, name, type}) ] } ] end),
     components: ($f.components // null),
     componentSets: ($f.componentSets // null),
     styles: ($f.styles // null),
     nodes: $nodes_json[0],
     sources: $sources_json[0]
   }' > "$CACHE"

echo "INFO: snapshot written to ${CACHE}" >&2

# Keep a copy keyed by file so a later run for THIS file can be answered from
# cache instead of re-fetching. The current slot is a single one: without the
# store, alternating between two features that target different Figma files
# evicts the snapshot every time and the "fresh" path never hits. Copying (not
# moving) keeps the well-known path authoritative for the agent.
if [[ -n "$FILE_KEY" ]] && STORE="$(figma_snapshot_store_path "$FILE_KEY")"; then
  mkdir -p "$(dirname "$STORE")"
  cp "$CACHE" "$STORE" 2>/dev/null || echo "WARN: could not keep a per-file copy of the snapshot at ${STORE}." >&2
fi

if [[ ${#TEAMS[@]} -gt 0 ]]; then
  echo "----- TEAM / PROJECT / FILE INDEX -----"
  jq -r '
    .teams[]?
    | "team \(.id) \(if .name then "(" + .name + ")" else "" end)",
      ( .projects[]?
        | "  project \(.id) (\(.name)) — \(.files | length) file(s)",
          ( .files[]? | "    \(.key)\t\(.name)" )
      )
  ' "$CACHE"
fi

if [[ -n "$FILE_KEY" ]]; then
  echo "----- PAGE INDEX -----"
  jq -r '.pages[] | "\(.id)\t\(.name)\t(\(.frames | length) frames)"' "$CACHE"
fi
