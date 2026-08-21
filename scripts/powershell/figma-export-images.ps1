#!/usr/bin/env pwsh
# =============================================================================
# figma-export-images.ps1 — render Figma nodes to image files
# =============================================================================
# PowerShell 7+ port of scripts/bash/figma-export-images.sh (same contract).
#
# Two needs share the /images endpoint and nothing else. They are separate MODES
# because their lifecycles are opposite, and one flag doing both would put
# throwaway files under version control (or leave deliverables in a git-ignored
# cache).
#
#   --mode preview (default): a picture of each candidate frame, so the developer
#     CONFIRMS the creative by looking at it (design rule 5). Written to
#     specs/<feature>/assets/ and COMMITTED — .figma/cache/ is git-ignored, so a
#     preview written there renders as a broken image in the spec a reviewer
#     reads on GitHub.
#   --mode asset: a real asset the implementation ships (a logo as .svg, a mock
#     as .png). Written where --out says, committed, and recorded in a manifest
#     so a re-run neither re-downloads an unchanged node nor silently overwrites
#     a hand-edited file.
#
# THE ENDPOINT RENDERS ASYNCHRONOUSLY: GET /v1/images/:key returns a map of node
# id -> temporary URL, and each URL must then be downloaded. Two steps, not one.
#
# Usage:
#   figma-export-images.ps1 --file <fileKey> --node <id> [--node <id> ...]
#     [--mode preview|asset] [--format png|jpg|svg|pdf] [--scale N]
#     [--out <dir>] [--batch-size N] [--force] [--config <path>]
# =============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/figma-common.ps1"

$fileKey = ''
$mode = 'preview'
$format = ''
$scale = '2'
$outDir = ''
$batchSize = 10
$force = $false
$nodes = @()
$i = 0
while ($i -lt $args.Count) {
    switch -Regex ($args[$i]) {
        '^--file$'       { $fileKey = [string]$args[$i + 1]; $i += 2; continue }
        '^--node$'       { $nodes += [string]$args[$i + 1]; $i += 2; continue }
        '^--mode$'       { $mode = [string]$args[$i + 1]; $i += 2; continue }
        '^--format$'     { $format = [string]$args[$i + 1]; $i += 2; continue }
        '^--scale$'      { $scale = [string]$args[$i + 1]; $i += 2; continue }
        '^--out$'        { $outDir = [string]$args[$i + 1]; $i += 2; continue }
        '^--batch-size$' { $batchSize = [string]$args[$i + 1]; $i += 2; continue }
        '^--force$'      { $force = $true; $i += 1; continue }
        '^--config$'     { $env:FIGMA_CONFIG = [string]$args[$i + 1]; $i += 2; continue }
        default          { Write-FigmaStderr "ERROR: unknown arg '$($args[$i])'"; exit 1 }
    }
}

switch ($mode) {
    'preview' { if (-not $format) { $format = 'png' } }
    'asset'   { if (-not $format) { $format = 'svg' } }
    default   { Write-FigmaStderr "ERROR: --mode must be preview or asset (got '$mode')"; exit 1 }
}
if ($format -notin @('png', 'jpg', 'svg', 'pdf')) {
    Write-FigmaStderr "ERROR: --format must be png, jpg, svg or pdf (got '$format')"; exit 1
}
# Figma rejects scale on vector formats; sending it anyway is a 400 for a
# parameter that could never have meant anything.
if ($format -in @('svg', 'pdf')) {
    $scale = ''
} else {
    $parsed = 0.0
    if (-not [double]::TryParse($scale, [ref]$parsed) -or $parsed -lt 0.01 -or $parsed -gt 4) {
        Write-FigmaStderr "ERROR: --scale must be a number between 0.01 and 4 (got '$scale')"; exit 1
    }
}
if ("$batchSize" -notmatch '^[1-9][0-9]*$') {
    Write-FigmaStderr "ERROR: --batch-size must be a positive integer (got '$batchSize')"; exit 1
}
$batchSize = [int]$batchSize
if (-not $fileKey) { Write-FigmaStderr 'ERROR: --file <fileKey> is required'; exit 1 }
if ($nodes.Count -eq 0) { Write-FigmaStderr 'ERROR: at least one --node <id> is required'; exit 1 }

# Canonicalize here rather than trusting the caller: an agent that copies the id
# out of a deep link hands over the URL form ('12-345'), which the API answers
# with an empty image map.
$normalized = @()
foreach ($raw in $nodes) {
    $canon = ConvertTo-FigmaNodeId $raw
    if (-not $canon) {
        Write-FigmaStderr "ERROR: --node '$raw' is not a Figma node id. Expected '12:345' (the URL form 'node-id=12-345' is accepted)."
        exit 1
    }
    $normalized += $canon
}
$nodes = $normalized

