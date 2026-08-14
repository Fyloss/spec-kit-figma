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

@test "decodes a lower-case url-encoded node-id (%3a)" {
  run "$SCRIPT" "https://www.figma.com/design/AbC123/Flow?node-id=12%3a345"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "12:345" ]]
}

@test "ignores the tracking suffix that Figma appends after the node-id" {
  run "$SCRIPT" "https://www.figma.com/design/AbC123/Flow?node-id=12-345&t=Xy9Z-4"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "12:345" ]]
}

@test "normalizes an instance node-id (I-prefixed, ';'-chained)" {
  # "Copy link to selection" on a nested instance yields I<a>-<b>%3B<c>-<d>.
  # MCP servers and the REST API expect I<a>:<b>;<c>:<d> — a partially
  # normalized id is reported as "node not found in the file".
  run "$SCRIPT" "https://www.figma.com/design/AbC123/Flow?node-id=I123-456%3B789-012"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "I123:456;789:012" ]]
}

@test "normalizes every separator of a chained node-id, not just the first" {
  run "$SCRIPT" "https://www.figma.com/design/AbC123/Flow?node-id=1-2%3B3-4"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "1:2;3:4" ]]
}

@test "parses a node-id behind an HTML-escaped ampersand (&amp;)" {
  # Feature input pasted from a rich-text source (Jira, Confluence, an HTML
  # email) carries the separators escaped, so the character before 'node-id'
  # is ';' rather than '&'. Anchoring on '&' alone silently drops the id and
  # the pinned frame degrades to a broad link.
  run "$SCRIPT" "https://www.figma.com/design/AbC123/Flow?type=design&amp;node-id=12-345&amp;m=dev"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "12:345" ]]
}

@test "reports a malformed node-id as null instead of forwarding it" {
  # Better a broad link (the agent asks which frame) than a bogus id that the
  # MCP server rejects with "the node may have been deleted".
  run "$SCRIPT" "https://www.figma.com/design/AbC123/Flow?node-id=not-a-node"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "null" ]]
}

@test "parses a proto link" {
  run "$SCRIPT" "https://www.figma.com/proto/PrOtO1/Demo"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.kind')" == "proto" ]]
  [[ "$(echo "$output" | jq -r '.fileId')" == "PrOtO1" ]]
  [[ "$(echo "$output" | jq -r '.startNodeId')" == "null" ]]
}

@test "a prototype link keeps the flow start alongside the viewed frame" {
  # A prototype URL carries TWO frames: node-id is whatever the designer was
  # looking at when they copied the link, starting-point-node-id is the entry
  # point of the flow. Dropping the latter leaves the snapshot without the
  # frame the parcours actually starts from.
  run "$SCRIPT" "https://www.figma.com/proto/PrOtO1/Demo?page-id=0%3A1&node-id=12-345&starting-point-node-id=1%3A2&t=Xy9Z-4"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "12:345" ]]
  [[ "$(echo "$output" | jq -r '.startNodeId')" == "1:2" ]]
}

@test "a prototype link with only a starting point still pins that frame" {
  # Hand-trimmed and embed URLs drop node-id; without the fallback the link
  # degrades to 'broad' and the agent has to ask which frame — although the
  # URL names it.
  run "$SCRIPT" "https://www.figma.com/proto/PrOtO1/Demo?starting-point-node-id=1%3A2"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "null" ]]
  [[ "$(echo "$output" | jq -r '.startNodeId')" == "1:2" ]]
}

@test "a malformed starting-point-node-id is reported as null, never forwarded" {
  run "$SCRIPT" "https://www.figma.com/proto/PrOtO1/Demo?starting-point-node-id=nope"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.startNodeId')" == "null" ]]
}

@test "starting-point-node-id is not mistaken for node-id" {
  # '&starting-point-node-id=' ends with the literal 'node-id=' — a regex
  # anchored loosely would read the flow start as the viewed frame.
  run "$SCRIPT" "https://www.figma.com/proto/PrOtO1/Demo?starting-point-node-id=1%3A2&node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodeId')" == "12:345" ]]
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
