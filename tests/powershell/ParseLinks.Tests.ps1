# Pester tests for figma-parse-links.ps1 — mirrors tests/parse-links.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
}

Describe 'figma-parse-links.ps1' {
    It 'extracts a design link with a node id (dash form -> colon)' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('see https://www.figma.com/design/AbC123/Flow?node-id=12-345 please')
        $r.ExitCode | Should -Be 0
        $r.Json.fileId | Should -Be 'AbC123'
        $r.Json.nodeId | Should -Be '12:345'
        $r.Json.kind | Should -Be 'design'
    }

    It 'decodes a %3A-encoded node id' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('https://figma.com/file/Zz9/Old?node-id=1%3A2')
        $r.Json.fileId | Should -Be 'Zz9'
        $r.Json.nodeId | Should -Be '1:2'
        $r.Json.kind | Should -Be 'file'
    }

    It 'reports a null nodeId for a broad link' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('https://www.figma.com/proto/Kk77/Proto')
        $r.Json.nodeId | Should -Be $null
        $r.Json.kind | Should -Be 'proto'
    }

    It 'emits one JSON object per link' {
        $text = 'a https://www.figma.com/design/A1/X?node-id=1-2 b https://www.figma.com/file/B2/Y c'
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @($text)
        $objects = @($r.Stdout.Trim() -split "`n" | ForEach-Object { $_ | ConvertFrom-Json })
        $objects.Count | Should -Be 2
        $objects[0].fileId | Should -Be 'A1'
        $objects[1].fileId | Should -Be 'B2'
    }

    It 'reads from stdin when no argument is given' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' -StdinText 'x https://www.figma.com/design/StdIn1/F?node-id=3-4 y'
        $r.ExitCode | Should -Be 0
        $r.Json.fileId | Should -Be 'StdIn1'
        $r.Json.nodeId | Should -Be '3:4'
    }

    It 'prints nothing and exits 0 when no link is present' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('no figma link here')
        $r.ExitCode | Should -Be 0
        $r.Stdout.Trim() | Should -Be ''
    }

    It 'prints nothing and exits 0 on empty stdin' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' -StdinText ''
        $r.ExitCode | Should -Be 0
        $r.Stdout.Trim() | Should -Be ''
    }
}