$root = Get-FigmaRepoRoot
if (-not $outDir) {
    if ($mode -eq 'preview') {
        $outDir = Join-Path $root (Join-Path 'specs' (Join-Path (Get-FigmaFeatureKey) 'assets'))
    } else {
        Write-FigmaStderr 'ERROR: --out <dir> is required in asset mode: where a shipped asset belongs is a project decision (design system vs app), never a default this script may pick.'
        exit 1
    }
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$manifestPath = ''
$manifest = [ordered]@{}
if ($mode -eq 'asset') {
    # The manifest is what makes a re-run safe: it records what this script wrote
    # and what the file looked like when it did, so an asset a human has since
    # edited is never silently overwritten.
    $manifestPath = Join-Path $outDir '.figma-assets.json'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $loaded = Read-FigmaJsonFile $manifestPath
            foreach ($p in @($loaded.PSObject.Properties)) { $manifest[$p.Name] = $p.Value }
        } catch { }
    }
}

# Report paths relative to the repo root, as the bash twin does. The
# canonicalisation lives in figma-common.ps1 (Get-FigmaPhysicalPath) because it
# is neither export-specific nor obvious: it walks symlinked ancestors, and it
# must never probe the filesystem root, which throws on Windows.
function Get-RelativeToRoot {
    param([string]$Path)
    Get-FigmaRelativePath $Path $script:root
}

# A node id is not a filename: ':' is a path separator on Windows and ';' appears
# in nested-instance ids.
function Get-SafeName { param([string]$Id) $Id -replace '[:;]', '_' }
function Get-Sha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$exported = @()
$failed = @()
$urlMap = @{}

# ---- step 1: ask Figma to render, in batches --------------------------------
for ($b = 0; $b -lt $nodes.Count; $b += $batchSize) {
    $batch = @($nodes[$b..([math]::Min($b + $batchSize - 1, $nodes.Count - 1))])
    $ids = ($batch -join ',').Replace(';', '%3B')
    $query = "/images/${fileKey}?ids=$ids&format=$format"
    if ($scale) { $query += "&scale=$scale" }
    try {
        $resp = (Invoke-FigmaApi $query) | ConvertFrom-Json
    } catch {
        Write-FigmaStderr "WARN: Figma refused to render a batch of $($batch.Count) node(s); they are reported as failed."
        foreach ($n in $batch) { $failed += [ordered]@{ nodeId = $n; reason = 'render-request-failed' } }
        continue
    }
    if ($resp.err) { Write-FigmaStderr "WARN: Figma returned an error for this batch: $($resp.err)" }
    foreach ($p in @($resp.images.PSObject.Properties)) { $urlMap[$p.Name] = $p.Value }
}

# ---- step 2: download each rendered URL -------------------------------------
$timeout = if ($env:FIGMA_IMAGE_TIMEOUT) { [int]$env:FIGMA_IMAGE_TIMEOUT } else { 60 }
foreach ($node in $nodes) {
    $imgUrl = $urlMap[$node]
    if (-not $imgUrl) {
        if (-not ($failed | Where-Object { $_.nodeId -eq $node })) {
            $failed += [ordered]@{ nodeId = $node; reason = 'no-image-returned' }
        }
        continue
    }

    $dest = Join-Path $outDir "$(Get-SafeName $node).$format"
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # The rendered URL is a plain signed URL on Figma's CDN and must NOT carry
        # the PAT: sending it would leak a credential to a third-party host.
        Invoke-WebRequest -Uri $imgUrl -OutFile $tmp -TimeoutSec $timeout -ErrorAction Stop | Out-Null
    } catch {
        $failed += [ordered]@{ nodeId = $node; reason = 'download-failed' }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        continue
    }

    $newSha = Get-Sha256 $tmp
    $status = 'written'
    if (Test-Path -LiteralPath $dest) {
        $oldSha = Get-Sha256 $dest
        $recordedSha = if ($manifest[$node]) { [string]$manifest[$node].sha256 } else { '' }
        if ($oldSha -eq $newSha) {
            $status = 'unchanged'
        } elseif ($mode -eq 'asset' -and -not $force -and $recordedSha -and $recordedSha -ne $oldSha) {
            # The file on disk is not what this script last wrote: a human changed
            # it. Overwriting would destroy work with no trace.
            $status = 'skipped-modified'
            Write-FigmaStderr "WARN: $dest was modified after its last export; keeping it. Pass --force to overwrite."
        }
    }
    if ($status -eq 'written') { Move-Item -LiteralPath $tmp -Destination $dest -Force }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    $bytes = if (Test-Path -LiteralPath $dest) { (Get-Item -LiteralPath $dest).Length } else { 0 }
    $rel = Get-RelativeToRoot $dest
    $exported += [ordered]@{ nodeId = $node; path = $rel; bytes = $bytes; status = $status }

    if ($mode -eq 'asset' -and $status -ne 'skipped-modified') {
        $manifest[$node] = [ordered]@{
            sha256 = $newSha; path = $rel; format = $format
            exportedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }
}

if ($manifestPath) { ConvertTo-FigmaJson $manifest | Set-Content -LiteralPath $manifestPath -Encoding utf8 }

$relOut = Get-RelativeToRoot $outDir
ConvertTo-FigmaJson ([ordered]@{
    mode     = $mode
    fileId   = $fileKey
    outDir   = $relOut
    format   = $format
    scale    = $(if ($scale) { [double]$scale } else { $null })
    exported = @($exported)
    failed   = @($failed)
    manifest = $(if ($manifestPath) { Get-RelativeToRoot $manifestPath } else { $null })
})
