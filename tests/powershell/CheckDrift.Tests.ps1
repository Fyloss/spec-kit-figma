# Pester tests for figma-check-drift.ps1 — mirrors tests/figma-check-drift.bats.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
    $script:Fixtures = Get-FixturesDir

    # Declared here, not inside Describe: Pester 5 runs It blocks in a scope that
    # only sees functions defined by a file-level BeforeAll.
    function Set-Doc {
        param([string]$FileId, [string]$LastModified)
        $marker = if ($LastModified) {
            "<!-- speckit-figma:section phase=spec file=$FileId lastModified=$LastModified -->"
        } else {
            '<!-- speckit-figma:section phase=spec -->'
        }
        Set-Content -LiteralPath $script:doc -Value "$marker`n## Figma Design Context"
    }

    function Set-Snapshot {
        param([string]$FileId, [string]$LastModified)
        Set-Content -LiteralPath $script:snap -Value "{`"fileId`":`"$FileId`",`"lastModified`":`"$LastModified`"}"
    }
}

Describe 'figma-check-drift.ps1' {
    BeforeEach {
        $script:ws = New-TempWorkspace
        $env:SPECIFY_FEATURE = '001-checkout'
        $script:specDir = Join-Path $ws 'specs/001-checkout'
        New-Item -ItemType Directory -Force -Path $specDir | Out-Null
        $script:doc = Join-Path $specDir 'spec.md'
        $script:snap = Join-Path $ws '.figma/cache/context-snapshot.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
    }

    AfterEach { Remove-Item Env:\SPECIFY_FEATURE -ErrorAction SilentlyContinue }

    It 'reports drift when the Figma file changed after the spec' {
        Set-Doc 'ABC123' '2026-08-01T10:00:00Z'
        Set-Snapshot 'ABC123' '2026-08-14T09:12:33Z'
        $r = Invoke-FigmaScript 'figma-check-drift.ps1' @() -Workspace $ws
        $r.ExitCode | Should -Be 0
        $json = $r.Stdout | ConvertFrom-Json
        $json.drifted | Should -BeTrue
        $json.reason | Should -Be 'drifted'
        # Asserted on the raw JSON text, not on the parsed object: PowerShell's
        # ConvertFrom-Json coerces an ISO-8601 string into [datetime], which would
        # compare a DateTime against a string and never match. What matters is
        # that the emitted JSON carries the timestamps verbatim.
        $r.Stdout | Should -Match ([regex]::Escape('"documentLastModified": "2026-08-01T10:00:00Z"'))
        $r.Stdout | Should -Match ([regex]::Escape('"figmaLastModified": "2026-08-14T09:12:33Z"'))
    }

    It 'reports ok when the design has not moved' {
        Set-Doc 'ABC123' '2026-08-14T09:12:33Z'
        Set-Snapshot 'ABC123' '2026-08-14T09:12:33Z'
        $json = (Invoke-FigmaScript 'figma-check-drift.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $json.drifted | Should -BeFalse
        $json.reason | Should -Be 'ok'
    }

    It 'does not manufacture drift from a snapshot older than the document' {
        Set-Doc 'ABC123' '2026-08-14T09:12:33Z'
        Set-Snapshot 'ABC123' '2026-07-01T00:00:00Z'
        $json = (Invoke-FigmaScript 'figma-check-drift.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $json.reason | Should -Be 'ok'
    }

    It 'treats a design-less feature as not applicable' {
        Set-Content -LiteralPath $doc -Value "# Spec`nNo Figma here."
        Set-Snapshot 'ABC123' '2026-08-14T09:12:33Z'
        $json = (Invoke-FigmaScript 'figma-check-drift.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $json.applicable | Should -BeFalse
        $json.reason | Should -Be 'no-marker'
    }

    It 'reports unknown-timestamp for a marker predating drift tracking' {
        Set-Doc 'ABC123' ''
        Set-Snapshot 'ABC123' '2026-08-14T09:12:33Z'
        $json = (Invoke-FigmaScript 'figma-check-drift.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $json.drifted | Should -BeFalse
        $json.reason | Should -Be 'unknown-timestamp'
    }

    It 'skips the comparison when the snapshot targets another file' {
        Set-Doc 'ABC123' '2026-08-01T10:00:00Z'
        Set-Snapshot 'OTHER999' '2026-08-14T09:12:33Z'
        $json = (Invoke-FigmaScript 'figma-check-drift.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $json.reason | Should -Be 'not-applicable'
    }

    It 'never fails when there is nothing to compare' {
        Set-Doc 'ABC123' '2026-08-01T10:00:00Z'
        $r = Invoke-FigmaScript 'figma-check-drift.ps1' @() -Workspace $ws
        $r.ExitCode | Should -Be 0
        ($r.Stdout | ConvertFrom-Json).reason | Should -Be 'no-snapshot'
    }

    It 'exits non-zero under --strict on a real drift' {
        Set-Doc 'ABC123' '2026-08-01T10:00:00Z'
        Set-Snapshot 'ABC123' '2026-08-14T09:12:33Z'
        (Invoke-FigmaScript 'figma-check-drift.ps1' @('--strict') -Workspace $ws).ExitCode | Should -Be 1
    }

    It 'still exits 0 under --strict when the check cannot run' {
        # The gate fires on evidence of drift, never on the absence of evidence.
        Set-Doc 'ABC123' '2026-08-01T10:00:00Z'
        (Invoke-FigmaScript 'figma-check-drift.ps1' @('--strict') -Workspace $ws).ExitCode | Should -Be 0
    }

    It 'rejects an unknown flag' {
        (Invoke-FigmaScript 'figma-check-drift.ps1' @('--nope') -Workspace $ws).ExitCode | Should -Be 1
    }

    It 'rejects a phase outside spec|plan|tasks' {
        (Invoke-FigmaScript 'figma-check-drift.ps1' @('--phase', 'implement') -Workspace $ws).ExitCode | Should -Be 1
    }
}
