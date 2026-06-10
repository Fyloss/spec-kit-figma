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
