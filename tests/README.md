# Tests

Automated tests for the bash scripts of the SpecKit Figma extension, written with
[bats-core](https://github.com/bats-core/bats-core).

## Layout
- `helpers/common.bash` — shared setup (paths, temporary workspace helper).
- `fixtures/` — sample `figma.projects.config.json` files (valid and invalid).
- `figma-validate-config.bats` — config validation (modes, placeholders, secrets, contextSource).
- `figma-detect-target.bats` — target routing (multi-repo / mono-repo, excluded).
- `figma-parse-links.bats` — Figma link parsing from free-form input.
- `figma-resolve-source.bats` — design-context engine resolution (REST default, MCP + REST fallback).
- `figma-common.bats` — shared helpers (token loading, env var resolution, cache path, engine helpers, apiBaseUrl allowlist).
- `figma-introspect.bats` — introspection entrypoint (argument validation, large-payload snapshot via a fake curl).
- `figma-ensure-context.bats` — automatic pre-specify/plan/tasks hook (skip reasons, snapshot freshness, target auto-resolution, link-scope classification, stale-section cleanup).
- `figma-render-section.bats` — ready-to-paste section rendering (placeholder substitution, pages/frames/candidate-frame tables, machine marker).
- `figma-verify-section.bats` — post-generation section verification (phase-specific marker detection, strict-mode CI gate, document resolution).
- `install.bats` — installer (file copies, idempotency, auto-context hook injection).

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
