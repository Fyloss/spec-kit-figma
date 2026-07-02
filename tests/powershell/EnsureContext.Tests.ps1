# Pester tests for figma-ensure-context.ps1 and figma-resolve-source.ps1 —
# mirrors tests/ensure-context.bats and tests/resolve-source.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
    $script:Fixtures = Get-FixturesDir
}

Describe 'figma-ensure-context.ps1 (skip paths)' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
    }

    It 'is a safe no-op without a config (no-config)' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.ran | Should -BeFalse
        $r.Json.reason | Should -Be 'no-config'
        $r.Json.mustInject | Should -BeFalse
    }

    It 'skips on unresolved placeholders' {
        Copy-Item (Join-Path $Fixtures 'unresolved-placeholder.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'unresolved-placeholders'
    }

    It 'skips on an invalid config' {
        Copy-Item (Join-Path $Fixtures 'invalid-mode.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'invalid-config'
    }

    It 'skips an excluded target' {
        $cfg = Get-Content (Join-Path $Fixtures 'multirepo-valid.json') -Raw | ConvertFrom-Json
        $name = @($cfg.submodules.PSObject.Properties.Name)[0]
        $cfg.excluded = @($name)
        ConvertTo-Json -InputObject $cfg -Depth 100 | Set-Content (Join-Path $ws 'figma.projects.config.json') -Encoding utf8
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @($name) -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'target-excluded'
    }

    It 'clears stale rendered sections when Figma does not apply' {
        Set-Content (Join-Path $ws '.figma/cache/section.spec.md') 'stale'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.Json.reason | Should -Be 'no-config'
        Test-Path (Join-Path $ws '.figma/cache/section.spec.md') | Should -BeFalse
    }

    It 'rejects a non-numeric --max-age-minutes' {
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--max-age-minutes', 'nope') -Workspace $ws
        $r.ExitCode | Should -Be 1
    }
}

Describe 'figma-ensure-context.ps1 (fresh snapshot + injection contract)' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        Install-SectionTemplates $ws
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        Write-FakeSnapshot $ws | Out-Null
        # The snapshot must be newer than the config for the fresh path.
        (Get-Item (Join-Path $ws '.figma/cache/context-snapshot.json')).LastWriteTime = Get-Date
    }

    It 'reports fresh with mustInject and the three rendered sections' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.ran | Should -BeFalse
        $r.Json.reason | Should -Be 'fresh'
        $r.Json.mustInject | Should -BeTrue
        foreach ($k in @('specSection', 'planSection', 'tasksSection')) {
            $r.Json.$k | Should -Not -BeNullOrEmpty
            Test-Path $r.Json.$k | Should -BeTrue
        }
    }

    It 'treats a snapshot older than --max-age-minutes as stale (dry-run)' {
        (Get-Item (Join-Path $ws '.figma/cache/context-snapshot.json')).LastWriteTime = (Get-Date).AddMinutes(-120)
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--max-age-minutes', '60', '--dry-run') -Workspace $ws
        $r.Json.reason | Should -Be 'dry-run'
    }

    It 'treats a snapshot older than the config as stale (dry-run)' {
        (Get-Item (Join-Path $ws 'figma.projects.config.json')).LastWriteTime = (Get-Date).AddMinutes(5)
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run') -Workspace $ws
        $r.Json.reason | Should -Be 'dry-run'
    }

    It 'parses direct links from --input and reports frame scope when covered' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'see https://www.figma.com/design/AbC123/X?node-id=1-2') -Workspace $ws
        $r.Json.reason | Should -Be 'fresh'
        $r.Json.linkScope | Should -Be 'frame'
        @($r.Json.links).Count | Should -Be 1
        @($r.Json.links)[0].nodeId | Should -Be '1:2'
    }

    It 'treats a snapshot that does not cover the linked node as stale' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'https://www.figma.com/design/AbC123/X?node-id=99-99') -Workspace $ws
        $r.Json.reason | Should -Be 'dry-run'
        @($r.Json.introspectArgs) | Should -Contain '--node'
        @($r.Json.introspectArgs) | Should -Contain '99:99'
    }

    It 'a linked file different from the snapshot forces re-introspection of that file' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'https://www.figma.com/design/OtherFile/X?node-id=1-2') -Workspace $ws
        $r.Json.reason | Should -Be 'dry-run'
        @($r.Json.introspectArgs) | Should -Contain 'OtherFile'
    }

    It 'reads the feature input from stdin with --input -' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', '-') -Workspace $ws -StdinText 'link https://www.figma.com/design/AbC123/X?node-id=1-2'
        $r.Json.linkScope | Should -Be 'frame'
    }

    It 'reports broad scope with candidate frames for a link without node-id' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'https://www.figma.com/design/AbC123/X') -Workspace $ws
        $r.Json.linkScope | Should -Be 'broad'
        @($r.Json.candidateFrames).Count | Should -Be 2
        @($r.Json.candidateFrames)[0].id | Should -Be '1:2'
    }
}

