#!/usr/bin/env bash
# =============================================================================
# install.sh — install the SpecKit Figma extension into a target workspace
# =============================================================================
# Usage:
#   ./install.sh [--target <workspace-root>] [--mode single-repo|mono-repo|multi-repo]
# What it does (idempotent):
#   - copies the figma.projects.config example to <root>/figma.projects.config.json
#   - copies the helper scripts to <root>/scripts/bash/ (docs and commands
#     invoke ./scripts/bash/*.sh from the workspace root)
#   - copies .env.example to <root>/.env.example
#   - ensures .env and .figma-context-snapshot.json are git-ignored
#   - creates .specify/memory/ and installs the design-rules memory
#   - appends an auto-context block to the workspace's /speckit.specify and
#     /speckit.tasks command prompts so Figma introspection runs automatically
#     (skip with --no-hooks)
#   - prints the next steps (it does NOT replace placeholders or write tokens)
# =============================================================================
set -euo pipefail
EXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default to the workspace the installer is invoked from (its git root, else $PWD),
# NOT the extension's own repo. --target still overrides this.
TARGET="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MODE="single-repo"
HOOKS="true"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --no-hooks) HOOKS="false"; shift ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

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

# The docs and slash-commands run ./scripts/bash/*.sh from the workspace root,
# so the helper scripts must live in the workspace, not only in this checkout.
# Always refreshed: they are extension-owned code, not user-edited files.
if [[ "$(cd "$TARGET" && pwd -P)" == "$EXT_DIR" ]]; then
  echo "SKIP: scripts/bash/ (target is the extension checkout itself)."
else
  mkdir -p "$TARGET/scripts/bash"
  cp "$EXT_DIR/scripts/bash/"*.sh "$TARGET/scripts/bash/"
  echo "ADDED: scripts/bash/ (figma-*.sh helpers)"
fi

# Explicit existence check: cp -n's exit status is not portable (GNU coreutils
# <9.2 exits 0 on skip), and silencing stderr would report real failures as SKIP.
if [[ -e "$TARGET/.env.example" ]]; then
  echo "SKIP: .env.example already present."
else
  cp "$EXT_DIR/config/.env.example" "$TARGET/.env.example"
  echo "ADDED: $TARGET/.env.example"
fi

GI="$TARGET/.gitignore"
touch "$GI"
for entry in ".env" ".figma-context-snapshot.json"; do
  grep -qxF "$entry" "$GI" || { echo "$entry" >> "$GI"; echo "GITIGNORE: added $entry"; }
done

# The introspect command mandates loading this memory file, so it must always
# be installed — create .specify/memory rather than silently skipping.
mkdir -p "$TARGET/.specify/memory"
cp "$EXT_DIR/memory/figma-design-rules.md" "$TARGET/.specify/memory/figma-design-rules.md"
echo "ADDED: .specify/memory/figma-design-rules.md"

# -----------------------------------------------------------------------------
# Auto-context hooks: append a managed block to the workspace's existing
# /speckit.specify and /speckit.tasks command prompts so the agent refreshes
# the Figma snapshot automatically — no manual /speckit.figma.introspect run.
# -----------------------------------------------------------------------------
HOOK_MARKER_BEGIN="BEGIN SPECKIT-FIGMA AUTO-CONTEXT"
HOOK_MARKER_END="END SPECKIT-FIGMA AUTO-CONTEXT"
inject_hook() {
  local file="$1" action="HOOKED"
  if grep -qF "$HOOK_MARKER_BEGIN" "$file"; then
    # Managed block: strip the previous copy (markers included) and re-append
    # the current one, so re-running install.sh upgrades existing workspaces.
    local tmp; tmp="$(mktemp)"
    awk -v b="$HOOK_MARKER_BEGIN" -v e="$HOOK_MARKER_END" '
      index($0, b) { skip = 1; next }
      index($0, e) { skip = 0; next }
      !skip { print }
    ' "$file" > "$tmp"
    # Collapse the trailing blank lines left by the removal so re-runs do not
    # accumulate whitespace ($(cat) strips them, printf restores one newline).
    printf '%s\n' "$(cat "$tmp")" > "$file"
    rm -f "$tmp"
    action="UPDATED"
  fi
  cat >> "$file" <<'HOOK'

<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed by spec-kit-figma; re-running install.sh refreshes this block) -->
## Figma design context (automatic)

Before generating, refresh the Figma design context:

1. From the workspace root, run `./scripts/bash/figma-ensure-context.sh`,
   piping the user's RAW feature input (description, arguments, any pasted
   links — verbatim) via `--input -` (pass the target package name as the
   first argument in mono-/multi-repo workspaces):

   ```bash
   ./scripts/bash/figma-ensure-context.sh --input - <<'SPECKIT_FIGMA_INPUT'
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
2. When it prints `"ran": true` or `"reason": "fresh"`, load
   `.figma-context-snapshot.json` and apply the rules of
   `/speckit.figma.introspect` (sections 3-7: frame confirmation, component
   placement, token gaps, tests + Storybook sub-tasks) to the Figma-relevant
   parts of your output. Treat any `links` reported in the status JSON as
   authoritative design targets for the affected components.
3. For any other skip reason, proceed without Figma context and add a short
   note mentioning the reason.
<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->
HOOK
  echo "${action}: ${file#"$TARGET"/}"
}

if [[ "$HOOKS" == "true" ]]; then
  HOOKED_ANY="false"
  # Per-agent command locations created by `specify init` (markdown-based agents).
  for dir in .claude/commands .github/prompts .cursor/commands .windsurf/workflows .opencode/command; do
    for stem in specify tasks; do
      for f in "$TARGET/$dir/speckit.${stem}.md" "$TARGET/$dir/speckit.${stem}.prompt.md"; do
        [[ -f "$f" ]] || continue
        inject_hook "$f"
        HOOKED_ANY="true"
      done
    done
  done
  if [[ "$HOOKED_ANY" == "false" ]]; then
    echo "NOTE: no /speckit.specify or /speckit.tasks command files found — run 'specify init' first, then re-run install.sh to enable automatic Figma context."
  fi
fi

cat <<EOF

Next steps:
  1. Edit figma.projects.config.json — list targets, fill excluded[], replace REPLACE_WITH_* ids.
  2. Local dev: cp .env.example .env and add your READ-ONLY Figma PAT (see docs/CREDENTIALS.md).
     CI / Cloud Agent: set credentials.source = "ci-secret" and inject a platform secret.
  3. Validate (from the workspace root):  ./scripts/bash/figma-validate-config.sh
  4. Register the commands (commands/speckit.figma.setup.md, commands/speckit.figma.introspect.md)
     with your SpecKit agent of choice — or install natively with
     'specify extension add' (see extension.yml / docs/INSTALL.md), which registers
     /speckit.figma.setup and /speckit.figma.introspect for you.
EOF
