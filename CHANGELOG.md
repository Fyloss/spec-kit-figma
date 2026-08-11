# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-08-10

### Changed

- **BREAKING — a Figma link in the feature input is now what triggers the
  extension.** `figma-ensure-context` used to treat a valid config with a mapped,
  enabled target as enough: it introspected and forced the design section into
  every `spec.md`, `plan.md` and `tasks.md`, so a feature like "add a Redis cache
  on the billing endpoint" came back carrying a Figma section it had no business
  carrying. The mapping in `figma.projects.config.json` says *where* a creative
  would live, not *whether* a feature has one — only the link answers that. With
  no link the run now ends at the new `no-figma-link` reason: no introspection,
  no rendered section, `mustInject: false`, and the `after_*` verify hooks report
  `not-applicable`.
- Workspaces that relied on `pageToPackageMapping` alone to obtain design context
  without pasting a link must now paste the Figma link in the feature
  description, or run `/speckit.figma.introspect` by hand.
- As a consequence, `figma-ensure-context` no longer derives an introspection
  scope from the config (`--team` / `--project` / `--file`); that path was
  unreachable once a link became mandatory. `/speckit.figma.introspect` remains
  the way to introspect a mapped team or project.

### Added

- Figma links detected in the feature input are remembered **per feature**
  (`.figma/cache/links/<feature>.json`, already covered by the `.figma/cache/`
  gitignore entry), so the link is pasted once at `/speckit.specify` and
  `/speckit.plan` / `/speckit.tasks` inherit it. Scoping is per feature so the
  next, design-less feature never inherits the previous one's link. The feature
  identity follows SpecKit's own resolution: `SPECIFY_FEATURE`, then
  `.specify/feature.json`, then the git branch.
- When that per-feature memory is absent, the link is recovered from the
  committed `spec.md`. `.figma/cache/` is git-ignored, so the memory does not
  travel with the branch: a fresh clone, a CI job or a teammate who just pulled
  reached `/speckit.plan` with no link and fell through to `no-figma-link` —
  under which the agent is told to add *nothing* about Figma, so `plan.md`
  silently lost the design section `spec.md` carries. The recovery is gated on
  the `speckit-figma:section phase=spec` marker: a `figma.com` URL merely
  mentioned in the prose of a spec is not a design section and must not become a
  trigger. The document must also be one the current feature positively owns
  (`identified-only`): with nothing identifying the feature, "the only spec
  around" belongs to another one, and inheriting its creative would re-create
  the very regression this release removes. A recovered link re-warms the cache.
- Prototype links keep their flow starting point. A `/proto/` URL names two
  frames — `node-id`, whatever the designer was viewing when they copied the
  link, and `starting-point-node-id`, the entry point of the parcours — and only
  the first was introspected. Both are now deep-fetched (same batched request, so
  no extra API cost), which also pins a prototype link whose `node-id` is
  missing instead of degrading it to a broad link. Parsed links carry a new
  `startNodeId` field.
- The `no-figma-link` outcome is now surfaced conversationally, without touching
  the document. Nothing distinguishes a front-end feature whose author simply
  forgot to paste the link from a back-end one that legitimately has none, and
  the document is deliberately silent — so a forgotten link produced a spec with
  no design context and no signal at all, through `plan.md` and `tasks.md` too.
  The console line now names the remedy, and the agent instructions separate the
  two surfaces: nothing in the generated document, one plain sentence in the chat
  reply. It stays a statement, not a question: the agent still never asks for a
  link, blocks, or goes looking for one with an MCP tool.
- `figma_feature_key` / `figma_feature_links_path` / `figma_resolve_phase_doc`
  (bash) and `Get-FigmaFeatureKey` / `Get-FigmaFeatureLinksPath` /
  `Get-FigmaPhaseDoc` (PowerShell). `figma-verify-section` now shares the
  document resolver instead of carrying its own copy, and the resolver honours
  the feature identity (`SPECIFY_FEATURE`, `.specify/feature.json`) before
  falling back to the branch.

## [1.7.0] - 2026-08-10

### Fixed

