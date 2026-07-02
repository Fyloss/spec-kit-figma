#!/usr/bin/env pwsh
# =============================================================================
# figma-resolve-source.ps1 — resolve the effective design-context engine
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-resolve-source.sh (same contract).
# Decides which engine the agent should use for this run:
#   - "rest" (default): portable, CI-friendly (Invoke-WebRequest against the REST API).
#   - "mcp": a Model Context Protocol Figma server, when reachable.
# When contextSource = "mcp" but the MCP server is unreachable, it transparently
# falls back to "rest" (unless mcp.fallbackToRest = false, which is a hard error).
#
# Usage: figma-resolve-source.ps1 [path/to/figma.projects.config.json]
# Prints a JSON object on stdout:
#   { "requested": "rest|mcp", "effective": "rest|mcp",
#     "fellBack": true|false,
#     "mcp": { "url": "...", "reachable": true|false, "fallbackToRest": true|false },
#     "claudeCode": { "detected": true|false, "officialFigmaPlugin": true|false } }
# When running in Claude Code without a Figma plugin, a recommendation to install
# `figma@claude-plugins-official` is also printed to stderr (see
# Write-FigmaClaudePluginAdvice; silence with FIGMA_NO_PLUGIN_ADVICE=1).
# Exit codes: 0 = resolved, 1 = MCP required but unreachable (fallback disabled).
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$config = if ($args.Count -ge 1 -and $args[0]) { [string]$args[0] } else { Get-FigmaDefaultConfig }
if (-not (Test-FigmaConfig $config)) { exit 1 }

$requested = [string](Get-FigmaContextSource $config)
$mcpUrl = [string](Get-FigmaMcpUrl $config)
$fallback = Test-FigmaMcpFallbackEnabled $config

$reachable = $false
if ($requested -eq 'mcp') {
    if (Test-FigmaMcpAvailable $config) { $reachable = $true }
}

# Derive the effective engine from the single probe above (probing again via
# Resolve-FigmaContextSource would block on a second timeout and could disagree
# with $reachable if the server flaps between probes). The decision table itself
# is shared with figma-common.ps1.
try {
    $effective = Resolve-FigmaContextSourceDecision $requested $reachable $fallback $mcpUrl
} catch {
    ConvertTo-FigmaJson ([ordered]@{
        requested = $requested; effective = $null; fellBack = $false
        mcp = [ordered]@{ url = $mcpUrl; reachable = $reachable; fallbackToRest = $fallback }
    })
    exit 1
}

$fellBack = ($requested -eq 'mcp' -and $effective -eq 'rest')

# Claude Code advisory: surface the official Figma plugin when it would help.
# The human-readable tip goes to stderr (see Write-FigmaClaudePluginAdvice); the
# JSON carries the same signal so /speckit.figma.setup can report it too.
$claudeCode = Test-FigmaIsClaudeCode
$figmaPlugin = Test-FigmaClaudeFigmaPluginInstalled
Write-FigmaClaudePluginAdvice

ConvertTo-FigmaJson ([ordered]@{
    requested = $requested
    effective = $effective
    fellBack  = $fellBack
    mcp = [ordered]@{ url = $mcpUrl; reachable = $reachable; fallbackToRest = $fallback }
    claudeCode = [ordered]@{ detected = $claudeCode; officialFigmaPlugin = $figmaPlugin }
})
exit 0
