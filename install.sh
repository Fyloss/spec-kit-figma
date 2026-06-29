#!/usr/bin/env bash
# =============================================================================
# install.sh — install the SpecKit Figma extension into a target workspace
# =============================================================================
# Usage:
#   ./install.sh [--target <workspace-root>] [--mode single-repo|mono-repo|multi-repo]
#                [--prompt-hooks | --no-hooks]
# What it does (idempotent):
#   - copies the figma.projects.config example to <root>/figma.projects.config.json
#   - copies the helper scripts to <root>/.specify/scripts/bash/ (docs and
#     commands invoke ./.specify/scripts/bash/*.sh from the workspace root, the
#     SpecKit convention — alongside .specify/memory/)
#   - ensures .figma-context-snapshot.json is git-ignored
#   - creates .specify/memory/ and installs the design-rules memory
#   - by default LEAVES the /speckit.specify, /speckit.plan and /speckit.tasks
#     prompts untouched (automatic Figma context runs via the extension.yml hooks
#     before_specify/before_plan/before_tasks -> /speckit.figma.ensure) and removes any
#     auto-context block a previous version injected. --prompt-hooks opts back
#     into prompt injection for agents without SpecKit extension-hook support;
#     --no-hooks touches nothing (not even cleanup).
#   - prints the next steps (it does NOT replace placeholders or write tokens)
# =============================================================================
set -euo pipefail
EXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Extract the first numeric `version:` value from a YAML file. Accepts the value
# bare, single- or double-quoted. `schema_version:` / `speckit_version:` do not
# match `^[[:space:]]*version:`, so the first hit is the extension's own version.
# Defined here (not inside the coherence block) so every caller shares one regex.
yaml_version() {
  [[ -f "$1" ]] || return 0
  sed -n "s/^[[:space:]]*version:[[:space:]]*['\"]\{0,1\}\([0-9][0-9.]*\)['\"]\{0,1\}.*/\1/p" "$1" 2>/dev/null | head -1
}

# Extension id and version, read from the extension's own manifest. The id drives
# the SpecKit paths we inspect later, so we derive it rather than hardcoding it.
EXT_VERSION="$(yaml_version "$EXT_DIR/extension.yml")"
[[ -n "$EXT_VERSION" ]] || EXT_VERSION="unknown"
EXT_ID="$(sed -n "s/^[[:space:]]*id:[[:space:]]*['\"]\{0,1\}\([A-Za-z0-9._-]\{1,\}\)['\"]\{0,1\}.*/\1/p" "$EXT_DIR/extension.yml" 2>/dev/null | head -1)"
[[ -n "$EXT_ID" ]] || EXT_ID="figma"

# Per-agent command locations created by `specify init` (markdown-based agents).
# Single source of truth: both the hook-injection loop and the command-drift
# loop iterate this, so a newly supported agent format is added in one place.
AGENT_CMD_DIRS=(.claude/commands .github/prompts .cursor/commands .windsurf/workflows .opencode/command)

# Default to the workspace the installer is invoked from (its git root, else $PWD),
# NOT the extension's own repo. --target still overrides this.
TARGET="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MODE="single-repo"
HOOKS="clean"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --prompt-hooks) HOOKS="inject"; shift ;;
    --no-hooks) HOOKS="off"; shift ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

# Canonical target path, resolved once. Used to tell apart "installing into a
# project" from "running inside the extension checkout itself".
TARGET_REAL="$(cd "$TARGET" 2>/dev/null && pwd -P || echo "$TARGET")"

case "$MODE" in single-repo|mono-repo|multi-repo) ;; *) echo "ERROR: --mode must be single-repo|mono-repo|multi-repo" >&2; exit 1 ;; esac

case "$MODE" in
  single-repo) EXAMPLE_SUFFIX="singlerepo" ;;
  mono-repo)   EXAMPLE_SUFFIX="monorepo" ;;
  multi-repo)  EXAMPLE_SUFFIX="multirepo" ;;
esac
EXAMPLE="$EXT_DIR/config/figma.projects.config.${EXAMPLE_SUFFIX}.example.json"
CONFIG_DEST="$TARGET/figma.projects.config.json"

if [[ -f "$CONFIG_DEST" ]]; then
  echo "SKIP: $CONFIG_DEST already exists (not overwritten)."
else
  cp "$EXAMPLE" "$CONFIG_DEST"
  echo "ADDED: $CONFIG_DEST (from $MODE example) — edit it and replace REPLACE_WITH_* ids."
fi

