#!/usr/bin/env bats
# Tests for scripts/bash/figma-extract-values.sh (deterministic design values).

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-extract-values.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  SNAP="${WORKSPACE}/.figma/cache/context-snapshot.json"
  cat > "$SNAP" <<'JSON'
{"fileId":"AbC123","lastModified":"2026-08-14T09:12:33Z","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"SummaryCard","type":"FRAME",
 "layoutMode":"VERTICAL","paddingTop":24,"paddingRight":16,"paddingBottom":24,"paddingLeft":70,
 "itemSpacing":12,"primaryAxisAlignItems":"MIN","counterAxisAlignItems":"CENTER","cornerRadius":8,
 "absoluteBoundingBox":{"width":360,"height":240},"children":[
  {"id":"12:346","name":"Title","type":"TEXT","style":{"fontFamily":"Inter","fontWeight":600,
   "fontSize":18,"lineHeightPx":24,"letterSpacing":0,"textAlignHorizontal":"LEFT","textAlignVertical":"TOP"},
   "styles":{"text":"S:abc123"}},
  {"id":"12:347","name":"Spacer","type":"RECTANGLE","absoluteBoundingBox":{"width":328,"height":70}},
  {"id":"12:348","name":"Empty group","type":"GROUP"}]}}}}}
JSON
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

@test "every length is emitted WITH its unit, never as a bare number" {
  # A bare 70 is what lets a length be re-read as a scale index downstream —
  # theme.spacing(70) on a spacing:4 theme renders 280px, and nothing fails.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.nodes[0].facts.paddingLeft')" == "70px" ]]
  [[ "$(echo "$output" | jq -r '.nodes[0].facts.itemSpacing')" == "12px" ]]
  # Nothing numeric may survive as a raw number in a length field.
  [[ "$(echo "$output" | jq -r '[.nodes[].facts | to_entries[] | select(.key | test("padding|Spacing|width|height|fontSize|lineHeight|cornerRadius")) | .value | type] | unique | join(",")')" == "string" ]]
}

@test "layout facts are extracted verbatim from the node" {
  run "$SCRIPT"
  facts="$(echo "$output" | jq -c '.nodes[0].facts')"
  [[ "$(echo "$facts" | jq -r '.layoutMode')" == "VERTICAL" ]]
  [[ "$(echo "$facts" | jq -r '.counterAxisAlignItems')" == "CENTER" ]]
  [[ "$(echo "$facts" | jq -r '.width')" == "360px" ]]
}

@test "typography facts are extracted from the text node" {
  run "$SCRIPT"
  t="$(echo "$output" | jq -c '.nodes[] | select(.id == "12:346") | .facts')"
  [[ "$(echo "$t" | jq -r '.fontSize')" == "18px" ]]
  [[ "$(echo "$t" | jq -r '.lineHeightPx')" == "24px" ]]
  [[ "$(echo "$t" | jq -r '.fontWeight')" == "600" ]]
  [[ "$(echo "$t" | jq -r '.textAlignHorizontal')" == "LEFT" ]]
  # The style id is the bridge to the Design System token.
  [[ "$(echo "$t" | jq -r '.styles.text')" == "S:abc123" ]]
}

@test "a node carrying no design value contributes no row" {
  # Structural containers would otherwise bury the rows that matter.
  run "$SCRIPT"
  [[ "$(echo "$output" | jq -r '[.nodes[].id] | index("12:348")')" == "null" ]]
  [[ "$(echo "$output" | jq -r '.totalNodes')" == "4" ]]
  [[ "$(echo "$output" | jq -r '.rowCount')" == "3" ]]
}

@test "a zero padding Figma never sent is absent, not fabricated as 0px" {
  # A fabricated 0px reads as a deliberate design decision the mockup never made.
  run "$SCRIPT"
  [[ "$(echo "$output" | jq -r '.nodes[] | select(.id == "12:347") | .facts | has("paddingTop")')" == "false" ]]
}

@test "markdown output carries both tables and the unit warning" {
  run "$SCRIPT" --format markdown
  [ "$status" -eq 0 ]
  [[ "$output" == *"Layout values"* ]]
  [[ "$output" == *"Typography values"* ]]
  [[ "$output" == *"70px"* ]]
  [[ "$output" == *"never pass a raw px number to a scale-indexed helper"* ]]
  [[ "$output" == *"figma-design-rules.custom.md"* ]]
}

@test "--node restricts the digest to the requested node" {
  run "$SCRIPT" --node 99:999
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.rowCount')" == "0" ]]
}

@test "--max-rows truncates and says so, instead of growing unbounded" {
  run "$SCRIPT" --max-rows 1
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.truncated')" == "true" ]]
  [[ "$(echo "$output" | jq -r '.nodes | length')" == "1" ]]
  run "$SCRIPT" --max-rows 1 --format markdown
  [[ "$output" == *"Truncated"* ]]
}

