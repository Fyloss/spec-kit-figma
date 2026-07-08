# Install guide — SpecKit Figma extension

Agent-agnostic. Works with any SpecKit-initialized workspace (Copilot, Claude,
Gemini, Cursor, …) on a **single-repo** (default), **mono-repo** or **multi-repo**
(git submodules) layout.

## Prerequisites
- A SpecKit workspace (`.specify/` present).
- `git`, plus one of the two script toolchains (both are installed into the
  workspace, so a mixed team shares one setup):
  - **macOS / Linux**: `bash` 4+, `curl`, `jq` — runs the
    `.specify/scripts/bash/*.sh` helpers;
  - **Windows**: [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
    (`pwsh`) — runs the `.specify/scripts/powershell/*.ps1` ports (built-in JSON
    and HTTP support: no `curl`, no `jq` needed). Every `figma-*.sh` helper has
    a `figma-*.ps1` twin with the same flags, the same JSON output and the same
    exit codes; anywhere this guide shows
    `./.specify/scripts/bash/<name>.sh`, Windows users run
    `./.specify/scripts/powershell/<name>.ps1` from `pwsh`.
- A read-only Figma Personal Access Token (local) or a CI secret (pipelines).

## 1. Install

### Option A — SpecKit extension (recommended)
The repo ships an `extension.yml` manifest, so SpecKit can install and register
the commands for you:
```bash
# from a release/source ZIP
specify extension add figma --from https://github.com/Fyloss/spec-kit-figma/archive/refs/heads/main.zip

# or from a local checkout
specify extension add --dev /path/to/spec-kit-figma
```
This registers all of the extension's commands — `/speckit.figma.setup`,
`/speckit.figma.update`, `/speckit.figma.ensure`, `/speckit.figma.introspect` and
`/speckit.figma.verify` — with your agent. Verify with `specify extension list`.
With this option you can skip the manual command registration in step 4.

> Option A registers the **commands** only. Also run the manual installer
> (Option B) once so the helper scripts (`.specify/scripts/bash/`), the config
> example and the design-rules constitution are copied into the workspace — the
> commands invoke `./.specify/scripts/bash/*.sh` from the workspace root (the
> SpecKit convention, alongside `.specify/memory/`).

### Option B — Manual installer (alternative)
```bash
# run from the target workspace root (or pass --target /path/to/workspace-root)
# single-repo (default)
./install.sh

# mono-repo
./install.sh --mode mono-repo

# multi-repo (git submodules)
./install.sh --mode multi-repo
```

On Windows, run the PowerShell 7+ port instead — same flags, same behaviour,
same output:

```powershell
# from pwsh, in the target workspace root (or pass --target <workspace-root>)
./install.ps1
./install.ps1 --mode mono-repo
./install.ps1 --mode multi-repo
```

The installer copies the config example to `figma.projects.config.json`, copies
the helper scripts (including `figma-ensure-context.sh`,
`figma-render-section.sh` and `figma-verify-section.sh`) to
`.specify/scripts/bash/` **and their PowerShell ports to
`.specify/scripts/powershell/`** (both families, whatever the platform the
installer runs on, so macOS/Linux and Windows teammates share one committed
workspace), installs the spec/plan/tasks section templates into
`.specify/templates/`, git-ignores the `.figma/cache/` directory (snapshot +
rendered sections), and installs the design-rules constitution into `.figma/`
(committed, next to the git-ignored `cache/`). It also copies these user guides
(CREDENTIALS / INSTALL / MONOREPO) into **`.figma/docs/`** (always refreshed, so
the workspace docs match the installed version) and appends a short managed
**figma section** to the workspace `README.md` (created if missing) — extension
version and layout mode, the read-only PAT setup, and links to the local
`.figma/docs/` guides. The section sits between `SPECKIT-FIGMA README` markers
and is refreshed in place on re-runs; the rest of the README is never touched.
Pass `--no-readme` to skip it. By **default it leaves the `/speckit.specify`,
`/speckit.plan` and `/speckit.tasks` command prompts untouched** — automatic
context runs through the `extension.yml` hooks. Pass `--prompt-hooks` to instead
append a managed **auto-context block** to those three prompts (for agents
without SpecKit extension-hook support), or `--no-hooks` to touch nothing;
re-run `install.sh` after `specify init` if the prompts did not exist yet. It
never writes tokens or replaces id placeholders.

### Updating an existing install

Updating the extension in a project is **two complementary jobs** — they use
different tools, and you need both, exactly as on first install:

| What | Tool | Notes |
| --- | --- | --- |
| Assets + hooks (`.specify/scripts`, `.specify/templates`, `.figma/figma-design-rules.md`, `.figma/docs/`, the README figma section, prompt hooks) | `install.sh` | idempotent; never overwrites `figma.projects.config.json` or the design-rules overlay `.figma/figma-design-rules.custom.md`; only the managed block of `README.md` is touched |
| Slash-command registration (`speckit.figma.*`, per agent format) | `specify extension add figma` | agent-format aware; the **only** thing that registers commands, and what records the installed version at `.specify/extensions/figma/extension.yml` |

The new files come **exclusively from the official repository** — do not reuse
a local checkout lying around on the developer's machine. Start with a **fast
up-to-date check** (one `git ls-remote`, no clone): releases are tagged
`v<version>` (e.g. `v1.5.0`) and the installed version lives in
`.specify/extensions/figma/extension.yml` (e.g. `1.5.0`). If they match, there
is nothing to update. Otherwise **fetch** a fresh copy of the release tag
(shallow clone into a temp directory), then **re-apply** it — no uninstall is
required, both tools are self-healing:

```bash
# from the target workspace root
INSTALLED="$(sed -n "s/^[[:space:]]*version:[[:space:]]*['\"]\{0,1\}\([0-9][0-9.]*\)['\"]\{0,1\}.*/\1/p" \
  .specify/extensions/figma/extension.yml | head -n 1)"
LATEST_TAG="$(git ls-remote --tags --refs https://github.com/Fyloss/spec-kit-figma 'v[0-9]*' \
  | sed 's|.*refs/tags/||' | sort -V | tail -n 1)"
[ "v$INSTALLED" = "$LATEST_TAG" ] && { echo "Already up to date ($INSTALLED)"; exit 0; }

EXT_SRC="$(mktemp -d)/spec-kit-figma"
git clone --depth 1 --branch "$LATEST_TAG" https://github.com/Fyloss/spec-kit-figma "$EXT_SRC"   # or --branch <tag> to pin another release
specify extension add figma --from "$EXT_SRC"   # re-register commands (picks up NEW commands)
"$EXT_SRC"/install.sh                            # re-sync assets + hooks; reports coherence (in sync / mismatch)
```

(On Windows: clone the same way into `$env:TEMP`, then run `install.ps1` from
`pwsh`, same flags.)

This is exactly what the `/speckit.figma.update` slash-command does for you —
prefer it over the manual sequence above.

SpecKit records the install across two files (the extension keeps no parallel
stamp of its own):

- **`.specify/extensions/figma/extension.yml`** — the per-extension manifest,
  which carries the installed `version`.
- the **project registry** listing installed extensions under `installed:` —
  named **`.specify/extensions.yml`** on most SpecKit versions and
  **`.specify/extension.yml`** on some others. `install.sh` accepts both.

`install.sh` reads the manifest version and reports coherence — `in sync at
<version>` when the synced assets match the registered commands, or `WARN: figma
version mismatch …` when they differ (your cue to re-run `specify extension
add`). If only the registry is present, it reports figma as registered but with
an unreadable version rather than claiming it is missing. It also warns
`WARN: figma command(s) not registered for <dir>` when a configured agent is
missing a command file.

In a configured workspace you can run the whole procedure with the bundled
**`/speckit.figma.update`** command, which orchestrates both tools and reports
what changed. Re-running the interactive `/speckit.figma.setup` is **not** the
way to update — it is for first-time configuration.

## 2. Configure
Edit `figma.projects.config.json`:
- choose `mode` (`single-repo` / `mono-repo` / `multi-repo`);
- declare front-end targets and their `figmaFileId` / optional `figmaProjectId`;
- fill `pageToPackageMapping`, `routingRules`, and `designSystem`;
- list back-end / infra / BFF targets under `excluded`;
- set `figma.credentials.source` (`env` local, `ci-secret` for CI / Cloud Agent).

Validate with the JSON Schema in your editor:
`config/figma.projects.config.schema.json`.

## 3. Credentials
See [CREDENTIALS.md](CREDENTIALS.md). Local: store your read-only PAT in the OS
keychain and export `FIGMA_PAT_COMMAND` (no `.env`). CI/Cloud Agent: inject a
platform secret.

## 4. Register the commands with your agent
> Skip this step if you installed via `specify extension add` (Option A) — SpecKit
> already registered all of the extension's commands (`/speckit.figma.setup`,
> `/speckit.figma.update`, `/speckit.figma.ensure`, `/speckit.figma.introspect`,
> `/speckit.figma.verify`).

