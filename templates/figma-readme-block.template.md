<!-- BEGIN SPECKIT-FIGMA README (managed by spec-kit-figma v{{EXTENSION_VERSION}}; re-running install.sh or install.ps1 refreshes this section — edits inside will be lost) -->
## Figma design context (SpecKit extension)

This workspace uses [spec-kit-figma]({{REPOSITORY_URL}}) v{{EXTENSION_VERSION}}
({{MODE}} layout): `/speckit.specify`, `/speckit.plan` and `/speckit.tasks`
automatically ground the generated documents in the Figma mockups declared in
[`figma.projects.config.json`](figma.projects.config.json).

### One-time setup per developer — toolchain

Install the row for your OS. A mixed team shares one setup: every
`.specify/scripts/bash/<name>.sh` has a `.specify/scripts/powershell/<name>.ps1`
twin with the same flags, the same JSON output and the same exit codes.

| OS | Needed | Install |
|---|---|---|
| **macOS** | `git`, `bash` 4+, `curl`, `jq` | `brew install bash jq` — `git`/`curl` come with the Xcode Command Line Tools (`xcode-select --install`) |
| **Linux** | `git`, `bash` 4+, `curl`, `jq` | `sudo apt-get install -y git curl jq` (Debian/Ubuntu) · `sudo dnf install -y git curl jq` (Fedora/RHEL) · `sudo pacman -S git curl jq` (Arch) |
| **Windows** | `git`, [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`) | `winget install Microsoft.PowerShell` — built-in JSON and HTTP, so **no `curl` and no `jq` needed** |

Check what you have: `git --version && bash --version && curl --version && jq --version`
(Windows: `pwsh -Version`).

**`jq` is not optional on macOS/Linux** — every bash helper is built on it.
Without it the auto-context hook still exits cleanly and never blocks generation,
but it reports `"reason": "missing-dependency"` and the agent loses the
deterministic path (link parsing, node-id canonicalization, snapshot). It then
falls back to improvising, a common source of wrong node ids being sent to a
Figma MCP server.

No `sudo`, or Homebrew's Cellar not writable? The static binary needs no admin
rights — pick the asset matching your machine:

```bash
# macOS Apple Silicon: jq-macos-arm64  ·  macOS Intel: jq-macos-amd64
# Linux x86_64:        jq-linux-amd64  ·  Linux ARM64: jq-linux-arm64
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/jq https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64
chmod +x ~/.local/bin/jq
# add to your shell profile (~/.zshrc on macOS, ~/.bashrc on most Linux distros):
export PATH="$HOME/.local/bin:$PATH"
```

Last resort on a locked-down macOS/Linux machine: install PowerShell 7+ and run
the `.specify/scripts/powershell/*.ps1` twins instead — they need neither `curl`
nor `jq`.

### One-time setup per developer — read-only Figma PAT

Generate a **read-only** personal access token in your Figma account settings,
store it in your OS credential store, and export the retrieval command from
your shell profile — never commit the token, never put it in a `.env`.

macOS (keychain):

```bash
security add-generic-password -s figma-pat -a "$USER" -w 'figd_xxxxxxxx'
echo 'export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"' >> ~/.zshrc
```

Windows (PowerShell 7+ with the SecretManagement + SecretStore modules; the
`.ps1` helper twins live in `.specify/scripts/powershell/`):

```powershell
Set-Secret -Name figma-pat -Secret 'figd_xxxxxxxx'
# in $PROFILE:
$env:FIGMA_PAT_COMMAND = 'Get-Secret figma-pat -AsPlainText'
```

CI / Cloud Agents use an injected platform secret instead
(`figma.credentials.source: "ci-secret"` in the config).

### Optional per developer — Figma MCP server (higher mockup fidelity)

The default REST engine needs nothing beyond the PAT. Adding a Figma **MCP**
server gives the agent the design's structured node data (exact spacing, layout
constraints, tokens, variants, component bindings), so it reproduces the mockups
far more faithfully. MCP has its **own** authentication — the PAT above is not
used for it, and regenerating the PAT neither fixes nor breaks MCP.

**Claude Code** — install the official plugin, which wires Figma's hosted server
(`https://mcp.figma.com/mcp`) in as a native tool:

```bash
claude plugin install figma@claude-plugins-official
```

**VS Code** — add the same hosted server to your agent (manual: auto-detection is
Claude-Code-only). With GitHub Copilot in agent mode, run **MCP: Add Server…**
from the Command Palette (type *HTTP*, URL `https://mcp.figma.com/mcp`) or commit
`.vscode/mcp.json`:

```jsonc
{ "servers": { "figma": { "type": "http", "url": "https://mcp.figma.com/mcp" } } }
```

Cline, Continue and the Claude Code extension do **not** read `.vscode/mcp.json` —
add the same URL through their own MCP configuration.

Then sign in to Figma at the OAuth prompt and set `figma.contextSource: "mcp"` in
`figma.projects.config.json`. The extension probes the server and falls back to
REST when it is absent, so the config stays portable (keep `rest` in CI).

> Getting *"The provided node ID was not found in the file"*? That message comes
> from the MCP server, not from this extension — see
> [install guide → troubleshooting](.figma/docs/INSTALL.md#troubleshooting--the-provided-node-id-was-not-found-in-the-file).
> The most frequent cause is the **local** Dev Mode server
> (`http://127.0.0.1:3845/mcp`), which only sees the file currently open in the
> Figma desktop app; the hosted server above is file-agnostic.

### Updating

Run `/speckit.figma.update` in your agent: it fetches the new version directly
from the [official repository]({{REPOSITORY_URL}}) (no local checkout needed),
re-syncs assets and hooks, and re-registers the slash-commands. Your
`figma.projects.config.json` and design-rules overlay are preserved.

Local guides, synced to the installed extension version:
[credentials & PAT setup](.figma/docs/CREDENTIALS.md) ·
[install & update](.figma/docs/INSTALL.md) ·
[mono/multi-repo layouts](.figma/docs/MONOREPO.md)
<!-- END SPECKIT-FIGMA README -->
