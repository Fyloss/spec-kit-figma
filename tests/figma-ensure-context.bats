#!/usr/bin/env bats
# Tests for scripts/bash/figma-ensure-context.sh (automatic pre-specify/tasks hook)

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-ensure-context.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

# Extract the trailing JSON status object from mixed stderr/stdout output.
status_json() {
  echo "$output" | sed -n '/^{/,$p'
}

@test "missing config is a safe no-op (exit 0, reason no-config)" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.ran')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "no-config" ]]
}

@test "unresolved placeholders skip without blocking" {
  cp "${FIXTURES_DIR}/unresolved-placeholder.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "unresolved-placeholders" ]]
}

@test "invalid config skips without blocking" {
  echo '{ "mode": "what" }' > "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "invalid-config" ]]
}

@test "excluded target skips silently" {
  cp "${FIXTURES_DIR}/multirepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" back-bff
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "target-excluded" ]]
}

@test "single-repo resolves the target to repo and plans a --file introspection" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
  [[ "$(status_json | jq -r '.target')" == "repo" ]]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file single123FILE" ]]
}

@test "multi-repo with a single enabled target auto-resolves it" {
  cp "${FIXTURES_DIR}/multirepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.target')" == "design-system" ]]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
}

@test "multi-repo with several enabled targets requires an explicit target" {
  cat > "${WORKSPACE}/figma.projects.config.json" <<'JSON'
{
  "version": "1.0",
  "mode": "multi-repo",
  "figma": { "credentials": { "source": "env" } },
  "submodules": {
    "app-a": { "enabled": true, "role": "app", "figmaFileId": "fileA" },
    "app-b": { "enabled": true, "role": "app", "figmaFileId": "fileB" }
  }
}
JSON
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "ambiguous-target" ]]
}

@test "team-based target plans --team introspection" {
  cp "${FIXTURES_DIR}/organization-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" design-system --dry-run
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--team 111222333" ]]
}

@test "a fresh snapshot skips introspection" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{}' > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.ran')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
}

@test "a config newer than the snapshot forces re-introspection" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{}' > "${WORKSPACE}/.figma-context-snapshot.json"
  touch -t 202601010000 "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
}

@test "a failed introspection is reported but never blocks (exit 0)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  unset FIGMA_PAT
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.ran')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "introspect-failed" ]]
}

@test "rejects a non-numeric --max-age-minutes" {
  run "$SCRIPT" --max-age-minutes never
  [ "$status" -eq 1 ]
  [[ "$output" == *"--max-age-minutes must be a positive integer"* ]]
}

# --- Direct Figma links in the feature input (--input) -----------------------

@test "--input with a direct Figma link plans introspection of the linked file and node" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input \
    "Build the checkout page https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 12:345" ]]
  [[ "$(status_json | jq -r '.links | length')" == "1" ]]
  [[ "$(status_json | jq -r '.links[0].nodeId')" == "12:345" ]]
}

@test "--input - reads the feature description from stdin" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run bash -c "printf '%s' 'See https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345' \
    | \"$SCRIPT\" --dry-run --input -"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 12:345" ]]
}

@test "a link without node-id introspects the linked file only" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "https://www.figma.com/design/LinkFILE999/Checkout"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999" ]]
}

@test "several links to the same file dedupe into one file and multiple nodes" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/LinkFILE999/A?node-id=1-2 and https://www.figma.com/design/LinkFILE999/A?node-id=3-4"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file LinkFILE999 --node 1:2 --node 3:4" ]]
}

@test "links to several files use the first and surface a warning" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/FirstFILE/A?node-id=1-2 https://www.figma.com/design/SecondFILE/B?node-id=3-4"
  [ "$status" -eq 0 ]
  [[ "$output" == *"distinct Figma files"* ]]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file FirstFILE --node 1:2" ]]
}

@test "input without links keeps the config-derived scope" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --dry-run --input "No design links in this feature."
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.introspectArgs | join(" ")')" == "--file single123FILE" ]]
  [[ "$(status_json | jq -r '.links | length')" == "0" ]]
}

@test "a direct link bypasses a fresh snapshot that does not cover its node" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{}' > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "dry-run" ]]
}

@test "a fresh snapshot already covering the linked node stays fresh" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"LinkFILE999","nodes":{"nodes":{"12:345":{}}}}' \
    > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --dry-run --input \
    "https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
}

# --- Mandatory section integration & broad-link handling -----------------------

