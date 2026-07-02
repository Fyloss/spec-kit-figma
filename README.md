# spec-kit-figma

An **agent-agnostic** extension for [GitHub SpecKit](https://github.com/github/spec-kit)
that grounds spec / plan / task / implementation generation in **Figma** design
context. It works on any project that follows the same architecture. It defaults
to a **single-repo** (one repository, one front-end app) and also supports
**mono-repo** (Nx / Turborepo / pnpm / yarn / Lerna) and **multi-repo** (git
submodules) layouts.

## What it does
- Activates Figma integration only for **front-end** targets, driven by a single
  `figma.projects.config.json` (back-end / infra / BFF are excluded silently).
- Lets the agent **autonomously introspect** the mapped Figma design context from
  any level of the hierarchy — a single **file**, a whole **project**, or an entire
  **team** (organization > team > projects > files) — without per-page approval.
  The REST snapshot indexes pages, top-level frames and the file's
  component/style metadata; deeper node detail (nested layers, variants, layout
  constraints) is fetched on demand via `--depth` / `--node`.
- Ships two design-context engines: a portable **REST** engine (default — curl +
  jq, CI-friendly) and an **optional MCP** engine (`figma.contextSource: "mcp"`)
  that delivers richer context and **more faithful mockup implementation** when a
  Figma MCP server is available, with **automatic REST fallback** when the server
  is absent.
- Enforces a **3-level component resolution** (reuse → create-in-DS → create-in-app)
  with the Design System kept **purely presentational** (no business logic).
  **Works with or without a Design System**: when none is configured, the
  resolution collapses to *reuse → app/lib* and token gaps are not raised.
- Honors review remarks: direct Figma links in the input, shared mockups across
  apps or features, a **project-defined responsive policy** (declared in the
  overlay), **creative confirmation** checkpoints, **token-gap** detection (the
  agent never edits the DS directly), and mandatory **automated tests** on UI
  changes (plus a component-catalog entry when the project uses one, e.g. Storybook).

## Layout
```
.
├── extension.yml                        # SpecKit extension manifest (read by `specify extension add`)
├── install.sh                          # optional manual installer (single/mono/multi-repo)
├── commands/                           # agent-agnostic command templates
│   ├── speckit.figma.setup.md
│   ├── speckit.figma.update.md         # re-sync assets/hooks + re-register commands (idempotent)
│   ├── speckit.figma.ensure.md         # auto-context (before_specify/before_plan/before_tasks hooks)
│   ├── speckit.figma.introspect.md
│   └── speckit.figma.verify.md         # post-gen section check (after_* hooks; CI gate via --strict)
├── config/
│   ├── figma.projects.config.schema.json
│   ├── figma.projects.config.singlerepo.example.json
│   ├── figma.projects.config.multirepo.example.json
│   ├── figma.projects.config.monorepo.example.json
│   └── figma.projects.config.organization.example.json
├── scripts/
│   └── bash/                           # curl + jq, 429 backoff, keychain token loading
├── tests/                              # bats test suite + fixtures
├── templates/
│   ├── spec-figma-section.template.md
│   ├── plan-figma-section.template.md
│   └── tasks-figma-section.template.md
├── .figma/
│   ├── figma-design-rules.md           # non-negotiable agent rules (constitution base; overwritten on update)
│   └── figma-design-rules.custom.md     # your overlay — overrides the base, preserved across updates (cache/ stays git-ignored)
└── docs/
    └── INSTALL.md  CREDENTIALS.md  MONOREPO.md
```

## Quick start

### Install as a SpecKit extension (recommended)
```bash
# from a release/source ZIP
specify extension add figma --from https://github.com/Fyloss/spec-kit-figma/archive/refs/heads/main.zip

# or from a local checkout
specify extension add --dev /path/to/spec-kit-figma
```
This registers the `/speckit.figma.setup`, `/speckit.figma.update`,
`/speckit.figma.ensure`, `/speckit.figma.introspect` and
`/speckit.figma.verify` commands with your agent. Then run
`/speckit.figma.setup` once.

**Figma context is refreshed automatically:** the manifest's
`before_specify` / `before_plan` / `before_tasks` hooks invoke
`/speckit.figma.ensure`, which runs
`./.specify/scripts/bash/figma-ensure-context.sh` before generation, piping in the
user's raw feature input (`--input -`). When Figma applies, the script renders a
ready-to-paste design section per phase and reports `mustInject: true` so the
agent integrates it **regardless of model** — never silently omitting it. After
generation, the `after_specify` / `after_plan` / `after_tasks` hooks invoke
`/speckit.figma.verify`, which confirms the section actually landed in the
document (and self-corrects if it did not). Run
`figma-verify-section.sh --phase <spec|plan|tasks> --strict` in CI to **fail the
build** when a detected Figma mockup was not integrated. **Direct Figma links pasted in the
feature description are detected automatically**: the linked file and frames
become authoritative design targets and are introspected at node level — no
manual command needed. The script is a safe no-op when the extension is
unconfigured, the target is excluded, or the snapshot is fresh (and covers the
linked nodes) — and it never blocks spec/tasks generation. Running
`/speckit.figma.introspect` manually remains available for deep dives
(specific nodes, custom depth).

> [!WARNING]
> **Use a capable model (Claude Sonnet or better).** Lighter models are strongly
> discouraged for this extension.
>
> Each Spec Kit SDD command is a multi-step protocol, not just Markdown generation:
> the agent must first run a setup script (under `.specify/scripts/`) that detects
> the feature branch, resolves plan/spec file paths, etc., then read that output and
> apply the template. The Figma hooks add another such step — run
> `figma-ensure-context.sh`, read its `mustInject` report, and integrate the rendered
> design section.
>
> Lightweight models such as Claude Haiku are built for fast, read-only exploration
> and intermittently skip exactly this "run the script → read the result → apply the
> instruction" chain. It is not really random — it is a reliability gap on structured,
> multi-step instructions. With such a model there is a real risk the Figma hook is
> silently skipped and the design section is never injected. (Inside Claude Code, the
> exploration agent currently runs on Haiku for quick codebase searches — its real
> niche, but not Spec Kit orchestration.) The `after_*` verify hooks reduce, but do
> not eliminate, this risk.
>
> For the steps that actually interpret the mockups (`specify`, `plan`), Opus is
> preferable — that's where visual intent is translated into the spec, and an error
> there propagates downstream.

The workspace's `/speckit.specify`, `/speckit.plan` and `/speckit.tasks` prompt
files are **never modified by default**. If your agent does not support SpecKit
extension hooks, opt into prompt injection with `./install.sh --prompt-hooks`
(a managed block, refreshed in place on re-runs); a default `install.sh` run
removes any block injected by a previous extension version.

### Manual install (alternative)
```bash
# run from the target workspace root (or pass --target /path/to/workspace-root)
# single-repo (default)
./install.sh

# mono-repo
./install.sh --mode mono-repo

# multi-repo (git submodules)
./install.sh --mode multi-repo

# then edit figma.projects.config.json, add credentials, and:
./.specify/scripts/bash/figma-validate-config.sh
```
See [docs/INSTALL.md](docs/INSTALL.md), [docs/CREDENTIALS.md](docs/CREDENTIALS.md)
and [docs/MONOREPO.md](docs/MONOREPO.md).

## Requirements
- `bash` 4+, `curl`, `jq`, `git`.
- A **read-only** Figma PAT (local) or a CI/Cloud secret (pipelines). Scopes scale
  with the introspection level: a single file needs `file_content:read` +
  `file_metadata:read`; **project- or team-level introspection
  (`figmaProjectId` / `figmaTeamId` / `figmaTeamIds`) additionally requires
  `projects:read`** (and the token must belong to a member of those teams) so the
  organization > team > projects > files hierarchy can be enumerated. See
  [docs/CREDENTIALS.md](docs/CREDENTIALS.md) for the full scope matrix.
- **Behind a corporate proxy?** A transport failure (`curl` exit 5, HTTP `000`)
  is a proxy/network problem, not a bad token. The single curl chokepoint
  auto-retries once with the proxy stripped; if it still fails, see
  [docs/CREDENTIALS.md → Troubleshooting — proxy vs auth](docs/CREDENTIALS.md#troubleshooting--proxy-vs-auth-read-this-before-blaming-the-token).

## Design-context engines (REST / MCP)
The engine is selected per workspace via `figma.contextSource`:

| Value | Engine | When |
| --- | --- | --- |
| `"rest"` *(default)* | curl + jq against the Figma REST API | Always portable; the only engine guaranteed in CI. |
| `"mcp"` | A Figma MCP (Model Context Protocol) server | Richer context, and **more faithful mockup implementation**, for users who run the server locally. |

> **MCP yields more accurate implementations.** Because the MCP engine exposes
> the design's structured node data — exact spacing, layout constraints, tokens,
> variants and component bindings — the agent reproduces mockups far more
> precisely than from the REST snapshot alone. When fidelity to the original
> Figma design matters, prefer `figma.contextSource: "mcp"`.

> [!TIP]
> **Using Claude Code? Install the official Figma plugin.** It is by far the most
> reliable way to get MCP design context with Claude Code:
> ```bash
> claude plugin install figma@claude-plugins-official
> ```
> The plugin wires Figma's **hosted** MCP server (`https://mcp.figma.com/mcp`) in
> as a native Claude Code tool — no local Dev Mode server, no extra config — and
> then you simply set `figma.contextSource: "mcp"` in
> `figma.projects.config.json`. When the extension's scripts run inside Claude
> Code and the plugin is absent, `figma-resolve-source.sh` (and `/speckit.figma.setup`)
> print a one-line reminder; silence it with `FIGMA_NO_PLUGIN_ADVICE=1`. Note
> this hosted server differs from the local Dev Mode MCP server
> (`http://127.0.0.1:3845/mcp`), which the extension's curl probe targets by
> default via `figma.mcp.url`.

> [!TIP]
> **Using VS Code? Add Figma's hosted MCP server.** The same hosted server
> (`https://mcp.figma.com/mcp`) works with any VS Code agent that supports MCP —
> no local Dev Mode server required. With **GitHub Copilot (agent mode)**, which
> consumes VS Code's native MCP support, run **MCP: Add Server…** from the Command
> Palette (pick *HTTP*, URL `https://mcp.figma.com/mcp`), or add it to your
> workspace `.vscode/mcp.json`:
> ```jsonc
> {
>   "servers": {
>     "figma": { "type": "http", "url": "https://mcp.figma.com/mcp" }
>   }
> }
> ```
> Other VS Code agents (Cline, Continue, the Claude Code extension…) do **not**
> read `.vscode/mcp.json` — add the same URL through their own MCP configuration
> instead. Sign in to Figma when prompted for OAuth, then set
> `figma.contextSource: "mcp"` in `figma.projects.config.json`. (Auto-detection of
> this server is Claude-Code-only; in VS Code, add it manually as above.)

With `"mcp"`, configure `figma.mcp` (`url`, optional `serverName`,
`fallbackToRest`). The extension probes the server and, when it is unreachable,
**transparently falls back to REST** — unless `fallbackToRest: false`, which makes
an absent server a hard error. Resolve the effective engine at any time:
```bash
./.specify/scripts/bash/figma-resolve-source.sh
# -> {"requested":"mcp","effective":"rest","fellBack":true,
#     "claudeCode":{"detected":true,"officialFigmaPlugin":false}, ...}
```
The `claudeCode` block reports whether the run is inside Claude Code and whether
the official Figma plugin is installed, so tooling can recommend it when missing.
You keep full portability (REST) while offering MCP richness to those who have it.

## Testing
The bash scripts are covered by a [bats](https://github.com/bats-core/bats-core)
test suite and linted with `shellcheck`.
```bash
# install tooling (macOS)
# bash is required: bats under the system bash 3.2 silently ignores failing
# assertions that are not the last command of a test (errexit limitation).
brew install bats-core shellcheck bash

# run the linter and the tests
shellcheck -x scripts/bash/*.sh install.sh
bats tests/
```
The same checks run automatically on every pull request via GitHub Actions
([.github/workflows/ci.yml](.github/workflows/ci.yml)).

## Single-repo vs mono-repo vs multi-repo
Same routing rules, component resolution, token handling, responsive and
credential policies. Only the topology wrapper differs: a **single-repo** and a
**mono-repo** use a single `repo` object (the mono-repo additionally declares its
internal `apps`/`libs`), while a **multi-repo** uses a `submodules` map. Details
in [docs/MONOREPO.md](docs/MONOREPO.md).
