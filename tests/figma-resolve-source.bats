#!/usr/bin/env bats
# Tests for scripts/bash/figma-resolve-source.sh

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-resolve-source.sh"
  WORKSPACE="$(make_temp_workspace)"
  # Silence the Claude Code plugin advisory by default so it never pollutes the
  # JSON these tests parse; the dedicated advisory tests re-enable it explicitly.
  export FIGMA_NO_PLUGIN_ADVICE=1
}

teardown() {
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

@test "fails when the config file is missing" {
  run "$SCRIPT" "${WORKSPACE}/does-not-exist.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found"* ]]
}

@test "resolves to rest by default" {
  cat > "${WORKSPACE}/config.json" <<'JSON'
{ "figma": { "contextSource": "rest" } }
JSON
  run "$SCRIPT" "${WORKSPACE}/config.json"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.requested')" == "rest" ]]
  [[ "$(echo "$output" | jq -r '.effective')" == "rest" ]]
  [[ "$(echo "$output" | jq -r '.fellBack')" == "false" ]]
}

@test "defaults to rest when contextSource is absent" {
  cat > "${WORKSPACE}/config.json" <<'JSON'
{ "figma": { "credentials": { "source": "env" } } }
JSON
  run "$SCRIPT" "${WORKSPACE}/config.json"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.effective')" == "rest" ]]
}

@test "falls back to rest when MCP is unreachable" {
  cat > "${WORKSPACE}/config.json" <<'JSON'
{ "figma": { "contextSource": "mcp", "mcp": { "url": "http://127.0.0.1:9/mcp" } } }
JSON
  run "$SCRIPT" "${WORKSPACE}/config.json"
  [ "$status" -eq 0 ]
  json="$(echo "$output" | sed -n '/^{/,$p')"
  [[ "$(echo "$json" | jq -r '.requested')" == "mcp" ]]
  [[ "$(echo "$json" | jq -r '.effective')" == "rest" ]]
  [[ "$(echo "$json" | jq -r '.fellBack')" == "true" ]]
  [[ "$(echo "$json" | jq -r '.mcp.reachable')" == "false" ]]
}

@test "errors (effective null) when MCP unreachable and fallback disabled" {
  cat > "${WORKSPACE}/config.json" <<'JSON'
{ "figma": { "contextSource": "mcp", "mcp": { "url": "http://127.0.0.1:9/mcp", "fallbackToRest": false } } }
JSON
  run "$SCRIPT" "${WORKSPACE}/config.json"
  [ "$status" -eq 1 ]
  json="$(echo "$output" | sed -n '/^{/,$p')"
  [[ "$(echo "$json" | jq -r '.effective')" == "null" ]]
  [[ "$(echo "$json" | jq -r '.mcp.fallbackToRest')" == "false" ]]
}

@test "honors FIGMA_CONFIG when no config argument is given" {
  cat > "${WORKSPACE}/config.json" <<'JSON'
{ "figma": { "contextSource": "rest" } }
JSON
  export FIGMA_CONFIG="${WORKSPACE}/config.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.effective')" == "rest" ]]
}

@test "recommends the Figma plugin in Claude Code when it is missing" {
  cat > "${WORKSPACE}/config.json" <<'JSON'
{ "figma": { "contextSource": "rest" } }
JSON
  export CLAUDECODE=1
  unset FIGMA_NO_PLUGIN_ADVICE
  mkdir -p "${WORKSPACE}/claude-home/plugins"
  echo '{ "version": 2, "plugins": {} }' > "${WORKSPACE}/claude-home/plugins/installed_plugins.json"
  export CLAUDE_CONFIG_DIR="${WORKSPACE}/claude-home"
  run "$SCRIPT" "${WORKSPACE}/config.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"figma@claude-plugins-official"* ]]
  json="$(echo "$output" | sed -n '/^{/,$p')"
  [[ "$(echo "$json" | jq -r '.claudeCode.detected')" == "true" ]]
  [[ "$(echo "$json" | jq -r '.claudeCode.officialFigmaPlugin')" == "false" ]]
}

@test "stays quiet and reports the plugin when it is already installed" {
  cat > "${WORKSPACE}/config.json" <<'JSON'
{ "figma": { "contextSource": "rest" } }
JSON
  export CLAUDECODE=1
  unset FIGMA_NO_PLUGIN_ADVICE
  mkdir -p "${WORKSPACE}/claude-home/plugins"
  echo '{ "version": 2, "plugins": { "figma@claude-plugins-official": [] } }' \
    > "${WORKSPACE}/claude-home/plugins/installed_plugins.json"
  export CLAUDE_CONFIG_DIR="${WORKSPACE}/claude-home"
  run "$SCRIPT" "${WORKSPACE}/config.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"claude plugin install"* ]]
  [[ "$(echo "$output" | jq -r '.claudeCode.officialFigmaPlugin')" == "true" ]]
}
