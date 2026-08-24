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
            'FIGMA_SNAPSHOT_MAX_AGE_MINUTES', 'FIGMA_CACHE_GC', 'FIGMA_CACHE_RETENTION_DAYS',
            'CLAUDECODE', 'AI_AGENT', 'SPECIFY_FEATURE')) {
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

# Turn a workspace into a git repository checked out on a given branch, so a
# test can exercise the branch-derived paths. An empty commit is needed because
# `git rev-parse --abbrev-ref HEAD` prints "HEAD" (and fails) on an unborn
# branch. Returns the root as git reports it: on macOS git resolves /var/... to
# its real /private/var/... path, and so do the scripts.
function Initialize-GitWorkspace {
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$Branch)
    git init -q -b $Branch $Workspace | Out-Null
    git -C $Workspace -c user.email=test@example.com -c user.name=Test `
        -c commit.gpgsign=false commit -q --allow-empty -m 'init' | Out-Null
    return (git -C $Workspace rev-parse --show-toplevel)
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

# Stage the extension tree exactly where `specify extension add` installs it.
# That tree is where the helpers and templates LIVE AND RUN FROM, so install.ps1
# requires it (and refuses to run without it), and figma-render-section resolves
# its templates relative to it. Copied, not linked: the suite deletes the
# workspace, which must never reach back into the checkout.
function Install-ExtensionTree {
    param([Parameter(Mandatory)][string]$Workspace)
    $treeHome = Join-Path $Workspace '.specify/extensions/figma'
    $null = New-Item -ItemType Directory -Force -Path $treeHome
    Copy-Item -Path (Join-Path (Get-RepoRoot) 'scripts') -Destination $treeHome -Recurse -Force
    Copy-Item -Path (Join-Path (Get-RepoRoot) 'templates') -Destination $treeHome -Recurse -Force
    return $treeHome
}

# Install the section templates where the renderer under test resolves them: in
# the tree it lives in. Kept as a thin wrapper so the render/verify tests read
# the same as before.
function Install-SectionTemplates {
    param([string]$Workspace)
    $dest = Join-Path $Workspace '.specify/extensions/figma/templates'
    $null = New-Item -ItemType Directory -Force -Path $dest
    Get-ChildItem -Path (Join-Path (Get-RepoRoot) 'templates') -Filter '*figma-section.template.md' |
        Copy-Item -Destination $dest
}

# Path of the rendered section for the feature the test is acting as — mirrors
# Get-FigmaSectionPath, which scopes renders per feature so a design-less feature
# cannot wipe a design one's. Falls back to "default" exactly as the helper does
# when nothing identifies a feature (the temp workspace is not a git repo).
function Get-SectionPath {
    param([string]$Workspace, [string]$Phase)
    $key = if ($env:SPECIFY_FEATURE) { $env:SPECIFY_FEATURE } else { 'default' }
    Join-Path (Join-Path (Join-Path $Workspace '.figma/cache/sections') $key) "$Phase.md"
}

# Stage a fake rendered section, creating the per-feature directory the real
# renderer would have created.
function Set-FakeSection {
    param([string]$Workspace, [string]$Phase, [string]$Content = 'stale')
    $path = Get-SectionPath $Workspace $Phase
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path)
    Set-Content -LiteralPath $path -Value $Content
    return $path
}

# Set a file's mtime N minutes in the past — mirrors backdate_file in the bats
# helpers, so the cache-housekeeping tests can age an entry past its window.
function Set-FigmaFileAge {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$Minutes)
    (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddMinutes(-$Minutes)
}

# Stage a remembered-links file for an arbitrary feature key (Set-FakeSection
# covers the current one), optionally aged past the retention window.
function Set-FakeLinksEntry {
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$Key,
        [int]$AgeMinutes = 0)
    $dir = Join-Path $Workspace '.figma/cache/links'
    $null = New-Item -ItemType Directory -Force -Path $dir
    $path = Join-Path $dir "$Key.json"
    Set-Content -LiteralPath $path -Value '[{"fileId":"F1","nodeId":"1:2"}]'
    if ($AgeMinutes -gt 0) { Set-FigmaFileAge -Path $path -Minutes $AgeMinutes }
    return $path
}

# Same, for a rendered section belonging to an arbitrary feature key.
function Set-FakeSectionFor {
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$Key,
        [string]$Phase = 'spec', [int]$AgeMinutes = 0)
    $dir = Join-Path (Join-Path $Workspace '.figma/cache/sections') $Key
    $null = New-Item -ItemType Directory -Force -Path $dir
    $path = Join-Path $dir "$Phase.md"
    Set-Content -LiteralPath $path -Value 'rendered'
    if ($AgeMinutes -gt 0) { Set-FigmaFileAge -Path $path -Minutes $AgeMinutes }
    return $path
}

# Same, for a per-file snapshot in the store.
function Set-FakeStoredSnapshot {
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$FileId,
        [int]$AgeMinutes = 0)
    $dir = Join-Path $Workspace '.figma/cache/snapshots'
    $null = New-Item -ItemType Directory -Force -Path $dir
    $path = Join-Path $dir "$FileId.json"
    Set-Content -LiteralPath $path -Value "{`"fileId`":`"$FileId`",`"pages`":[]}"
    if ($AgeMinutes -gt 0) { Set-FigmaFileAge -Path $path -Minutes $AgeMinutes }
    return $path
}

# Start the mock Figma server (tests/helpers/mock-figma-server.py) on a free port
# and point FIGMA_API_BASE at it. Returns @{ Port; Process }.
#
# FIGMA_API_BASE is the documented local escape hatch: Get-FigmaApiBase rejects a
# non-figma.com host coming from the CONFIG — so a committed file can never
# redirect the token — but honours the env var for proxies and test mocks.
function Start-MockFigma {
    param([string]$Unrenderable = '')
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $script = Join-Path (Get-RepoRoot) 'tests/helpers/mock-figma-server.py'
    # The interpreter is NOT called 'python3' everywhere, and merely FINDING a
    # command by that name is not enough on Windows: %LOCALAPPDATA%\Microsoft\
    # WindowsApps ships a python3.exe App Execution Alias that is a Store stub —
    # Get-Command finds it, Start-Process starts it, and it exits immediately
    # without ever binding a port. Probe each candidate by actually running it
    # and requiring a Python 3 banner, so a stub is rejected rather than
    # selected.
    $python = $null
    foreach ($cand in @('python3', 'python', 'py')) {
        $cmd = Get-Command $cand -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $cmd) { continue }
        $banner = & $cmd.Source '--version' 2>&1
        if ($LASTEXITCODE -eq 0 -and "$banner" -match 'Python 3') {
            $python = $cmd.Source
            break
        }
    }
    if (-not $python) {
        throw 'Start-MockFigma: no working Python 3 interpreter found (tried python3, python, py). The Figma export tests need one to run the mock server.'
    }
    # Keep the mock's own output: when it dies on start, its stderr is the only
    # thing that says why, and the CI log shows the thrown message only.
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath $python -ArgumentList @($script, "$port", $Unrenderable) `
        -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $ready = $false
    for ($i = 0; $i -lt 100; $i++) {
        if ($proc.HasExited) {
            $diag = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue),
                    (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) -join ' | '
            throw "Start-MockFigma: the mock server exited immediately (exit $($proc.ExitCode)). Interpreter: $python. Output: $diag"
        }
        try {
            $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port)
            $c.Close(); $ready = $true; break
        } catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $ready) {
        try { $proc.Kill() } catch { }
        $diag = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue),
                (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) -join ' | '
        throw "Start-MockFigma: the mock server did not accept connections on port $port within 10s. Interpreter: $python. Output: $diag"
    }
    $env:FIGMA_API_BASE = "http://127.0.0.1:$port/v1"
    $env:FIGMA_PAT = 'test-token'
    return @{ Port = $port; Process = $proc }
}

function Stop-MockFigma {
    param($Mock)
    if ($Mock -and $Mock.Process -and -not $Mock.Process.HasExited) {
        try { $Mock.Process.Kill() } catch { }
    }
    Remove-Item Env:\FIGMA_API_BASE -ErrorAction SilentlyContinue
    Remove-Item Env:\FIGMA_PAT -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Start-MockFigma, Stop-MockFigma
Export-ModuleMember -Function Get-RepoRoot, Get-ScriptsDir, Get-FixturesDir,
    Reset-FigmaEnvironment, New-TempWorkspace, Initialize-GitWorkspace, Invoke-FigmaScript,
    Write-FakeSnapshot, Install-ExtensionTree, Install-SectionTemplates, Get-SectionPath,
    Set-FakeSection, Set-FigmaFileAge, Set-FakeLinksEntry, Set-FakeSectionFor,
    Set-FakeStoredSnapshot
