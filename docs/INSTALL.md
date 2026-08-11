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

> [!IMPORTANT]
> **`jq` is not optional on macOS/Linux** — every bash helper is built on it.
> Without it the auto-context hook degrades to `"reason": "missing-dependency"`:
> it still exits 0 and never blocks generation, but the agent loses the
> deterministic path (link parsing, node-id canonicalization, snapshot) and falls
> back to improvising, which is a common source of
> [wrong node ids sent to MCP](#troubleshooting--the-provided-node-id-was-not-found-in-the-file).
>
> When `brew install jq` is not an option (no `sudo`, Homebrew's Cellar not
> writable — common on managed machines), install the static binary into your own
> `PATH`; it needs no admin rights:
>
> ```bash
> mkdir -p ~/.local/bin
> curl -fsSL -o ~/.local/bin/jq \
>   https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64
> chmod +x ~/.local/bin/jq
> echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # then restart the shell
> ```
>
> Swap `jq-macos-arm64` for `jq-macos-amd64`, `jq-linux-amd64` or
> `jq-linux-arm64` as needed. The scripts print these same instructions when they
> detect the missing dependency. Alternative: run the **PowerShell 7+ ports**
> (`.specify/scripts/powershell/*.ps1`) — they use built-in JSON and need no `jq` at all,
> on macOS and Linux too.

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
This registers all of the extension's commands — `/speckit.figma.config`,
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
a local checkout lying around on the developer's machine. First **fetch** a
fresh copy (shallow clone into a temp directory), then **re-apply** it — no
uninstall is required, both tools are self-healing:

```bash
# from the target workspace root
EXT_SRC="$(mktemp -d)/spec-kit-figma"
git clone --depth 1 https://github.com/Fyloss/spec-kit-figma "$EXT_SRC"   # add --branch <tag> to pin a release
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
what changed. Re-running the interactive `/speckit.figma.config` is **not** the
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

## 3b. Optional — Figma MCP server (higher mockup fidelity)

The extension works out of the box on the **REST** engine (`figma.contextSource:
"rest"`), which needs nothing but the PAT and is the only engine guaranteed in
CI. Adding a Figma **MCP** server on top gives the agent the design's structured
node data (exact spacing, layout constraints, tokens, variants, component
bindings), so it reproduces mockups far more faithfully. It is optional and
per-developer: the config stays portable and falls back to REST automatically.

MCP auth is **separate from the PAT**: the hosted server uses its own OAuth
sign-in, the local Dev Mode server uses your Figma desktop session. Regenerating
your PAT neither fixes nor breaks MCP.

### Claude Code

```bash
claude plugin install figma@claude-plugins-official
```

The official plugin wires Figma's **hosted** server
(`https://mcp.figma.com/mcp`) in as a native tool — no local server, no extra
config. Sign in to Figma when prompted, then set `figma.contextSource: "mcp"` in
`figma.projects.config.json`. `figma-resolve-source.sh` detects Claude Code and
reminds you when the plugin is missing (silence it with
`FIGMA_NO_PLUGIN_ADVICE=1`).

### VS Code

Add the same hosted server to whichever agent you use — auto-detection is
Claude-Code-only, so this step is manual.

- **GitHub Copilot (agent mode)** consumes VS Code's native MCP support: run
  **MCP: Add Server…** from the Command Palette (pick *HTTP*, URL
  `https://mcp.figma.com/mcp`), or commit a workspace `.vscode/mcp.json`:

  ```jsonc
  {
    "servers": {
      "figma": { "type": "http", "url": "https://mcp.figma.com/mcp" }
    }
  }
  ```

- **Cline, Continue, the Claude Code extension…** do *not* read
  `.vscode/mcp.json` — add the same URL through their own MCP configuration.

Sign in to Figma when the OAuth prompt appears, then set
`figma.contextSource: "mcp"`.

### Local Dev Mode server (alternative)

`figma.mcp.url` defaults to `http://127.0.0.1:3845/mcp`, the **local** Dev Mode
server exposed by the Figma desktop app (Preferences → *Enable Dev Mode MCP
server*, Dev/Full seat required). It is faster but scoped: it only sees the file
**currently open** in the desktop app. Prefer the hosted server unless you
specifically need the local one.

### Troubleshooting — "The provided node ID was not found in the file"

This message comes from the **MCP server**, never from this extension. It means
the id the server received does not exist in the file it looked at. In order of
likelihood:

| Cause | Check | Fix |
|---|---|---|
| Local Dev Mode server, wrong file open | is `figma.mcp.url` `127.0.0.1:3845`? | open the target file in Figma Desktop, or switch to `https://mcp.figma.com/mcp` |
| Id passed in URL form (`12-345` instead of `12:345`), or with the `&t=…` suffix still attached | read the tool-call arguments in your agent's MCP log | let the agent take ids from `figma-parse-links.sh` / the `ensure` hook's `links`, which are already canonical |
| `nodeId` paired with the wrong `fileKey` (component library, or a Figma **branch** — a branch has its own file key) | compare both against the deep link | use the `fileId` and `nodeId` of the *same* parse result |
| `jq` missing → the helpers never ran, so the agent hand-extracted the id | is there a `"reason": "missing-dependency"` in the hook output? | install `jq` (see [Prerequisites](#prerequisites)) — the deterministic path is what makes the id correct |
| The node really was deleted | see below | ask the designer for a current link |

Cross-check with the REST path, which is immune (it canonicalizes and validates
the id before any call):

```bash
./.specify/scripts/bash/figma-introspect.sh --file <fileKey> --node <nodeId>
jq '.nodes.nodes | keys' .figma/cache/context-snapshot.json
```

If REST returns the node, the id is correct and the problem is the MCP server's
scope (wrong file open, or not signed in to the right Figma account). If REST
returns nothing either, the node genuinely does not exist in that file.

`--node` accepts both forms — `12-345` is normalized to `12:345`, and nested
instances (`I12:345;678:901`) are supported; a value that is not a node id is
rejected with an explicit error instead of a silent empty result.

## 4. Register the commands with your agent
> Skip this step if you installed via `specify extension add` (Option A) — SpecKit
> already registered all of the extension's commands (`/speckit.figma.config`,
> `/speckit.figma.update`, `/speckit.figma.ensure`, `/speckit.figma.introspect`,
> `/speckit.figma.verify`).

For a manual install, the extension ships **agent-agnostic** command templates:
- `commands/speckit.figma.config.md`
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
| GitHub Copilot | `.github/prompts/speckit.figma.config.prompt.md`, `…/speckit.figma.introspect.prompt.md` |
| Claude | `.claude/commands/speckit.figma.config.md`, `…/speckit.figma.introspect.md` |
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
Run `/speckit.figma.config` once. From then on, Figma context is **automatic**:
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