For a manual install, the extension ships **agent-agnostic** command templates:
- `commands/speckit.figma.setup.md`
- `commands/speckit.figma.update.md` (re-sync assets/hooks + re-register commands
  on a version bump; preserves the config — see "Updating an existing install")
- `commands/speckit.figma.ensure.md` (auto-context; wired to the
  `before_specify`/`before_plan`/`before_tasks` hooks when installed via Option A)
- `commands/speckit.figma.introspect.md`
- `commands/speckit.figma.verify.md` (post-generation check; wired to the
  `after_specify`/`after_plan`/`after_tasks` hooks when installed via Option A —
  `--strict` / `figma.verifyStrict` turns it into a CI gate)

Map them to your agent's command location, e.g.:

| Agent | Destination |
|---|---|
| GitHub Copilot | `.github/prompts/speckit.figma.setup.prompt.md`, `…/speckit.figma.introspect.prompt.md` |
| Claude | `.claude/commands/speckit.figma.setup.md`, `…/speckit.figma.introspect.md` |
| Gemini / others | the agent's command/prompt directory |

The installer already copies the design-rules constitution to
`.figma/figma-design-rules.md` so the rules ship with the workspace; copy it
manually only if you skipped `install.sh`.

### Customizing the design rules (persists across updates)
`.figma/figma-design-rules.md` is the **extension-owned base**: it is overwritten
on every `/speckit.figma.update`, so never edit it. To customize the rules, edit
the **user overlay** `.figma/figma-design-rules.custom.md`, which the installer
creates once from a template and **never** overwrites. The agent loads the overlay
right after the base and, **on conflict, the overlay wins** — so it can add, refine
or override any base rule (e.g. declare your responsive policy, make a specific
component catalog mandatory, or add naming conventions). Commit both files.

