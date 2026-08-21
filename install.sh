#!/usr/bin/env bash
# =============================================================================
# install.sh — install the SpecKit Figma extension into a target workspace
# =============================================================================
# Usage:
#   ./install.sh [--target <workspace-root>] [--mode single-repo|mono-repo|multi-repo]
#                [--prompt-hooks | --no-hooks] [--no-readme]
# What it does (idempotent):
#   - copies the figma.projects.config example to <root>/figma.projects.config.json
#   - checks the extension tree SpecKit installs (<root>/.specify/extensions/figma/)
#     is present: the helpers and templates run FROM it, so `specify extension add`
#     is a prerequisite, and this installer no longer copies either into the
#     workspace. Copies left by earlier versions are removed.
#   - ensures the .figma/cache/ directory (generated/cached artifacts) is git-ignored
#   - installs the design-rules constitution base into .figma/ (committed, next to
#     cache/; extension-owned, always refreshed) and creates the user overlay
#     .figma/figma-design-rules.custom.md once (skip-if-exists; never overwritten,
#     so project customizations survive updates)
#   - copies the guides (CREDENTIALS / INSTALL / MONOREPO / ARCHITECTURE) to .figma/docs/
#     (extension-owned, always refreshed — the workspace docs match the
#     installed version, and work offline)
#   - appends/refreshes a managed "Figma design context" section in the
#     workspace README.md (created if missing): extension version + layout mode,
#     the read-only PAT setup, and links to the local .figma/docs/ guides.
#     Same marker mechanism as the prompt auto-context block; the rest of the
#     README is never touched. --no-readme skips it entirely.
#   - by default LEAVES the /speckit.specify, /speckit.plan, /speckit.tasks,
#     /speckit.analyze and /speckit.implement
#     prompts untouched (automatic Figma context runs via the extension.yml hooks
#     before_specify/before_plan/before_tasks/before_analyze/before_implement ->
#     /speckit.figma.ensure, after_analyze -> /speckit.figma.drift) and removes any
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

# Strip a managed block (markers included) from a file, collapsing the
# trailing blank lines so repeated runs do not accumulate whitespace
# ($(cat) strips them, printf restores one newline). Shared by the prompt
# auto-context hook and the workspace README section.
strip_managed_block() {
  local file="$1" begin="$2" end="$3"
  # An unterminated block (BEGIN without END — e.g. a manually-edited file)
  # would strip to EOF and clobber user content. Refuse (status 1) so the
  # caller warns and leaves the file untouched instead.
  if grep -qF "$begin" "$file" && ! grep -qF "$end" "$file"; then
    return 1
  fi
  local tmp; tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    index($0, b) { skip = 1; next }
    index($0, e) { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  printf '%s\n' "$(cat "$tmp")" > "$file"
  rm -f "$tmp"
}

# Shared caller-side message for the strip_managed_block refusal above.
warn_unterminated() {
  echo "WARN: unterminated SPECKIT-FIGMA block in ${1#"$TARGET"/} (BEGIN without END marker) — left untouched; restore the END marker and re-run install.sh." >&2
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
README_BLOCK="on"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --prompt-hooks) HOOKS="inject"; shift ;;
    --no-hooks) HOOKS="off"; shift ;;
    --no-readme) README_BLOCK="off"; shift ;;
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
# The helpers are NOT copied into the workspace any more: they run straight from
# the extension tree SpecKit itself installs, .specify/extensions/figma/. That
# tree already carries scripts/, templates/ and this installer, so copying them a
# second time into .specify/scripts/ and .specify/templates/ produced two
# versions of the same file — and the copy could silently drift from the manifest
# SpecKit records the version of. `specify extension add` is now the single way
# the code reaches a workspace; this installer only handles what it does not
# cover (config example, design-rules, guides, README block, hooks).
#
# So the tree is a PRECONDITION, checked before anything else is written. A
# workspace missing it would install cleanly and then fail on every hook, with an
# error naming a path the developer never heard of.
EXT_HOME="$TARGET/.specify/extensions/${EXT_ID}"
if [[ ! -f "$EXT_HOME/scripts/bash/figma-common.sh" ]]; then
  cat >&2 <<EOF
