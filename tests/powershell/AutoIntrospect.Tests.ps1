# Pester tests for the autoIntrospect policy in figma-ensure-context.ps1 —
# mirrors the autoIntrospect block of tests/figma-ensure-context.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
    $script:Fixtures = Get-FixturesDir
    $script:Link = 'https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345'
}

Describe 'figma-ensure-context.ps1 (autoIntrospect)' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        $env:SPECIFY_FEATURE = 'auto-test'
    }

    AfterEach { Remove-Item Env:\SPECIFY_FEATURE -ErrorAction SilentlyContinue }

    It 'defaults to off, so a link-less run still ends at no-figma-link' {
        # The 2.0.0 contract is the default and must stay it.
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'add a Redis cache') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'no-figma-link'
        $r.Json.trigger | Should -Be 'none'
        $r.Json.mustInject | Should -BeFalse
    }

    It 'declines an on-request target when no design intent was claimed' {
        Copy-Item (Join-Path $Fixtures 'autointrospect-on-request-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'build the checkout panel') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'auto-declined'
        $r.Json.trigger | Should -Be 'none'
    }

    It 'introspects the mapped file for on-request + --assume-design' {
        Copy-Item (Join-Path $Fixtures 'autointrospect-on-request-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--assume-design', '--input', 'build the checkout panel') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'dry-run'
        $r.Json.trigger | Should -Be 'auto'
        $r.Json.introspectArgs | Should -Contain '--file'
        $r.Json.introspectArgs | Should -Contain 'single123FILE'
        # No node id exists to pin: the autonomous scope is the whole file.
        $r.Json.introspectArgs | Should -Not -Contain '--node'
    }

    It 'grants nothing to --assume-design when the target keeps mode off' {
        # An agent must never be able to authorise itself.
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--assume-design', '--input', 'build the checkout panel') -Workspace $ws
        $r.Json.reason | Should -Be 'no-figma-link'
        $r.Stderr | Should -Match ([regex]::Escape("autoIntrospect.mode='off'"))
    }

    It 'introspects a link-less run on an always target, with no flag' {
        Copy-Item (Join-Path $Fixtures 'autointrospect-always-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'build the checkout panel') -Workspace $ws
        $r.Json.reason | Should -Be 'dry-run'
        $r.Json.trigger | Should -Be 'auto'
    }

    It 'lets a pasted link win over an always-on target' {
        Copy-Item (Join-Path $Fixtures 'autointrospect-always-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', $Link) -Workspace $ws
        $r.Json.trigger | Should -Be 'link'
        $r.Json.introspectArgs | Should -Contain 'LinkFILE999'
        $r.Json.introspectArgs | Should -Not -Contain 'single123FILE'
    }

    It 'invents no link and remembers none on an autonomous run' {
        Copy-Item (Join-Path $Fixtures 'autointrospect-always-valid.json') (Join-Path $ws 'figma.projects.config.json')
        Install-SectionTemplates $ws
        $snap = Join-Path $ws '.figma/cache/context-snapshot.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
        Set-Content -LiteralPath $snap -Value '{"fileId":"single123FILE","pages":[{"id":"0:1","name":"Checkout","frames":[{"id":"12:345","name":"Summary","type":"FRAME"}]}]}'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'build the checkout panel') -Workspace $ws
        $r.Json.reason | Should -Be 'fresh'
        @($r.Json.links).Count | Should -Be 0
        Test-Path (Join-Path $ws '.figma/cache/links/auto-test.json') | Should -BeFalse
    }

    It 'classifies an autonomous run as broad, so rule 5 fires by construction' {
        Copy-Item (Join-Path $Fixtures 'autointrospect-always-valid.json') (Join-Path $ws 'figma.projects.config.json')
        Install-SectionTemplates $ws
        $snap = Join-Path $ws '.figma/cache/context-snapshot.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
        Set-Content -LiteralPath $snap -Value '{"fileId":"single123FILE","pages":[{"id":"0:1","name":"Checkout","frames":[{"id":"12:345","name":"Summary","type":"FRAME"}]}]}'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'build the checkout panel') -Workspace $ws
        $r.Json.linkScope | Should -Be 'broad'
        @($r.Json.candidateFrames).Count | Should -Be 1
        $r.Json.confirmFrames | Should -BeTrue
        $r.Json.mustInject | Should -BeTrue
    }

    It 'refuses a file over maxFrames and asks for a node id' {
        # maxFrames = 3 in the fixture; the snapshot holds 4 top-level frames.
        Copy-Item (Join-Path $Fixtures 'autointrospect-always-valid.json') (Join-Path $ws 'figma.projects.config.json')
        Install-SectionTemplates $ws
        $snap = Join-Path $ws '.figma/cache/context-snapshot.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
        Set-Content -LiteralPath $snap -Value '{"fileId":"single123FILE","pages":[{"id":"0:1","name":"C","frames":[{"id":"1:1","name":"A"},{"id":"1:2","name":"B"},{"id":"1:3","name":"C"},{"id":"1:4","name":"D"}]}]}'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'build the checkout panel') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'too-large-for-auto'
        $r.Json.mustInject | Should -BeFalse
        $r.Json.specSection | Should -BeNullOrEmpty
        $r.Stderr | Should -Match 'maxFrames'
    }

    It 'never applies the frame budget to a link-driven run' {
        Copy-Item (Join-Path $Fixtures 'autointrospect-always-valid.json') (Join-Path $ws 'figma.projects.config.json')
        Install-SectionTemplates $ws
        $snap = Join-Path $ws '.figma/cache/context-snapshot.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
        Set-Content -LiteralPath $snap -Value '{"fileId":"LinkFILE999","pages":[{"id":"0:1","name":"C","frames":[{"id":"1:1","name":"A"},{"id":"1:2","name":"B"},{"id":"1:3","name":"C"},{"id":"1:4","name":"D"}]}],"nodes":{"nodes":{"12:345":{"document":{"type":"FRAME"}}}}}'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', $Link) -Workspace $ws
        $r.Json.reason | Should -Be 'fresh'
        $r.Json.trigger | Should -Be 'link'
    }

    It 'reports auto-unavailable rather than crawling a project or team' {
        Copy-Item (Join-Path $Fixtures 'autointrospect-no-file.json') (Join-Path $ws 'figma.projects.config.json')
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'build the checkout panel') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'auto-unavailable'
        $r.Stderr | Should -Match 'figmaFileId'
    }
}
