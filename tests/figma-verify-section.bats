#!/usr/bin/env bats
# Tests for scripts/bash/figma-verify-section.sh (post-generation section check)

load helpers/common

setup() {
  SCRIPT="${SCRIPTS_DIR}/figma-verify-section.sh"
  WORKSPACE="$(make_temp_workspace)"
  cd "$WORKSPACE"
  RENDERED="${WORKSPACE}/.figma/cache/section.spec.md"
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
  [[ "$(status_json | jq -r '.remedy')" == *".figma/cache/section.spec.md"* ]]
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

@test "resolves specs/*/<phase>.md when exactly one exists and --doc is omitted" {
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

# --- Review fixes: ambiguous-doc safety & phase-specific machine marker --------

@test "ambiguous multiple specs/*/<phase>.md does not silently pick one (doc-not-found)" {
  printf 'rendered\n' > "$RENDERED"
  mkdir -p "${WORKSPACE}/specs/001-a" "${WORKSPACE}/specs/002-b"
  printf '# A\n## Figma Design Context *(extension: figma)*\n' > "${WORKSPACE}/specs/001-a/spec.md"
  printf '# B no section\n' > "${WORKSPACE}/specs/002-b/spec.md"
  run "$SCRIPT" --phase spec
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "doc-not-found" ]]
  run "$SCRIPT" --phase spec --strict
  [ "$status" -ne 0 ]
}

@test "recognizes the phase-specific machine marker without the heading text" {
  printf 'rendered\n' > "$RENDERED"
  printf '# Spec\n<!-- speckit-figma:section phase=spec -->\nbody\n' > "$DOC"
  run "$SCRIPT" --phase spec --doc "$DOC"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "ok" ]]
}

@test "a wrong-phase machine marker is not accepted as the right phase via the machine marker" {
  printf 'rendered\n' > "$RENDERED"
  # Only the plan machine marker is present (no heading, no spec marker).
  printf '# Doc\n<!-- speckit-figma:section phase=plan -->\nbody\n' > "$DOC"
  run "$SCRIPT" --phase spec --doc "$DOC"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "section-missing" ]]
}

@test "a legacy heading from the WRONG phase is not accepted (no cross-phase false-ok)" {
  # plan-phase verification is applicable (a plan section was rendered this run)...
  printf 'rendered\n' > "${WORKSPACE}/.figma/cache/section.plan.md"
  # ...but the document only carries the SPEC heading (legacy, no machine marker).
  # The old phase-agnostic "(extension: figma)" suffix matched it and reported ok.
  printf '# Plan\n\n## Figma Design Context *(extension: figma)*\n\nbody\n' > "${WORKSPACE}/plan.md"
  run "$SCRIPT" --phase plan --doc "${WORKSPACE}/plan.md"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "section-missing" ]]
  [[ "$(status_json | jq -r '.verified')" == "false" ]]
}

@test "a legacy heading for the MATCHING phase is still accepted (backward compat)" {
  printf 'rendered\n' > "${WORKSPACE}/.figma/cache/section.plan.md"
  printf '# Plan\n\n## Figma Design Plan *(extension: figma)*\n\nbody\n' > "${WORKSPACE}/plan.md"
  run "$SCRIPT" --phase plan --doc "${WORKSPACE}/plan.md"
  [ "$status" -eq 0 ]
  [[ "$(status_json | jq -r '.reason')" == "ok" ]]
}

# The after_specify/after_plan/after_tasks hooks all invoke this ONE command
# file with no arguments, so its prompt must bind each hook to the matching
# phase. A spec-hardcoded example would make a weak agent verify spec after
# plan/tasks generation, letting a missing section pass even under --strict.
@test "verify command doc binds each after-hook to its own phase (no spec-only default)" {
  doc="${REPO_ROOT}/commands/speckit.figma.verify.md"
  grep -qF "after_plan" "$doc"
  grep -qF "after_tasks" "$doc"
  grep -qF -- "--phase plan" "$doc"
  grep -qF -- "--phase tasks" "$doc"
  # ...and it must NOT ship a runnable example that hardcodes the spec phase.
  ! grep -qE 'figma-verify-section\.sh --phase spec( |$)' "$doc"
}
