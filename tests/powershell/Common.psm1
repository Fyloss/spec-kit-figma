# Shared helpers for the Pester test suite of the PowerShell script ports.
# Mirrors tests/helpers/common.bash: resolves the repository root, the scripts
# under test, and provides an isolated non-git temporary workspace factory.

# Repository root = two levels up from this helper (tests/powershell -> repo root).
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:ScriptsDir = Join-Path $script:RepoRoot 'scripts/powershell'
$script:FixturesDir = Join-Path $script:RepoRoot 'tests/fixtures'

function Get-RepoRoot { $script:RepoRoot }
function Get-ScriptsDir { $script:ScriptsDir }
function Get-FixturesDir { $script:FixturesDir }

# Hermetic credentials: a developer's real Figma token must never leak into the
# suite — otherwise tests that expect introspection to FAIL for lack of a token
# would instead hit the real Figma API. Also drop any inherited config/API-base
# overrides and silence the Claude Code plugin advisory.
function Reset-FigmaEnvironment {
    foreach ($name in @('FIGMA_PAT', 'FIGMA_PAT_COMMAND', 'FIGMA_CONFIG', 'FIGMA_API_BASE',
            'FIGMA_DIAG_FILE', 'FIGMA_API_MAX_ATTEMPTS', 'FIGMA_API_RETRY_DELAY',
            'FIGMA_SNAPSHOT_MAX_AGE_MINUTES', 'CLAUDECODE', 'AI_AGENT')) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    $env:FIGMA_NO_PLUGIN_ADVICE = '1'
}

# Create an isolated, non-git temporary workspace so that Get-FigmaRepoRoot
# falls back to $PWD instead of resolving the extension's own git root.
# Pre-creates .figma/cache so tests can stage a snapshot or rendered section.
function New-TempWorkspace {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "figma-pester-$([System.IO.Path]::GetRandomFileName())"
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir '.figma/cache')
    return (Resolve-Path $dir).Path
}

# Run one of the scripts under test from inside a workspace directory, capturing
# stdout, stderr and the exit code. Returns @{ Stdout; Stderr; ExitCode; Json }.
# Json is the parsed stdout when it parses as JSON, else $null.
# The script runs in a CHILD pwsh process (as real callers do): the helpers
# write diagnostics via [Console]::Error, which an in-process `2>` redirection
# cannot capture — a process boundary can.
function Invoke-FigmaScript {
    param(
        [Parameter(Mandatory)] [string]$Name,      # e.g. 'figma-validate-config.ps1'
        [string[]]$Arguments = @(),
        [string]$Workspace = (Get-Location).Path,
        [string]$StdinText = $null
    )
    $scriptPath = Join-Path (Get-ScriptsDir) $Name
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "figma-pester-err-$([System.IO.Path]::GetRandomFileName())"
    Push-Location $Workspace
    try {
        if ($null -ne $StdinText) {
            $stdout = ($StdinText | pwsh -NoProfile -File $scriptPath @Arguments 2>$stderrFile) | Out-String
        } else {
            $stdout = (pwsh -NoProfile -File $scriptPath @Arguments 2>$stderrFile) | Out-String
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $stderr = ''
    if (Test-Path -LiteralPath $stderrFile) {
        $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
    $json = $null
    if ($stdout.Trim().StartsWith('{') -or $stdout.Trim().StartsWith('[')) {
        try { $json = $stdout | ConvertFrom-Json } catch { }
    }
    return @{ Stdout = $stdout; Stderr = [string]$stderr; ExitCode = $exitCode; Json = $json }
}

# Minimal valid snapshot used by render/verify/ensure tests.
function Write-FakeSnapshot {
    param([string]$Workspace, [string]$FileId = 'AbC123')
    $snapshot = [ordered]@{
        fileId        = $FileId
        projectId     = $null
        teams         = $null
        contextSource = 'rest'
        generatedAt   = '2026-07-02T10:00:00Z'
        lastModified  = '2026-07-01T09:00:00Z'
        version       = '42'
        pages         = @(
            [ordered]@{ id = '0:1'; name = 'Landing | Home'; frames = @(
                [ordered]@{ id = '1:2'; name = 'Hero'; type = 'FRAME' },
                [ordered]@{ id = '1:3'; name = 'Footer'; type = 'FRAME' }
            ) },
            [ordered]@{ id = '0:2'; name = 'Empty'; frames = @() }
        )
        components    = [ordered]@{ c1 = @{}; c2 = @{} }
        componentSets = $null
        styles        = [ordered]@{ s1 = @{} }
        nodes         = [ordered]@{ nodes = [ordered]@{ '1:2' = [ordered]@{ document = [ordered]@{ type = 'FRAME' } } } }
    }
    $path = Join-Path $Workspace '.figma/cache/context-snapshot.json'
    ConvertTo-Json -InputObject $snapshot -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

# Install the section templates into a workspace so the renderer finds them.
function Install-SectionTemplates {
    param([string]$Workspace)
    $dest = Join-Path $Workspace '.specify/templates'
    $null = New-Item -ItemType Directory -Force -Path $dest
    Get-ChildItem -Path (Join-Path (Get-RepoRoot) 'templates') -Filter '*figma-section.template.md' |
        Copy-Item -Destination $dest
}

Export-ModuleMember -Function Get-RepoRoot, Get-ScriptsDir, Get-FixturesDir,
    Reset-FigmaEnvironment, New-TempWorkspace, Invoke-FigmaScript,
    Write-FakeSnapshot, Install-SectionTemplates
