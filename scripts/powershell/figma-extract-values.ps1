#!/usr/bin/env pwsh
# =============================================================================
# figma-extract-values.ps1 — deterministic design values from a snapshot
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-extract-values.sh (same contract).
#
# The extension's promise is that the design section is produced deterministically
# "REGARDLESS of the agent model". That was built for the section's STRUCTURE and
# never for its VALUES: the snapshot is a raw dump of the Figma node tree, and the
# spacing/typography tables were left for the model to mine out of it. Weaker
# models do not mine megabytes of JSON; they guess.
#
# UNITS ARE ALWAYS EXPLICIT. Every length is emitted as "<n>px", never as a bare
# number — a raw 70 handed to a scale-indexed helper (Tailwind's `mt-70`, or MUI's
# `theme.spacing(70)` on a theme built with `spacing: 4`) silently becomes 280px.
# The extension's job stops at "this is 70 absolute CSS px at 1x"; HOW a project
# converts it is declared in the `.figma/figma-design-rules.custom.md` overlay.
#
# Usage:
#   figma-extract-values.ps1 [--snapshot <path>] [--format json|markdown]
#     [--max-rows N] [--node <id> ...]
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$snapshot = ''
$format = 'json'
$maxRows = 120
$wantNodes = @()
$i = 0
while ($i -lt $args.Count) {
    switch -Regex ($args[$i]) {
        '^--snapshot$' { $snapshot = [string]$args[$i + 1]; $i += 2; continue }
        '^--format$'   { $format = [string]$args[$i + 1]; $i += 2; continue }
        '^--max-rows$' { $maxRows = [string]$args[$i + 1]; $i += 2; continue }
        '^--node$'     { $wantNodes += [string]$args[$i + 1]; $i += 2; continue }
        default        { Write-FigmaStderr "ERROR: unknown arg '$($args[$i])'"; exit 1 }
    }
}

if ($format -notin @('json', 'markdown')) {
    Write-FigmaStderr "ERROR: --format must be json or markdown (got '$format')"; exit 1
}
if ("$maxRows" -notmatch '^[1-9][0-9]*$') {
    Write-FigmaStderr "ERROR: --max-rows must be a positive integer (got '$maxRows')"; exit 1
}
$maxRows = [int]$maxRows

if (-not $snapshot) { $snapshot = Get-FigmaCachePath }
if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf)) {
    Write-FigmaStderr "ERROR: snapshot not found: $snapshot (run figma-introspect.ps1 first)"; exit 1
}

# Renders a length with its unit, and only when the value is a real number: Figma
# omits paddings that are zero on some node types, and a fabricated "0px" reads as
# a deliberate design decision the mockup never made.
function Format-Px {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [double] -and $Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [decimal]) { return $null }
    $d = [double]$Value
    if ($d -eq [math]::Floor($d)) { return "$([long]$d)px" }
    return "$($d)px"
}

function Get-NodeFacts {
    param($Node)
    $style = $Node.style
    $facts = [ordered]@{
        layoutMode            = $Node.layoutMode
        paddingTop            = Format-Px $Node.paddingTop
        paddingRight          = Format-Px $Node.paddingRight
        paddingBottom         = Format-Px $Node.paddingBottom
        paddingLeft           = Format-Px $Node.paddingLeft
        itemSpacing           = Format-Px $Node.itemSpacing
        primaryAxisAlignItems = $Node.primaryAxisAlignItems
        counterAxisAlignItems = $Node.counterAxisAlignItems
        cornerRadius          = Format-Px $Node.cornerRadius
        width                 = Format-Px $Node.absoluteBoundingBox.width
        height                = Format-Px $Node.absoluteBoundingBox.height
        fontFamily            = $style.fontFamily
        fontWeight            = $style.fontWeight
        fontSize              = Format-Px $style.fontSize
        lineHeightPx          = Format-Px $style.lineHeightPx
        letterSpacing         = Format-Px $style.letterSpacing
        textAlignHorizontal   = $style.textAlignHorizontal
        textAlignVertical     = $style.textAlignVertical
        # Style ids are the bridge to the Design System: a node bound to a shared
        # style must map to the matching token, not to the raw value it renders.
        styles                = $(if ($Node.styles -and @($Node.styles.PSObject.Properties).Count -gt 0) { $Node.styles } else { $null })
        componentId           = $Node.componentId
    }
    $out = [ordered]@{}
    foreach ($k in $facts.Keys) { if ($null -ne $facts[$k] -and '' -ne $facts[$k]) { $out[$k] = $facts[$k] } }
    return $out
}

