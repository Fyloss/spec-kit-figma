# Pester tests for figma-export-images.ps1 — mirrors tests/figma-export-images.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
}

Describe 'figma-export-images.ps1' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        $env:SPECIFY_FEATURE = '001-checkout'
        $script:mock = $null
    }

    AfterEach {
        if ($script:mock) { Stop-MockFigma $script:mock }
        Remove-Item Env:\SPECIFY_FEATURE -ErrorAction SilentlyContinue
    }

    It 'writes a preview beside the spec, where a reviewer can see it' {
        # .figma/cache/ is git-ignored: a preview written there renders as a
        # broken image in the spec.md a reviewer reads on GitHub.
        $script:mock = Start-MockFigma
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345') -Workspace $ws
        $r.ExitCode | Should -Be 0 -Because "the script failed. stderr: $($r.Stderr) | stdout: $($r.Stdout)"
        $r.Json.mode | Should -Be 'preview' -Because "stderr: $($r.Stderr)"
        $r.Json.outDir | Should -Be 'specs/001-checkout/assets' -Because "stderr: $($r.Stderr)"
        Test-Path (Join-Path $ws 'specs/001-checkout/assets/12_345.png') | Should -BeTrue
        $r.Json.exported[0].status | Should -Be 'written' -Because "stderr: $($r.Stderr)"
    }

    It 'canonicalizes the URL form of a node id' {
        $script:mock = Start-MockFigma
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12-345') -Workspace $ws
        $r.Json.exported[0].nodeId | Should -Be '12:345' -Because "stderr: $($r.Stderr)"
    }

    It 'refuses to guess where a shipped asset belongs' {
        $script:mock = Start-MockFigma
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'asset') -Workspace $ws
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match '--out'
    }

    It 'defaults asset mode to svg and records a manifest' {
        $script:mock = Start-MockFigma
        $out = Join-Path $ws 'src/assets'
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'asset', '--out', $out) -Workspace $ws
        $r.ExitCode | Should -Be 0 -Because "the script failed. stderr: $($r.Stderr) | stdout: $($r.Stdout)"
        $r.Json.format | Should -Be 'svg' -Because "stderr: $($r.Stderr)"
        Test-Path (Join-Path $out '12_345.svg') | Should -BeTrue
        $manifest = Get-Content (Join-Path $out '.figma-assets.json') -Raw | ConvertFrom-Json
        $manifest.'12:345'.format | Should -Be 'svg'
        $manifest.'12:345'.sha256.Length | Should -Be 64
        # The report must carry a repo-relative path, like the bash twin.
        $r.Json.outDir | Should -Be 'src/assets' -Because "stderr: $($r.Stderr)"
    }

    It 'rewrites nothing when the node has not changed' {
        $script:mock = Start-MockFigma
        $out = Join-Path $ws 'src/assets'
        Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'asset', '--out', $out) -Workspace $ws | Out-Null
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'asset', '--out', $out) -Workspace $ws
        $r.Json.exported[0].status | Should -Be 'unchanged' -Because "stderr: $($r.Stderr)"
    }

    It 'never silently overwrites a hand-edited asset' {
        # Destroying a manual edit with no trace is worse than a stale asset.
        $script:mock = Start-MockFigma
        $out = Join-Path $ws 'src/assets'
        Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'asset', '--out', $out) -Workspace $ws | Out-Null
        Set-Content -LiteralPath (Join-Path $out '12_345.svg') -Value 'hand edited'
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'asset', '--out', $out) -Workspace $ws
        $r.Json.exported[0].status | Should -Be 'skipped-modified' -Because "stderr: $($r.Stderr)"
        (Get-Content -LiteralPath (Join-Path $out '12_345.svg') -Raw).Trim() | Should -Be 'hand edited'
    }

    It 'overwrites a hand-edited asset only with --force' {
        $script:mock = Start-MockFigma
        $out = Join-Path $ws 'src/assets'
        Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'asset', '--out', $out) -Workspace $ws | Out-Null
        Set-Content -LiteralPath (Join-Path $out '12_345.svg') -Value 'hand edited'
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'asset', '--out', $out, '--force') -Workspace $ws
        $r.Json.exported[0].status | Should -Be 'written' -Because "stderr: $($r.Stderr)"
        (Get-Content -LiteralPath (Join-Path $out '12_345.svg') -Raw).Trim() | Should -Not -Be 'hand edited'
    }

    It 'never sends the PAT to the rendered image URL' {
        # The render URL is a signed CDN link, not a Figma API endpoint.
        $script:mock = Start-MockFigma
        Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345') -Workspace $ws | Out-Null
        $leaked = (Invoke-RestMethod -Uri "http://127.0.0.1:$($mock.Port)/leaked").leaked
        @($leaked).Count | Should -Be 0
    }

    It 'reports a node Figma cannot render instead of dropping it' {
        $script:mock = Start-MockFigma '99:999'
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--node', '99:999') -Workspace $ws
        @($r.Json.exported).Count | Should -Be 1 -Because "stderr: $($r.Stderr)"
        $r.Json.failed[0].nodeId | Should -Be '99:999' -Because "stderr: $($r.Stderr)"
        $r.Json.failed[0].reason | Should -Be 'no-image-returned' -Because "stderr: $($r.Stderr)"
    }

    It 'batches ids so a big file does not time out' {
        $script:mock = Start-MockFigma
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '1:1', '--node', '1:2', '--node', '1:3', '--batch-size', '2') -Workspace $ws
        @($r.Json.exported).Count | Should -Be 3 -Because "stderr: $($r.Stderr)"
    }

    It 'drops scale for vector formats rather than sending it' {
        $script:mock = Start-MockFigma
        $r = Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--format', 'svg', '--scale', '3') -Workspace $ws
        $r.Json.scale | Should -BeNullOrEmpty
    }

    It 'rejects invalid arguments before any network call' {
        (Invoke-FigmaScript 'figma-export-images.ps1' @('--node', '12:345') -Workspace $ws).ExitCode | Should -Be 1
        (Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123') -Workspace $ws).ExitCode | Should -Be 1
        (Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--mode', 'nope') -Workspace $ws).ExitCode | Should -Be 1
        (Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--format', 'gif') -Workspace $ws).ExitCode | Should -Be 1
        (Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', '12:345', '--scale', '99') -Workspace $ws).ExitCode | Should -Be 1
        (Invoke-FigmaScript 'figma-export-images.ps1' @('--file', 'ABC123', '--node', 'not a node') -Workspace $ws).ExitCode | Should -Be 1
    }
}
