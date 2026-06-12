# Credentials — Figma access token

This document answers the open question raised during review:
**"Why not use a `.env` for the Figma Personal Access Token (PAT)?"** — and
defines the policy for local, CI and GitHub Cloud Agent contexts.

## TL;DR
- **Local development → YES, use a `.env`.** It is the right tool: per-developer,
  git-ignored, least-privilege, zero shared secret.
- **CI / GitHub Cloud Agent → NO `.env`.** Use the platform secret store
  (`credentials.source: "ci-secret"`). A `.env` committed or baked into an image
  is a leak waiting to happen.

The token is **never** stored in `figma.projects.config.json`. The config only
declares *where* to read the token from (`credentials.source` + `envVar` /
`secretName`), never the value.

## Challenge: why `.env` is appropriate locally
Arguments **for** `.env` (the recommended local approach):
- **Per-developer token**: each developer uses their own PAT → least privilege,
  easy revocation, clear audit trail.
- **Git-ignored by construction**: `.env` and `.figma-context-snapshot.json` are
  added to `.gitignore` by the installer; the token never reaches version control.
- **No shared secret**: nothing to rotate centrally for local work.
- **Parsed, not sourced**: the scripts read `FIGMA_PAT` from `.env` by line
  extraction (no `source`/`dotenv` execution), so a malicious `.env` cannot run
  arbitrary shell code.
- **Standard & frictionless**: matches the team's existing convention of using
  environment variables for sensitive configuration.

Arguments **against** `.env` (and the mitigations):
- *Risk of accidental commit* → mitigated by enforced `.gitignore` + a secret
  scanner in CI. Consider a pre-commit hook that blocks `figd_` token patterns.
- *Plaintext on disk* → acceptable for a read-only PAT scoped to file reads; for
  stricter needs, use the OS keychain via `FIGMA_PAT_COMMAND` (see
  [Keychain instead of .env](#keychain-instead-of-env-figma_pat_command)).
- *Not suitable for shared/automated runners* → that is exactly why CI uses a
  secret store instead (below).

**Conclusion:** keep `.env` for local development, but make `credentials.source`
explicit so the same config works unchanged in CI by switching to `ci-secret`.

## Local development (`credentials.source: "env"`)
```bash
# .env.example is placed at the workspace root by install.sh
# (its source lives at config/.env.example in the extension checkout)
cp .env.example .env
# edit .env → FIGMA_PAT=figd_xxxxxxxx  (READ-ONLY scopes only)
```
Generate the PAT at <https://www.figma.com/developers/api#access-tokens> with the
minimal scopes: `file_content:read`, `file_metadata:read`.

## Keychain instead of .env (`FIGMA_PAT_COMMAND`)

To avoid any plaintext token on disk — and keep it out of files an agent could
read — store the PAT in a secret manager and declare the retrieval command in
your shell profile (NOT in the workspace):

```bash
# one-time: store the PAT in the macOS keychain
security add-generic-password -s figma-pat -a "$USER" -w 'figd_xxxxxxxx'

# in ~/.zshrc — the scripts fetch the token at call time
export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"
```

Resolution order in the scripts: environment variable (`FIGMA_PAT`) >
`FIGMA_PAT_COMMAND` > `.env`. The command is executed **without a shell**
(tokenized exec), so pipes or substitutions in its value are inert; and like
`FIGMA_API_BASE`, it is only ever read from the trusted local environment,
never from the committed config — a malicious PR cannot smuggle a command in.
Works with any CLI secret manager (`security`, 1Password `op read`, `pass`,
`secret-tool`, …) as long as the token is printed on stdout.

## Keeping the token away from the agent

The agent **never needs the token**: the scripts load it internally, send it
only as an `X-Figma-Token` header to `https://*.figma.com` (enforced), and
never echo it. The design-rules memory and the commands instruct the agent to
rely exclusively on the scripts' JSON output. To enforce this at the harness
level, deny the agent read access to the token sources, e.g. for Claude Code
in `.claude/settings.json`:

```json
{
  "permissions": {
    "deny": [
      "Read(./.env)",
      "Bash(security find-generic-password*)"
    ]
  }
}
```

Combined with `FIGMA_PAT_COMMAND` + keychain (no `.env` at all), the token
never exists in any file of the workspace.

## CI / GitHub Cloud Agent (`credentials.source: "ci-secret"`)
Set in `figma.projects.config.json`:
```json
"credentials": { "source": "ci-secret", "secretName": "FIGMA_PAT" }
```
Then inject the secret at runtime (never a committed `.env`):

```yaml
# GitHub Actions example
jobs:
  speckit:
    runs-on: ubuntu-latest
    env:
      FIGMA_PAT: ${{ secrets.FIGMA_PAT }}   # stored in repo/org secrets
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/bash/figma-validate-config.sh
```

At runtime the scripts read the token from the **environment variable named by
`envVar`** (default `FIGMA_PAT`; when `envVar` is unset, `secretName` is used as
the variable name). `secretName` itself identifies the secret in the CI store.
When the two names differ, declare both:

```json
"credentials": { "source": "ci-secret", "secretName": "ORG_FIGMA_TOKEN", "envVar": "FIGMA_PAT" }
```
```yaml
    env:
      FIGMA_PAT: ${{ secrets.ORG_FIGMA_TOKEN }}
```

For a **GitHub Cloud Agent** accessing Figma (future-proofing):
- Provision a **dedicated service PAT** (or a Figma OAuth app where available),
  scoped read-only, owned by a service account — not a person.
- Store it as an **organization/environment secret**; the agent reads it as an
  environment variable. The extension scripts already prefer the environment
  variable over any `.env`, so no code change is needed.
- Apply **least privilege** and rotate on a schedule; restrict the secret to the
  environments that actually run SpecKit.
- Never write the token to `.figma-context-snapshot.json` (the snapshot stores
  design structure only, no credentials).

## Hard rules
- The token MUST NOT appear in any committed file (`figma.projects.config.json`,
  scripts, snapshots, logs).
- Scripts MUST NOT echo the token. Validation rejects any `token`/`pat`/
  `accessToken` field found in the config.
- `.env` and `.figma-context-snapshot.json` MUST stay git-ignored.
