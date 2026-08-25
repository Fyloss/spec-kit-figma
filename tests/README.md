# Tests

Automated tests for the bash scripts of the SpecKit Figma extension, written with
[bats-core](https://github.com/bats-core/bats-core).

## Layout
- `helpers/common.bash` — shared setup (paths, temporary workspace helper).
- `fixtures/` — sample `figma.projects.config.json` files (valid and invalid).
- `helpers/mock-figma-server.py` — a stand-in for the Figma `/images` endpoint, used by the export suites. It answers the render request and serves the rendered bytes on a token-free path, so a test can assert the PAT is never sent to the CDN URL.
- `helpers/mock-figma-router.py` — a generic Figma stand-in driven by a JSON routing table (substring match -> fixture file), for tests that must exercise several distinct endpoints in one run — e.g. cross-file source-component resolution: a file fetch, a nodes fetch, a component-registry lookup, then another file's own nodes fetch.
- `figma-validate-config.bats` — config validation (modes, placeholders, secrets, contextSource).
- `figma-detect-target.bats` — target routing (multi-repo / mono-repo, excluded).
- `figma-parse-links.bats` — Figma link parsing from free-form input (node-id canonicalization: URL form, `%3A`/`%3B` encoding, nested instances, tracking suffix, malformed ids).
- `figma-resolve-source.bats` — design-context engine resolution (REST default, MCP + REST fallback).
- `figma-common.bats` — shared helpers (token loading, env var resolution, cache path, cache housekeeping, engine helpers, apiBaseUrl allowlist).
- `figma-introspect.bats` — introspection entrypoint (argument validation, `--node` canonicalization, large-payload snapshot via a fake curl, cross-file source-component resolution via the Figma component registry and its graceful degradation).
- `figma-ensure-context.bats` — the automatic `before_*` hook, now on all six phases (skip reasons, snapshot freshness, target auto-resolution, link-scope classification incl. `oversized`, the `autoIntrospect` decision table and its frame budget, stale-section cleanup, cache housekeeping).
- `figma-render-section.bats` — ready-to-paste section rendering (placeholder substitution, pages/frames/candidate-frame tables, machine marker).
- `figma-verify-section.bats` — post-generation section verification (phase-specific marker detection, strict-mode CI gate, document resolution).
- `figma-check-drift.bats` — post-analyze design drift (marker timestamps vs the snapshot, strict-mode gate, and the paths where the check simply cannot run).
- `figma-extract-values.bats` — deterministic design values (explicit units, absent-is-not-zero, source-component tagging, truncation).
- `figma-export-images.bats` — image export (preview vs asset mode, the manifest and its refusal to overwrite a hand-edited file, batching, and the assertion that the PAT never reaches the CDN URL).
- `figma-check-orphans.bats` — features orphaned by the 2.0.0 trigger change (section marker without a recoverable link).
- `powershell/` — the Pester suite, mirroring the bats one file for file
  (`Common`, `ValidateConfig`, `DetectTarget`, `ParseLinks`, `EnsureContext`,
  `RenderVerify`, `Install`, plus `AutoIntrospect`, `CheckDrift`, `ExtractValues`,
  `ExportImages`, `CheckOrphans`). Both ports must agree on flags, JSON and exit
  codes, so a behaviour change belongs in both suites or in neither.
- `install.bats` — installer (extension-tree precondition, removal of the duplicated helper/template copies, idempotency, auto-context hook injection, workspace docs + managed README section).

The suite is offline: no test calls the Figma API. Network-dependent paths
(`figma_api` retries, `figma-introspect.sh` traversal) are exercised against
unreachable local ports or a fake `curl` on `$PATH`. The MCP probe is exercised
against an unreachable local port to validate the REST fallback without a
running server.

## Running locally
```bash
# from the repository root
brew install bats-core shellcheck   # macOS; use your package manager otherwise
shellcheck -x scripts/bash/*.sh install.sh
bats tests/
```

## CI
The same checks run on every pull request through
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).
