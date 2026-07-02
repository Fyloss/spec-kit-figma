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

@test "install puts the design-rules constitution in .figma/" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/figma-design-rules.md" ]
}

@test "install scaffolds the design-rules custom overlay in .figma/" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/figma-design-rules.custom.md" ]
}

@test "re-running install preserves user edits to the custom overlay (skip-if-exists)" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  printf '\n## My project rule\n- custom line\n' >> "${WORKSPACE}/.figma/figma-design-rules.custom.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  grep -qF "My project rule" "${WORKSPACE}/.figma/figma-design-rules.custom.md"
  [[ "$output" == *"figma-design-rules.custom.md already exists"* ]]
}

@test "install always refreshes the base but never overwrites the custom overlay" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  # User tampers with both files.
  printf 'tampered base\n' > "${WORKSPACE}/.figma/figma-design-rules.md"
  printf 'tampered custom\n' > "${WORKSPACE}/.figma/figma-design-rules.custom.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  # The base is extension-owned: it is restored.
  ! grep -qxF "tampered base" "${WORKSPACE}/.figma/figma-design-rules.md"
  # The overlay is user-owned: it is left untouched.
  grep -qxF "tampered custom" "${WORKSPACE}/.figma/figma-design-rules.custom.md"
}

@test "install never git-ignores the custom overlay (CI / Cloud Agents must see it)" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  ! grep -q "figma-design-rules.custom.md" "${WORKSPACE}/.gitignore"
}

@test "install removes a legacy .specify/memory design-rules copy" {
  mkdir -p "${WORKSPACE}/.specify/memory"
  printf 'legacy\n' > "${WORKSPACE}/.specify/memory/figma-design-rules.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ ! -e "${WORKSPACE}/.specify/memory/figma-design-rules.md" ]
  [ -f "${WORKSPACE}/.figma/figma-design-rules.md" ]
}

@test "install never creates a .env or .env.example file" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ ! -e "${WORKSPACE}/.env" ]
  [ ! -e "${WORKSPACE}/.env.example" ]
}

@test "install git-ignores .figma/cache/ but not .env" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  grep -qxF ".figma/cache/" "${WORKSPACE}/.gitignore"
  ! grep -qxF ".env" "${WORKSPACE}/.gitignore"
}

@test "install migrates a legacy .figma/ gitignore entry to .figma/cache/" {
  printf '.figma/\n' > "${WORKSPACE}/.gitignore"
  printf '{}' > "${WORKSPACE}/.figma/context-snapshot.json"
  printf 'stale\n' > "${WORKSPACE}/.figma/section.spec.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  ! grep -qxF ".figma/" "${WORKSPACE}/.gitignore"
  grep -qxF ".figma/cache/" "${WORKSPACE}/.gitignore"
  # Legacy root-level cached artifacts are dropped; the constitution remains.
  [ ! -e "${WORKSPACE}/.figma/context-snapshot.json" ]
  [ ! -e "${WORKSPACE}/.figma/section.spec.md" ]
  [ -f "${WORKSPACE}/.figma/figma-design-rules.md" ]
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

# --- Update / sync awareness -------------------------------------------------

@test "re-running install restores a helper script removed from the workspace" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  rm -f "${WORKSPACE}/.specify/scripts/bash/figma-introspect.sh"
  [ ! -f "${WORKSPACE}/.specify/scripts/bash/figma-introspect.sh" ]
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -x "${WORKSPACE}/.specify/scripts/bash/figma-introspect.sh" ]
}

@test "install keeps no parallel version stamp (SpecKit's manifest is the source of truth)" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ ! -f "${WORKSPACE}/.specify/.figma-extension-version" ]
}

@test "install reports figma not yet registered when SpecKit has no manifest" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet registered"* ]]
}

@test "install reports in sync when the registered version matches the assets" {
  src_ver="$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' "${REPO_ROOT}/extension.yml" | head -1)"
  mkdir -p "${WORKSPACE}/.specify/extensions/figma"
  printf 'extension:\n  id: figma\n  version: "%s"\n' "$src_ver" \
    > "${WORKSPACE}/.specify/extensions/figma/extension.yml"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
}