# The docs and slash-commands run ./.specify/scripts/bash/*.sh from the workspace
# root (the SpecKit convention, alongside .specify/memory/), so the helper scripts
# must live in the workspace, not only in this checkout.
# Always refreshed: they are extension-owned code, not user-edited files.
if [[ "$TARGET_REAL" == "$EXT_DIR" ]]; then
  echo "SKIP: .specify/scripts/bash/ (target is the extension checkout itself; scripts already at scripts/bash/)."
else
  mkdir -p "$TARGET/.specify/scripts/bash"
  cp "$EXT_DIR/scripts/bash/"*.sh "$TARGET/.specify/scripts/bash/"
  echo "ADDED: .specify/scripts/bash/ (figma-*.sh helpers)"
fi

GI="$TARGET/.gitignore"
touch "$GI"
for SNAPSHOT_ENTRY in ".figma-context-snapshot.json" ".figma-section.*.md"; do
  grep -qxF "$SNAPSHOT_ENTRY" "$GI" || { echo "$SNAPSHOT_ENTRY" >> "$GI"; echo "GITIGNORE: added $SNAPSHOT_ENTRY"; }
done

# The introspect command mandates loading this memory file, so it must always
# be installed — create .specify/memory rather than silently skipping.
mkdir -p "$TARGET/.specify/memory"
cp "$EXT_DIR/memory/figma-design-rules.md" "$TARGET/.specify/memory/figma-design-rules.md"
echo "ADDED: .specify/memory/figma-design-rules.md"

# The section templates MUST be installed so figma-render-section.sh can produce
# the ready-to-paste spec/plan/tasks blocks in the workspace (not only from the
# extension checkout). Extension-owned, always refreshed.
if [[ "$TARGET_REAL" != "$EXT_DIR" ]]; then
  mkdir -p "$TARGET/.specify/templates"
  # Guard the glob: if no *figma-section.template.md exists (partial/corrupted
  # checkout), the unquoted glob would stay literal and cp would fail, aborting
  # the installer under set -e mid-way. Consume the failure and warn instead.
  if cp "$EXT_DIR/templates/"*figma-section.template.md "$TARGET/.specify/templates/" 2>/dev/null; then
    echo "ADDED: .specify/templates/ (spec/plan/tasks figma-section templates)"
  else
    echo "WARN: no *figma-section.template.md found in ${EXT_DIR}/templates/ — section rendering will fall back to the extension checkout." >&2
  fi
fi

# -----------------------------------------------------------------------------
# Version coherence. SpecKit records the *registered* extension — and thus the
# version whose slash-commands are wired — written by `specify extension add`.
# We keep NO parallel stamp: that would be a second source of truth that can
# desync from SpecKit's. We read SpecKit's own record and compare it to the
# version these ASSETS come from, so a half-applied update (assets re-synced but
# commands not re-registered, or vice versa) is surfaced instead of silently
# diverging. Skipped when the target IS the extension checkout.
#
# Two SpecKit files, with version-dependent names:
#   - the per-extension manifest .specify/extensions/<id>/extension.yml carries
#     the installed `version`; its mere presence also proves the extension is
#     registered, even when the version cannot be parsed;
#   - the project registry lists installed extensions under `installed:` and is
#     named .specify/extensions.yml on some SpecKit versions and
#     .specify/extension.yml on others — we accept BOTH, as a registration
#     signal and as a fallback when the per-extension manifest is absent.
# -----------------------------------------------------------------------------
if [[ "$TARGET_REAL" != "$EXT_DIR" ]]; then
  MANIFEST="$TARGET/.specify/extensions/${EXT_ID}/extension.yml"
  REGISTERED_VERSION="$(yaml_version "$MANIFEST")"

  # Registered? The manifest existing is proof on its own; otherwise look for the
  # id as an `installed:` list item in either registry name. The awk scopes the
  # match to the installed: block so a `- <id>` under another key (hooks,
  # disabled, ...) cannot raise a false positive.
  FIGMA_REGISTERED="false"
  [[ -f "$MANIFEST" ]] && FIGMA_REGISTERED="true"
  for REG in "$TARGET/.specify/extensions.yml" "$TARGET/.specify/extension.yml"; do
    [[ -f "$REG" ]] || continue
    if awk -v id="$EXT_ID" '
      /^[A-Za-z_][A-Za-z0-9_-]*:/ { in_installed = ($0 ~ /^installed:/); next }
      in_installed && $0 ~ ("^[[:space:]]*-[[:space:]]+" id "[[:space:]]*$") { found = 1 }
      END { exit (found ? 0 : 1) }
    ' "$REG"; then
      FIGMA_REGISTERED="true"
    fi
  done

  if [[ -n "$REGISTERED_VERSION" ]]; then
    if [[ "$REGISTERED_VERSION" == "$EXT_VERSION" ]]; then
      echo "INFO: ${EXT_ID} extension in sync at ${EXT_VERSION} (assets and registered commands match)."
    else
      echo "WARN: ${EXT_ID} version mismatch — assets just synced to ${EXT_VERSION} but SpecKit has commands registered at ${REGISTERED_VERSION}. Run 'specify extension add ${EXT_ID} --from <source>' to align the commands." >&2
    fi
  elif [[ "$FIGMA_REGISTERED" == "true" ]]; then
    echo "INFO: ${EXT_ID} registered with SpecKit but its installed version could not be read from this layout; assets synced at ${EXT_VERSION}. Re-run 'specify extension add ${EXT_ID}' if commands misbehave."
  else
    echo "INFO: ${EXT_ID} assets synced at ${EXT_VERSION}; extension not yet registered with SpecKit — run 'specify extension add ${EXT_ID}' to register its commands."
  fi
