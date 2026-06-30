---
description: Configure the SpecKit Figma extension for this workspace (single-repo by default, mono-repo or multi-repo) and validate connectivity before any spec/plan/tasks run. Choose the REST engine (portable, CI-friendly) or the MCP engine, which delivers more faithful mockup implementation.
---

# /speckit.figma.setup — Configure the Figma extension

You are setting up the Figma integration for SpecKit. Be deterministic and never
print or echo the access token.

## Scripts

Run these from the workspace root. The short names used below map to:

- `validate` → `./.specify/scripts/bash/figma-validate-config.sh`
- `detect` → `./.specify/scripts/bash/figma-detect-target.sh`
- `resolve` → `./.specify/scripts/bash/figma-resolve-source.sh`

## Steps

1. **Detect topology.** Inspect the workspace. If a `.gitmodules` file exists and
   references front-end repositories, propose `mode: "multi-repo"`. Otherwise, if
   the repo contains an `nx.json` / `turbo.json` / `pnpm-workspace.yaml` with
   multiple apps, propose `mode: "mono-repo"`. Otherwise default to
   `mode: "single-repo"` (one repository, one front-end app). Ask the user to confirm.

2. **Sync assets, then scaffold config.** Always run the extension's
   `install.sh --mode <mode>` first — it is idempotent and is what keeps an
   already-installed workspace up to date: it refreshes the helper scripts,
   section templates and design-rules memory, re-wires the hooks, checks the
   synced asset version against the version SpecKit has registered (at
   `.specify/extensions/figma/extension.yml`) and flags a mismatch, and warns if
   any figma slash-command is missing for a configured agent (run `specify
   extension add figma` to (re)register those). Do NOT gate this on whether the config already
   exists — that was the bug that left re-runs stale. `install.sh` only
   *scaffolds* `figma.projects.config.json` (from the matching
   `figma.projects.config.{singlerepo|monorepo|multirepo}.example.json` in the
   extension checkout's `config/`) when it is absent, and never overwrites an
   existing one. When it has just been scaffolded, adapt it: list the front-end
   targets, mark back-end / infra / BFF targets under `excluded`, and fill
   `pageToPackageMapping` and `routingRules`. If the config already existed,
   leave it untouched unless the user asks to reconfigure a specific field.

3. **Credentials.** Ensure `credentials.source` is set:
   - **Scopes (read-only).** A single-file setup needs `file_content:read` +
     `file_metadata:read`. A `figmaProjectId` or `figmaTeamId(s)` setup (the
     org-level granularity) **additionally requires `projects:read`** — without it the
     team/project enumeration fails with `403`/`404`. Instruct the user to select
     all three scopes when any project/team id is used (see `docs/CREDENTIALS.md`).
   - `env` for local development → instruct the user to store their own
     **read-only** Figma PAT in the OS keychain and export `FIGMA_PAT_COMMAND`
     from their shell profile (NOT in the workspace — there is no `.env`), e.g.:
     ```bash
     security add-generic-password -s figma-pat -a "$USER" -w 'figd_xxxxxxxx'
     echo 'export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"' >> ~/.zshrc
     ```
     Confirm `.figma/context-snapshot.json` is git-ignored. Never write a token
     to any workspace file (see `docs/CREDENTIALS.md`).
   - `ci-secret` for CI / GitHub Cloud Agent → set `secretName` (and `envVar`
     when the variable injected at runtime differs from the secret name) and
     document the secret in the pipeline (see `docs/CREDENTIALS.md`). Never
     write a token here.

3b. **Design-context engine.** Set `figma.contextSource`:
   - `rest` (default) → fully portable, CI-friendly; nothing else to configure.
   - `mcp` → for users running a Figma MCP server (e.g. the local Figma Dev Mode
     MCP server). **Recommended when mockup fidelity matters**: the MCP engine
     exposes the design's structured node data (exact spacing, layout constraints,
     tokens, variants and component bindings), so the agent reproduces mockups far
     more precisely than from the REST snapshot alone. Set `figma.mcp.url` (default
     `http://127.0.0.1:3845/mcp`) and optionally `serverName`. Keep
     `mcp.fallbackToRest: true` (default) so the extension degrades gracefully to
     REST when the server is absent. Only set it to `false` when MCP is mandatory
     for the run. Recommend keeping `rest` in CI.

4. **Replace placeholders.** Substitute every `REPLACE_WITH_*` value with a real
   Figma id. Pick the level that matches how the team's design is organized:
   - `figmaFileId` → a single Figma file;
   - `figmaProjectId` → a whole project (the agent enumerates its files);
   - `figmaTeamId` (or `figmaTeamIds` for several teams of the same organization)
     → a whole team (the agent enumerates every project, then every file). Use the
     `config/figma.projects.config.organization.example.json` example as a
     starting point for an org-with-multiple-teams setup. At least one of these
     ids MUST be set per enabled target. **Reminder:** `figmaProjectId` /
     `figmaTeamId(s)` require the PAT to carry the `projects:read` scope (step 3).

5. **Validate.** Run the `validate` script. If it exits non-zero, surface the
   exact error and stop — do not proceed to spec generation with an invalid config.

6. **Smoke test.** Run `detect` for one front-end target and one excluded target
   to confirm routing behaves as expected.

7. **Engine check.** Run `resolve` to confirm the effective engine. With
   `contextSource: "mcp"` and no server running, expect `fellBack: true` and
   `effective: "rest"` — confirm the fallback is acceptable for this environment.

Report a concise summary: mode, enabled targets, excluded targets, credential
source, context engine (requested + effective), and validation result.
