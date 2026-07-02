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
printf 'null' > "$FILE_FILE"
printf 'null' > "$NODES_FILE"
if [[ -n "$FILE_KEY" ]]; then
  echo "INFO: introspecting file ${FILE_KEY} at depth ${DEPTH}..." >&2
  figma_api "/files/${FILE_KEY}?depth=${DEPTH}" > "$FILE_FILE"

  # Optionally enrich with specific node detail (e.g. from parsed Figma links).
  if [[ ${#NODES[@]} -gt 0 ]]; then
    IDS="$(IFS=, ; echo "${NODES[*]}")"
    figma_api "/files/${FILE_KEY}/nodes?ids=${IDS}" > "$NODES_FILE"
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
     nodes: $nodes_json[0]
   }' > "$CACHE"

echo "INFO: snapshot written to ${CACHE}" >&2

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
