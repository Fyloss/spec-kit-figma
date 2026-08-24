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
├── CHANGELOG.md                        # version history (Keep a Changelog format)
├── .extensionignore                    # development-only files excluded from the installed copy
├── install.sh                          # project wiring, run from the installed tree (single/mono/multi-repo)
├── install.ps1                         # the same installer for Windows (PowerShell 7+)
├── commands/                           # agent-agnostic command templates
│   ├── speckit.figma.config.md
│   ├── speckit.figma.update.md         # re-sync assets/hooks + re-register commands (idempotent)
│   ├── speckit.figma.ensure.md         # auto-context (all five before_* hooks)
│   ├── speckit.figma.introspect.md
│   ├── speckit.figma.verify.md         # post-gen section check (after_* hooks; CI gate via --strict)
│   └── speckit.figma.drift.md          # post-analyze design-drift report (after_analyze hook)
├── config/
│   ├── figma.projects.config.schema.json
│   ├── figma.projects.config.singlerepo.example.json
│   ├── figma.projects.config.multirepo.example.json
│   ├── figma.projects.config.monorepo.example.json
│   └── figma.projects.config.organization.example.json
├── scripts/
│   ├── bash/                           # curl + jq, 429 backoff, keychain token loading (macOS/Linux)
│   └── powershell/                     # PowerShell 7+ ports — same flags/JSON/exit codes (Windows)
├── tests/                              # bats test suite + Pester (PowerShell) suite + fixtures
├── templates/
│   ├── spec-figma-section.template.md
│   ├── plan-figma-section.template.md
│   ├── tasks-figma-section.template.md
│   └── figma-readme-block.template.md  # managed section install.sh appends to the workspace README
├── .figma/
│   ├── figma-design-rules.md           # non-negotiable agent rules (constitution base; overwritten on update)
│   └── figma-design-rules.custom.md     # your overlay — overrides the base, preserved across updates (cache/ stays git-ignored)
└── docs/
    └── INSTALL.md  CREDENTIALS.md  MONOREPO.md  ARCHITECTURE.md
```

## Quick start

### Install as a SpecKit extension (recommended)
```bash
# from the latest tagged release (reproducible, matches the catalog entry)
specify extension add figma --from https://github.com/Fyloss/spec-kit-figma/archive/refs/tags/v1.7.0.zip

# from the development branch (may be ahead of the latest release)
specify extension add figma --from https://github.com/Fyloss/spec-kit-figma/archive/refs/heads/main.zip

# or from a local checkout
specify extension add --dev /path/to/spec-kit-figma
```
Once the extension is listed in the Spec Kit community catalog, it is also
discoverable via `specify extension search figma`.
This registers the `/speckit.figma.config`, `/speckit.figma.update`,
`/speckit.figma.ensure`, `/speckit.figma.introspect`, `/speckit.figma.verify`
and `/speckit.figma.drift` commands with your agent. Then run
`/speckit.figma.config` once.

**Figma context is refreshed automatically:** the manifest's
`before_specify` / `before_plan` / `before_tasks` / `before_converge` /
`before_analyze` / `before_implement` hooks invoke
`/speckit.figma.ensure`, which runs
`./.specify/extensions/figma/scripts/bash/figma-ensure-context.sh` before generation, piping in the
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

**`/speckit.converge` is covered as a task-generating phase.** It assesses the
codebase against spec/plan/tasks and appends the remaining unbuilt work to
`tasks.md`, so it needs the design context exactly as `/speckit.tasks` does —
without it the appended UI tasks are re-derived from prose with no Figma value
behind them, and `implement` builds from those. Because converge *rewrites* a
document that already carries the section, `after_converge` re-runs the same
check as `after_tasks`. **This is why the extension now requires SpecKit
`>=0.11.2`** — converge's command template, and therefore its hook points, first
ship in that release; every other hook has existed far longer.

**`analyze` and `implement` are covered too, differently.** They generate no
document, so there is no section to paste; what `ensure` gives them is the
**context** — the effective ruleset (`.figma/figma-design-rules.md` plus your
`.figma/figma-design-rules.custom.md` overlay) and a current snapshot.
`/speckit.implement` is the phase that actually writes the code, so it is the
phase where those rules bind: component placement, token mapping, unit
conversion, tests and catalog entries. It is also what restores the snapshot on a
fresh clone — `.figma/cache/` is git-ignored, so a teammate who picks up an
existing PR has none — which is what keeps the agent from improvising a raw Figma
MCP call with a node id it re-extracted from a URL.

After `/speckit.analyze`, the `after_analyze` hook invokes
`/speckit.figma.drift`. Analyze checks the documents against each other; drift
checks them against Figma. All three can agree perfectly and still describe a
creative the designer has since changed — on a PR that has been open two weeks,
that is what produces an implementation faithful to an obsolete design. The check
compares the Figma `lastModified` recorded in the section marker with the current
snapshot, reports it in the chat, and never edits a document. `--strict` (or
`figma.verifyStrict`) makes a real drift fail the build; being unable to check
never does.

### Exporting images from Figma

`/speckit.figma.export` renders nodes to files. Two modes, opposite lifecycles:

**`preview`** — a picture of each candidate frame, so you confirm the creative by
looking at it instead of reading node ids. PNG @2x into
`specs/<feature>/assets/`, **committed**: `.figma/cache/` is git-ignored, so a
preview written there is invisible to a PR reviewer and `spec.md` shows a broken
image.

```bash
./.specify/extensions/figma/scripts/bash/figma-export-images.sh \
  --file <fileKey> --node 12:345 --node 12:400
