# Pester tests for figma-detect-target.ps1 — mirrors tests/detect-target.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
    $script:Fixtures = Get-FixturesDir
}

Describe 'figma-detect-target.ps1' {
    It 'maps the single repo target in single-repo mode' {
        $r = Invoke-FigmaScript 'figma-detect-target.ps1' @('repo', (Join-Path $Fixtures 'singlerepo-valid.json'))
        $r.ExitCode | Should -Be 0
        $r.Json.enabled | Should -BeTrue
        $r.Json.reason | Should -Be 'mapped'
        $r.Json.figmaFileId | Should -Not -BeNullOrEmpty
    }

    It 'reports not-mapped for an unknown target' {
        $r = Invoke-FigmaScript 'figma-detect-target.ps1' @('unknown-pkg', (Join-Path $Fixtures 'multirepo-valid.json'))
        $r.ExitCode | Should -Be 0
        $r.Json.enabled | Should -BeFalse
        $r.Json.reason | Should -Be 'not-mapped'
    }

    It 'resolves a mono-repo app to the repo node' {
        $cfg = Get-Content (Join-Path $Fixtures 'monorepo-valid.json') -Raw | ConvertFrom-Json
        $app = @($cfg.repo.monorepo.apps)[0]
        $r = Invoke-FigmaScript 'figma-detect-target.ps1' @($app, (Join-Path $Fixtures 'monorepo-valid.json'))
        $r.ExitCode | Should -Be 0
        $r.Json.enabled | Should -BeTrue
        $r.Json.reason | Should -Be 'mapped'
    }

    It 'excluded targets win and are silent' {
        $ws = New-TempWorkspace
        $cfg = Get-Content (Join-Path $Fixtures 'multirepo-valid.json') -Raw | ConvertFrom-Json
        $name = @($cfg.submodules.PSObject.Properties.Name)[0]
        $cfg.excluded = @($name)
        $custom = Join-Path $ws 'config.json'
        ConvertTo-Json -InputObject $cfg -Depth 100 | Set-Content $custom -Encoding utf8
        $r = Invoke-FigmaScript 'figma-detect-target.ps1' @($name, $custom)
        $r.ExitCode | Should -Be 0
        $r.Json.enabled | Should -BeFalse
        $r.Json.reason | Should -Be 'excluded'
    }

    It 'errors on a missing target argument' {
        $r = Invoke-FigmaScript 'figma-detect-target.ps1' @()
        $r.ExitCode | Should -Be 1
    }

    It 'errors on an invalid config' {
        $r = Invoke-FigmaScript 'figma-detect-target.ps1' @('repo', (Join-Path $Fixtures 'not-json.txt'))
        $r.ExitCode | Should -Be 1
    }
}
