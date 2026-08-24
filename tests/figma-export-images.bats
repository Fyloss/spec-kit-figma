#!/usr/bin/env bats
# Tests for scripts/bash/figma-export-images.sh (preview + asset export).

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-export-images.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  export SPECIFY_FEATURE="001-checkout"
}

teardown() {
  stop_mock_figma
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

# `run` merges stderr into $output; the JSON report is the trailing object.
status_json() {
  echo "$output" | sed -n '/^{/,$p'
}

@test "preview mode writes beside the spec, where a reviewer can see it" {
  # .figma/cache/ is git-ignored: a preview written there renders as a broken
  # image in the spec.md a reviewer reads on GitHub.
  start_mock_figma
  run "$SCRIPT" --file ABC123 --node 12:345
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.mode')" == "preview" ]]
  [[ "$(status_json | jq -r '.outDir')" == "specs/001-checkout/assets" ]]
  [ -f "${WORKSPACE}/specs/001-checkout/assets/12_345.png" ]
  [[ "$(status_json | jq -r '.exported[0].status')" == "written" ]]
}

@test "the URL form of a node id is canonicalized, not rejected downstream" {
  start_mock_figma
  run "$SCRIPT" --file ABC123 --node 12-345
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.exported[0].nodeId')" == "12:345" ]]
}

@test "asset mode refuses to guess where a shipped asset belongs" {
  start_mock_figma
  run "$SCRIPT" --file ABC123 --node 12:345 --mode asset
  [ "$status" -eq 1 ]
  [[ "$output" == *"--out"* ]]
}

@test "asset mode defaults to svg and records a manifest" {
  start_mock_figma
  run "$SCRIPT" --file ABC123 --node 12:345 --mode asset --out "${WORKSPACE}/src/assets"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.format')" == "svg" ]]
  [ -f "${WORKSPACE}/src/assets/12_345.svg" ]
  manifest="${WORKSPACE}/src/assets/.figma-assets.json"
  [ -f "$manifest" ]
  [[ "$(jq -r '."12:345".format' "$manifest")" == "svg" ]]
  [[ "$(jq -r '."12:345".sha256 | length' "$manifest")" == "64" ]]
}

@test "a re-export of an unchanged node rewrites nothing" {
  start_mock_figma
  "$SCRIPT" --file ABC123 --node 12:345 --mode asset --out "${WORKSPACE}/src/assets" >/dev/null
  run "$SCRIPT" --file ABC123 --node 12:345 --mode asset --out "${WORKSPACE}/src/assets"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.exported[0].status')" == "unchanged" ]]
}

@test "a hand-edited asset is never silently overwritten" {
  # Destroying a designer's or developer's manual edit with no trace is worse
  # than a stale asset, so the export yields and says so.
  start_mock_figma
  "$SCRIPT" --file ABC123 --node 12:345 --mode asset --out "${WORKSPACE}/src/assets" >/dev/null
  echo "hand edited" > "${WORKSPACE}/src/assets/12_345.svg"
  run "$SCRIPT" --file ABC123 --node 12:345 --mode asset --out "${WORKSPACE}/src/assets"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.exported[0].status')" == "skipped-modified" ]]
  [[ "$(cat "${WORKSPACE}/src/assets/12_345.svg")" == "hand edited" ]]
  [[ "$output" == *"--force"* ]]
}

@test "--force overwrites a hand-edited asset on purpose" {
  start_mock_figma
  "$SCRIPT" --file ABC123 --node 12:345 --mode asset --out "${WORKSPACE}/src/assets" >/dev/null
  echo "hand edited" > "${WORKSPACE}/src/assets/12_345.svg"
  run "$SCRIPT" --file ABC123 --node 12:345 --mode asset --out "${WORKSPACE}/src/assets" --force
  [[ "$(status_json | jq -r '.exported[0].status')" == "written" ]]
  [[ "$(cat "${WORKSPACE}/src/assets/12_345.svg")" != "hand edited" ]]
}

@test "the PAT is never sent to the rendered image URL" {
  # The render URL is a signed CDN link, not a Figma API endpoint. Attaching the
  # token there would leak a credential to a third-party host.
  start_mock_figma
  "$SCRIPT" --file ABC123 --node 12:345 >/dev/null
  leaked="$(curl -fsS "http://127.0.0.1:${MOCK_PORT}/leaked" | jq -r '.leaked | length')"
  [ "$leaked" -eq 0 ]
}

@test "a node Figma cannot render is reported, not silently missing" {
  start_mock_figma "99:999"
  run "$SCRIPT" --file ABC123 --node 12:345 --node 99:999
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.exported | length')" == "1" ]]
  [[ "$(status_json | jq -r '.failed[0].nodeId')" == "99:999" ]]
  [[ "$(status_json | jq -r '.failed[0].reason')" == "no-image-returned" ]]
}

@test "ids are requested in batches, so a big file does not time out" {
  start_mock_figma
  run "$SCRIPT" --file ABC123 --node 1:1 --node 1:2 --node 1:3 --batch-size 2
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.exported | length')" == "3" ]]
}

@test "scale is dropped for vector formats rather than sent and rejected" {
  start_mock_figma
  run "$SCRIPT" --file ABC123 --node 12:345 --format svg --scale 3
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.scale')" == "null" ]]
}

@test "invalid arguments are rejected before any network call" {
  run "$SCRIPT" --node 12:345
  [ "$status" -eq 1 ]
  run "$SCRIPT" --file ABC123
  [ "$status" -eq 1 ]
  run "$SCRIPT" --file ABC123 --node 12:345 --mode nope
  [ "$status" -eq 1 ]
  run "$SCRIPT" --file ABC123 --node 12:345 --format gif
  [ "$status" -eq 1 ]
  run "$SCRIPT" --file ABC123 --node 12:345 --scale 99
  [ "$status" -eq 1 ]
  run "$SCRIPT" --file ABC123 --node "not a node"
  [ "$status" -eq 1 ]
}
