#!/usr/bin/env bats
# Tests for scripts/bash/figma-parse-links.sh

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-parse-links.sh"
}

@test "parses a design link with a node-id (argument input)" {
  run "$SCRIPT" "https://www.figma.com/design/AbC123/Flow?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.fileId')" == "AbC123" ]]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "12:345" ]]
  [[ "$(echo "$output" | jq -r '.kind')" == "design" ]]
}

@test "parses a file link without a node-id (nodeId is null)" {
  run "$SCRIPT" "https://www.figma.com/file/XyZ789/MyFile"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.fileId')" == "XyZ789" ]]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "null" ]]
  [[ "$(echo "$output" | jq -r '.kind')" == "file" ]]
}

@test "decodes a url-encoded node-id (%3A)" {
  run "$SCRIPT" "https://www.figma.com/design/AbC123/Flow?node-id=12%3A345"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "12:345" ]]
}

@test "parses a proto link" {
  run "$SCRIPT" "https://www.figma.com/proto/PrOtO1/Demo"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.kind')" == "proto" ]]
  [[ "$(echo "$output" | jq -r '.fileId')" == "PrOtO1" ]]
}

@test "parses multiple links from free-form text" {
  input="see https://www.figma.com/design/AAA111/One?node-id=1-2 and https://www.figma.com/file/BBB222/Two"
  run "$SCRIPT" "$input"
  [ "$status" -eq 0 ]
  count="$(echo "$output" | jq -s 'length')"
  [ "$count" -eq 2 ]
}

@test "produces no output when there are no links" {
  run "$SCRIPT" "there is no figma link here"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reads input from stdin" {
  run bash -c "echo 'https://www.figma.com/design/Std1N/FromPipe?node-id=7-8' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.fileId')" == "Std1N" ]]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "7:8" ]]
}
