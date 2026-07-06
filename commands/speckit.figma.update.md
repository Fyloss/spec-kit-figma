---
description: Update an already-installed Figma extension in this workspace to a newer version fetched from the official repository — first a fast release-tag check (no clone; exits immediately when already up to date), then re-sync the helper scripts, templates, design-rules constitution and hooks, re-register slash-commands, and report what changed. Idempotent; no uninstall required.
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

1. **Fast up-to-date check — no clone.** Before fetching anything, compare the
   installed version against the latest published release tag. Releases are
   tagged `v<version>` (e.g. `v1.5.0`) on the official repository, and the
   installed version is recorded by SpecKit at
   `.specify/extensions/figma/extension.yml` (`extension.version`, e.g. `1.5.0`).
   A single `git ls-remote` answers this in one round trip — no clone, no
   GitHub API:

   ```bash
   INSTALLED="$(sed -n "s/^[[:space:]]*version:[[:space:]]*['\"]\{0,1\}\([0-9][0-9.]*\)['\"]\{0,1\}.*/\1/p" \
     .specify/extensions/figma/extension.yml | head -n 1)"
   LATEST_TAG="$(git ls-remote --tags --refs https://github.com/Fyloss/spec-kit-figma 'v[0-9]*' \
     | sed 's|.*refs/tags/||' | sort -V | tail -n 1)"
   ```

   On Windows (PowerShell 7+):

   ```powershell
   $installed = (Select-String -Path .specify/extensions/figma/extension.yml `
     -Pattern "^\s*version:\s*['`"]?([0-9][0-9.]*)").Matches[0].Groups[1].Value
   $latestTag = git ls-remote --tags --refs https://github.com/Fyloss/spec-kit-figma 'v[0-9]*' |
     ForEach-Object { ($_ -split 'refs/tags/')[1] } |
     Sort-Object { [version]$_.TrimStart('v') } | Select-Object -Last 1
   ```

   Decide from the result:

   - `"v$INSTALLED" == "$LATEST_TAG"` → **stop here.** Report
     `Already up to date (<installed>, latest release <tag>)` and do NOT run
     steps 2–4. This is the common case and must stay this cheap.
   - Versions differ → continue with the update, using `$LATEST_TAG` as the
     release to install in step 2.
   - `git ls-remote` failed (offline, repo unreachable) or returned no `v*`
     tag → the check is inconclusive; say so and continue with the full update
     from `main` rather than failing.
   - The user explicitly asked to force a re-sync or pin a specific version →
     skip the short-circuit and honor their request.

2. **Acquire the new version from the official repository.** Updates come
   exclusively from the extension's official repository. Do NOT search the
   developer's machine for an existing spec-kit-figma checkout and do NOT ask
   the user for a local path — always fetch a fresh copy. Shallow-clone the
   release tag found in step 1 into a temporary directory and use that clone
   as the source for steps 3 and 4:

   ```bash
   EXT_SRC="$(mktemp -d)/spec-kit-figma"
   git clone --depth 1 --branch "$LATEST_TAG" https://github.com/Fyloss/spec-kit-figma "$EXT_SRC"
   ```

   On Windows (PowerShell 7+):

   ```powershell
   $extSrc = Join-Path ([IO.Path]::GetTempPath()) "spec-kit-figma-$([Guid]::NewGuid().ToString('N'))"
   git clone --depth 1 --branch $latestTag https://github.com/Fyloss/spec-kit-figma $extSrc
   ```

   Cloning the tag keeps the update aligned with what step 1 compared against
   (the production release), not whatever `main` currently holds. Omit
   `--branch` only when step 1 found no release tag; to pin a different
   release at the user's request, pass that tag instead. The step 1
   `$INSTALLED` value is the "before" version for the final report.

3. **Re-register the slash-commands first.** Note the currently-installed
   version (from `.specify/extensions/figma/extension.yml`) so you can report the
   before/after, then re-register the commands for every configured agent — this
   is what picks up new or renamed commands, and `install.sh` does NOT do it.
   Re-registering *before* the asset sync means the final coherence check reports
   a clean `in sync` instead of a transient mismatch. Prefer the SpecKit CLI when
   it is on PATH:

   ```bash
   specify extension add figma --from "$EXT_SRC"
   ```

   On Windows (PowerShell 7+), same command with the step 2 variable:

   ```powershell
   specify extension add figma --from $extSrc
   ```

   This is idempotent; if your SpecKit version refuses to re-add an existing
   extension, remove then re-add (`specify extension remove figma` first). If
   `specify` is not available, report the exact command for the user to run and
   continue.

4. **Re-sync assets and hooks.** From the workspace root, run the freshly
   cloned source's installer. It is idempotent: it refreshes the helper scripts,
   section templates and design-rules constitution, re-wires the hooks, and reports
   coherence against SpecKit's registered version — `in sync at <version>` once
   step 3 has re-registered, or `WARN: figma version mismatch …` if registration
   was skipped or failed:

   ```bash
   "$EXT_SRC"/install.sh --target "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   ```

   On Windows (PowerShell 7+), run the installer's port instead — same flags,
   same output:

   ```powershell
   & (Join-Path $extSrc 'install.ps1') --target ((git rev-parse --show-toplevel 2>$null) ?? $PWD)
   ```

   Add `--prompt-hooks` only if this workspace relies on prompt injection rather
   than SpecKit extension hooks (the same flag used at install time).

5. **Report.** Summarize concisely: the registered version before (captured in
   step 3) vs after, which assets were refreshed (from `install.sh`'s `ADDED:`
   lines), the final coherence line (`in sync` vs `mismatch`), and any command
   that still needs `specify extension add` for a given agent. The temporary
   clone from step 2 is disposable — it lives in the system temp directory and
   can be left for the OS to clean up. Do not run spec/plan/tasks
   generation — this command's job ends at a clean, up-to-date install.
