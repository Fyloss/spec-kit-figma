# Credentials — Figma access token

This document defines the policy for storing and loading the Figma Personal
Access Token (PAT) across local, CI and GitHub Cloud Agent contexts.

## TL;DR
- **Local development → use the OS keychain.** Store the PAT in your OS keychain
  (macOS `security`, 1Password, `pass`, …) and export `FIGMA_PAT_COMMAND` in your
  shell profile so the scripts fetch it at call time. **No `.env` file** — the
  token never touches a file in the workspace.
- **CI / GitHub Cloud Agent → use the platform secret store**
  (`credentials.source: "ci-secret"`). The secret is injected as an environment
  variable at runtime.

The token is **never** stored in `figma.projects.config.json`. The config only
declares *where* to read the token from (`credentials.source` + `envVar` /
`secretName`), never the value.

## Why the keychain (and not a `.env`)
A plaintext `.env` keeps the token in a file on disk that an agent — or an
accidental `git add -A` — could read or commit. Storing the PAT in the OS
keychain and resolving it through `FIGMA_PAT_COMMAND` removes that surface
entirely:
- **No plaintext on disk**: the token lives in the OS secret store, encrypted at
  rest, gated by the OS session.
- **Nothing to git-ignore**: there is no token file in the workspace to leak.
- **Per-developer token**: each developer uses their own read-only PAT → least
  privilege, easy revocation, clear audit trail.
- **Out of the agent's reach**: combined with a harness deny rule (below) the
  token never exists anywhere the agent can read.

## Local development (`credentials.source: "env"`)

Store the PAT in the OS keychain, then export the retrieval command from your
shell profile (NOT from the workspace):

```bash
# 1. one-time: store the READ-ONLY PAT in the macOS keychain
security add-generic-password -s figma-pat -a "$USER" -w 'figd_xxxxxxxx'

# 2. add the retrieval command to ~/.zshrc (paste it directly, no editor needed)
echo 'export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"' >> ~/.zshrc

# 3. reload the shell so FIGMA_PAT_COMMAND is set
source ~/.zshrc
```

Generate the PAT at <https://www.figma.com/developers/api#access-tokens>. **The
scopes depend on the introspection level declared in `figma.projects.config.json`**
— the documented minimum (`file_content:read`, `file_metadata:read`) only covers a
**single file**. Team / project enumeration additionally needs **`projects:read`**:

| Config level | Endpoints used | Required read-only scopes |
|---|---|---|
| `figmaFileId` (single file) | `GET /files/:key`, `GET /files/:key/nodes` | `file_content:read`, `file_metadata:read` |
| `figmaProjectId` (whole project) | `+ GET /projects/:project_id/files` | `+ projects:read` |
| `figmaTeamId` / `figmaTeamIds` (whole team / org) | `+ GET /teams/:team_id/projects` | `+ projects:read` |

> **Org-level setups (the `figmaTeamId(s)` granularity):** select **all three** scopes —
> `file_content:read`, `file_metadata:read`, `projects:read`. Without `projects:read`
> the team/project enumeration returns `403`/`404` (the introspection then fails with a
> `projects:read`-scope hint) even though individual files would read fine. The PAT
> owner must also be a **member of every team** being enumerated.

The scripts run `FIGMA_PAT_COMMAND` at call time and read the token from its
stdout. It is executed **without a shell** (tokenized exec), so pipes or
substitutions in its value are inert; and like `FIGMA_API_BASE`, it is only ever
read from the trusted local environment, never from the committed config — a
malicious PR cannot smuggle a command in. Works with any CLI secret manager as
long as the token is printed on stdout, e.g.:

| Secret manager | `FIGMA_PAT_COMMAND` value |
|---|---|
| macOS keychain | `security find-generic-password -s figma-pat -w` |
| 1Password CLI  | `op read op://Private/figma-pat/credential` |
| `pass`         | `pass show figma/pat` |
| `secret-tool`  | `secret-tool lookup service figma-pat` |

