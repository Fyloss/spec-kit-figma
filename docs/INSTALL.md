# Install guide — SpecKit Figma extension

Agent-agnostic. Works with any SpecKit-initialized workspace (Copilot, Claude,
Gemini, Cursor, …) on a **single-repo** (default), **mono-repo** or **multi-repo**
(git submodules) layout.

## Prerequisites
- A SpecKit workspace (`.specify/` present).
- `bash` 4+, `curl`, `jq`, `git`.
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
This registers `/speckit.figma.setup` and `/speckit.figma.introspect` with your
agent. Verify with `specify extension list`. With this option you can skip the
manual command registration in step 4.

> Option A registers the **commands** only. Also run the manual installer
> (Option B) once so the helper scripts (`.specify/scripts/bash/`), the config
> example and the design-rules memory are copied into the workspace — the
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
The installer copies the config example to `figma.projects.config.json`, copies
the helper scripts to `.specify/scripts/bash/`, git-ignores
`.figma-context-snapshot.json`, installs the design-rules memory into
`.specify/memory/`, and appends an **auto-context block** to the workspace's
existing `/speckit.specify` and `/speckit.tasks` command prompts (skip with
`--no-hooks`; re-run `install.sh` after `specify init` if the prompts did not
exist yet). It never writes tokens or replaces id placeholders.

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
> already registered `/speckit.figma.setup` and `/speckit.figma.introspect`.

For a manual install, the extension ships **agent-agnostic** command templates:
- `commands/speckit.figma.setup.md`
- `commands/speckit.figma.ensure.md` (auto-context; wired to the
  `before_specify`/`before_plan`/`before_tasks` hooks when installed via Option A)
- `commands/speckit.figma.introspect.md`

Map them to your agent's command location, e.g.:

| Agent | Destination |
|---|---|
| GitHub Copilot | `.github/prompts/speckit.figma.setup.prompt.md`, `…/speckit.figma.introspect.prompt.md` |
| Claude | `.claude/commands/speckit.figma.setup.md`, `…/speckit.figma.introspect.md` |
| Gemini / others | the agent's command/prompt directory |

The installer already copies `memory/figma-design-rules.md` into
`.specify/memory/` so the rules are loaded with the constitution; copy it
manually only if you skipped `install.sh`.

## 5. Validate the setup
```bash
./.specify/scripts/bash/figma-validate-config.sh
./.specify/scripts/bash/figma-detect-target.sh <a-front-end-target>
./.specify/scripts/bash/figma-detect-target.sh <an-excluded-target>
```

## 6. Use in the SpecKit flow
Run `/speckit.figma.setup` once. From then on, Figma context is **automatic**:
the extension hooks (`before_specify` / `before_plan` / `before_tasks` in `extension.yml`)
invoke `/speckit.figma.ensure`, which runs
`./.specify/scripts/bash/figma-ensure-context.sh` before generation, piping in the
user's raw feature input (`--input -`). It re-introspects only when
`.figma-context-snapshot.json` is missing or stale (older than 60 minutes, or
older than the config — override with `FIGMA_SNAPSHOT_MAX_AGE_MINUTES` or
`--max-age-minutes`). Figma context is injected into `spec.md` and `tasks.md`
for front-end targets and skipped for excluded ones; any skip (no config,
placeholders, excluded target, failed introspection) is surfaced as a note and
never blocks generation.

Your `/speckit.specify` and `/speckit.tasks` prompt files are **not modified**
by default. If your agent does not support SpecKit extension hooks, run
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