Describe 'figma-ensure-context.ps1 (introspection failure diagnostics)' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
    }

    It 'reports introspect-failed with code NETWORK on a transport failure' {
        $env:FIGMA_API_BASE = 'http://127.0.0.1:9'   # closed port -> transport failure
        $env:FIGMA_PAT = 'fake-token'
        $env:FIGMA_API_MAX_ATTEMPTS = '1'
        $env:FIGMA_API_RETRY_DELAY = '1'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.ran | Should -BeFalse
        $r.Json.reason | Should -Be 'introspect-failed'
        $r.Json.code | Should -Be 'NETWORK'
        $r.Stderr | Should -Match 'not a credentials one'
    }

    It 'reports introspect-failed with code AUTH when no token is available' {
        $env:FIGMA_API_BASE = 'http://127.0.0.1:9'
        $env:FIGMA_API_MAX_ATTEMPTS = '1'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.Json.reason | Should -Be 'introspect-failed'
        $r.Json.code | Should -Be 'AUTH'
    }

    It 'does not clear a prior rendered section on a transient failure (fail-closed gate)' {
        Set-Content (Join-Path $ws '.figma/cache/section.plan.md') 'prior render'
        $env:FIGMA_API_BASE = 'http://127.0.0.1:9'
        $env:FIGMA_PAT = 'fake-token'
        $env:FIGMA_API_MAX_ATTEMPTS = '1'
        $env:FIGMA_API_RETRY_DELAY = '1'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.Json.reason | Should -Be 'introspect-failed'
        Test-Path (Join-Path $ws '.figma/cache/section.plan.md') | Should -BeTrue
    }
}

Describe 'figma-resolve-source.ps1' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
    }

    It 'defaults to the REST engine' {
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-resolve-source.ps1' -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.requested | Should -Be 'rest'
        $r.Json.effective | Should -Be 'rest'
        $r.Json.fellBack | Should -BeFalse
    }

    It 'falls back to REST when MCP is unreachable and fallback is enabled' {
        $cfg = Get-Content (Join-Path $Fixtures 'singlerepo-valid.json') -Raw | ConvertFrom-Json
        $cfg.figma | Add-Member -NotePropertyName contextSource -NotePropertyValue 'mcp' -Force
        $cfg.figma | Add-Member -NotePropertyName mcp -NotePropertyValue ([pscustomobject]@{ url = 'http://127.0.0.1:9/mcp' }) -Force
        ConvertTo-Json -InputObject $cfg -Depth 100 | Set-Content (Join-Path $ws 'figma.projects.config.json') -Encoding utf8
        $env:FIGMA_MCP_PROBE_TIMEOUT = '1'
        $r = Invoke-FigmaScript 'figma-resolve-source.ps1' -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.requested | Should -Be 'mcp'
        $r.Json.effective | Should -Be 'rest'
        $r.Json.fellBack | Should -BeTrue
        $r.Json.mcp.reachable | Should -BeFalse
    }

    It 'hard-fails when MCP is required and fallback is disabled' {
        $cfg = Get-Content (Join-Path $Fixtures 'singlerepo-valid.json') -Raw | ConvertFrom-Json
        $cfg.figma | Add-Member -NotePropertyName contextSource -NotePropertyValue 'mcp' -Force
        $cfg.figma | Add-Member -NotePropertyName mcp -NotePropertyValue ([pscustomobject]@{ url = 'http://127.0.0.1:9/mcp'; fallbackToRest = $false }) -Force
        ConvertTo-Json -InputObject $cfg -Depth 100 | Set-Content (Join-Path $ws 'figma.projects.config.json') -Encoding utf8
        $env:FIGMA_MCP_PROBE_TIMEOUT = '1'
        $r = Invoke-FigmaScript 'figma-resolve-source.ps1' -Workspace $ws
        $r.ExitCode | Should -Be 1
        $r.Json.effective | Should -Be $null
    }
}
