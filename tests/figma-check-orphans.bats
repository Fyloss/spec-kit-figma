#!/usr/bin/env bats
# Tests for scripts/bash/figma-check-orphans.sh (features orphaned by 2.0.0).

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-check-orphans.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  mkdir -p "${WORKSPACE}/specs"
}

teardown() {
  cd "$REPO_ROOT"
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

status_json() { echo "$output" | sed -n '/^{/,$p'; }

# An era-1.6.0 spec: a real design section, but the mapping was the trigger so no
# url was ever recorded.
stage_orphan() { # $1 = feature name
  mkdir -p "${WORKSPACE}/specs/$1"
  printf '<!-- speckit-figma:section phase=spec -->\n## Figma Design Context\n\nNone — context derived from page mapping.\n' \
    > "${WORKSPACE}/specs/$1/spec.md"
}

stage_healthy() { # $1 = feature name
  mkdir -p "${WORKSPACE}/specs/$1"
  printf '<!-- speckit-figma:section phase=spec file=ABC123 lastModified=x -->\n[frame](https://www.figma.com/design/ABC123/X?node-id=12-345)\n' \
    > "${WORKSPACE}/specs/$1/spec.md"
}

@test "a mapping-derived spec with no link is reported as orphaned" {
  stage_orphan "001-checkout"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.orphans | length')" == "1" ]]
  [[ "$(status_json | jq -r '.orphans[0].feature')" == "001-checkout" ]]
  [[ "$(status_json | jq -r '.orphans[0].reason')" == "no-link-recorded" ]]
}

@test "a spec carrying a link is healthy" {
  stage_healthy "002-cart"
  run "$SCRIPT"
  [[ "$(status_json | jq -r '.orphans | length')" == "0" ]]
  [[ "$(status_json | jq -r '.healthy')" == "1" ]]
}

@test "a design-less spec is not scanned at all" {
  # A back-end feature has no design context to lose.
  mkdir -p "${WORKSPACE}/specs/003-billing"
  printf '# Spec\n\nAdd a Redis cache on the billing endpoint.\n' > "${WORKSPACE}/specs/003-billing/spec.md"
  run "$SCRIPT"
  [[ "$(status_json | jq -r '.scanned')" == "0" ]]
  [[ "$(status_json | jq -r '.orphans | length')" == "0" ]]
}

@test "a figma.com url in prose does not make a spec healthy" {
  # The marker is what identifies a section the extension produced; a url merely
  # mentioned in prose was never a trigger and must not read as one.
  mkdir -p "${WORKSPACE}/specs/004-notes"
  printf '# Spec\n\nSee https://www.figma.com/design/ABC123/X for context.\n' > "${WORKSPACE}/specs/004-notes/spec.md"
  run "$SCRIPT"
  [[ "$(status_json | jq -r '.scanned')" == "0" ]]
}

@test "the diagnostic names both ways out, not just the problem" {
  stage_orphan "001-checkout"
  run "$SCRIPT"
  [[ "$output" == *"paste the Figma link"* ]]
  [[ "$output" == *"autoIntrospect"* ]]
  [[ "$output" == *"001-checkout"* ]]
}

@test "mixed features are counted separately" {
  stage_orphan "001-checkout"
  stage_healthy "002-cart"
  stage_orphan "003-account"
  run "$SCRIPT"
  [[ "$(status_json | jq -r '.scanned')" == "3" ]]
  [[ "$(status_json | jq -r '.healthy')" == "1" ]]
  [[ "$(status_json | jq -r '[.orphans[].feature] | join(",")')" == "001-checkout,003-account" ]]
}

@test "no specs directory is not a failure" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.scanned')" == "0" ]]
}

@test "--strict exits non-zero when an orphan exists" {
  stage_orphan "001-checkout"
  run "$SCRIPT" --strict
  [ "$status" -eq 1 ]
}

@test "--strict exits 0 when every feature is healthy" {
  stage_healthy "002-cart"
  run "$SCRIPT" --strict
  [ "$status" -eq 0 ]
}

@test "the update command tells the agent to run this check" {
  doc="${REPO_ROOT}/commands/speckit.figma.update.md"
  grep -qF "figma-check-orphans.sh" "$doc"
  # And forbids it from guessing the link itself.
  grep -qiF "Do not edit any" "$doc"
}
