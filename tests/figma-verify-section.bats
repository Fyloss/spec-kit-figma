#!/usr/bin/env bats
# Tests for scripts/bash/figma-verify-section.sh (post-generation section check)

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-verify-section.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  RENDERED="${WORKSPACE}/.figma-section.spec.md"
  DOC="${WORKSPACE}/spec.md"
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

# Extract the trailing JSON object from mixed stderr/stdout captured by `run`.
status_json() {
  echo "$output" | sed -n '/^{/,$p'
}

@test "not-applicable when no section was rendered (Figma did not apply)" {
  printf '# Spec\n\nNo design here.\n' > "$DOC"
  run "$SCRIPT" --phase spec --doc "$DOC"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "not-applicable" ]]
  [[ "$(status_json | jq -r '.verified')" == "true" ]]
}

@test "ok when the document contains the Figma section marker" {
  printf 'rendered\n' > "$RENDERED"
  printf '# Spec\n\n## Figma Design Context *(extension: figma)*\n\nfile AbC.\n' > "$DOC"
  run "$SCRIPT" --phase spec --doc "$DOC"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "ok" ]]
  [[ "$(status_json | jq -r '.verified')" == "true" ]]
}

@test "section-missing when a mockup was detected but the doc lacks the section" {
  printf 'rendered\n' > "$RENDERED"
  printf '# Spec\n\nNothing about Figma here.\n' > "$DOC"
  run "$SCRIPT" --phase spec --doc "$DOC"
  [ "$status" -eq 0 ]   # non-blocking by default
  [[ "$(status_json | jq -r '.reason')" == "section-missing" ]]
  [[ "$(status_json | jq -r '.verified')" == "false" ]]
  [[ "$(status_json | jq -r '.remedy')" == *".figma-section.spec.md"* ]]
}

@test "strict mode exits non-zero on a missing section" {
  printf 'rendered\n' > "$RENDERED"
  printf '# Spec\n\nNothing about Figma here.\n' > "$DOC"
  run "$SCRIPT" --phase spec --doc "$DOC" --strict
  [ "$status" -ne 0 ]
  [[ "$(status_json | jq -r '.reason')" == "section-missing" ]]
}

@test "config figma.verifyStrict=true enables strict mode" {
  printf 'rendered\n' > "$RENDERED"
  printf '# Spec\n\nNothing here.\n' > "$DOC"
  printf '{"figma":{"verifyStrict":true}}\n' > "${WORKSPACE}/figma.projects.config.json"
  run "$SCRIPT" --phase spec --doc "$DOC" --config "${WORKSPACE}/figma.projects.config.json"
  [ "$status" -ne 0 ]
  [[ "$(status_json | jq -r '.reason')" == "section-missing" ]]
}

@test "doc-not-found is non-blocking by default and strict-fails" {
  printf 'rendered\n' > "$RENDERED"
  run "$SCRIPT" --phase spec
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "doc-not-found" ]]
  run "$SCRIPT" --phase spec --strict
  [ "$status" -ne 0 ]
}

@test "resolves the newest specs/*/<phase>.md when --doc is omitted" {
  printf 'rendered\n' > "$RENDERED"
  mkdir -p "${WORKSPACE}/specs/001-feat"
  printf '# Spec\n\n## Figma Design Context *(extension: figma)*\n' > "${WORKSPACE}/specs/001-feat/spec.md"
  run "$SCRIPT" --phase spec
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "ok" ]]
  [[ "$(status_json | jq -r '.doc')" == *"specs/001-feat/spec.md" ]]
}

@test "rejects an unknown phase" {
  run "$SCRIPT" --phase bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"--phase must be one of"* ]]
}
