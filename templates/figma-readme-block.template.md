<!-- BEGIN SPECKIT-FIGMA README (managed by spec-kit-figma v{{EXTENSION_VERSION}}; re-running install.sh refreshes this section — edits inside will be lost) -->
## Figma design context (SpecKit extension)

This workspace uses [spec-kit-figma]({{REPOSITORY_URL}}) v{{EXTENSION_VERSION}}
({{MODE}} layout): `/speckit.specify`, `/speckit.plan` and `/speckit.tasks`
automatically ground the generated documents in the Figma mockups declared in
[`figma.projects.config.json`](figma.projects.config.json).

### One-time setup per developer — read-only Figma PAT

Generate a **read-only** personal access token in your Figma account settings,
store it in your OS keychain, and export the retrieval command from your shell
profile — never commit the token, never put it in a `.env` (macOS example):

```bash
security add-generic-password -s figma-pat -a "$USER" -w 'figd_xxxxxxxx'
echo 'export FIGMA_PAT_COMMAND="security find-generic-password -s figma-pat -w"' >> ~/.zshrc
```

CI / Cloud Agents use an injected platform secret instead
(`figma.credentials.source: "ci-secret"` in the config).

Local guides, synced to the installed extension version:
[credentials & PAT setup](.figma/docs/CREDENTIALS.md) ·
[install & update](.figma/docs/INSTALL.md) ·
[mono/multi-repo layouts](.figma/docs/MONOREPO.md)
<!-- END SPECKIT-FIGMA README -->
