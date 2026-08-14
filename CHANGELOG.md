# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-08-11

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
- **BREAKING — `/speckit.figma.setup` is renamed `/speckit.figma.config`.** The
  command never installed anything (`install.sh` / `install.ps1` do that): it
  detects the topology, writes `figma.projects.config.json`, and validates
  connectivity. `config` says what it does, and matches the sibling extension
  `spec-kit-charter`, which already exposes `/speckit.charter.config`. Re-run
  `specify extension add` to register the new name; no alias is kept, because two
  names for one command is the confusion the rename removes.
- **`role` is no longer required on a target.** Validation rejected a config
  without it, yet no helper branched on it: `figma-detect-target` copies it into
  its JSON output and nothing reads it back. It stays enum-validated when present
  — a value outside the enum is a typo, not a choice — and stays documented,
  because it tells a human what a target is. Existing configs are unaffected.
- **Rendered sections moved to `.figma/cache/sections/<feature>/<phase>.md`**,
  from the flat `.figma/cache/section.<phase>.md`. Both installers drop the old
  flat files. Nothing needs to reference these paths by hand — the orchestrator
  reports them in `specSection` / `planSection` / `tasksSection` — but a
  workspace that hardcoded them somewhere must follow.
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
- Snapshots are cached per Figma file under `.figma/cache/snapshots/`, on top of
  the single `context-snapshot.json` slot. That slot is the snapshot of the
  *current* run — the well-known path every command prompt hands to the agent —
  and one slot is enough to publish a snapshot but not to cache one: two features
  targeting different Figma files evicted each other, so the `fresh` path never
  hit and every phase re-paid a full file fetch plus a nodes fetch for a snapshot
  that had been valid minutes earlier. A run whose link is already covered by a
  stored snapshot now restores it instead of re-introspecting.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) maps the subsystems with Mermaid
  diagrams: the decision flow and every skip reason, link resolution and its
  guards, the introspection pipeline, engine selection, credential resolution,
  the section lifecycle, and which parts of the config are executable versus
  written for human readers. Installed into workspaces alongside the other
  guides.
- The README now states that `figma.contextSource: "mcp"` does **not** replace
  the PAT. The deterministic introspection always goes through the REST API,
  whatever the configured engine; MCP improves how the agent *renders* the
  design, not how the snapshot is *collected*. A local Dev Mode server alone,
  with no PAT, fails with `"reason": "introspect-failed"` and `"code": "AUTH"`.
- The schema now says what `pageToPackageMapping` is: guidance in the
  `/speckit.figma.introspect` prompt, not a mapping any helper parses. Same for
  `role`.
- **Cache housekeeping.** `.figma/cache/` only ever grew: a `links/<key>.json`
  and a `sections/<key>/` per branch that ever ran a phase, a
  `snapshots/<fileId>.json` per Figma file ever linked. Disk was not the problem
  — key *reuse* was: a key derives from a branch name, so a new feature on a
  recycled name inherited the remembered links of whatever used the name before
  it, and came back carrying a design section for someone else's mockup. Every
  real (non-dry) run now sweeps the cache at most once a day, on an
  ownership-first policy: an entry survives as long as `specs/<key>/` exists —
  the signal is committed, so it outlives the branch — and is collected only when
  it is *both* orphaned and untouched for `FIGMA_CACHE_RETENTION_DAYS` (7).
  Stored snapshots have no owner to consult and go on age alone, never below the
  freshness window a caller configured. The feature of the run doing the sweep is
  exempt unconditionally, and a live feature's renders are never collected —
  `figma-verify-section` reads "Figma applied to this run" from their existence,
  so collecting them would turn a `--strict` gate fail-open. `FIGMA_CACHE_GC=off`
  disables the sweep, `=force` ignores the daily throttle.
- `figma_gc_cache` / `figma_gc_key_is_live` (bash) and `Invoke-FigmaCacheGc` /
  `Test-FigmaGcKeyIsLive` (PowerShell).
- `figma_snapshot_store_path` (bash) / `Get-FigmaSnapshotStorePath` (PowerShell).
- `figma_feature_key` / `figma_feature_links_path` / `figma_resolve_phase_doc`
  (bash) and `Get-FigmaFeatureKey` / `Get-FigmaFeatureLinksPath` /
  `Get-FigmaPhaseDoc` (PowerShell). `figma-verify-section` now shares the
  document resolver instead of carrying its own copy, and the resolver honours
  the feature identity (`SPECIFY_FEATURE`, `.specify/feature.json`) before
  falling back to the branch.

### Fixed

- **A design-less feature could make a `--strict` CI gate pass for a document
  genuinely missing its design section.** `figma-verify-section` decides "Figma
  applied to this run" from the *existence* of the rendered section, while
  resolving a per-feature document — but the section lived in a single global
  slot. Running a feature without a mockup deleted the renders of a feature with
  one, whose `after_*` hook then reported `not-applicable`: fail-open, precisely
  what the gate exists to prevent. Sections are now scoped per feature, resolved
  through the same feature identity as the remembered links, so `ensure` and
  `verify` always agree and a wipe only ever touches the current feature.
- The PowerShell port accepted any remembered-links file that parsed, including a
  JSON object root, where bash requires an array. A hand-edited
  `.figma/cache/links/<feature>.json` holding a single object instead of a
  one-element array was honoured on Windows and ignored everywhere else. The
  check now reads the JSON root off the text, because `ConvertFrom-Json` unrolls
  a one-element array into a bare object and the deserialized shape cannot tell
  the two apart.

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