Resolution order in the scripts: the environment variable named by
`credentials.envVar` (default `FIGMA_PAT`) > `FIGMA_PAT_COMMAND`. There is **no
`.env` fallback** — if neither is set the scripts fail with an explicit error
pointing back here. If `FIGMA_PAT_COMMAND` is set but its command fails or
prints nothing, the scripts warn and then fail with that same error; they never
silently continue without a token.

## Keeping the token away from the agent

The agent **never needs the token**: the scripts load it internally, send it
only as an `X-Figma-Token` header to `https://*.figma.com` (enforced), and
never echo it. The design-rules memory and the commands instruct the agent to
rely exclusively on the scripts' JSON output. To enforce this at the harness
level, deny the agent access to the token sources, e.g. for Claude Code in
`.claude/settings.json`:

```json
{
  "permissions": {
    "deny": [
      "Bash(security find-generic-password*)"
    ]
  }
}
```

With the PAT in the keychain (no `.env` at all), the token never exists in any
file of the workspace.

## CI / GitHub Cloud Agent (`credentials.source: "ci-secret"`)
Set in `figma.projects.config.json`:
```json
"credentials": { "source": "ci-secret", "secretName": "FIGMA_PAT" }
```
Then inject the secret at runtime (never a committed file):

```yaml
# GitHub Actions example
jobs:
  speckit:
    runs-on: ubuntu-latest
    env:
      FIGMA_PAT: ${{ secrets.FIGMA_PAT }}   # stored in repo/org secrets
    steps:
      - uses: actions/checkout@v4
      - run: ./.specify/scripts/bash/figma-validate-config.sh
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
  variable, so no code change is needed.
- Apply **least privilege** and rotate on a schedule; restrict the secret to the
  environments that actually run SpecKit.
- Never write the token to `.figma-context-snapshot.json` (the snapshot stores
  design structure only, no credentials).

## Troubleshooting — proxy vs. auth (read this before blaming the token)

The Figma REST API (`api.figma.com`) is a **public** endpoint. The single most
common false diagnosis is reporting an **authentication** failure when the real
problem is a **corporate proxy** that cannot reach figma.com.

**HTTP 000 / `curl` exit 5 = proxy, not auth.** Concretely:

| Symptom | Real cause | What the scripts report |
|---|---|---|
| `curl` exit `5` ("couldn't resolve proxy"), HTTP `000` | broken/unreachable proxy | `NETWORK/PROXY error` (code `NETWORK`) |
| `curl` exit `6` with a proxy set | proxy DNS failure | `NETWORK/PROXY error` (code `NETWORK`) |
| HTTP `401` / `403` | missing/invalid PAT or insufficient scope | `AUTH/SCOPE error` (code `AUTH`) |
| HTTP `404` | wrong key, or PAT owner not a team member | `NOT FOUND` (code `NOT_FOUND`) |

**Self-healing:** the single curl chokepoint (`figma_curl_get` in
`figma-common.sh`) detects a proxy-connection failure (exit 5, or exit 6 / HTTP
000 with a proxy configured) and **retries once with every proxy variable
stripped**:

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    "no_proxy=*" "NO_PROXY=*" curl ...
```

This works in **both** topologies without configuration:
- **broken corporate proxy** (proxy → exit 5, direct → 200): the strip retry
  reaches Figma directly;
- **proxy-only egress** (CI / locked-down: direct fails, proxy is the only way
  out): the first, proxy-configured attempt already succeeds, so the strip never
  runs.

The retry is transport-only: the PAT is still sent solely as the `X-Figma-Token`
header to `https://*.figma.com`, never logged. If a `NETWORK` error persists
after the auto-retry, the proxy/network — **not** the token — is at fault. The
`figma.ensure` status JSON carries a machine-readable `code`
(`NETWORK`/`AUTH`/`NOT_FOUND`) so the calling command reports the true cause.

## Hard rules
- The token MUST NOT appear in any committed file (`figma.projects.config.json`,
  scripts, snapshots, logs).
- The token MUST NOT be written to any file in the workspace — locally it lives
  in the OS keychain, fetched via `FIGMA_PAT_COMMAND`; in CI it comes from the
  platform secret store.
- Scripts MUST NOT echo the token. Validation rejects any `token`/`pat`/
  `accessToken` field found in the config.
- `.figma-context-snapshot.json` MUST stay git-ignored.