## 5. Validate the setup
```bash
./.specify/scripts/bash/figma-validate-config.sh
./.specify/scripts/bash/figma-detect-target.sh <a-front-end-target>
./.specify/scripts/bash/figma-detect-target.sh <an-excluded-target>
```

Windows (PowerShell 7+):

```powershell
./.specify/scripts/powershell/figma-validate-config.ps1
./.specify/scripts/powershell/figma-detect-target.ps1 <a-front-end-target>
./.specify/scripts/powershell/figma-detect-target.ps1 <an-excluded-target>
```

## 6. Use in the SpecKit flow
Run `/speckit.figma.setup` once. From then on, Figma context is **automatic**:
the extension hooks (`before_specify` / `before_plan` / `before_tasks` in `extension.yml`)
invoke `/speckit.figma.ensure`, which runs
`./.specify/scripts/bash/figma-ensure-context.sh` (on Windows:
`./.specify/scripts/powershell/figma-ensure-context.ps1`) before generation,
piping in the user's raw feature input (`--input -`). It re-introspects only when
`.figma/cache/context-snapshot.json` is missing or stale (older than 60 minutes, or
older than the config — override with `FIGMA_SNAPSHOT_MAX_AGE_MINUTES` or
`--max-age-minutes`). Figma context is injected into `spec.md`, `plan.md` and `tasks.md`
for front-end targets and skipped for excluded ones; any skip (no config,
placeholders, excluded target, failed introspection) is surfaced as a note and
never blocks generation.

After generation, the `after_specify`/`after_plan`/`after_tasks` hooks run
`/speckit.figma.verify` (`figma-verify-section.sh`), which confirms the Figma
section was actually integrated when a mockup was detected — and self-corrects
if it is missing. Enable a hard CI gate with `--strict` (or `figma.verifyStrict`
in the config) to make a missing section fail the run instead of only warning.

All six hooks are declared `optional: false` in `extension.yml`, so a compliant
SpecKit host **auto-executes** them on every `specify` / `plan` / `tasks` run —
the agent is never offered an opt-in prompt it could decline. They stay safe
no-ops when Figma does not apply (no config, excluded target, no mockup), so
making them mandatory never blocks non-Figma projects.

Your `/speckit.specify`, `/speckit.plan` and `/speckit.tasks` prompt files are
**not modified** by default. If your agent does not support SpecKit extension hooks, run
`./install.sh --prompt-hooks` to append a managed auto-context block to those
prompts instead (refreshed in place on re-runs). A default `install.sh` run
removes any block injected by a previous extension version; `--no-hooks`
leaves the prompts strictly untouched (no injection, no cleanup).

**Direct Figma links are handled automatically.** When the feature description
contains Figma links (`figma.com/design|file|proto/...`, with or without
`node-id`), `figma-ensure-context.sh` parses them and introspects the linked
file with node-level detail; the linked frames become the authoritative design
targets, overriding the config mapping for that run. A snapshot that does not
cover the linked nodes is treated as stale and refreshed. The user never needs
to run a manual command for this — pasting the link in the spec input is
enough. (Links to several distinct files: the first is auto-introspected and a
warning lists the others.)

Run `/speckit.figma.introspect` manually only for deep dives: specific nodes
(`--node`), deeper trees (`--depth`), or team/project exploration.
