# Pester tests for figma-introspect.ps1's cross-file source-component
# resolution — mirrors the two "resolves.../degrades..." tests in
# tests/figma-introspect.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
}

Describe 'figma-introspect.ps1 (cross-file source-component resolution)' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
    }

    AfterEach {
        if ($script:mock) { Stop-MockFigmaRouter $script:mock }
    }

    It 'resolves a source component published from another file (Design System or any library)' {
        # Main file: the instance's componentId ("9:9") is a published component
        # this file references, but does not itself define — the library case.
        $fileBody = @{
            name = 'f'; lastModified = '2026-01-01T00:00:00Z'; version = '1'
            document = @{ children = @() }
            components = @{ '9:9' = @{ key = 'PUBLISHEDKEY'; name = 'Button (library)' } }
            styles = @{}
        }
        # The linked node: a FRAME containing an INSTANCE of that library component.
        $nodeBody = @{
            nodes = @{ '1:1' = @{ document = @{ id = '1:1'; type = 'FRAME'
                children = @(@{ id = '1:2'; type = 'INSTANCE'; componentId = '9:9' }) } } }
        }
        # Same-file source lookup: "9:9" is not a real node in this file.
        $sourcesEmptyBody = @{ nodes = @{ '9:9' = $null } }
        # The Figma component registry: this published key is owned by another file.
        $componentMetaBody = @{ meta = @{ key = 'PUBLISHEDKEY'; file_key = 'DSFILEKEY'; node_id = '42:42' } }
        # That other file's own node fetch: the real component definition.
        $dsNodeBody = @{ nodes = @{ '42:42' = @{ document = @{ id = '42:42'; name = 'Button'; type = 'COMPONENT' } } } }

        $script:mock = Start-MockFigmaRouter -Routes @(
            @{ match = '/components/'; body = $componentMetaBody }
            @{ match = '/files/DSFILEKEY/'; body = $dsNodeBody }
            @{ match = 'ids=1:1'; body = $nodeBody }
            @{ match = 'ids=9:9'; body = $sourcesEmptyBody }
            @{ match = '/files/abc123?depth='; body = $fileBody }
        )

        $r = Invoke-FigmaScript 'figma-introspect.ps1' @('--file', 'abc123', '--node', '1:1') -Workspace $ws
        $r.ExitCode | Should -Be 0

        $snap = Get-Content (Join-Path $ws '.figma/cache/context-snapshot.json') -Raw | ConvertFrom-Json
        $snap.sources.nodes.'9:9'.document.name | Should -Be 'Button'
        $snap.sources.externalFiles.'9:9' | Should -Be 'DSFILEKEY'
    }

    It 'degrades gracefully when a cross-file component cannot be resolved' {
        $fileBody = @{
            name = 'f'; lastModified = '2026-01-01T00:00:00Z'; version = '1'
            document = @{ children = @() }
            components = @{ '9:9' = @{ key = 'PUBLISHEDKEY'; name = 'Button (library)' } }
            styles = @{}
        }
        $nodeBody = @{
            nodes = @{ '1:1' = @{ document = @{ id = '1:1'; type = 'FRAME'
                children = @(@{ id = '1:2'; type = 'INSTANCE'; componentId = '9:9' }) } } }
        }
        $sourcesEmptyBody = @{ nodes = @{ '9:9' = $null } }
        # The published key has no entry in the component registry (e.g. the PAT
        # cannot read it, or Figma reports 404-shaped empty metadata).
        $componentMetaBody = @{ meta = @{} }

        $script:mock = Start-MockFigmaRouter -Routes @(
            @{ match = '/components/'; body = $componentMetaBody }
            @{ match = 'ids=1:1'; body = $nodeBody }
            @{ match = 'ids=9:9'; body = $sourcesEmptyBody }
            @{ match = '/files/abc123?depth='; body = $fileBody }
        )

        $r = Invoke-FigmaScript 'figma-introspect.ps1' @('--file', 'abc123', '--node', '1:1') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Stderr | Should -Match 'has no resolvable owning file'

        $snap = Get-Content (Join-Path $ws '.figma/cache/context-snapshot.json') -Raw | ConvertFrom-Json
        $snap.sources.nodes.'9:9' | Should -BeNullOrEmpty
    }
}
