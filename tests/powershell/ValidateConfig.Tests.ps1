# Pester tests for figma-validate-config.ps1 — mirrors tests/validate-config.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
    $script:Fixtures = Get-FixturesDir
}

Describe 'figma-validate-config.ps1' {
    It 'accepts the valid <_> fixture' -ForEach @('singlerepo-valid', 'monorepo-valid', 'multirepo-valid', 'organization-valid', 'page-named-token') {
        $r = Invoke-FigmaScript 'figma-validate-config.ps1' @((Join-Path $Fixtures "$_.json"))
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match '^OK: '
    }

    It 'rejects <name> with exit code <code>' -ForEach @(
        @{ name = 'invalid-mode'; code = 1 }
        @{ name = 'missing-figma-id'; code = 1 }
        @{ name = 'missing-target-fields'; code = 1 }
        @{ name = 'inline-token'; code = 1 }
        @{ name = 'bad-credentials-source'; code = 1 }
        @{ name = 'bad-context-source'; code = 1 }
        @{ name = 'unresolved-placeholder'; code = 2 }
        @{ name = 'unresolved-team-placeholder'; code = 2 }
    ) {
        $r = Invoke-FigmaScript 'figma-validate-config.ps1' @((Join-Path $Fixtures "$name.json"))
        $r.ExitCode | Should -Be $code
    }

    It 'fails with exit 1 on a missing config file' {
        $r = Invoke-FigmaScript 'figma-validate-config.ps1' @('/nonexistent/figma.projects.config.json')
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match 'config not found'
    }

    It 'fails with exit 1 on a file that is not JSON' {
        $r = Invoke-FigmaScript 'figma-validate-config.ps1' @((Join-Path $Fixtures 'not-json.txt'))
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match 'not valid JSON'
    }

    It 'reports the placeholder values on exit 2' {
        $r = Invoke-FigmaScript 'figma-validate-config.ps1' @((Join-Path $Fixtures 'unresolved-placeholder.json'))
        $r.ExitCode | Should -Be 2
        $r.Stderr | Should -Match 'REPLACE_WITH_'
    }
}