@test "an applicable run marks the section mandatory and renders spec/plan/tasks" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"single123FILE","pages":[{"id":"0:1","name":"Home","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}],"components":{},"styles":{}}' \
    > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "true" ]]
  [[ "$(status_json | jq -r '.specSection')" == *".figma-section.spec.md" ]]
  [[ "$(status_json | jq -r '.planSection')" == *".figma-section.plan.md" ]]
  [[ "$(status_json | jq -r '.tasksSection')" == *".figma-section.tasks.md" ]]
  [ -f "${WORKSPACE}/.figma-section.spec.md" ]
  [ -f "${WORKSPACE}/.figma-section.plan.md" ]
  [ -f "${WORKSPACE}/.figma-section.tasks.md" ]
  grep -q "Hero" "${WORKSPACE}/.figma-section.spec.md"
}

@test "a broad link (file/page, no node-id) flags linkScope broad with candidate frames" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"BroadFILE","pages":[{"id":"0:1","name":"Home","frames":[{"id":"1:2","name":"Hero","type":"FRAME"},{"id":"1:3","name":"Footer","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --input "Build the home page https://www.figma.com/design/BroadFILE/Home"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "broad" ]]
  [[ "$(status_json | jq -r '.candidateFrames | length')" == "2" ]]
  [[ "$(status_json | jq -r '.mustInject')" == "true" ]]
  grep -qi "confirm which of these frames" "${WORKSPACE}/.figma-section.spec.md"
}

@test "a link pinned to a top-level frame reports linkScope frame" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"PinFILE","nodes":{"nodes":{"9:9":{}}},"pages":[{"id":"0:1","name":"P","frames":[{"id":"9:9","name":"Card","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/PinFILE/X?node-id=9-9"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "frame" ]]
}

# --- Review fixes: stale-section cleanup & broad/frame classification ----------

@test "ensure clears stale rendered sections when Figma no longer applies" {
  # No config -> no-config skip path. A leftover .figma-section.*.md from a prior
  # run must be removed so the verifier does not treat this run as 'applicable'.
  printf 'stale\n' > "${WORKSPACE}/.figma-section.tasks.md"
  printf 'stale\n' > "${WORKSPACE}/.figma-section.spec.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-config" ]]
  [ ! -f "${WORKSPACE}/.figma-section.tasks.md" ]
  [ ! -f "${WORKSPACE}/.figma-section.spec.md" ]
}

@test "ensure preserves a prior rendered section on a transient introspect-failure" {
  # Figma APPLIES (valid config, enabled target) but introspection fails for lack
  # of a token. A prior phase's render must NOT be wiped: the verifier keys
  # 'applicable' on the file's existence, so wiping it would make after_* verify
  # report not-applicable and let a --strict CI gate silently pass for a run where
  # Figma genuinely applies. Unlike no-config, this skip is transient -> keep it.
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  printf 'prior render\n' > "${WORKSPACE}/.figma-section.tasks.md"
  unset FIGMA_PAT
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "introspect-failed" ]]
  [ -f "${WORKSPACE}/.figma-section.tasks.md" ]
}

@test "a link to a deep-fetched node that is not a top-level frame stays pinned (linkScope frame)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  # 50:9 is deep-fetched into .nodes.nodes but is NOT a top-level page frame.
  echo '{"fileId":"DeepFILE","nodes":{"nodes":{"50:9":{}}},"pages":[{"id":"0:1","name":"P","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/DeepFILE/X?node-id=50-9"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "frame" ]]
}

@test "a link whose node-id is a page/canvas is broad (covers many frames)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  # 0:1 IS a page id in the snapshot, not a specific frame.
  echo '{"fileId":"PageFILE","nodes":{"nodes":{"0:1":{}}},"pages":[{"id":"0:1","name":"Home","frames":[{"id":"1:2","name":"Hero","type":"FRAME"},{"id":"1:3","name":"Footer","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/PageFILE/Home?node-id=0-1"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "broad" ]]
  [[ "$(status_json | jq -r '.candidateFrames | length')" == "2" ]]
}

# --- Copilot review: broad detection via node type (document root / canvas) ----

@test "a link to a CANVAS-type node not indexed in pages[] is broad (by node type)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  # 7:7 is deep-fetched with type CANVAS but is NOT in .pages[].id.
  echo '{"fileId":"CanvFILE","nodes":{"nodes":{"7:7":{"document":{"type":"CANVAS"}}}},"pages":[{"id":"0:1","name":"P","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/CanvFILE/X?node-id=7-7"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "broad" ]]
}

@test "a link to a SECTION-type node stays pinned (linkScope frame)" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  echo '{"fileId":"SecFILE","nodes":{"nodes":{"8:8":{"document":{"type":"SECTION"}}}},"pages":[{"id":"0:1","name":"P","frames":[{"id":"1:2","name":"Hero","type":"FRAME"}]}]}' \
    > "${WORKSPACE}/.figma-context-snapshot.json"
  run "$SCRIPT" --input "https://www.figma.com/design/SecFILE/X?node-id=8-8"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "fresh" ]]
  [[ "$(status_json | jq -r '.linkScope')" == "frame" ]]
}