```

**`asset`** — a real asset the implementation ships: a logo as `.svg`, a gallery
mock as `.png`. `--out` is mandatory, because where a shipped asset belongs (the
Design System, or one app) is a placement decision like any other. A
`.figma-assets.json` manifest beside the files makes a re-run report `unchanged`
instead of re-downloading, and **refuses to overwrite a file you have edited
since** — `--force` is how you say you meant it.

```bash
./.specify/extensions/figma/scripts/bash/figma-export-images.sh \
  --mode asset --file <fileKey> --node 90:1 --format svg --out src/design-system/assets
```

This command is deliberately **not hooked**: it writes into your repository, so
it runs when you ask for it.

### The right node: source components, and page-sized links

**A linked node is almost always an instance**, and an instance is the flattened
rendering of a main component — overrides applied, variant fixed. Implementing
from it describes one appearance of a component rather than the component.
Introspection now resolves the definitions behind the linked instances
automatically (the "right-click → show source" step), lists them in the section,
and tags every extracted value `instance` or `source` so an override stays
visible instead of being merged into one number.

**A node id pins a node, not necessarily a creative.** A link copied from a
full-page desktop frame pins a `FRAME` like any other — it looks exact while
covering the whole page. Such a link is now reported as `linkScope: "oversized"`
and gets the same enumerate-and-confirm treatment as a page-level link, with the
node's own children as candidates: you linked the right page, you just say which
block. Thresholds: `FIGMA_OVERSIZED_HEIGHT` (3000px),
`FIGMA_OVERSIZED_DESCENDANTS` (150).

### Design values are extracted, not guessed

The rendered section carries the **real numbers** from the mockup — layout
direction, the four paddings, gaps, both axis alignments, corner radius, box
size, and per text node the family, weight, size, line height, letter spacing and
alignment, plus the style ids that bridge to your Design System. They are
computed from the snapshot by `figma-extract-values`, so the agent copies a table
instead of mining a multi-megabyte node dump it will never read in full. That is
what makes the result independent of the model you run.

**Every length is emitted with its unit — `70px`, never a bare `70`.** The
extension stops there, deliberately: it states an absolute CSS px value at 1x and
does *not* convert. A bare number is what lets a length be silently re-read as
something else — passed to a scale-indexed helper such as Tailwind's `mt-70` or
MUI's `theme.spacing(70)` on a theme built with `spacing: 4`, a 70px margin
becomes **280px**, and nothing fails.

**How your project converts px is your contract, declared once in the overlay**
`.figma/figma-design-rules.custom.md` — name your conversion helper, your root
font size, and your scale factor. No config schema could cover MUI `useStyles`
with a custom `pxToRem`, Tailwind, CSS variables, styled-components and
vanilla-extract at once, and a half-covering one is worse than none.
`config/figma-design-rules.custom.example.md` ships a ready-to-uncomment example.

### Optional: autonomous introspection, per target

By default the extension does nothing without a Figma link — see the paragraph
below. A target whose Figma file is small enough to reason about as a whole can
re-open the config-derived path:

```jsonc
"repo": {
  "figmaFileId": "…",
  "autoIntrospect": { "mode": "on-request", "maxFrames": 60 }
}
```

| `mode` | Trigger | Use it for |
|--------|---------|-----------|
| `off` *(default)* | a link, and nothing else | everything, unless you decide otherwise |
| **`on-request`** *(recommended)* | the agent judges the feature to have a creative and passes `--assume-design` | a Figma file you are happy to have read whole |
| `always` | any run on a mapped, enabled target | small, front-end-only projects |

**The config authorizes, the agent triggers.** `--assume-design` grants nothing
on a target left at `off` — the authorization lives in a committed file,
reviewable in a PR, so an agent can never grant it to itself.

**`maxFrames` is a hard budget, not advice.** When the mapped file holds more
top-level frames than that, the run stops at `too-large-for-auto` and asks for a
link pinning the frame, because context that wide is too diluted to implement
faithfully. Large Figma files should keep `mode: "off"` and pass a node id — that
is the whole point of the distinction. Autonomous runs also have nothing pinning
the creative, so the frame-confirmation checkpoint always applies before tasks
are generated (`confirmFrames: false` opts out, for a file with one unambiguous
creative).

Requires `figmaFileId` on the target: introspecting a whole project or team is
`/speckit.figma.introspect`, run by hand — never an automatic pre-generation hook.

**A Figma link is what makes a run a design run.** Paste one in the feature
description at `/speckit.specify` and the design section is generated and made
mandatory; paste none and the hooks report `no-figma-link` and add nothing at
all — a back-end feature never comes back with a design section stapled to its
spec, even in a workspace where the target is mapped to a Figma file. The
mapping in `figma.projects.config.json` says *where* a creative would live, not
*whether* this feature has one. The link is pasted once: it is remembered for
that feature, so `/speckit.plan` and `/speckit.tasks` inherit it without you
re-pasting. That memory lives in the git-ignored `.figma/cache/`, so when it is
absent — a fresh clone, a CI job, a teammate who just pulled the branch — the
link is read back from the `spec.md` the earlier phase committed.

Every feature gets its own entry there, so switching branches never mixes two
features' design context, and a daily housekeeping sweep reclaims the entries of
branches that never became a feature (see
[ARCHITECTURE.md](docs/ARCHITECTURE.md#housekeeping) — `FIGMA_CACHE_RETENTION_DAYS`,
`FIGMA_CACHE_GC=off`).

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
extension hooks, opt into prompt injection with `./.specify/extensions/figma/install.sh --prompt-hooks`
(a managed block, refreshed in place on re-runs); a default `install.sh` run
removes any block injected by a previous extension version.

### Then wire it to the project

`specify extension add` above brings the extension's code in; this second step
configures the project around it (config example, design rules, guides, README
block, optional prompt hooks). It runs **from the installed tree** and refuses to
run if that tree is missing:
```bash
# run from the target workspace root (or pass --target /path/to/workspace-root)
# single-repo (default)
./.specify/extensions/figma/install.sh

