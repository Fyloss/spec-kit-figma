# Pester tests for figma-render-section.ps1 and figma-verify-section.ps1 —
# mirrors tests/render-section.bats and tests/verify-section.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
    $script:Fixtures = Get-FixturesDir
}

Describe 'figma-render-section.ps1' {
    BeforeEach {
        $script:ws = New-TempWorkspace
        Install-SectionTemplates $ws
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        Write-FakeSnapshot $ws | Out-Null
    }

    It 'renders the <_> section with the machine marker and filled placeholders' -ForEach @('spec', 'plan', 'tasks') {
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', $_) -Workspace $ws
        $r.ExitCode | Should -Be 0
        $out = $r.Stdout.Trim()
        Test-Path $out | Should -BeTrue
        $content = Get-Content $out -Raw
        $content | Should -Match ([regex]::Escape("<!-- speckit-figma:section phase=$_ -->"))
        $content | Should -Match 'AbC123'
        $content | Should -Match '2026-07-02T10:00:00Z'
        # Deterministic placeholders are gone; judgement placeholders may remain.
        $content | Should -Not -Match ([regex]::Escape('{{FIGMA_FILE_ID}}'))
        $content | Should -Not -Match ([regex]::Escape('{{rest | mcp}}'))
    }

    It 'escapes pipes in page names inside the markdown tables' {
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', 'spec') -Workspace $ws
        $content = Get-Content $r.Stdout.Trim() -Raw
        $content | Should -Match ([regex]::Escape('Landing \| Home'))
    }

    It 'renders the direct-links table from --links' {
        $links = '[{"fileId":"AbC123","nodeId":"1:2","kind":"design","url":"https://www.figma.com/design/AbC123/X?node-id=1-2"}]'
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', 'spec', '--links', $links) -Workspace $ws
        $content = Get-Content $r.Stdout.Trim() -Raw
        $content | Should -Match 'node-id=1-2'
        $content | Should -Not -Match ([regex]::Escape('_None — context derived from the page mapping._'))
    }

    It 'adds the creative-confirmation table for candidate frames' {
        $cands = '[{"id":"1:2","name":"Hero","page":"Landing"},{"id":"1:3","name":"Footer","page":"Landing"}]'
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', 'tasks', '--candidate-frames', $cands) -Workspace $ws
        $content = Get-Content $r.Stdout.Trim() -Raw
        $content | Should -Match 'A broad Figma link'
        $content | Should -Match ([regex]::Escape('| 1 | Landing | Hero | `1:2` |'))
    }

    It 'rejects a non-array --links value' {
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', 'spec', '--links', '{"not":"array"}') -Workspace $ws
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match 'must be a JSON array'
    }

    It 'fails cleanly when the snapshot is missing' {
        Remove-Item (Join-Path $ws '.figma/cache/context-snapshot.json')
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', 'spec') -Workspace $ws
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match 'snapshot not found'
    }

    It 'rejects an unknown phase' {
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', 'bogus') -Workspace $ws
        $r.ExitCode | Should -Be 1
    }
}

Describe 'figma-verify-section.ps1' {
    BeforeEach {
        $script:ws = New-TempWorkspace
        Install-SectionTemplates $ws
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        Write-FakeSnapshot $ws | Out-Null
        # Render a real section for the spec phase and stage a spec document.
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', 'spec') -Workspace $ws
        $script:rendered = $r.Stdout.Trim()
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws 'specs/001-feature')
        $script:doc = Join-Path $ws 'specs/001-feature/spec.md'
    }

    It 'reports not-applicable when no section was rendered' {
        Remove-Item $rendered
        Set-Content $doc "# Spec"
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'spec') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.verified | Should -BeTrue
        $r.Json.applicable | Should -BeFalse
        $r.Json.reason | Should -Be 'not-applicable'
    }

    It 'reports section-missing when the doc lacks the marker (exit 0 by default)' {
        Set-Content $doc "# Spec without section"
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'spec') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.verified | Should -BeFalse
        $r.Json.reason | Should -Be 'section-missing'
        $r.Json.remedy | Should -Match 'Insert the rendered Figma section'
    }

    It 'exits non-zero on section-missing under --strict' {
        Set-Content $doc "# Spec without section"
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'spec', '--strict') -Workspace $ws
        $r.ExitCode | Should -Be 1
    }

    It 'reports ok when the machine marker is present' {
        Set-Content $doc ("# Spec`n" + (Get-Content $rendered -Raw))
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'spec') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.verified | Should -BeTrue
        $r.Json.reason | Should -Be 'ok'
    }

    It 'recognizes the legacy heading fallback' {
        Set-Content $doc "# Spec`n`n## Figma Design Context (extension: figma)`nbody"
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'spec') -Workspace $ws
        $r.Json.reason | Should -Be 'ok'
    }

    It 'does not accept a wrong-phase section' {
        # A plan section pasted into spec.md must NOT verify the spec phase.
        Set-Content $doc "# Spec`n<!-- speckit-figma:section phase=plan -->"
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'spec') -Workspace $ws
        $r.Json.reason | Should -Be 'section-missing'
    }

    It 'refuses to guess between several candidate documents (doc-not-found)' {
        Set-Content $doc "# Spec"
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws 'specs/002-other')
        Set-Content (Join-Path $ws 'specs/002-other/spec.md') "# Other"
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'spec') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'doc-not-found'
    }

    It 'honours an explicit --doc path' {
        $other = Join-Path $ws 'somewhere-else.md'
        Set-Content $other ("x`n" + (Get-Content $rendered -Raw))
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'spec', '--doc', $other) -Workspace $ws
        $r.Json.reason | Should -Be 'ok'
    }

    It 'rejects an unknown phase' {
        $r = Invoke-FigmaScript 'figma-verify-section.ps1' @('--phase', 'bogus') -Workspace $ws
        $r.ExitCode | Should -Be 1
    }
}