@test "install warns on version mismatch when the registered version is older" {
  mkdir -p "${WORKSPACE}/.specify/extensions/figma"
  printf 'extension:\n  id: figma\n  version: "0.9.0"\n' \
    > "${WORKSPACE}/.specify/extensions/figma/extension.yml"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mismatch"* ]]
  [[ "$output" == *"0.9.0"* ]]
}

@test "install recognizes figma registered via the plural extensions.yml registry" {
  mkdir -p "${WORKSPACE}/.specify"
  printf 'installed:\n- agent-context\n- figma\n' > "${WORKSPACE}/.specify/extensions.yml"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered with SpecKit"* ]]
  ! [[ "$output" == *"not yet registered"* ]]
}

@test "install recognizes figma registered via the singular extension.yml registry" {
  mkdir -p "${WORKSPACE}/.specify"
  printf 'installed:\n- figma\n' > "${WORKSPACE}/.specify/extension.yml"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered with SpecKit"* ]]
  ! [[ "$output" == *"not yet registered"* ]]
}

@test "install parses a single-quoted manifest version (reports in sync)" {
  src_ver="$(sed -n "s/^[[:space:]]*version:[[:space:]]*['\"]\{0,1\}\([0-9][0-9.]*\)['\"]\{0,1\}.*/\1/p" "${REPO_ROOT}/extension.yml" | head -1)"
  mkdir -p "${WORKSPACE}/.specify/extensions/figma"
  printf "extension:\n  id: figma\n  version: '%s'\n" "$src_ver" \
    > "${WORKSPACE}/.specify/extensions/figma/extension.yml"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
}

@test "a present manifest with an unparseable version still counts as registered (not 'not yet registered')" {
  mkdir -p "${WORKSPACE}/.specify/extensions/figma"
  printf 'extension:\n  id: figma\n  version: "latest"\n' \
    > "${WORKSPACE}/.specify/extensions/figma/extension.yml"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered with SpecKit"* ]]
  ! [[ "$output" == *"not yet registered"* ]]
}

@test "a '- figma' item outside the installed: block does not count as registered" {
  mkdir -p "${WORKSPACE}/.specify"
  printf 'installed:\n- agent-context\ndisabled:\n- figma\n' \
    > "${WORKSPACE}/.specify/extensions.yml"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not yet registered"* ]]
}

@test "the per-extension manifest version wins over the registry registration signal" {
  mkdir -p "${WORKSPACE}/.specify/extensions/figma"
  printf 'installed:\n- figma\n' > "${WORKSPACE}/.specify/extensions.yml"
  printf 'extension:\n  id: figma\n  version: "0.9.0"\n' \
    > "${WORKSPACE}/.specify/extensions/figma/extension.yml"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mismatch"* ]]
  [[ "$output" == *"0.9.0"* ]]
}

@test "install warns when figma commands are missing from a configured agent dir" {
  mkdir -p "${WORKSPACE}/.claude/commands"
  echo "# specify" > "${WORKSPACE}/.claude/commands/speckit.specify.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not registered"* ]]
  [[ "$output" == *".claude/commands"* ]]
}

# --- Workspace docs + README section -----------------------------------------

@test "install copies the user guides into .figma/docs/" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/.figma/docs/CREDENTIALS.md" ]
  [ -f "${WORKSPACE}/.figma/docs/INSTALL.md" ]
  [ -f "${WORKSPACE}/.figma/docs/MONOREPO.md" ]
}

@test "re-running install refreshes the local guides (extension-owned)" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  printf 'tampered guide\n' > "${WORKSPACE}/.figma/docs/CREDENTIALS.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  ! grep -qxF "tampered guide" "${WORKSPACE}/.figma/docs/CREDENTIALS.md"
}

@test "install creates a README with the managed figma section when none exists" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -f "${WORKSPACE}/README.md" ]
  # Created README opens with a title derived from the workspace directory.
  head -1 "${WORKSPACE}/README.md" | grep -q "^# "
  grep -q "BEGIN SPECKIT-FIGMA README" "${WORKSPACE}/README.md"
  grep -q "END SPECKIT-FIGMA README" "${WORKSPACE}/README.md"
  grep -q "FIGMA_PAT_COMMAND" "${WORKSPACE}/README.md"
  grep -q ".figma/docs/CREDENTIALS.md" "${WORKSPACE}/README.md"
}