# mono-repo
./.specify/extensions/figma/install.sh --mode mono-repo

# multi-repo (git submodules)
./.specify/extensions/figma/install.sh --mode multi-repo

# then edit figma.projects.config.json, add credentials, and:
./.specify/extensions/figma/scripts/bash/figma-validate-config.sh
```

On **Windows**, run the PowerShell 7+ port instead — same flags, same output
(`pwsh -File ./.specify/extensions/figma/install.ps1`, then `./.specify/extensions/figma/scripts/powershell/figma-validate-config.ps1`).
`specify extension add` installs **both** script families at
`.specify/extensions/figma/scripts/`, whatever your own platform, so a mixed
macOS/Linux/Windows team shares one setup — and the helpers run straight from
there, never copied elsewhere in the workspace.
The installer also copies these guides into the workspace at `.figma/docs/`
(refreshed on every update, so they match the installed version) and appends a
short managed **figma section** to the workspace `README.md` (created if
missing): extension version + layout mode, the read-only PAT setup every
developer needs, and links to the local guides. Only the marked block is ever
touched, and it is refreshed in place on re-runs — pass `--no-readme` to opt
out.

See [docs/INSTALL.md](docs/INSTALL.md), [docs/CREDENTIALS.md](docs/CREDENTIALS.md)
and [docs/MONOREPO.md](docs/MONOREPO.md). For how the pieces fit together —
which script owns which decision, and where a run can stop —
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) maps every subsystem with Mermaid
diagrams.

## Requirements
- `git`, plus one script toolchain per developer machine:
  - **macOS / Linux**: `bash` 4+, `curl`, `jq` (runs `.specify/extensions/figma/scripts/bash/*.sh`). `jq`
    is required, not optional: without it the auto-context hook reports
    `"reason": "missing-dependency"` and the agent loses the deterministic path.
    No `sudo` / non-writable Homebrew? Install the static binary into
    `~/.local/bin` — see
    [docs/INSTALL.md → Prerequisites](docs/INSTALL.md#prerequisites);
  - **Windows**: PowerShell 7+ (`pwsh`) — runs the `.specify/extensions/figma/scripts/powershell/*.ps1`
    ports, which use PowerShell's built-in JSON and HTTP support (no `curl`,
    no `jq`). Same flags, same JSON output, same exit codes as the bash
    helpers, so commands, hooks and CI gates behave identically.
- A **read-only** Figma PAT (local) or a CI/Cloud secret (pipelines). Scopes scale
  with the introspection level: a single file needs `file_content:read` +
  `file_metadata:read`; **project- or team-level introspection
  (`figmaProjectId` / `figmaTeamId` / `figmaTeamIds`) additionally requires
  `projects:read`** (and the token must belong to a member of those teams) so the
  organization > team > projects > files hierarchy can be enumerated. See
  [docs/CREDENTIALS.md](docs/CREDENTIALS.md) for the full scope matrix.
- **On Windows with PowerShell SecretStore?** A vault created with the defaults
  needs an interactive password unlock, which an agent hook can never answer —
  `Get-Secret` then fails and the run looks like a missing PAT. One-time fix
  (secrets stay encrypted at rest under your Windows profile via DPAPI):
  `Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false`.
  See [docs/CREDENTIALS.md → SecretStore and non-interactive lookups](docs/CREDENTIALS.md#secretstore-and-non-interactive-lookups-windows).
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

> [!IMPORTANT]
> **The two engines are not alternatives, and MCP does not replace the PAT.**
>
> The deterministic introspection — `figma-introspect` →
> `.figma/cache/context-snapshot.json` → ready-to-paste section — **always** goes
> through the REST API and requires a PAT, whatever `contextSource` is set to.
>
> What `"mcp"` adds: the effective engine is recorded in the snapshot and
> reported to the agent, which may then query its own MCP tool to reproduce the
> mockup more faithfully. MCP improves how the agent **renders** the design, not
> how the snapshot is **collected**.
>
> In practice: a local Dev Mode server alone, with no PAT configured, fails
> introspection with `"reason": "introspect-failed"` and `"code": "AUTH"`.
> Generation is not blocked — that is the extension's contract — but it proceeds
> without design context.

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
> Code and the plugin is absent, `figma-resolve-source.sh` (and `/speckit.figma.config`)
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
./.specify/extensions/figma/scripts/bash/figma-resolve-source.sh
# -> {"requested":"mcp","effective":"rest","fellBack":true,
#     "claudeCode":{"detected":true,"officialFigmaPlugin":false}, ...}
```
The `claudeCode` block reports whether the run is inside Claude Code and whether
the official Figma plugin is installed, so tooling can recommend it when missing.
You keep full portability (REST) while offering MCP richness to those who have it.

> [!NOTE]
> **"The provided node ID was not found in the file"** comes from the MCP server,
> not from this extension, and is unrelated to your PAT (MCP authenticates
> separately). Usual causes: the **local** Dev Mode server only sees the file
> currently open in Figma Desktop; an id kept in URL form (`12-345` instead of
> `12:345`) or paired with the wrong file key (a Figma **branch** has its own
> key). Node ids handed out by `figma-parse-links.sh` and by the `ensure` hook's
> `links` are already canonical — agents must pass them through verbatim rather
> than re-deriving them. Full table in
> [docs/INSTALL.md → Troubleshooting](docs/INSTALL.md#troubleshooting--the-provided-node-id-was-not-found-in-the-file).

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
