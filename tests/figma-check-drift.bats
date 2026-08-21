#!/usr/bin/env bats
# Tests for scripts/bash/figma-check-drift.sh (after_analyze hook).

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-check-drift.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  export SPECIFY_FEATURE="001-checkout"
  mkdir -p "${WORKSPACE}/specs/${SPECIFY_FEATURE}"
  DOC="${WORKSPACE}/specs/${SPECIFY_FEATURE}/spec.md"
  SNAP="${WORKSPACE}/.figma/cache/context-snapshot.json"
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

status_json() {
  echo "$output" | sed -n '/^{/,$p'
}

# Stage a spec carrying the section marker with the two drift facts.
stage_doc() { # $1 = fileId, $2 = lastModified ("" for a pre-drift-tracking marker)
  if [ -n "$2" ]; then
    printf '<!-- speckit-figma:section phase=spec file=%s lastModified=%s -->\n## Figma Design Context\n' "$1" "$2" > "$DOC"
  else
    printf '<!-- speckit-figma:section phase=spec -->\n## Figma Design Context\n' > "$DOC"
  fi
}

stage_snapshot() { # $1 = fileId, $2 = lastModified
  printf '{"fileId":"%s","lastModified":"%s"}\n' "$1" "$2" > "$SNAP"
}

@test "a Figma file modified after the spec is reported as drift" {
  stage_doc "ABC123" "2026-08-01T10:00:00Z"
  stage_snapshot "ABC123" "2026-08-14T09:12:33Z"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.drifted')" == "true" ]]
  [[ "$(status_json | jq -r '.reason')" == "drifted" ]]
  [[ "$(status_json | jq -r '.documentLastModified')" == "2026-08-01T10:00:00Z" ]]
  [[ "$(status_json | jq -r '.figmaLastModified')" == "2026-08-14T09:12:33Z" ]]
}

@test "an unchanged Figma file reports ok" {
  stage_doc "ABC123" "2026-08-14T09:12:33Z"
  stage_snapshot "ABC123" "2026-08-14T09:12:33Z"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.drifted')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "ok" ]]
}

@test "a snapshot OLDER than the document is not drift" {
  # Re-running an earlier phase must not manufacture a drift report.
  stage_doc "ABC123" "2026-08-14T09:12:33Z"
  stage_snapshot "ABC123" "2026-07-01T00:00:00Z"
  run "$SCRIPT"
  [[ "$(status_json | jq -r '.reason')" == "ok" ]]
}

@test "a design-less feature is not applicable, never a finding" {
  printf '# Spec\n\nNo Figma here.\n' > "$DOC"
  stage_snapshot "ABC123" "2026-08-14T09:12:33Z"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.applicable')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "no-marker" ]]
}

@test "a marker without timestamps reports unknown-timestamp, not drift" {
  # Documents generated before the marker carried the facts must not be read as
  # evidence that the design moved.
  stage_doc "ABC123" ""
  stage_snapshot "ABC123" "2026-08-14T09:12:33Z"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.drifted')" == "false" ]]
  [[ "$(status_json | jq -r '.reason')" == "unknown-timestamp" ]]
}

@test "a snapshot for another file skips the comparison" {
  # A creative that legitimately moved files must not report permanent drift.
  stage_doc "ABC123" "2026-08-01T10:00:00Z"
  stage_snapshot "OTHER999" "2026-08-14T09:12:33Z"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "not-applicable" ]]
}

@test "a missing snapshot is never a failure" {
  stage_doc "ABC123" "2026-08-01T10:00:00Z"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-snapshot" ]]
}

@test "a missing document is never a failure" {
  stage_snapshot "ABC123" "2026-08-14T09:12:33Z"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "doc-not-found" ]]
}

@test "--strict exits non-zero on a real drift" {
  stage_doc "ABC123" "2026-08-01T10:00:00Z"
  stage_snapshot "ABC123" "2026-08-14T09:12:33Z"
  run "$SCRIPT" --strict
  [ "$status" -eq 1 ]
}

@test "--strict still exits 0 when the check simply cannot run" {
  # The gate fires on evidence of drift, never on the absence of evidence.
  stage_doc "ABC123" "2026-08-01T10:00:00Z"
  run "$SCRIPT" --strict
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "no-snapshot" ]]
}

@test "verifyStrict in the config enables strict mode" {
  cp "${FIXTURES_DIR}/singlerepo-valid.json" "${WORKSPACE}/figma.projects.config.json"
  jq '.figma.verifyStrict = true' "${WORKSPACE}/figma.projects.config.json" > "${WORKSPACE}/tmp.json"
  mv "${WORKSPACE}/tmp.json" "${WORKSPACE}/figma.projects.config.json"
  stage_doc "ABC123" "2026-08-01T10:00:00Z"
  stage_snapshot "ABC123" "2026-08-14T09:12:33Z"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "an unknown flag is a hard error, not a silent no-op" {
  run "$SCRIPT" --nope
  [ "$status" -eq 1 ]
}

@test "--phase rejects a value outside spec|plan|tasks" {
  run "$SCRIPT" --phase implement
  [ "$status" -eq 1 ]
}
