#!/usr/bin/env bash
# =============================================================================
# figma-resolve-source.sh — resolve the effective design-context engine
# =============================================================================
# Decides which engine the agent should use for this run:
#   - "rest" (default): portable, CI-friendly (curl + jq against the REST API).
#   - "mcp": a Model Context Protocol Figma server, when reachable.
# When contextSource = "mcp" but the MCP server is unreachable, it transparently
# falls back to "rest" (unless mcp.fallbackToRest = false, which is a hard error).
#
# Usage: figma-resolve-source.sh [path/to/figma.projects.config.json]
# Prints a JSON object on stdout:
#   { "requested": "rest|mcp", "effective": "rest|mcp",
#     "fellBack": true|false,
#     "mcp": { "url": "...", "reachable": true|false, "fallbackToRest": true|false },
#     "claudeCode": { "detected": true|false, "officialFigmaPlugin": true|false } }
# When running in Claude Code without a Figma plugin, a recommendation to install
# `figma@claude-plugins-official` is also printed to stderr (see
# figma_claude_plugin_advice; silence with FIGMA_NO_PLUGIN_ADVICE=1).
# Exit codes: 0 = resolved, 1 = MCP required but unreachable (fallback disabled).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./figma-common.sh
source "${SCRIPT_DIR}/figma-common.sh"
figma_require jq

CONFIG="${1:-$(figma_default_config)}"
figma_check_config "$CONFIG" || exit 1

REQUESTED="$(figma_context_source "$CONFIG")"
MCP_URL="$(figma_mcp_url "$CONFIG")"
FALLBACK="false"; figma_mcp_fallback_enabled "$CONFIG" && FALLBACK="true"

REACHABLE="false"
if [[ "$REQUESTED" == "mcp" ]]; then
  if figma_mcp_available "$CONFIG"; then REACHABLE="true"; fi
fi

# Derive the effective engine from the single probe above (probing again via
# figma_resolve_context_source would block on a second timeout and could
# disagree with REACHABLE if the server flaps between probes). The decision
# table itself is shared with figma-common.sh.
if ! EFFECTIVE="$(figma_decide_context_source "$REQUESTED" "$REACHABLE" "$FALLBACK" "$MCP_URL")"; then
  jq -n \
    --arg requested "$REQUESTED" \
    --arg url "$MCP_URL" \
    --argjson reachable "$REACHABLE" \
    --argjson fallback "$FALLBACK" \
    '{requested:$requested, effective:null, fellBack:false,
      mcp:{url:$url, reachable:$reachable, fallbackToRest:$fallback}}'
  exit 1
fi

FELL_BACK="false"
[[ "$REQUESTED" == "mcp" && "$EFFECTIVE" == "rest" ]] && FELL_BACK="true"

# Claude Code advisory: surface the official Figma plugin when it would help.
# The human-readable tip goes to stderr (see figma_claude_plugin_advice); the
# JSON carries the same signal so /speckit.figma.setup can report it too.
CLAUDE_CODE="false"; figma_is_claude_code && CLAUDE_CODE="true"
FIGMA_PLUGIN="false"; figma_claude_figma_plugin_installed && FIGMA_PLUGIN="true"
figma_claude_plugin_advice

jq -n \
  --arg requested "$REQUESTED" \
  --arg effective "$EFFECTIVE" \
  --arg url "$MCP_URL" \
  --argjson reachable "$REACHABLE" \
  --argjson fallback "$FALLBACK" \
  --argjson fellBack "$FELL_BACK" \
  --argjson claudeCode "$CLAUDE_CODE" \
  --argjson figmaPlugin "$FIGMA_PLUGIN" \
  '{requested:$requested, effective:$effective, fellBack:$fellBack,
    mcp:{url:$url, reachable:$reachable, fallbackToRest:$fallback},
    claudeCode:{detected:$claudeCode, officialFigmaPlugin:$figmaPlugin}}'
