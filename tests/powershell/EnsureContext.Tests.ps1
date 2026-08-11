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

    It 'emits the documented status schema, including the dependency key' {
        # The bash twin always emits "dependency" (null unless jq is missing) and
        # both READMEs promise the same JSON output from either port; a missing key
        # makes the Windows status object diverge from the documented schema.
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        @($r.Json.PSObject.Properties.Name) | Should -Contain 'dependency'
        $r.Json.dependency | Should -Be $null
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
        # A Figma link is what makes a run a design run, so every test on the
        # applicable path carries one. It points at the fake snapshot's file/node.
        $script:link = 'https://www.figma.com/design/AbC123/X?node-id=1-2'
    }

    It 'reports fresh with mustInject and the three rendered sections' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', $link) -Workspace $ws
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
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--max-age-minutes', '60', '--dry-run', '--input', $link) -Workspace $ws
        $r.Json.reason | Should -Be 'dry-run'
    }

    It 'treats a snapshot older than the config as stale (dry-run)' {
        (Get-Item (Join-Path $ws 'figma.projects.config.json')).LastWriteTime = (Get-Date).AddMinutes(5)
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', $link) -Workspace $ws
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
        $script:link = 'https://www.figma.com/design/AbC123/X?node-id=1-2'
    }

    It 'reports introspect-failed with code NETWORK on a transport failure' {
        $env:FIGMA_API_BASE = 'http://127.0.0.1:9'   # closed port -> transport failure
        $env:FIGMA_PAT = 'fake-token'
        $env:FIGMA_API_MAX_ATTEMPTS = '1'
        $env:FIGMA_API_RETRY_DELAY = '1'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', $link) -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.ran | Should -BeFalse
        $r.Json.reason | Should -Be 'introspect-failed'
        $r.Json.code | Should -Be 'NETWORK'
        $r.Stderr | Should -Match 'not a credentials one'
    }

    It 'reports introspect-failed with code AUTH when no token is available' {
        $env:FIGMA_API_BASE = 'http://127.0.0.1:9'
        $env:FIGMA_API_MAX_ATTEMPTS = '1'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', $link) -Workspace $ws
        $r.Json.reason | Should -Be 'introspect-failed'
        $r.Json.code | Should -Be 'AUTH'
    }

    It 'does not clear a prior rendered section on a transient failure (fail-closed gate)' {
        Set-Content (Join-Path $ws '.figma/cache/section.plan.md') 'prior render'
        $env:FIGMA_API_BASE = 'http://127.0.0.1:9'
        $env:FIGMA_PAT = 'fake-token'
        $env:FIGMA_API_MAX_ATTEMPTS = '1'
        $env:FIGMA_API_RETRY_DELAY = '1'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', $link) -Workspace $ws
        $r.Json.reason | Should -Be 'introspect-failed'
        Test-Path (Join-Path $ws '.figma/cache/section.plan.md') | Should -BeTrue
    }
}

