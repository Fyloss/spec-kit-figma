#!/usr/bin/env bats
# Tests for scripts/bash/figma-detect-target.sh

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-detect-target.sh"
  MULTI="${FIXTURES_DIR}/multirepo-valid.json"
  MONO="${FIXTURES_DIR}/monorepo-valid.json"
  SINGLE="${FIXTURES_DIR}/singlerepo-valid.json"
  ORG="${FIXTURES_DIR}/organization-valid.json"
}

@test "multi-repo: excluded target is silently disabled" {
  run "$SCRIPT" back-bff "$MULTI"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "false" ]]
  [[ "$(echo "$output" | jq -r '.reason')" == "excluded" ]]
}

@test "multi-repo: mapped and enabled target" {
  run "$SCRIPT" design-system "$MULTI"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
  [[ "$(echo "$output" | jq -r '.reason')" == "mapped" ]]
  [[ "$(echo "$output" | jq -r '.figmaFileId')" == "abc123DESIGN" ]]
  [[ "$(echo "$output" | jq -r '.role')" == "design-system" ]]
}

@test "multi-repo: mapped but disabled target" {
  run "$SCRIPT" storefront "$MULTI"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "false" ]]
  [[ "$(echo "$output" | jq -r '.reason')" == "disabled" ]]
}

@test "multi-repo: unknown target is not-mapped" {
  run "$SCRIPT" totally-unknown "$MULTI"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "false" ]]
  [[ "$(echo "$output" | jq -r '.reason')" == "not-mapped" ]]
}

@test "mono-repo: an app package resolves to the repo" {
  run "$SCRIPT" app-storefront "$MONO"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
  [[ "$(echo "$output" | jq -r '.figmaFileId')" == "mono123FILE" ]]
}

@test "mono-repo: a lib package resolves to the repo" {
  run "$SCRIPT" design-system "$MONO"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
}

@test "mono-repo: excluded package is disabled" {
  run "$SCRIPT" app-bff "$MONO"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.reason')" == "excluded" ]]
}

@test "mono-repo: the literal 'repo' target resolves to the repo" {
  run "$SCRIPT" repo "$MONO"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
}

@test "single-repo: any target resolves to the single repo" {
  run "$SCRIPT" my-storefront "$SINGLE"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
  [[ "$(echo "$output" | jq -r '.reason')" == "mapped" ]]
  [[ "$(echo "$output" | jq -r '.figmaFileId')" == "single123FILE" ]]
  [[ "$(echo "$output" | jq -r '.role')" == "app" ]]
}

@test "single-repo: the literal 'repo' target resolves to the repo" {
  run "$SCRIPT" repo "$SINGLE"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
}

@test "fails when the config file is missing" {
  run "$SCRIPT" some-target "${FIXTURES_DIR}/does-not-exist.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found"* ]]
}

@test "fails when no target argument is given" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "team-based: exposes a single figmaTeamId" {
  run "$SCRIPT" design-system "$ORG"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
  [[ "$(echo "$output" | jq -r '.figmaTeamId')" == "111222333" ]]
  [[ "$(echo "$output" | jq -r '.figmaFileId')" == "null" ]]
}

@test "team-based: exposes a figmaTeamIds array" {
  run "$SCRIPT" storefront "$ORG"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
  [[ "$(echo "$output" | jq -r '.figmaTeamIds | length')" == "2" ]]
  [[ "$(echo "$output" | jq -r '.figmaTeamIds[0]')" == "444555666" ]]
}

@test "honors FIGMA_CONFIG when no config argument is given" {
  export FIGMA_CONFIG="$SINGLE"
  run "$SCRIPT" repo
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.enabled')" == "true" ]]
  [[ "$(echo "$output" | jq -r '.reason')" == "mapped" ]]
}
