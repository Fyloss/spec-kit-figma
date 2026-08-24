#!/usr/bin/env bats
# Tests for scripts/bash/figma-render-section.sh (deterministic section rendering)

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-render-section.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  SNAP="${WORKSPACE}/.figma/cache/context-snapshot.json"
  cat > "$SNAP" <<'JSON'
{
  "fileId": "AbC123",
  "projectId": "999",
  "generatedAt": "2026-06-24T10:00:00Z",
  "lastModified": "2026-06-20T08:00:00Z",
  "contextSource": "rest",
  "pages": [
    {"id":"0:1","name":"Home","frames":[{"id":"12:345","name":"Hero","type":"FRAME"},{"id":"12:346","name":"Footer","type":"FRAME"}]},
    {"id":"0:2","name":"Checkout","frames":[{"id":"20:1","name":"Cart","type":"FRAME"}]}
  ],
  "components": {"c1":{},"c2":{}},
  "styles": {"s1":{}}
}
JSON
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

@test "renders the spec section with deterministic scalars filled from the snapshot" {
  run "$SCRIPT" --phase spec --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  local out="$output"
  [ -f "$out" ]
  grep -q 'AbC123' "$out"            # file id substituted
  grep -q '999' "$out"               # project id substituted
  grep -q '2026-06-24T10:00:00Z' "$out"
  grep -q 'Hero' "$out"              # real frame from the snapshot
  grep -q 'Cart' "$out"
  ! grep -q '{{FIGMA_FILE_ID}}' "$out"   # scalar placeholder is gone
}

@test "writes .figma/cache/section.<phase>.md for each phase" {
  for phase in spec plan tasks; do
    run "$SCRIPT" --phase "$phase" --snapshot "$SNAP"
    [ "$status" -eq 0 ]
    [ -f "${WORKSPACE}/.figma/cache/sections/${SPECIFY_FEATURE:-default}/${phase}.md" ]
  done
}

@test "lists candidate frames and a confirmation prompt for broad links" {
  run "$SCRIPT" --phase spec --snapshot "$SNAP" \
    --links '[{"url":"https://figma.com/design/AbC123/Flow","fileId":"AbC123","nodeId":null}]' \
    --candidate-frames '[{"id":"12:345","name":"Hero","page":"Home"},{"id":"20:1","name":"Cart","page":"Checkout"}]'
  [ "$status" -eq 0 ]
  grep -qi 'confirm which of these frames' "$output"
  grep -q '12:345' "$output"
}

@test "rejects an unknown phase" {
  run "$SCRIPT" --phase bogus --snapshot "$SNAP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--phase must be one of"* ]]
}

@test "fails clearly when the snapshot is missing" {
  run "$SCRIPT" --phase spec --snapshot "${WORKSPACE}/does-not-exist.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"snapshot not found"* ]]
}

# --- Review fixes: sed-escaping of values & phase machine marker --------------

@test "snapshot values with sed metacharacters render literally (no corruption)" {
  cat > "$SNAP" <<'JSON'
{ "fileId": "AbC123", "projectId": "a&b@c", "generatedAt": "t", "lastModified": "u",
  "contextSource": "rest", "pages": [], "components": {}, "styles": {} }
JSON
  run "$SCRIPT" --phase spec --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  grep -qF 'a&b@c' "$output"                       # value preserved verbatim
  ! grep -qF '{{FIGMA_PROJECT_ID' "$output"        # placeholder fully substituted
}

@test "emits a phase-specific machine marker the verifier can match" {
  run "$SCRIPT" --phase plan --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  grep -qF 'speckit-figma:section phase=plan' "$output"
}

# --- Copilot review: engine placeholder & candidate-frames validation ---------

@test "substitutes the deterministic engine placeholder {{rest | mcp}}" {
  cat > "$SNAP" <<'JSON'
{ "fileId": "AbC", "projectId": "1", "generatedAt": "t", "lastModified": "u",
  "contextSource": "mcp", "pages": [], "components": {}, "styles": {} }
JSON
  run "$SCRIPT" --phase plan --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  ! grep -qF '{{rest | mcp}}' "$output"          # placeholder filled
  grep -qiE 'engine.*: *mcp' "$output"           # filled with the snapshot value
}