fi

# -----------------------------------------------------------------------------
# Prompt auto-context block. DEFAULT ("clean"): the prompts are NOT modified —
# automatic Figma context is provided by the extension.yml hooks
# (before_specify/before_plan/before_tasks -> /speckit.figma.ensure) — and any block a
# previous extension version injected is removed. "--prompt-hooks" ("inject")
# appends/refreshes the managed block for agents without SpecKit
# extension-hook support. "--no-hooks" ("off") touches nothing.
# -----------------------------------------------------------------------------
HOOK_MARKER_BEGIN="BEGIN SPECKIT-FIGMA AUTO-CONTEXT"
HOOK_MARKER_END="END SPECKIT-FIGMA AUTO-CONTEXT"

# Strip the managed block (markers included) from a prompt file, collapsing
# the trailing blank lines so repeated runs do not accumulate whitespace
# ($(cat) strips them, printf restores one newline).
strip_hook_block() {
  local file="$1"
  local tmp; tmp="$(mktemp)"
  awk -v b="$HOOK_MARKER_BEGIN" -v e="$HOOK_MARKER_END" '
    index($0, b) { skip = 1; next }
    index($0, e) { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  printf '%s\n' "$(cat "$tmp")" > "$file"
  rm -f "$tmp"
}

remove_hook() {
  local file="$1"
  grep -qF "$HOOK_MARKER_BEGIN" "$file" || return 0
  strip_hook_block "$file"
  echo "CLEANED: ${file#"$TARGET"/} (auto-context now runs via the extension hooks; use --prompt-hooks to reinstate prompt injection)"
}

inject_hook() {
  local file="$1" action="HOOKED"
  if grep -qF "$HOOK_MARKER_BEGIN" "$file"; then
    # Managed block: strip the previous copy and re-append the current one,
    # so re-running install.sh upgrades existing workspaces.
    strip_hook_block "$file"
    action="UPDATED"
  fi
  cat >> "$file" <<'HOOK'

<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed by spec-kit-figma; re-running install.sh refreshes this block) -->
## Figma design context (automatic)

Before generating, refresh the Figma design context:

1. From the workspace root, run `./.specify/scripts/bash/figma-ensure-context.sh`,
   piping the user's RAW feature input (description, arguments, any pasted
   links — verbatim) via `--input -` (pass the target package name as the
   first argument in mono-/multi-repo workspaces):

   ```bash
   ./.specify/scripts/bash/figma-ensure-context.sh --input - <<'SPECKIT_FIGMA_INPUT'
   <the user's verbatim feature input>
   SPECKIT_FIGMA_INPUT
   ```

   Any direct Figma link in the input is detected and introspected
   automatically — the linked file/frames become the authoritative design
   targets (node-level detail included), so no manual
   /speckit.figma.introspect run is needed. The script is a safe no-op when
   the extension is not configured, the target is excluded, or
   `.figma-context-snapshot.json` is already fresh and covers the linked
   nodes.
2. When it prints `"ran": true` or `"reason": "fresh"` with `"mustInject": true`,
   the Figma design section is MANDATORY in this document — never omit it,
   whatever the agent model. The script renders a ready-to-paste section to the
   path reported in `specSection` / `planSection` / `tasksSection` (the one
   matching this command): insert that rendered block VERBATIM into the
   generated document, then load `.figma-context-snapshot.json` and complete the
   judgement placeholders by applying the rules of `/speckit.figma.introspect`
   (sections 3-7: frame confirmation, component placement, token gaps, tests +
   Storybook sub-tasks). Treat any `links` reported in the status JSON as
   authoritative design targets for the affected components.