@test "install appends the figma section to an existing README without touching its content" {
  printf '# My project\n\nSome intro.\n' > "${WORKSPACE}/README.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  head -1 "${WORKSPACE}/README.md" | grep -q "^# My project"
  grep -qF "Some intro." "${WORKSPACE}/README.md"
  grep -q "BEGIN SPECKIT-FIGMA README" "${WORKSPACE}/README.md"
}

@test "re-running install keeps a single refreshed copy of the README figma section" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UPDATED: figma section"* ]]
  count="$(grep -c "BEGIN SPECKIT-FIGMA README" "${WORKSPACE}/README.md")"
  [ "$count" -eq 1 ]
}

@test "install refreshes an outdated README figma section in place" {
  cat > "${WORKSPACE}/README.md" <<'OLD'
# My project

<!-- BEGIN SPECKIT-FIGMA README (managed by spec-kit-figma v0.9.0) -->
old readme section body
<!-- END SPECKIT-FIGMA README -->
OLD
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  head -1 "${WORKSPACE}/README.md" | grep -q "^# My project"
  ! grep -q "old readme section body" "${WORKSPACE}/README.md"
  grep -q "FIGMA_PAT_COMMAND" "${WORKSPACE}/README.md"
  count="$(grep -c "BEGIN SPECKIT-FIGMA README" "${WORKSPACE}/README.md")"
  [ "$count" -eq 1 ]
}

@test "the README figma section embeds the extension version from extension.yml" {
  src_ver="$(sed -n "s/^[[:space:]]*version:[[:space:]]*['\"]\{0,1\}\([0-9][0-9.]*\)['\"]\{0,1\}.*/\1/p" "${REPO_ROOT}/extension.yml" | head -1)"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  grep -qF "v${src_ver}" "${WORKSPACE}/README.md"
  # No placeholder may survive the rendering.
  ! grep -q "{{" "${WORKSPACE}/README.md"
}

@test "an update run without --mode keeps the mode advertised by the existing config" {
  run "$INSTALL" --target "$WORKSPACE" --mode mono-repo
  [ "$status" -eq 0 ]
  # Update runs typically omit --mode; the config must win over the default.
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  grep -qF "(mono-repo layout)" "${WORKSPACE}/README.md"
  ! grep -qF "(single-repo layout)" "${WORKSPACE}/README.md"
}

@test "install appends the figma section to a lowercase readme.md" {
  printf '# my project\n' > "${WORKSPACE}/readme.md"
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  grep -q "BEGIN SPECKIT-FIGMA README" "${WORKSPACE}/readme.md"
}

@test "--no-readme leaves an existing README strictly untouched" {
  cat > "${WORKSPACE}/README.md" <<'OLD'
# My project

<!-- BEGIN SPECKIT-FIGMA README (managed by spec-kit-figma v0.9.0) -->
old readme section body
<!-- END SPECKIT-FIGMA README -->
OLD
  run "$INSTALL" --target "$WORKSPACE" --no-readme
  [ "$status" -eq 0 ]
  grep -q "old readme section body" "${WORKSPACE}/README.md"
  count="$(grep -c "BEGIN SPECKIT-FIGMA README" "${WORKSPACE}/README.md")"
  [ "$count" -eq 1 ]
}

@test "--no-readme does not create a README" {
  run "$INSTALL" --target "$WORKSPACE" --no-readme
  [ "$status" -eq 0 ]
  [ ! -e "${WORKSPACE}/README.md" ]
}

@test "the readme block template is not copied to .specify/templates/ (section templates only)" {
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ ! -e "${WORKSPACE}/.specify/templates/figma-readme-block.template.md" ]
}

@test "install does not warn about command drift when figma commands are present" {
  mkdir -p "${WORKSPACE}/.claude/commands"
  echo "# specify" > "${WORKSPACE}/.claude/commands/speckit.specify.md"
  for stem in setup ensure introspect verify update; do
    echo "# $stem" > "${WORKSPACE}/.claude/commands/speckit.figma.${stem}.md"
  done
  run "$INSTALL" --target "$WORKSPACE"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"not registered"* ]]
}