# A Figma link in the feature input is what makes a run a design run. Regression:
# with a valid config and an enabled target, the hook used to introspect and
# render the mandatory section for EVERY feature — including "add a Redis cache
# on the billing endpoint" — so spec.md got a Figma design section it had no
# business carrying.
Describe 'figma-ensure-context.ps1 (a Figma link is required)' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        Install-SectionTemplates $ws
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        Write-FakeSnapshot $ws | Out-Null
        (Get-Item (Join-Path $ws '.figma/cache/context-snapshot.json')).LastWriteTime = Get-Date
        $script:link = 'https://www.figma.com/design/AbC123/X?node-id=1-2'
    }

    It 'is a no-op when the input carries no link' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'Add a Redis cache on the billing endpoint.') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.ran | Should -BeFalse
        $r.Json.reason | Should -Be 'no-figma-link'
        $r.Json.mustInject | Should -BeFalse
        $r.Json.specSection | Should -Be $null
        Test-Path (Join-Path $ws '.figma/cache/section.spec.md') | Should -BeFalse
    }

    It 'is a no-op with no input at all, whatever the config maps' {
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' -Workspace $ws
        $r.Json.reason | Should -Be 'no-figma-link'
    }

    It 'names the remedy in the no-figma-link diagnostic' {
        # The document stays silent, so the console is the ONLY place a forgotten
        # link can still be caught — and only if the line says what to do about
        # it. A front-end feature whose author forgot to paste the link is
        # otherwise indistinguishable from a back-end one, through plan and tasks.
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'Build the new checkout screen.') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Stderr | Should -BeLike '*/speckit.specify*'
        $r.Stderr | Should -BeLike '*re-run*'
    }

    It 'clears a stale rendered section when no link applies' {
        Set-Content (Join-Path $ws '.figma/cache/section.spec.md') 'stale'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'Pure backend refactor.') -Workspace $ws
        $r.Json.reason | Should -Be 'no-figma-link'
        Test-Path (Join-Path $ws '.figma/cache/section.spec.md') | Should -BeFalse
    }

    It 'remembers the link so a later link-less phase still applies' {
        $env:SPECIFY_FEATURE = '001-checkout'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', $link) -Workspace $ws
        $r.Json.reason | Should -Be 'fresh'
        # /speckit.plan: same feature, no link in this phase's input.
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'Draft the implementation plan.') -Workspace $ws
        $r.Json.reason | Should -Be 'fresh'
        @($r.Json.links)[0].nodeId | Should -Be '1:2'
    }

    It 'scopes remembered links to their feature, never leaking to the next' {
        $env:SPECIFY_FEATURE = '001-checkout'
        Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', $link) -Workspace $ws | Out-Null
        $env:SPECIFY_FEATURE = '002-billing-cache'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'Add a Redis cache.') -Workspace $ws
        $r.Json.reason | Should -Be 'no-figma-link'
    }

    It 'degrades to no-figma-link when the remembered-links file is corrupt' {
        $env:SPECIFY_FEATURE = '001-checkout'
        $linksDir = Join-Path $ws '.figma/cache/links'
        New-Item -ItemType Directory -Force -Path $linksDir | Out-Null
        Set-Content (Join-Path $linksDir '001-checkout.json') '{"not":"an array"'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'No link in this phase.') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'no-figma-link'
    }

    It 'ignores a remembered-links file whose JSON root is not an array' {
        # Valid JSON, plausible content, wrong shape: a hand-edited file holding
        # a single object instead of a one-element array. ConvertFrom-Json
        # unrolls '[{...}]' into a bare object, so the deserialized shape cannot
        # tell the two apart — the JSON root has to be checked in the text, as
        # the bash port does with `jq 'select(type == "array")'`.
        $env:SPECIFY_FEATURE = '001-checkout'
        $linksDir = Join-Path $ws '.figma/cache/links'
        New-Item -ItemType Directory -Force -Path $linksDir | Out-Null
        Set-Content (Join-Path $linksDir '001-checkout.json') '{"fileId":"LinkFILE999","nodeId":"12:345"}'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'No link in this phase.') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'no-figma-link'
    }

    It 'never records the links a dry run detected' {
        $env:SPECIFY_FEATURE = '001-checkout'
        Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', $link) -Workspace $ws | Out-Null
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'No link in this phase.') -Workspace $ws
        $r.Json.reason | Should -Be 'no-figma-link'
    }
}

