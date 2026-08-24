# Pester tests for figma-check-orphans.ps1 — mirrors tests/figma-check-orphans.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment

    # An era-1.6.0 spec: a real design section, but the mapping was the trigger,
    # so no url was ever recorded.
    function Set-OrphanSpec {
        param([string]$Workspace, [string]$Feature)
        $dir = Join-Path $Workspace "specs/$Feature"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'spec.md') -Value "<!-- speckit-figma:section phase=spec -->`n## Figma Design Context`n`nNone — context derived from page mapping."
    }
    function Set-HealthySpec {
        param([string]$Workspace, [string]$Feature)
        $dir = Join-Path $Workspace "specs/$Feature"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'spec.md') -Value "<!-- speckit-figma:section phase=spec file=ABC123 lastModified=x -->`n[frame](https://www.figma.com/design/ABC123/X?node-id=12-345)"
    }
}

Describe 'figma-check-orphans.ps1' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        New-Item -ItemType Directory -Force -Path (Join-Path $ws 'specs') | Out-Null
    }

    It 'reports a mapping-derived spec with no link as orphaned' {
        Set-OrphanSpec $ws '001-checkout'
        $r = Invoke-FigmaScript 'figma-check-orphans.ps1' @() -Workspace $ws
        $r.ExitCode | Should -Be 0
        @($r.Json.orphans).Count | Should -Be 1
        $r.Json.orphans[0].feature | Should -Be '001-checkout'
        $r.Json.orphans[0].reason | Should -Be 'no-link-recorded'
    }

    It 'treats a spec carrying a link as healthy' {
        Set-HealthySpec $ws '002-cart'
        $r = Invoke-FigmaScript 'figma-check-orphans.ps1' @() -Workspace $ws
        @($r.Json.orphans).Count | Should -Be 0
        $r.Json.healthy | Should -Be 1
    }

    It 'does not scan a design-less spec' {
        $dir = Join-Path $ws 'specs/003-billing'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'spec.md') -Value '# Spec'
        $r = Invoke-FigmaScript 'figma-check-orphans.ps1' @() -Workspace $ws
        $r.Json.scanned | Should -Be 0
    }

    It 'does not treat a figma.com url in prose as a design section' {
        $dir = Join-Path $ws 'specs/004-notes'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'spec.md') -Value '# Spec`n`nSee https://www.figma.com/design/ABC123/X for context.'
        $r = Invoke-FigmaScript 'figma-check-orphans.ps1' @() -Workspace $ws
        $r.Json.scanned | Should -Be 0
    }

    It 'names both ways out in the diagnostic' {
        Set-OrphanSpec $ws '001-checkout'
        $r = Invoke-FigmaScript 'figma-check-orphans.ps1' @() -Workspace $ws
        $r.Stderr | Should -Match 'paste the Figma link'
        $r.Stderr | Should -Match 'autoIntrospect'
    }

    It 'counts mixed features separately' {
        Set-OrphanSpec $ws '001-checkout'
        Set-HealthySpec $ws '002-cart'
        Set-OrphanSpec $ws '003-account'
        $r = Invoke-FigmaScript 'figma-check-orphans.ps1' @() -Workspace $ws
        $r.Json.scanned | Should -Be 3
        $r.Json.healthy | Should -Be 1
        @($r.Json.orphans | ForEach-Object { $_.feature }) | Should -Be @('001-checkout', '003-account')
    }

    It 'exits non-zero under --strict when an orphan exists' {
        Set-OrphanSpec $ws '001-checkout'
        (Invoke-FigmaScript 'figma-check-orphans.ps1' @('--strict') -Workspace $ws).ExitCode | Should -Be 1
    }

    It 'exits 0 under --strict when every feature is healthy' {
        Set-HealthySpec $ws '002-cart'
        (Invoke-FigmaScript 'figma-check-orphans.ps1' @('--strict') -Workspace $ws).ExitCode | Should -Be 0
    }
}
