#!/usr/bin/env bats
# Tests for install.sh

load helpers/common

setup() {
  INSTALL="${REPO_ROOT}/install.sh"
  WORKSPACE="$(make_temp_workspace)"
}

teardown() {
  chmod -R u+w "$WORKSPACE" 2>/dev/null || true
  [ -n "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

@test "install copies the helper scripts into the target workspace" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -x "${WORKSPACE}/.specify/scripts/bash/figma-validate-config.sh" ]
  [ -x "${WORKSPACE}/.specify/scripts/bash/figma-detect-target.sh" ]
  [ -x "${WORKSPACE}/.specify/scripts/bash/figma-resolve-source.sh" ]
  [ -x "${WORKSPACE}/.specify/scripts/bash/figma-introspect.sh" ]
  [ -f "${WORKSPACE}/.specify/scripts/bash/figma-common.sh" ]
}

@test "install creates .specify/memory and installs the design rules" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.specify/memory/figma-design-rules.md" ]
}

@test "install never creates a .env or .env.example file" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ ! -e "${WORKSPACE}/.env" ]
  [ ! -e "${WORKSPACE}/.env.example" ]
}

@test "install git-ignores the snapshot but not .env" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  grep -qxF ".figma-context-snapshot.json" "${WORKSPACE}/.gitignore"
  ! grep -qxF ".env" "${WORKSPACE}/.gitignore"
}

@test "re-running install reports SKIP for files already present" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "install leaves the speckit command prompts untouched by default" {
  mkdir -p "${WORKSPACE}/.claude/commands" "${WORKSPACE}/.github/prompts"
  echo "# specify" > "${WORKSPACE}/.claude/commands/speckit.specify.md"
  echo "# tasks" > "${WORKSPACE}/.claude/commands/speckit.tasks.md"
  echo "# specify" > "${WORKSPACE}/.github/prompts/speckit.specify.prompt.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  ! grep -q "SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.claude/commands/speckit.specify.md"
  ! grep -q "SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.claude/commands/speckit.tasks.md"
  ! grep -q "SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.github/prompts/speckit.specify.prompt.md"
  [[ "$output" == *"extension hooks"* ]]
}

@test "a default install removes a previously injected auto-context block" {
  mkdir -p "${WORKSPACE}/.claude/commands"
  cat > "${WORKSPACE}/.claude/commands/speckit.specify.md" <<'OLD'
# specify

<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed by spec-kit-figma; re-running install.sh keeps a single copy) -->
old hook body
<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->
OLD
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEANED:"* ]]
  ! grep -q "SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.claude/commands/speckit.specify.md"
  grep -q "^# specify" "${WORKSPACE}/.claude/commands/speckit.specify.md"
}

@test "--prompt-hooks appends the auto-context hook to existing speckit command prompts" {
  mkdir -p "${WORKSPACE}/.claude/commands" "${WORKSPACE}/.github/prompts"
  echo "# specify" > "${WORKSPACE}/.claude/commands/speckit.specify.md"
  echo "# tasks" > "${WORKSPACE}/.claude/commands/speckit.tasks.md"
  echo "# specify" > "${WORKSPACE}/.github/prompts/speckit.specify.prompt.md"
  run "$INSTALL" --target "$WORKSPACE" --prompt-hooks
  [ "$status" -eq 0 ]
  grep -q "SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.claude/commands/speckit.specify.md"
  grep -q "SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.claude/commands/speckit.tasks.md"
  grep -q "SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.github/prompts/speckit.specify.prompt.md"
  grep -q "figma-ensure-context.sh" "${WORKSPACE}/.claude/commands/speckit.specify.md"
}

@test "re-running --prompt-hooks keeps a single copy of the auto-context hook" {
  mkdir -p "${WORKSPACE}/.claude/commands"
  echo "# specify" > "${WORKSPACE}/.claude/commands/speckit.specify.md"
  run "$INSTALL" --target "$WORKSPACE" --prompt-hooks
  [ "$status" -eq 0 ]
  run "$INSTALL" --target "$WORKSPACE" --prompt-hooks
  [ "$status" -eq 0 ]
  count="$(grep -c "BEGIN SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.claude/commands/speckit.specify.md")"
  [ "$count" -eq 1 ]
}

@test "the auto-context hook instructs piping the feature input into ensure-context" {
  mkdir -p "${WORKSPACE}/.claude/commands"
  echo "# specify" > "${WORKSPACE}/.claude/commands/speckit.specify.md"
  run "$INSTALL" --target "$WORKSPACE" --prompt-hooks
  [ "$status" -eq 0 ]
  grep -q -- "--input -" "${WORKSPACE}/.claude/commands/speckit.specify.md"
}

@test "--prompt-hooks refreshes an outdated auto-context hook in place" {
  mkdir -p "${WORKSPACE}/.claude/commands"
  cat > "${WORKSPACE}/.claude/commands/speckit.specify.md" <<'OLD'
# specify

<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed by spec-kit-figma; re-running install.sh keeps a single copy) -->
old hook body without input forwarding
<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->
OLD
  run "$INSTALL" --target "$WORKSPACE" --prompt-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"UPDATED:"* ]]
  count="$(grep -c "BEGIN SPECKIT-FIGMA AUTO-CONTEXT" "${WORKSPACE}/.claude/commands/speckit.specify.md")"
  [ "$count" -eq 1 ]
  ! grep -q "old hook body" "${WORKSPACE}/.claude/commands/speckit.specify.md"
  grep -q -- "--input -" "${WORKSPACE}/.claude/commands/speckit.specify.md"
  grep -q "^# specify" "${WORKSPACE}/.claude/commands/speckit.specify.md"
}

@test "--no-hooks leaves the speckit command prompts fully untouched" {
  mkdir -p "${WORKSPACE}/.claude/commands"
  cat > "${WORKSPACE}/.claude/commands/speckit.specify.md" <<'OLD'
# specify

<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed by spec-kit-figma) -->
old hook body
<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->
OLD
  run "$INSTALL" --target "$WORKSPACE" --no-hooks
  [ "$status" -eq 0 ]
  grep -q "old hook body" "${WORKSPACE}/.claude/commands/speckit.specify.md"
}

@test "--prompt-hooks notes when no speckit command files exist to hook" {
  run "$INSTALL" --target "$WORKSPACE" --prompt-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"no /speckit.specify, /speckit.plan or /speckit.tasks command files found"* ]]
}

@test "install copies the ensure-context helper script" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -x "${WORKSPACE}/.specify/scripts/bash/figma-ensure-context.sh" ]
}
