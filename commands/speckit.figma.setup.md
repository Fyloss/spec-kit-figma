---
description: Configure the SpecKit Figma extension for this workspace (single-repo by default, mono-repo or multi-repo) and validate connectivity before any spec/plan/tasks run.
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

2. **Scaffold config.** If `figma.projects.config.json` does not exist at the
   workspace root, run the extension's `install.sh --mode <mode>` (it copies the
   matching `figma.projects.config.{singlerepo|monorepo|multirepo}.example.json`
   from the extension checkout's `config/` directory) and adapt the result: list
   the front-end targets, mark back-end / infra / BFF targets under `excluded`,
   and fill `pageToPackageMapping` and `routingRules`.

3. **Credentials.** Ensure `credentials.source` is set:
   - `env` for local development → instruct the user to copy `.env.example`
     (placed at the workspace root by the installer) to `.env` and add their own
     **read-only** Figma PAT. Confirm `.env` and `.figma-context-snapshot.json`
     are git-ignored.
   - `ci-secret` for CI / GitHub Cloud Agent → set `secretName` (and `envVar`
     when the variable injected at runtime differs from the secret name) and
     document the secret in the pipeline (see `docs/CREDENTIALS.md`). Never
     write a token here.

3b. **Design-context engine.** Set `figma.contextSource`:
   - `rest` (default) → fully portable, CI-friendly; nothing else to configure.
   - `mcp` → for users running a Figma MCP server (e.g. the local Figma Dev Mode
     MCP server). Set `figma.mcp.url` (default `http://127.0.0.1:3845/mcp`) and
     optionally `serverName`. Keep `mcp.fallbackToRest: true` (default) so the
     extension degrades gracefully to REST when the server is absent. Only set it
     to `false` when MCP is mandatory for the run. Recommend keeping `rest` in CI.

4. **Replace placeholders.** Substitute every `REPLACE_WITH_*` value with a real
   Figma id. Pick the level that matches how the team's design is organized:
   - `figmaFileId` → a single Figma file;
   - `figmaProjectId` → a whole project (the agent enumerates its files);
   - `figmaTeamId` (or `figmaTeamIds` for several teams of the same organization)
     → a whole team (the agent enumerates every project, then every file). Use the
     `config/figma.projects.config.organization.example.json` example as a
     starting point for an org-with-multiple-teams setup. At least one of these
     ids MUST be set per enabled target.

5. **Validate.** Run the `validate` script. If it exits non-zero, surface the
   exact error and stop — do not proceed to spec generation with an invalid config.

6. **Smoke test.** Run `detect` for one front-end target and one excluded target
   to confirm routing behaves as expected.

7. **Engine check.** Run `resolve` to confirm the effective engine. With
   `contextSource: "mcp"` and no server running, expect `fellBack: true` and
   `effective: "rest"` — confirm the fallback is acceptable for this environment.

Report a concise summary: mode, enabled targets, excluded targets, credential
source, context engine (requested + effective), and validation result.
