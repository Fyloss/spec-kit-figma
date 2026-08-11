#!/usr/bin/env pwsh
# =============================================================================
# figma-parse-links.ps1 — extract Figma file/node references from free-form input
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-parse-links.sh (same contract).
# Handles the case where the spec-generation input contains direct Figma links.
# Usage:
#   figma-parse-links.ps1 "https://www.figma.com/design/AbC123/Flow?node-id=12-345 ..."
#   $INPUT | figma-parse-links.ps1
# Output: one JSON object per detected link:
#   {"fileId":"AbC123","nodeId":"12:345","startNodeId":null,"kind":"design","url":"..."}
# startNodeId carries a prototype's `starting-point-node-id`: a /proto/ URL names
# TWO frames — the one the designer was viewing (node-id) and the entry point of
# the flow — and both are creatives the spec needs. Callers treat it as an
# additional node id, which also pins a link whose node-id is missing.
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$text = ($args -join ' ')
if (-not $text) {
    $text = ($input | Out-String)
    if (-not $text -and -not [Console]::IsInputRedirected) { $text = '' }
    if (-not $text) {
        try { $text = [Console]::In.ReadToEnd() } catch { $text = '' }
    }
}
if (-not $text) { exit 0 }

# Match figma.com/file/<key>, figma.com/design/<key> and figma.com/proto/<key>,
# with optional node-id and starting-point-node-id queries.
$linkPattern = 'https?://(www\.)?figma\.com/(file|design|proto)/[A-Za-z0-9_-]+[^\s)"<]*'
$matches_ = [regex]::Matches($text, $linkPattern)
if ($matches_.Count -eq 0) { exit 0 }

foreach ($m in $matches_) {
    $url = $m.Value
    if (-not $url) { continue }
    $kindKey = [regex]::Match($url, 'figma\.com/(file|design|proto)/([A-Za-z0-9_-]+)')
    $kind = $kindKey.Groups[1].Value
    $key = $kindKey.Groups[2].Value
    # Take the whole node-id value (up to the next parameter or fragment) and let
    # ConvertTo-FigmaNodeId canonicalize it: the tracking suffix Figma appends
    # (&t=…) must not leak into the id, and nested-instance ids carry several
    # separators. The '&' separator is matched through any number of 'amp;'
    # escapes: input pasted from a rich-text source (Jira, Confluence, an HTML
    # email) arrives as '&amp;node-id=…', and requiring a bare '&' would silently
    # downgrade a pinned frame to a broad link.
    # An unrecognized value yields null — the caller then treats the link as broad
    # and asks which frame, which is safer than forwarding an id the API/MCP
    # server will reject.
    $node = $null
    $nodeMatch = [regex]::Match($url, '[?&](?:amp;)*node-id=([^&#\s]+)')
    if ($nodeMatch.Success) {
        $node = ConvertTo-FigmaNodeId $nodeMatch.Groups[1].Value
    }
    # The prototype's entry frame. Anchoring on '[?&](?:amp;)*' also keeps the
    # node-id match above from reading THIS parameter (it ends in 'node-id=', but
    # preceded by '-', never by a separator).
    $startNode = $null
    $startMatch = [regex]::Match($url, '[?&](?:amp;)*starting-point-node-id=([^&#\s]+)')
    if ($startMatch.Success) {
        $startNode = ConvertTo-FigmaNodeId $startMatch.Groups[1].Value
    }
    ConvertTo-FigmaJson ([ordered]@{
        fileId      = $key
        nodeId      = $node
        startNodeId = $startNode
        kind        = $kind
        url         = $url
    }) -Compress
}
exit 0
