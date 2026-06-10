#!/usr/bin/env bats
# Tests for scripts/bash/figma-resolve-source.sh

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-resolve-source.sh"
  WORKSPACE="$(make_temp_workspace)"
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