@test "a snapshot with no deep-fetched node yields an empty digest, not an error" {
  echo '{"fileId":"AbC123","pages":[]}' > "$SNAP"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.rowCount')" == "0" ]]
  run "$SCRIPT" --format markdown
  [ "$status" -eq 0 ]
  [[ "$output" == *"No layout value extracted"* ]]
}

@test "a missing snapshot is a hard error, not a silent empty digest" {
  rm -f "$SNAP"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "invalid --format and --max-rows are rejected" {
  run "$SCRIPT" --format yaml
  [ "$status" -eq 1 ]
  run "$SCRIPT" --max-rows 0
  [ "$status" -eq 1 ]
}

@test "the rendered spec section carries the extracted values" {
  # The whole point: the agent copies numbers instead of mining the raw snapshot.
  run "${SCRIPTS_DIR}/figma-render-section.sh" --phase spec --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  grep -q "Layout values" "$output"
  grep -q "70px" "$output"
}

# -----------------------------------------------------------------------------
# Source components — implement against the definition, not the instance.
# -----------------------------------------------------------------------------

@test "the source component behind an instance is extracted and tagged" {
  cat > "$SNAP" <<'JSON'
{"fileId":"AbC123","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Card instance","type":"INSTANCE",
  "componentId":"90:1","paddingLeft":70,"absoluteBoundingBox":{"width":360,"height":240}}}}},
 "sources":{"nodes":{"90:1":{"document":{"id":"90:1","name":"DsCard","type":"COMPONENT",
  "layoutMode":"VERTICAL","paddingTop":24,"paddingLeft":16,"itemSpacing":12,
  "absoluteBoundingBox":{"width":360,"height":240}}}}}}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.sourceComponents[0].name')" == "DsCard" ]]
  [[ "$(echo "$output" | jq -r '.nodes[] | select(.id == "12:345") | .origin')" == "instance" ]]
  [[ "$(echo "$output" | jq -r '.nodes[] | select(.id == "90:1") | .origin')" == "source" ]]
  # The definition's padding differs from the instance's override; both survive,
  # so the difference is visible as an override rather than silently merged.
  [[ "$(echo "$output" | jq -r '.nodes[] | select(.id == "90:1") | .facts.paddingLeft')" == "16px" ]]
  [[ "$(echo "$output" | jq -r '.nodes[] | select(.id == "12:345") | .facts.paddingLeft')" == "70px" ]]
}

@test "markdown names the source components and tells the agent which to implement" {
  cat > "$SNAP" <<'JSON'
{"fileId":"AbC123","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Card instance","type":"INSTANCE",
  "componentId":"90:1","paddingLeft":70}}}},
 "sources":{"nodes":{"90:1":{"document":{"id":"90:1","name":"DsCard","type":"COMPONENT","paddingLeft":16}}}}}
JSON
  run "$SCRIPT" --format markdown
  [[ "$output" == *"Source components behind the linked instances"* ]]
  [[ "$output" == *"DsCard"* ]]
  [[ "$output" == *"Implement against the **source component**"* ]]
  [[ "$output" == *"| Origin |"* ]]
}

@test "a snapshot with no sources renders no source table" {
  run "$SCRIPT" --format markdown
  [[ "$output" != *"Source components behind"* ]]
}

@test "a same-file source component is flagged 'same file', not external" {
  cat > "$SNAP" <<'JSON'
{"fileId":"AbC123","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Card instance","type":"INSTANCE",
  "componentId":"90:1","paddingLeft":70}}}},
 "sources":{"nodes":{"90:1":{"document":{"id":"90:1","name":"DsCard","type":"COMPONENT","paddingLeft":16}}}}}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.sourceComponents[0].fileKey // "null"')" == "null" ]]

  run "$SCRIPT" --format markdown
  [[ "$output" == *"| DsCard | \`90:1\` | same file |"* ]]
}

@test "a cross-file source component is flagged external, with its owning file key" {
  cat > "$SNAP" <<'JSON'
{"fileId":"AbC123","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Card instance","type":"INSTANCE",
  "componentId":"90:1","paddingLeft":70}}}},
 "sources":{"nodes":{"90:1":{"document":{"id":"90:1","name":"DsCard","type":"COMPONENT","paddingLeft":16}}},
  "externalFiles":{"90:1":"DSFILEKEY"}}}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.sourceComponents[0].fileKey')" == "DSFILEKEY" ]]

  run "$SCRIPT" --format markdown
  [[ "$output" == *"| DsCard | \`90:1\` | \`DSFILEKEY\` (external) |"* ]]
  [[ "$output" == *"resolved from another Figma file"* ]]
}