3. For any other skip reason, proceed without Figma context and add a short
   note mentioning the reason.
<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->
HOOK
  echo "${action}: ${file#"$TARGET"/}"
}

if [[ "$HOOKS" != "off" ]]; then
  HOOKED_ANY="false"
  for dir in "${AGENT_CMD_DIRS[@]}"; do
    for stem in specify plan tasks; do
      for f in "$TARGET/$dir/speckit.${stem}.md" "$TARGET/$dir/speckit.${stem}.prompt.md"; do
        [[ -f "$f" ]] || continue
        if [[ "$HOOKS" == "inject" ]]; then
          inject_hook "$f"
        else
          remove_hook "$f"
        fi
        HOOKED_ANY="true"
      done
    done
  done
  if [[ "$HOOKS" == "inject" && "$HOOKED_ANY" == "false" ]]; then
    echo "NOTE: no /speckit.specify, /speckit.plan or /speckit.tasks command files found — run 'specify init' first, then re-run install.sh --prompt-hooks to enable prompt injection."
  fi
  if [[ "$HOOKS" == "clean" ]]; then
    echo "INFO: speckit command prompts left untouched — automatic Figma context runs via the extension hooks (before_specify/before_plan/before_tasks -> /speckit.figma.ensure, after_specify/after_plan/after_tasks -> /speckit.figma.verify). Use --prompt-hooks if your agent does not support SpecKit extension hooks."
  fi
fi

# -----------------------------------------------------------------------------
# Command-drift detection. install.sh copies the workspace ASSETS but does NOT
# register the slash-commands — that is `specify extension add`'s job, which is
# agent-format aware. So a version bump that adds a new command (or a freshly
# configured agent) leaves the figma commands unregistered for that agent. We
# cannot register them here without duplicating SpecKit, but we CAN detect the
# gap and tell the user exactly what to run. The command stems are derived from
# the extension's own commands/ directory so new commands are covered for free.
# -----------------------------------------------------------------------------
FIGMA_STEMS=()
for cmd_file in "$EXT_DIR/commands/"speckit.figma.*.md; do
  [[ -e "$cmd_file" ]] || continue
  stem="$(basename "$cmd_file")"; stem="${stem#speckit.figma.}"; stem="${stem%.md}"
  FIGMA_STEMS+=("$stem")
done

if [[ ${#FIGMA_STEMS[@]} -gt 0 ]]; then
  for dir in "${AGENT_CMD_DIRS[@]}"; do
    [[ -d "$TARGET/$dir" ]] || continue
    # Only a dir that already holds a speckit command counts as a configured
    # agent — otherwise an empty/unrelated dir would trigger a false warning.
    ls "$TARGET/$dir/"speckit.* >/dev/null 2>&1 || continue
    missing=()
    for stem in "${FIGMA_STEMS[@]}"; do
      [[ -f "$TARGET/$dir/speckit.figma.${stem}.md" || -f "$TARGET/$dir/speckit.figma.${stem}.prompt.md" ]] && continue
      missing+=("$stem")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "WARN: figma command(s) not registered for ${dir}: ${missing[*]} — run 'specify extension add figma' to (re)register them for this agent." >&2
    fi
  done
fi

cat <<EOF

Next steps:
  1. Edit figma.projects.config.json — list targets, fill excluded[], replace REPLACE_WITH_* ids.
  2. Local dev: store your READ-ONLY Figma PAT in the OS keychain and export FIGMA_PAT_COMMAND
     in your shell profile, e.g. in ~/.zshrc (see docs/CREDENTIALS.md):
       security add-generic-password -s figma-pat -a "\$USER" -w 'figd_xxxxxxxx'
       echo 'export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"' >> ~/.zshrc
     CI / Cloud Agent: set credentials.source = "ci-secret" and inject a platform secret.
  3. Validate (from the workspace root):  ./.specify/scripts/bash/figma-validate-config.sh
  4. Register the extension commands (commands/speckit.figma.*.md)
     with your SpecKit agent of choice — or install natively with
     'specify extension add' (see extension.yml / docs/INSTALL.md), which registers
     /speckit.figma.setup, /speckit.figma.update, /speckit.figma.ensure,
     /speckit.figma.introspect and /speckit.figma.verify for you.
EOF
