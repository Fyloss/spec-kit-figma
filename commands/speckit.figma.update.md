---
description: Update an already-installed Figma extension in this workspace to a newer version — re-sync the helper scripts, templates, design-rules constitution and hooks, re-register slash-commands, and report what changed. Idempotent; no uninstall required.
---

# /speckit.figma.update — Update the Figma extension in this workspace

You are updating, not configuring. Do NOT re-run the interactive setup flow and
do NOT touch `figma.projects.config.json` or the design-rules overlay
`.figma/figma-design-rules.custom.md` — the user's configuration and customizations
are preserved. This command only re-applies the extension's code at a newer
version.

Updating an extension is two complementary jobs, and they are NOT the same tool:

- **Assets + hooks** (`.specify/scripts`, `.specify/templates`, the design-rules
  base `.figma/figma-design-rules.md`, the local guides `.figma/docs/`, the
  managed figma section of the workspace `README.md`, the prompt hooks) → the
  extension's own `install.sh`. The base, guides and README section are always
  refreshed (the README outside the marked block is never touched); the user
  overlay `.figma/figma-design-rules.custom.md` is created once and never
  overwritten.
- **Slash-command registration** (the `speckit.figma.*` command files, per agent
  format) → SpecKit's native `specify extension add`. This is also what records
  the installed version at `.specify/extensions/figma/extension.yml`.

Both are idempotent and self-healing, so **no uninstall is needed**. The
authoritative installed version lives in SpecKit's manifest
(`.specify/extensions/figma/extension.yml`); the extension keeps no parallel
stamp.

## Steps

1. **Re-acquire the new version.** The new files physically come from an updated
   extension source — a project cannot pull them from nowhere. Make sure the
   source is at the target version:
   - Local checkout: `git -C <spec-kit-figma> pull`.
   - Release zip: re-download the desired release.
   If you do not know where the extension checkout is, ask the user for its path
   (or the release URL). The currently-installed version is recorded by SpecKit
   at `.specify/extensions/figma/extension.yml` (`extension.version`).

2. **Re-register the slash-commands first.** Note the currently-installed
   version (from `.specify/extensions/figma/extension.yml`) so you can report the
   before/after, then re-register the commands for every configured agent — this
   is what picks up new or renamed commands, and `install.sh` does NOT do it.
   Re-registering *before* the asset sync means the final coherence check reports
   a clean `in sync` instead of a transient mismatch. Prefer the SpecKit CLI when
   it is on PATH:

   ```bash
   specify extension add figma --from <source>
   ```

   This is idempotent; if your SpecKit version refuses to re-add an existing
   extension, remove then re-add (`specify extension remove figma` first). If
   `specify` is not available, report the exact command for the user to run and
   continue.

3. **Re-sync assets and hooks.** From the workspace root, run the new source's
   installer. It is idempotent: it refreshes the helper scripts, section
   templates and design-rules constitution, re-wires the hooks, and reports coherence
   against SpecKit's registered version — `in sync at <version>` once step 2 has
   re-registered, or `WARN: figma version mismatch …` if registration was skipped
   or failed:

   ```bash
   <spec-kit-figma>/install.sh --target "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   ```

   Add `--prompt-hooks` only if this workspace relies on prompt injection rather
   than SpecKit extension hooks (the same flag used at install time).

4. **Report.** Summarize concisely: the registered version before (captured in
   step 2) vs after, which assets were refreshed (from `install.sh`'s `ADDED:`
   lines), the final coherence line (`in sync` vs `mismatch`), and any command
   that still needs `specify extension add` for a given agent. Do not run
   spec/plan/tasks
   generation — this command's job ends at a clean, up-to-date install.
