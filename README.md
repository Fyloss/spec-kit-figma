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
- Honors review remarks: direct Figma links in the input, shared mockups across
  apps, mobile-first **tablet responsiveness** without a tablet mockup, **creative
  confirmation** checkpoints, **token-gap** detection (DS update via CI), and
  mandatory **tests + Storybook** on UI changes.

## Layout
```
.
├── extension.yml                        # SpecKit extension manifest (read by `specify extension add`)
├── install.sh                          # optional manual installer (single/mono/multi-repo)
├── commands/                           # agent-agnostic command templates
│   ├── speckit.figma.setup.md
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
├── memory/
│   └── figma-design-rules.md           # non-negotiable agent rules
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
This registers the `/speckit.figma.setup`, `/speckit.figma.ensure`,
`/speckit.figma.introspect` and `/speckit.figma.verify` commands with your
agent. Then run `/speckit.figma.setup` once.

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

With `"mcp"`, configure `figma.mcp` (`url`, optional `serverName`,
`fallbackToRest`). The extension probes the server and, when it is unreachable,
**transparently falls back to REST** — unless `fallbackToRest: false`, which makes
an absent server a hard error. Resolve the effective engine at any time:
```bash
./.specify/scripts/bash/figma-resolve-source.sh
# -> {"requested":"mcp","effective":"rest","fellBack":true, ...}
```
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