ERROR: the Figma extension tree is missing from this workspace.
  Expected: ${EXT_HOME#"$TARGET"/}/scripts/

  The helpers now run from the tree SpecKit installs, so register the extension
  first, then re-run this installer:

    specify extension add ${EXT_ID} --from https://github.com/Fyloss/spec-kit-figma/archive/refs/heads/main.zip
    ./${EXT_HOME#"$TARGET"/}/install.sh

  (from a local checkout: specify extension add --dev /path/to/spec-kit-figma)
EOF
  exit 1
fi
echo "OK: helpers found at ${EXT_HOME#"$TARGET"/}/scripts/ (bash + PowerShell)"

# Earlier versions copied both script families into .specify/scripts/ and the
# section templates into .specify/templates/. Those copies are now dead weight
# that would shadow nothing but confuse everything — and a stale one is worse
# than none, since it is the version the developer reads while the extension runs
# another. Only the figma-* entries go: both directories belong to SpecKit and
# hold its own files.
LEGACY_REMOVED=0
for LEGACY_COPY in "$TARGET"/.specify/scripts/bash/figma-*.sh \
                   "$TARGET"/.specify/scripts/powershell/figma-*.ps1 \
                   "$TARGET"/.specify/templates/*figma-section.template.md; do
  [[ -f "$LEGACY_COPY" ]] || continue
  rm -f "$LEGACY_COPY" && LEGACY_REMOVED=$((LEGACY_REMOVED + 1))
done
if (( LEGACY_REMOVED > 0 )); then
  echo "REMOVED: ${LEGACY_REMOVED} duplicated helper/template file(s) from .specify/scripts/ and .specify/templates/ (they now live in .specify/extensions/figma/)"
fi
# rmdir, never rm -r: the directories are SpecKit's, and only an EMPTY one was
# ours to begin with.
rmdir "$TARGET/.specify/scripts/bash" "$TARGET/.specify/scripts/powershell" 2>/dev/null || true

EXAMPLE="$EXT_DIR/config/figma.projects.config.${EXAMPLE_SUFFIX}.example.json"
CONFIG_DEST="$TARGET/figma.projects.config.json"

if [[ -f "$CONFIG_DEST" ]]; then
  echo "SKIP: $CONFIG_DEST already exists (not overwritten)."
else
  cp "$EXAMPLE" "$CONFIG_DEST"
  echo "ADDED: $CONFIG_DEST (from $MODE example) — edit it and replace REPLACE_WITH_* ids."
fi

GI="$TARGET/.gitignore"
touch "$GI"
# All generated/cached Figma artifacts live under .figma/cache/ — a single entry
# covers the snapshot and every rendered section, while committed content
# (figma-design-rules.md) stays visible at the .figma/ root.
grep -qxF ".figma/cache/" "$GI" || { echo ".figma/cache/" >> "$GI"; echo "GITIGNORE: added .figma/cache/"; }
# Drop legacy entries/files from earlier versions so nothing lingers. `.figma/`
# must go too: it would hide the now-committed .figma/figma-design-rules.md.
for LEGACY_ENTRY in ".figma/" ".figma-context-snapshot.json" ".figma-section.*.md"; do
  if grep -qxF "$LEGACY_ENTRY" "$GI"; then
    grep -vxF "$LEGACY_ENTRY" "$GI" > "$GI.tmp" && mv "$GI.tmp" "$GI"
    echo "GITIGNORE: removed legacy $LEGACY_ENTRY"
  fi
done
rm -f "$TARGET/.figma-context-snapshot.json" "$TARGET"/.figma-section.*.md 2>/dev/null || true
# Cached artifacts written by earlier versions at the .figma/ root are dropped;
# they will be regenerated under .figma/cache/ on the next introspect run.
rm -f "$TARGET/.figma/context-snapshot.json" "$TARGET"/.figma/section.*.md 2>/dev/null || true
# Rendered sections are now scoped per feature under .figma/cache/sections/;
# the flat files earlier versions wrote are dead weight the verifier ignores.
rm -f "$TARGET"/.figma/cache/section.*.md 2>/dev/null || true

# The introspect command mandates loading this constitution file, so it must
# always be installed — into .figma/ (committed), not the git-ignored cache/.
mkdir -p "$TARGET/.figma"
cp "$EXT_DIR/.figma/figma-design-rules.md" "$TARGET/.figma/figma-design-rules.md"
echo "ADDED: .figma/figma-design-rules.md"
# Earlier versions installed it under .specify/memory/; drop that copy so a
# single canonical file remains.
rm -f "$TARGET/.specify/memory/figma-design-rules.md" 2>/dev/null || true

# The user overlay is created ONCE and NEVER overwritten: it holds project-specific
# customizations that must survive every update. On conflict with the base above,
# the overlay wins (see "Layering & precedence" in the base file). Without an
# overlay the base rules apply unchanged. Skipped when the target IS the extension
# checkout, so its own repo is not polluted with an untracked overlay.
if [[ "$TARGET_REAL" != "$EXT_DIR" ]]; then
  CUSTOM_DEST="$TARGET/.figma/figma-design-rules.custom.md"
  if [[ -f "$CUSTOM_DEST" ]]; then
    echo "SKIP: .figma/figma-design-rules.custom.md already exists (user overlay, not overwritten)."
  else
    cp "$EXT_DIR/config/figma-design-rules.custom.example.md" "$CUSTOM_DEST"
    echo "ADDED: .figma/figma-design-rules.custom.md (user overlay — customize freely; preserved across updates)."
  fi
fi

# The section templates are NOT copied either: figma-render-section resolves them
# next to itself, inside the extension tree, so they are always the exact version
# of the renderer that reads them.

# The user guides ship with the workspace so the README section below can link
# to LOCAL copies that match the installed version — a link to the upstream
# GitHub main would document a potentially different version and break offline.
# Extension-owned, always refreshed — like the design-rules base.
if [[ "$TARGET_REAL" != "$EXT_DIR" ]]; then
  mkdir -p "$TARGET/.figma/docs"
  # Guarded like the section-templates glob: a partial checkout must warn, not
  # abort the installer under set -e.
  if cp "$EXT_DIR/docs/"*.md "$TARGET/.figma/docs/" 2>/dev/null; then
    echo "ADDED: .figma/docs/ (CREDENTIALS / INSTALL / MONOREPO / ARCHITECTURE guides, synced to this version)"
  else
    echo "WARN: no guides found in ${EXT_DIR}/docs/ — the README links to .figma/docs/ will dangle." >&2
  fi
fi

# -----------------------------------------------------------------------------
# Workspace README section. The project's README gets a short managed block —
# same marker mechanism as the prompt auto-context hook — telling every
# developer that the extension is active (version + layout mode), how to set up
# their read-only Figma PAT, and where the full local guides live (.figma/docs/,
# synced above). Created if the README does not exist; refreshed in place on
# re-runs; the rest of the file is never touched. --no-readme skips all of it
# (no injection, no cleanup — the block, if any, is the user's to keep).
# Skipped when the target IS the extension checkout: its README is the
# extension's own documentation, not a consumer workspace's.
# -----------------------------------------------------------------------------
README_MARKER_BEGIN="BEGIN SPECKIT-FIGMA README"
README_MARKER_END="END SPECKIT-FIGMA README"
README_TEMPLATE="$EXT_DIR/templates/figma-readme-block.template.md"

if [[ "$README_BLOCK" == "on" && "$TARGET_REAL" != "$EXT_DIR" ]]; then
  if [[ ! -f "$README_TEMPLATE" ]]; then
    echo "WARN: templates/figma-readme-block.template.md missing from ${EXT_DIR} — README section not installed." >&2
  else
    # The block advertises the layout mode. An existing config is the source of
    # truth — an update run usually omits --mode, which must not silently
    # relabel a mono-/multi-repo workspace as single-repo. Fall back to --mode.
    CONFIG_MODE="$(sed -n 's/^[[:space:]]*"mode"[[:space:]]*:[[:space:]]*"\([a-z-]\{1,\}\)".*/\1/p' "$CONFIG_DEST" 2>/dev/null | head -1)"
    README_MODE="${CONFIG_MODE:-$MODE}"
    EXT_REPO_URL="$(sed -n "s/^[[:space:]]*repository:[[:space:]]*['\"]\{0,1\}\([^'\"[:space:]]\{1,\}\)['\"]\{0,1\}.*/\1/p" "$EXT_DIR/extension.yml" 2>/dev/null | head -1)"
    [[ -n "$EXT_REPO_URL" ]] || EXT_REPO_URL="https://github.com/Fyloss/spec-kit-figma"

    # Respect an existing README whatever its case; create README.md otherwise.
    README_DEST=""
    for readme_name in README.md Readme.md readme.md; do
      [[ -f "$TARGET/$readme_name" ]] && { README_DEST="$TARGET/$readme_name"; break; }
    done
    README_ACTION="ADDED"
    if [[ -z "$README_DEST" ]]; then
      README_DEST="$TARGET/README.md"
      printf '# %s\n' "$(basename "$TARGET_REAL")" > "$README_DEST"
      echo "ADDED: README.md (workspace had none — created with a title and the figma section)"
    elif grep -qF "$README_MARKER_BEGIN" "$README_DEST"; then
      # An unterminated block is refused by strip_managed_block: warn, keep the
      # file byte-for-byte intact and skip the append (no second BEGIN marker).
      if strip_managed_block "$README_DEST" "$README_MARKER_BEGIN" "$README_MARKER_END"; then
        README_ACTION="UPDATED"
      else
        warn_unterminated "$README_DEST"
        README_ACTION="skip"
      fi
    fi
    if [[ "$README_ACTION" != "skip" ]]; then
      # sed replacement values: neutralize the two metacharacters of the `s|…|…|`
      # form (& = whole match, | = our delimiter) so an exotic repository URL
      # cannot corrupt the rendered block.
      ESC_REPO_URL="${EXT_REPO_URL//&/\\&}"; ESC_REPO_URL="${ESC_REPO_URL//|/%7C}"
      {
        printf '\n'
        sed -e "s|{{EXTENSION_VERSION}}|${EXT_VERSION}|g" \
            -e "s|{{MODE}}|${README_MODE}|g" \
            -e "s|{{REPOSITORY_URL}}|${ESC_REPO_URL}|g" \
            "$README_TEMPLATE"
      } >> "$README_DEST"
      if [[ "$README_ACTION" == "UPDATED" ]]; then
        echo "UPDATED: figma section in ${README_DEST#"$TARGET"/} (refreshed to v${EXT_VERSION})"
      else
        echo "ADDED: figma section in ${README_DEST#"$TARGET"/} (PAT setup + local guide links; --no-readme to opt out)"
      fi
    fi
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

strip_hook_block() {
  strip_managed_block "$1" "$HOOK_MARKER_BEGIN" "$HOOK_MARKER_END"
}

remove_hook() {
  local file="$1"
  grep -qF "$HOOK_MARKER_BEGIN" "$file" || return 0
  strip_hook_block "$file" || { warn_unterminated "$file"; return 0; }
  echo "CLEANED: ${file#"$TARGET"/} (auto-context now runs via the extension hooks; use --prompt-hooks to reinstate prompt injection)"
}

inject_hook() {
  local file="$1" action="HOOKED"
  if grep -qF "$HOOK_MARKER_BEGIN" "$file"; then
    # Managed block: strip the previous copy and re-append the current one,
    # so re-running install.sh upgrades existing workspaces.
    strip_hook_block "$file" || { warn_unterminated "$file"; return 0; }
    action="UPDATED"
  fi
  cat >> "$file" <<'HOOK'

<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed by spec-kit-figma; re-running install.sh or install.ps1 refreshes this block) -->
## Figma design context (automatic)

Before generating, refresh the Figma design context:

1. From the workspace root, run `./.specify/extensions/figma/scripts/bash/figma-ensure-context.sh`
   (or, on Windows, the PowerShell 7+ port
   `./.specify/extensions/figma/scripts/powershell/figma-ensure-context.ps1` — same flags, same
   output), piping the user's RAW feature input (description, arguments, any
   pasted links — verbatim) via `--input -` (pass the target package name as
   the first argument in mono-/multi-repo workspaces):

   ```bash
   ./.specify/extensions/figma/scripts/bash/figma-ensure-context.sh --input - <<'SPECKIT_FIGMA_INPUT'
   <the user's verbatim feature input>
   SPECKIT_FIGMA_INPUT
   ```

   ```powershell
   @'
   <the user's verbatim feature input>
   '@ | ./.specify/extensions/figma/scripts/powershell/figma-ensure-context.ps1 --input -
   ```

   Any direct Figma link in the input is detected and introspected
   automatically — the linked file/frames become the authoritative design
   targets (node-level detail included), so no manual
   /speckit.figma.introspect run is needed. The script is a safe no-op when
   the extension is not configured, the target is excluded, or
   `.figma/cache/context-snapshot.json` is already fresh and covers the linked
   nodes.

   A Figma link is what makes a run a design run: with none in the input the
   script reports `"reason": "no-figma-link"` and there is nothing to inject.
   Forward the input VERBATIM — paraphrasing away the developer's link is what
   turns a design feature into a link-less one. The link is pasted once, at
   /speckit.specify, and remembered for the feature, so /speckit.plan and
   /speckit.tasks inherit it — or, when that git-ignored cache is missing, read
   back from the committed spec.md. Never strip the section marker it carries.
2. When it prints `"ran": true` or `"reason": "fresh"` with `"mustInject": true`,
   the Figma design section is MANDATORY in this document — never omit it,
   whatever the agent model. The script renders a ready-to-paste section to the
   path reported in `specSection` / `planSection` / `tasksSection` (the one
   matching this command): insert that rendered block VERBATIM into the
   generated document, then load `.figma/cache/context-snapshot.json` and complete the
   judgement placeholders by applying the rules of `/speckit.figma.introspect`
   (sections 3-7: frame confirmation, component placement, token gaps, tests +
   Storybook sub-tasks). Treat any `links` reported in the status JSON as
   authoritative design targets for the affected components.
3. On `"reason": "no-figma-link"` the feature has no mockup: add NOTHING about
   Figma to the document — no section, no placeholder, no "no mockup was
   provided" note. This is the normal outcome for any feature that is not driven
   by a creative. That silence scopes to the DOCUMENT: in your chat reply, state
   the fact once in a single plain sentence ("No Figma link detected; generated
   without design context") — it is the only signal a developer who simply forgot
   to paste the link can still act on. State it, do not ask for a link, and do
   not block.
4. For any other skip reason, proceed without Figma context and add a short
   note mentioning the reason.
5. **In `/speckit.implement` and `/speckit.analyze` there is no document section
   to paste** — those commands generate none. What the status gives you there is
   the CONTEXT: load `.figma/figma-design-rules.md` and, when present, the
   `.figma/figma-design-rules.custom.md` overlay (the overlay wins on conflict),
   then apply them to the code you write. Implementation is the moment those
   rules bind — component placement, token mapping, unit conversion, tests and
   catalog entries. Read the design values from the snapshot and the section
   already present in `spec.md` / `tasks.md`; never re-derive a node id from a
   URL and call a Figma MCP tool with it, which is how "the provided node ID was
   not found in the file" happens. The snapshot the hook just refreshed is the
   authoritative source.
6. **`/speckit.converge` appends to an existing `tasks.md`.** The Figma tasks
   section is very likely already there from the original `/speckit.tasks` run:
   keep it and its `speckit-figma:section phase=tasks` marker, add the newly
   derived design tasks into it, and never paste a second copy of the section.
<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->
HOOK
  echo "${action}: ${file#"$TARGET"/}"
}

if [[ "$HOOKS" != "off" ]]; then
  HOOKED_ANY="false"
  for dir in "${AGENT_CMD_DIRS[@]}"; do
    for stem in specify plan tasks analyze converge implement; do
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
    echo "NOTE: no /speckit.specify, /speckit.plan, /speckit.tasks, /speckit.analyze or /speckit.implement command files found — run 'specify init' first, then re-run install.sh --prompt-hooks to enable prompt injection."
  fi
  if [[ "$HOOKS" == "clean" ]]; then
    echo "INFO: speckit command prompts left untouched — automatic Figma context runs via the extension hooks (before_specify/before_plan/before_tasks/before_analyze/before_implement -> /speckit.figma.ensure, after_specify/after_plan/after_tasks -> /speckit.figma.verify, after_analyze -> /speckit.figma.drift). Use --prompt-hooks if your agent does not support SpecKit extension hooks."
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
EXT_STEMS=()
for cmd_file in "$EXT_DIR/commands/speckit.${EXT_ID}."*.md; do
  [[ -e "$cmd_file" ]] || continue
  stem="$(basename "$cmd_file")"; stem="${stem#speckit."${EXT_ID}".}"; stem="${stem%.md}"
  EXT_STEMS+=("$stem")
done

if [[ ${#EXT_STEMS[@]} -gt 0 ]]; then
  for dir in "${AGENT_CMD_DIRS[@]}"; do
    [[ -d "$TARGET/$dir" ]] || continue
    # Only a dir that already holds a speckit command counts as a configured
    # agent — otherwise an empty/unrelated dir would trigger a false warning.
    ls "$TARGET/$dir/"speckit.* >/dev/null 2>&1 || continue
    missing=()
    for stem in "${EXT_STEMS[@]}"; do
      [[ -f "$TARGET/$dir/speckit.${EXT_ID}.${stem}.md" || -f "$TARGET/$dir/speckit.${EXT_ID}.${stem}.prompt.md" ]] && continue
      missing+=("$stem")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "WARN: ${EXT_ID} command(s) not registered for ${dir}: ${missing[*]} — run 'specify extension add ${EXT_ID}' to (re)register them for this agent." >&2
    fi
  done
fi

cat <<EOF

Next steps:
  1. Edit figma.projects.config.json — list targets, fill excluded[], replace REPLACE_WITH_* ids.
  2. Local dev: store your READ-ONLY Figma PAT in the OS credential store and export
     FIGMA_PAT_COMMAND in your shell profile (full guide: .figma/docs/CREDENTIALS.md,
     also linked from the figma section of your README).
     macOS (keychain), e.g. in ~/.zshrc:
       security add-generic-password -s figma-pat -a "\$USER" -w 'figd_xxxxxxxx'
       echo 'export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"' >> ~/.zshrc
     Windows (PowerShell 7+ SecretManagement), in your PowerShell profile:
       Set-Secret -Name figma-pat -Secret 'figd_xxxxxxxx'
       Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:\$false
       \$env:FIGMA_PAT_COMMAND = 'Get-Secret figma-pat -AsPlainText'
       (the Set-SecretStoreConfiguration line is required: a default vault asks
        for a password no agent hook can type, and the run then looks like a
        missing PAT. Secrets stay encrypted at rest via your Windows profile.)
     CI / Cloud Agent: set credentials.source = "ci-secret" and inject a platform secret.
  3. Validate (from the workspace root):
       macOS/Linux:  ./.specify/extensions/figma/scripts/bash/figma-validate-config.sh
       Windows:      pwsh -File ./.specify/extensions/figma/scripts/powershell/figma-validate-config.ps1
  4. Register the extension commands (commands/speckit.figma.*.md)
     with your SpecKit agent of choice — or install natively with
     'specify extension add' (see extension.yml / docs/INSTALL.md), which registers
     /speckit.figma.config, /speckit.figma.update, /speckit.figma.ensure,
     /speckit.figma.introspect and /speckit.figma.verify for you.
EOF
