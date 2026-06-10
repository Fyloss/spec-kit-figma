#!/usr/bin/env bats
# Tests for scripts/bash/figma-validate-config.sh

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-validate-config.sh"
}

@test "accepts a valid multi-repo config" {
  run "$SCRIPT" "${FIXTURES_DIR}/multirepo-valid.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is valid"* ]]
  [[ "$output" == *"mode=multi-repo"* ]]
}

@test "accepts a valid mono-repo config" {
  run "$SCRIPT" "${FIXTURES_DIR}/monorepo-valid.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=mono-repo"* ]]
  [[ "$output" == *"credentials.source=ci-secret"* ]]
}

@test "accepts a valid single-repo config" {
  run "$SCRIPT" "${FIXTURES_DIR}/singlerepo-valid.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is valid"* ]]
  [[ "$output" == *"mode=single-repo"* ]]
}

@test "fails when the config file is missing" {
  run "$SCRIPT" "${FIXTURES_DIR}/does-not-exist.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found"* ]]
}

@test "fails on malformed JSON" {
  run "$SCRIPT" "${FIXTURES_DIR}/not-json.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "fails on an unknown mode" {
  run "$SCRIPT" "${FIXTURES_DIR}/invalid-mode.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be 'single-repo', 'mono-repo' or 'multi-repo'"* ]]
}

@test "exits 2 on an unresolved REPLACE_WITH_ placeholder" {
  run "$SCRIPT" "${FIXTURES_DIR}/unresolved-placeholder.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unresolved Figma id placeholder"* ]]
}

@test "accepts a team-based config (figmaTeamId / figmaTeamIds)" {
  run "$SCRIPT" "${FIXTURES_DIR}/organization-valid.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is valid"* ]]
  [[ "$output" == *"mode=multi-repo"* ]]
}

@test "exits 2 on an unresolved placeholder inside figmaTeamIds" {
  run "$SCRIPT" "${FIXTURES_DIR}/unresolved-team-placeholder.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unresolved Figma id placeholder"* ]]
}

@test "rejects an inline token field" {
  run "$SCRIPT" "${FIXTURES_DIR}/inline-token.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"secret-looking field"* ]]
}

@test "rejects an invalid credentials.source" {
  run "$SCRIPT" "${FIXTURES_DIR}/bad-credentials-source.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"credentials.source must be 'env' or 'ci-secret'"* ]]
}

@test "rejects an invalid contextSource" {
  run "$SCRIPT" "${FIXTURES_DIR}/bad-context-source.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contextSource must be 'rest' or 'mcp'"* ]]
}

@test "reports contextSource in the success line" {
  run "$SCRIPT" "${FIXTURES_DIR}/singlerepo-valid.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"contextSource=rest"* ]]
}

@test "rejects a target missing the required enabled/role fields" {
  run "$SCRIPT" "${FIXTURES_DIR}/missing-target-fields.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"enabled"* ]]
  [[ "$output" == *"role"* ]]
}

@test "rejects a target without any figma id" {
  run "$SCRIPT" "${FIXTURES_DIR}/missing-figma-id.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"at least one of"* ]]
}

@test "accepts a Figma page named 'token' in pageToPackageMapping" {
  run "$SCRIPT" "${FIXTURES_DIR}/page-named-token.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is valid"* ]]
}