- Node ids are now canonicalized at a single chokepoint
  (`figma_normalize_node_id` / `ConvertTo-FigmaNodeId`), so the URL form Figma
  puts in deep links can no longer reach a server as-is. Previously
  `figma-parse-links` converted only the **first** separator and required the id
  to start with a digit, which left nested-instance links
  (`node-id=I123-456%3B789-012`) unresolved and could forward a partially
  normalized id — both surface as *"The provided node ID was not found in the
  file"*. The extractor now takes the whole `node-id` value (the `&t=…` tracking
  suffix can no longer leak in), normalizes every separator, and reports an
  unrecognized value as `null` (broad link → the agent asks which frame) instead
  of forwarding a bogus id.
- `figma-introspect --node` validates and canonicalizes its input before any
  network call: `12-345` is accepted and queried as `12:345`, and a malformed
  value fails with an explicit error instead of an empty node set.
- A missing `jq` no longer breaks the auto-context hook's contract. It used to
  abort with a bare "'jq' is required but not installed" **before** emitting any
  status object, leaving the agent with nothing and pushing it to improvise —
  typically direct Figma MCP calls with a hand-extracted node id, the very
  failure above. `figma-ensure-context.sh` now answers with a jq-free
  `{"ran":false,"reason":"missing-dependency","dependency":"jq",…}` on stdout and
  exits 0, and every `figma_require` failure prints an install path that works
  without `sudo` or a writable Homebrew Cellar.

### Added

- **MCP node-id contract** in the command prompts (`/speckit.figma.introspect`
  section 1b-bis, `/speckit.figma.ensure` section 2). Passing ids to MCP tools
  was previously left to the model's own judgement, which made the step
  model-dependent: agents must now reuse the `fileId`/`nodeId` pair produced by
  `parse` verbatim, never re-derive an id from a URL, and treat a null `nodeId`
  as a broad link.
- A `missing-dependency` degraded-mode protocol in `/speckit.figma.ensure`
  (section 4) and `/speckit.figma.introspect` (section 1b-bis): when the helpers
  cannot run, the agent must apply the node-id normalization steps literally
  (cut at `&`/`#`, decode `%3A`/`%3B`, replace *every* `-`, validate the shape,
  pair with the file key of the same URL) and relay the install instructions
  instead of silently staying degraded.
- MCP installation instructions for **Claude Code** and **VS Code** in the
  managed README block written by the installer, and a dedicated section in
  `docs/INSTALL.md` covering the hosted server, the local Dev Mode server, and a
  troubleshooting table for *"The provided node ID was not found in the file"*
  (including the fact that MCP authenticates separately from the PAT).
- A `jq` prerequisite callout — with the admin-free static-binary install — in
  `docs/INSTALL.md`, the README requirements and the managed README block.

## [1.6.0] - 2026-07-07

### Added