$all = [System.Collections.Generic.List[object]]::new()
function Add-Walk {
    param($Node, [int]$Depth)
    $all.Add([ordered]@{
        id = $Node.id; name = $Node.name; type = $Node.type
        depth = $Depth; facts = (Get-NodeFacts $Node)
    })
    foreach ($child in @($Node.children)) {
        if ($null -ne $child) { Add-Walk $child ($Depth + 1) }
    }
}

$snap = Read-FigmaJsonFile $snapshot
$nodeMap = $snap.nodes.nodes
if ($nodeMap) {
    foreach ($prop in @($nodeMap.PSObject.Properties)) {
        if ($wantNodes.Count -gt 0 -and $prop.Name -notin $wantNodes) { continue }
        $doc = $prop.Value.document
        if ($doc) { Add-Walk $doc 0 }
    }
}

$rows = @($all | Where-Object { $_.facts.Keys.Count -gt 0 })
$digest = [ordered]@{
    snapshotFile = $snap.fileId
    lastModified = $snap.lastModified
    totalNodes   = $all.Count
    rowCount     = $rows.Count
    truncated    = ($rows.Count -gt $maxRows)
    nodes        = @($rows | Select-Object -First $maxRows)
}

if ($format -eq 'json') {
    ConvertTo-FigmaJson $digest -Compress
    exit 0
}

function Format-Cell {
    param($Value)
    if ($null -eq $Value -or '' -eq $Value) { return '—' }
    return ([string]$Value) -replace '\|', '\|' -replace '[\r\n]+', ' '
}
function Get-Indent { param([int]$D) '· ' * ([math]::Min($D, 6)) }

$layout = @($digest.nodes | Where-Object {
    $_.facts.layoutMode -or $_.facts.paddingTop -or $_.facts.paddingLeft -or
    $_.facts.itemSpacing -or $_.facts.width -or $_.facts.cornerRadius })
$text = @($digest.nodes | Where-Object { $_.facts.fontSize -or $_.facts.textAlignHorizontal })

$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append("**Layout values (auto-filled, absolute CSS px at 1x)**`n`n")
if ($layout.Count -eq 0) {
    [void]$sb.Append("_No layout value extracted — the snapshot holds no deep-fetched node._")
} else {
    [void]$sb.Append("| Node | Type | Direction | Padding T/R/B/L | Gap | Align (main/cross) | Radius | Size |`n")
    [void]$sb.Append("|------|------|-----------|-----------------|-----|--------------------|--------|------|`n")
    $lines = foreach ($n in $layout) {
        "| $(Get-Indent $n.depth)$(Format-Cell $n.name) ``$($n.id)`` | $(Format-Cell $n.type) | $(Format-Cell $n.facts.layoutMode) " +
        "| $(Format-Cell $n.facts.paddingTop) / $(Format-Cell $n.facts.paddingRight) / $(Format-Cell $n.facts.paddingBottom) / $(Format-Cell $n.facts.paddingLeft) " +
        "| $(Format-Cell $n.facts.itemSpacing) | $(Format-Cell $n.facts.primaryAxisAlignItems) / $(Format-Cell $n.facts.counterAxisAlignItems) " +
        "| $(Format-Cell $n.facts.cornerRadius) | $(Format-Cell $n.facts.width) × $(Format-Cell $n.facts.height) |"
    }
    [void]$sb.Append(($lines -join "`n"))
}
[void]$sb.Append("`n`n**Typography values (auto-filled, absolute CSS px at 1x)**`n`n")
if ($text.Count -eq 0) {
    [void]$sb.Append('_No text node extracted._')
} else {
    [void]$sb.Append("| Node | Family | Weight | Size | Line height | Letter spacing | Align (h/v) |`n")
    [void]$sb.Append("|------|--------|--------|------|-------------|----------------|-------------|`n")
    $lines = foreach ($n in $text) {
        "| $(Get-Indent $n.depth)$(Format-Cell $n.name) ``$($n.id)`` | $(Format-Cell $n.facts.fontFamily) | $(Format-Cell $n.facts.fontWeight) " +
        "| $(Format-Cell $n.facts.fontSize) | $(Format-Cell $n.facts.lineHeightPx) | $(Format-Cell $n.facts.letterSpacing) " +
        "| $(Format-Cell $n.facts.textAlignHorizontal) / $(Format-Cell $n.facts.textAlignVertical) |"
    }
    [void]$sb.Append(($lines -join "`n"))
}
if ($digest.truncated) {
    [void]$sb.Append("`n`n> ⚠️ Truncated to $($digest.nodes.Count) of $($digest.rowCount) nodes carrying values. Pin a narrower frame with a Figma node link to get the full digest.")
}
[void]$sb.Append("`n`n> Values are **absolute CSS px at 1x**. Convert them through this project's declared contract (``.figma/figma-design-rules.custom.md``); never pass a raw px number to a scale-indexed helper.")
$sb.ToString()
