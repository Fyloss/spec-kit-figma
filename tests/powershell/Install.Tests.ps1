# Pester tests for install.ps1 — mirrors the core of tests/install.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
    $script:Installer = Join-Path (Get-RepoRoot) 'install.ps1'

    # Child pwsh process: the installer writes warnings via [Console]::Error,
    # which only a process boundary lets us capture (see Invoke-FigmaScript).
    function Invoke-Installer {
        param([string]$Workspace, [string[]]$Arguments = @())
        $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "figma-pester-inst-$([System.IO.Path]::GetRandomFileName())"
        $stdout = (pwsh -NoProfile -File $script:Installer --target $Workspace @Arguments 2>$stderrFile) | Out-String
        $r = @{ Stdout = $stdout; ExitCode = $LASTEXITCODE; Stderr = '' }
        if (Test-Path $stderrFile) {
            $r.Stderr = [string](Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue)
            Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
        }
        return $r
    }
}

Describe 'install.ps1' {
    BeforeEach {
        $script:ws = New-TempWorkspace
    }

    It 'copies BOTH helper-script families into the target workspace' {
        $r = Invoke-Installer $ws
        $r.ExitCode | Should -Be 0
        foreach ($stem in @('figma-validate-config', 'figma-detect-target', 'figma-resolve-source', 'figma-introspect', 'figma-ensure-context')) {
            Test-Path (Join-Path $ws ".specify/scripts/bash/$stem.sh") | Should -BeTrue
            Test-Path (Join-Path $ws ".specify/scripts/powershell/$stem.ps1") | Should -BeTrue
        }
        Test-Path (Join-Path $ws '.specify/scripts/bash/figma-common.sh') | Should -BeTrue
        Test-Path (Join-Path $ws '.specify/scripts/powershell/figma-common.ps1') | Should -BeTrue
    }

    It 'scaffolds the config, design rules, overlay, templates and guides' {
        $r = Invoke-Installer $ws
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $ws 'figma.projects.config.json') | Should -BeTrue
        Test-Path (Join-Path $ws '.figma/figma-design-rules.md') | Should -BeTrue
        Test-Path (Join-Path $ws '.figma/figma-design-rules.custom.md') | Should -BeTrue
        Test-Path (Join-Path $ws '.specify/templates/spec-figma-section.template.md') | Should -BeTrue
        Test-Path (Join-Path $ws '.figma/docs/CREDENTIALS.md') | Should -BeTrue
        (Get-Content (Join-Path $ws '.gitignore')) | Should -Contain '.figma/cache/'
    }

    It 'never overwrites an existing config or the user overlay, but refreshes the base' {
        $null = Invoke-Installer $ws
        Add-Content (Join-Path $ws '.figma/figma-design-rules.custom.md') 'my custom rule'
        Set-Content (Join-Path $ws '.figma/figma-design-rules.md') 'tampered base'
        Set-Content (Join-Path $ws 'figma.projects.config.json') '{"mode":"single-repo"}'
        $r = Invoke-Installer $ws
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match 'already exists'
        (Get-Content (Join-Path $ws '.figma/figma-design-rules.custom.md') -Raw) | Should -Match 'my custom rule'
        (Get-Content (Join-Path $ws '.figma/figma-design-rules.md') -Raw) | Should -Not -Match 'tampered base'
        (Get-Content (Join-Path $ws 'figma.projects.config.json') -Raw) | Should -Match '"mode":"single-repo"'
    }

    It 'migrates a legacy .figma/ gitignore entry to .figma/cache/' {
        Set-Content (Join-Path $ws '.gitignore') '.figma/'
        Set-Content (Join-Path $ws '.figma/context-snapshot.json') '{}'
        Set-Content (Join-Path $ws '.figma/section.spec.md') 'stale'
        $r = Invoke-Installer $ws
        $r.ExitCode | Should -Be 0
        $lines = Get-Content (Join-Path $ws '.gitignore')
        $lines | Should -Not -Contain '.figma/'
        $lines | Should -Contain '.figma/cache/'
        Test-Path (Join-Path $ws '.figma/context-snapshot.json') | Should -BeFalse
        Test-Path (Join-Path $ws '.figma/section.spec.md') | Should -BeFalse
        Test-Path (Join-Path $ws '.figma/figma-design-rules.md') | Should -BeTrue
    }

    It 'creates a README with the managed figma section and refreshes it in place' {
        $r1 = Invoke-Installer $ws
        Test-Path (Join-Path $ws 'README.md') | Should -BeTrue
        $readme = Get-Content (Join-Path $ws 'README.md') -Raw
        $readme | Should -Match 'BEGIN SPECKIT-FIGMA README'
        $readme | Should -Match 'FIGMA_PAT_COMMAND'
        $readme | Should -Not -Match '\{\{'
        $r2 = Invoke-Installer $ws
        $r2.Stdout | Should -Match 'UPDATED: figma section'
        (Select-String -Path (Join-Path $ws 'README.md') -Pattern 'BEGIN SPECKIT-FIGMA README' -AllMatches).Matches.Count | Should -Be 1
    }

    It '--no-readme does not create a README' {
        $r = Invoke-Installer $ws @('--no-readme')
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $ws 'README.md') | Should -BeFalse
    }

    It 'leaves an unterminated README block untouched (no data loss)' {
        Set-Content (Join-Path $ws 'README.md') "# My project`n`n<!-- BEGIN SPECKIT-FIGMA README (managed) -->`nuser content after an unterminated marker`n"
        $r = Invoke-Installer $ws
        $r.ExitCode | Should -Be 0
        $r.Stderr | Should -Match 'unterminated'
        (Get-Content (Join-Path $ws 'README.md') -Raw) | Should -Match 'user content after an unterminated marker'
        (Select-String -Path (Join-Path $ws 'README.md') -Pattern 'BEGIN SPECKIT-FIGMA README' -AllMatches).Matches.Count | Should -Be 1
    }

    It '--prompt-hooks appends the auto-context hook with both script variants, once' {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws '.claude/commands')
        Set-Content (Join-Path $ws '.claude/commands/speckit.specify.md') '# specify'
        $null = Invoke-Installer $ws @('--prompt-hooks')
        $null = Invoke-Installer $ws @('--prompt-hooks')
        $content = Get-Content (Join-Path $ws '.claude/commands/speckit.specify.md') -Raw
        $content | Should -Match 'figma-ensure-context\.sh'
        $content | Should -Match 'figma-ensure-context\.ps1'
        $content | Should -Match '--input -'
        (Select-String -Path (Join-Path $ws '.claude/commands/speckit.specify.md') -Pattern 'BEGIN SPECKIT-FIGMA AUTO-CONTEXT' -AllMatches).Matches.Count | Should -Be 1
    }

    It 'a default run removes a previously injected auto-context block' {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws '.claude/commands')
        Set-Content (Join-Path $ws '.claude/commands/speckit.specify.md') "# specify`n`n<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed) -->`nold hook`n<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->"
        $r = Invoke-Installer $ws
        $r.Stdout | Should -Match 'CLEANED:'
        $content = Get-Content (Join-Path $ws '.claude/commands/speckit.specify.md') -Raw
        $content | Should -Not -Match 'SPECKIT-FIGMA AUTO-CONTEXT'
        $content | Should -Match '# specify'
    }

    It '--no-hooks leaves the prompts fully untouched' {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws '.claude/commands')
        Set-Content (Join-Path $ws '.claude/commands/speckit.specify.md') "# specify`n`n<!-- BEGIN SPECKIT-FIGMA AUTO-CONTEXT (managed) -->`nold hook body`n<!-- END SPECKIT-FIGMA AUTO-CONTEXT -->"
        $r = Invoke-Installer $ws @('--no-hooks')
        (Get-Content (Join-Path $ws '.claude/commands/speckit.specify.md') -Raw) | Should -Match 'old hook body'
    }

    It 'reports version coherence against the SpecKit manifest' {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws '.specify/extensions/figma')
        Set-Content (Join-Path $ws '.specify/extensions/figma/extension.yml') "extension:`n  id: figma`n  version: `"0.9.0`""
        $r = Invoke-Installer $ws
        $r.Stderr | Should -Match 'mismatch'
        $r.Stderr | Should -Match '0\.9\.0'
    }

    It 'warns when figma commands are missing from a configured agent dir' {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws '.claude/commands')
        Set-Content (Join-Path $ws '.claude/commands/speckit.specify.md') '# specify'
        $r = Invoke-Installer $ws
        $r.Stderr | Should -Match 'not registered'
        $r.Stderr | Should -Match '\.claude/commands'
    }

    It 'the workspace scripts validate a config end-to-end after install' {
        $null = Invoke-Installer $ws
        Copy-Item (Join-Path (Get-FixturesDir) 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json') -Force
        Push-Location $ws
        try {
            $out = & (Join-Path $ws '.specify/scripts/powershell/figma-validate-config.ps1')
            $LASTEXITCODE | Should -Be 0
            $out | Should -Match '^OK: '
        } finally {
            Pop-Location
        }
    }
}