- `.extensionignore` so `specify extension add` installs a clean copy: the test
  suites (bats/Pester), CI configuration and repo-only dotfiles are excluded
  from the installed extension ([#9](https://github.com/Fyloss/spec-kit-figma/pull/9)).
- `CHANGELOG.md` (this file) and the `homepage` field in `extension.yml`,
  aligning the extension with the Spec Kit extension catalog publishing
  requirements.

### Changed

- `extension.yml`: the manifest `description` was shortened to meet the
  catalog limit (under 100 characters); the full feature description lives in
  the README.
- README: the recommended `specify extension add --from` URL now points to the
  latest tagged release archive instead of the `main` branch, so installs are
  reproducible and match the published catalog entry.

## [1.5.0] - 2026-07-03

### Changed

- Updates are standardized as "fetch from the official repository": the
  `/speckit.figma.update` flow performs a fresh shallow clone of the official
  repo ([#7](https://github.com/Fyloss/spec-kit-figma/pull/7)).
- Added an "Updating" section to the managed README block pointing to
  `/speckit.figma.update` and the official repository.
- Install/update documentation revised accordingly.

## [1.4.0] - 2026-07-02

### Added

- **Windows support**: PowerShell 7+ ports of every bash helper
  (`scripts/powershell/`, 9 scripts) with the same flags, JSON output and exit
  codes — commands, hooks and CI gates behave identically on macOS, Linux and
  Windows ([#6](https://github.com/Fyloss/spec-kit-figma/pull/6)). Windows
  needs only `pwsh` and `git` (built-in HTTP/JSON: no curl, no jq).
- New `install.ps1`: full port of `install.sh` (managed README/hook blocks,
  version-coherence check, command-drift detection).
- New Pester suite (`tests/powershell/`, 108 tests) plus CI jobs on
  `windows-latest` and `ubuntu-latest`, and PSScriptAnalyzer lint.

### Changed

- Both installers now copy **both** script families into the workspace
  (`.specify/scripts/bash/` and `.specify/scripts/powershell/`), so a mixed
  macOS/Linux/Windows team shares one committed setup.
- `extension.yml` tool requirements: `git` stays required; `bash`/`curl`/`jq`
  become POSIX-only; `pwsh` is the Windows alternative.

## [1.3.0] - 2026-07-02

### Added

- `install.sh` now copies the user-facing guides (`CREDENTIALS.md`,
  `INSTALL.md`, `MONOREPO.md`) into the workspace at `.figma/docs/`, refreshed
  on every update so they match the installed version
  ([#5](https://github.com/Fyloss/spec-kit-figma/pull/5)).
- Managed **figma section** appended to the workspace `README.md` (created if
  missing): extension version + layout mode, the read-only Figma PAT setup and
  links to the local guides. Refreshed in place on re-runs; opt out with
  `--no-readme`.

## [1.2.0] - 2026-07-02

### Added

- Persistent user overlay `.figma/figma-design-rules.custom.md`: per-project
  design-rule customizations that **survive updates**, with local-wins
  precedence over the extension-owned base
  ([#4](https://github.com/Fyloss/spec-kit-figma/pull/4)).
- Graceful **no-Design-System** support: component resolution collapses to
  *reuse → app/lib* and token gaps are not raised.

### Changed

- Snapshot/render state moved under a dedicated cache directory
  (`.figma/cache/`); the design-rules concept renamed from "memory" to
  **constitution** ([#3](https://github.com/Fyloss/spec-kit-figma/pull/3)).
- The shipped base constitution is now universal: mobile-first, Storybook and
  the CI token-gap trigger moved to the overlay as opt-in defaults.

## [1.1.0] - 2026-07-02

### Added

- `figma-render-section.sh`: renders the spec/plan/tasks design sections with
  every deterministic placeholder pre-filled, so the agent integrates the
  section regardless of model ([#2](https://github.com/Fyloss/spec-kit-figma/pull/2)).
- `before_plan` hook and `plan-figma-section.template.md`.
- Post-generation verification gate (`figma-verify-section.sh`,
  `/speckit.figma.verify`, `after_*` hooks) with `--strict` CI mode.
- Broad Figma links (file/page-level) detected as `linkScope: "broad"` with
  `candidateFrames` listed for selection.
- First-class idempotent update flow (`/speckit.figma.update`).
- Proxy-vs-auth failure diagnostics and native MCP recommendations for
  Claude Code / VS Code.

### Fixed

- Documented that project/team introspection requires the `projects:read` PAT
  scope, with a scope matrix in `docs/CREDENTIALS.md` and an actionable
  `403`/`404` hint (`figma_scope_hint`).

## [1.0.0] - 2026-06-17

### Added

- Initial release: agent-agnostic SpecKit extension grounding spec/plan/tasks
  generation in Figma design context
  ([#1](https://github.com/Fyloss/spec-kit-figma/pull/1)).
- Portable REST engine (curl + jq) with optional MCP engine and automatic REST
  fallback.
- Single-repo, mono-repo and multi-repo layouts driven by
  `figma.projects.config.json`.
- 3-level component resolution (reuse → create-in-DS → create-in-app) with a
  purely presentational Design System.
- bats test suite and shellcheck lint, run in CI.

[1.6.0]: https://github.com/Fyloss/spec-kit-figma/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/Fyloss/spec-kit-figma/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/Fyloss/spec-kit-figma/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/Fyloss/spec-kit-figma/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/Fyloss/spec-kit-figma/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Fyloss/spec-kit-figma/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Fyloss/spec-kit-figma/releases/tag/v1.0.0