@test "substitutes the full-enum mode placeholder {{single-repo | mono-repo | multi-repo}}" {
  # The schema enum is single-repo|mono-repo|multi-repo; the renderer must fill
  # the placeholder that spells out the full enum. Exercised through the tree the
  # renderer really runs from, where its templates ship beside it.
  home="$(stage_extension_tree)"
  printf '## Figma Design Plan *(extension: figma)*\n\n- **Mode**: {{single-repo | mono-repo | multi-repo}}\n' \
    > "${home}/templates/plan-figma-section.template.md"
  run "${home}/scripts/bash/figma-render-section.sh" --phase plan --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  ! grep -qF '{{single-repo | mono-repo | multi-repo}}' "$output"   # placeholder filled
  grep -qF '**Mode**: single-repo' "$output"                        # schema default applied
}

@test "still substitutes the legacy mode placeholder {{multi-repo | mono-repo}}" {
  # A workspace installed before the enum was completed may still carry the old
  # placeholder — the renderer must keep filling it.
  home="$(stage_extension_tree)"
  printf '## Figma Design Plan *(extension: figma)*\n\n- **Mode**: {{multi-repo | mono-repo}}\n' \
    > "${home}/templates/plan-figma-section.template.md"
  run "${home}/scripts/bash/figma-render-section.sh" --phase plan --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  ! grep -qF '{{multi-repo | mono-repo}}' "$output"
  grep -qF '**Mode**: single-repo' "$output"
}

@test "the templates that ship with the helpers win over a workspace leftover" {
  # Precedence is script-relative first. A copy an earlier version installed into
  # .specify/templates/ must never shadow the one the running renderer shipped
  # with — that is how a workspace ends up rendering with a template from another
  # version.
  home="$(stage_extension_tree)"
  printf '## Figma Design Plan *(extension: figma)*\n\nshipped\n' \
    > "${home}/templates/plan-figma-section.template.md"
  mkdir -p "${WORKSPACE}/.specify/templates"
  printf '## Figma Design Plan *(extension: figma)*\n\nleftover\n' \
    > "${WORKSPACE}/.specify/templates/plan-figma-section.template.md"
  run "${home}/scripts/bash/figma-render-section.sh" --phase plan --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  grep -qF 'shipped' "$output"
  ! grep -qF 'leftover' "$output"
}

@test "rejects a non-array --candidate-frames" {
  run "$SCRIPT" --phase spec --snapshot "$SNAP" --candidate-frames '{"not":"an array"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"--candidate-frames must be a JSON array"* ]]
}

@test "candidate-frame checklist shows the Page column and escapes pipes in names" {
  run "$SCRIPT" --phase tasks --snapshot "$SNAP" \
    --candidate-frames '[{"id":"9:9","name":"Checkout | v2","page":"Flows | A"}]'
  [ "$status" -eq 0 ]
  local out="$output"
  [ -f "$out" ]
  # Page column is present so frames with the same name on different pages are
  # distinguishable in the creative-confirmation checklist.
  grep -qF '| # | Page | Frame | Node id |' "$out"
  # A literal "|" inside a Figma name is escaped so it cannot inject a spurious
  # table column when the section is pasted verbatim into the document.
  grep -qF 'Checkout \| v2' "$out"
  grep -qF 'Flows \| A' "$out"
}

# -----------------------------------------------------------------------------
# The section marker carries the drift facts (file + Figma lastModified).
# -----------------------------------------------------------------------------

@test "the section marker records the file and the Figma lastModified" {
  # figma-check-drift.sh reads these back instead of parsing rendered prose,
  # which would break the first time a heading is reworded or translated.
  run "$SCRIPT" --phase spec --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  marker="$(head -n1 "$output")"
  [[ "$marker" == *"speckit-figma:section phase=spec"* ]]
  [[ "$marker" == *"file=AbC123"* ]]
  [[ "$marker" == *"lastModified=2026-06-20T08:00:00Z"* ]]
}

@test "the enriched marker keeps the prefix every existing reader greps for" {
  # figma-verify-section.sh and figma-ensure-context.sh both grep the fixed
  # prefix, so appending fields must stay backward compatible by construction.
  run "$SCRIPT" --phase tasks --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  grep -qF 'speckit-figma:section phase=tasks' "$output"
}

@test "a snapshot without lastModified still renders a well-formed marker" {
  echo '{"fileId":"AbC123","pages":[]}' > "$SNAP"
  run "$SCRIPT" --phase spec --snapshot "$SNAP"
  [ "$status" -eq 0 ]
  marker="$(head -n1 "$output")"
  [[ "$marker" == *"lastModified=unknown"* ]]
  # "unknown" must read as "cannot compare", never as a timestamp.
  [[ "$marker" == *"-->"* ]]
}