# .figma/cache/ is git-ignored, so the remembered links do NOT travel with the
# branch: a teammate who pulls it, a fresh clone or a CI job reaches
# /speckit.plan with the spec but no cache. Falling through to "no-figma-link"
# there tells the agent to say NOTHING about Figma, so plan.md silently loses the
# design section spec.md carries. spec.md itself is the fallback.
Describe 'figma-ensure-context.ps1 (spec.md is the durable record of the link)' {
    BeforeAll {
        # Write a spec.md carrying an integrated Figma section for the feature.
        function New-SpecWithSection {
            param([string]$Workspace, [string]$Feature, [string]$Url)
            $dir = Join-Path (Join-Path $Workspace 'specs') $Feature
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            @(
                '# Checkout'
                ''
                '<!-- speckit-figma:section phase=spec -->'
                '## Figma Design Context'
                ''
                '| URL | File | Node |'
                '|-----|------|------|'
                "| $Url | ``x`` | ``x`` |"
            ) | Set-Content -LiteralPath (Join-Path $dir 'spec.md') -Encoding utf8
        }
    }

    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        Install-SectionTemplates $ws
        Copy-Item (Join-Path $Fixtures 'singlerepo-valid.json') (Join-Path $ws 'figma.projects.config.json')
        $env:SPECIFY_FEATURE = '001-checkout'
    }

    It 'falls back to the link recorded in spec.md when the cache is gone' {
        New-SpecWithSection $ws '001-checkout' 'https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'Draft the implementation plan.') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'dry-run'
        ($r.Json.introspectArgs -join ' ') | Should -Be '--file LinkFILE999 --node 12:345'
    }

    It 'reads spec.md only when it carries the Figma section marker' {
        # A figma.com URL merely mentioned in prose is not evidence that a design
        # section was ever integrated; only the machine marker is.
        $dir = Join-Path (Join-Path $ws 'specs') '001-checkout'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content (Join-Path $dir 'spec.md') 'See https://www.figma.com/design/LinkFILE999/X?node-id=12-345 for background.'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'Draft the plan.') -Workspace $ws
        $r.Json.reason | Should -Be 'no-figma-link'
    }

    It 'never reads another feature''s spec.md as a link source' {
        # The document is only evidence for the feature it belongs to. Falling
        # back to "the single specs/*/spec.md" when nothing identifies the
        # current feature would hand a design-less feature the previous one's
        # creative — the very regression the link requirement exists to prevent.
        Remove-Item Env:SPECIFY_FEATURE -ErrorAction SilentlyContinue
        New-SpecWithSection $ws '001-checkout' 'https://www.figma.com/design/OtherFEATURE/Checkout?node-id=12-345'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'Add a Redis cache on the billing endpoint.') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Json.reason | Should -Be 'no-figma-link'
    }

    It 're-warms the per-feature cache with the link recovered from spec.md' {
        New-SpecWithSection $ws '001-checkout' 'https://www.figma.com/design/LinkFILE999/Checkout?node-id=12-345'
        Invoke-FigmaScript 'figma-ensure-context.ps1' @('--input', 'Draft the implementation plan.') -Workspace $ws | Out-Null
        $cached = Join-Path $ws '.figma/cache/links/001-checkout.json'
        Test-Path $cached | Should -BeTrue
        @(Get-Content $cached -Raw | ConvertFrom-Json)[0].fileId | Should -Be 'LinkFILE999'
    }

    It 'still lets this phase''s input win over the link in spec.md' {
        New-SpecWithSection $ws '001-checkout' 'https://www.figma.com/design/OldFILE111/Checkout?node-id=1-1'
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input', 'Redo it from https://www.figma.com/design/NewFILE222/Checkout?node-id=9-9') -Workspace $ws
        ($r.Json.introspectArgs -join ' ') | Should -Be '--file NewFILE222 --node 9:9'
    }

    It 'introspects both the viewed frame and the flow start of a prototype' {
        # A prototype is a parcours: the frame the designer was on (node-id) and
        # the entry point of the flow (starting-point-node-id) are both creatives
        # the spec needs, and both come from the same batched nodes request.
        $r = Invoke-FigmaScript 'figma-ensure-context.ps1' @('--dry-run', '--input',
            'Build https://www.figma.com/proto/ProtoFILE1/Demo?node-id=12-345&starting-point-node-id=1%3A2') -Workspace $ws
        $r.Json.reason | Should -Be 'dry-run'
        # Both ids ride the same batched request, so their order carries no meaning.
        $r.Json.introspectArgs | Should -Contain 'ProtoFILE1'
        $r.Json.introspectArgs | Should -Contain '12:345'
        $r.Json.introspectArgs | Should -Contain '1:2'
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
