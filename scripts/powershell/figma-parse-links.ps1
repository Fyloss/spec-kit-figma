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
#   {"fileId":"AbC123","nodeId":"12:345","kind":"design","url":"..."}
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
# with optional node-id query.
$linkPattern = 'https?://(www\.)?figma\.com/(file|design|proto)/[A-Za-z0-9_-]+[^\s)"<]*'
$matches_ = [regex]::Matches($text, $linkPattern)
if ($matches_.Count -eq 0) { exit 0 }

foreach ($m in $matches_) {
    $url = $m.Value
    if (-not $url) { continue }
    $kindKey = [regex]::Match($url, 'figma\.com/(file|design|proto)/([A-Za-z0-9_-]+)')
    $kind = $kindKey.Groups[1].Value
    $key = $kindKey.Groups[2].Value
    $node = $null
    $nodeMatch = [regex]::Match($url, 'node-id=[0-9]+[-:%][0-9A-Za-z]+')
    if ($nodeMatch.Success) {
        $node = $nodeMatch.Value -replace '^node-id=', ''
        # Normalize the id separator to ':' — %3A (any case) first, else the
        # first '-' (the URL form of the canvas separator).
        if ($node -match '%3A|%3a') {
            $node = $node -replace '%3A', ':' -replace '%3a', ':'
        } else {
            $idx = $node.IndexOf('-')
            if ($idx -ge 0) { $node = $node.Substring(0, $idx) + ':' + $node.Substring($idx + 1) }
        }
    }
    ConvertTo-FigmaJson ([ordered]@{
        fileId = $key
        nodeId = $node
        kind   = $kind
        url    = $url
    }) -Compress
}
exit 0
