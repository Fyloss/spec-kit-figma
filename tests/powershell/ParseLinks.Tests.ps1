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

    It 'decodes a lower-case %3a-encoded node id' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('https://www.figma.com/design/AbC123/Flow?node-id=12%3a345')
        $r.Json.nodeId | Should -Be '12:345'
    }

    It 'ignores the tracking suffix appended after the node id' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('https://www.figma.com/design/AbC123/Flow?node-id=12-345&t=Xy9Z-4')
        $r.Json.nodeId | Should -Be '12:345'
    }

    It 'normalizes an instance node id (I-prefixed, ";"-chained)' {
        # "Copy link to selection" on a nested instance yields I<a>-<b>%3B<c>-<d>.
        # MCP servers and the REST API expect I<a>:<b>;<c>:<d> — a partially
        # normalized id is reported as "node not found in the file".
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('https://www.figma.com/design/AbC123/Flow?node-id=I123-456%3B789-012')
        $r.Json.nodeId | Should -Be 'I123:456;789:012'
    }

    It 'normalizes every separator of a chained node id, not just the first' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('https://www.figma.com/design/AbC123/Flow?node-id=1-2%3B3-4')
        $r.Json.nodeId | Should -Be '1:2;3:4'
    }

    It 'extracts a node id behind an HTML-escaped ampersand (&amp;)' {
        # Feature input pasted from a rich-text source (Jira, Confluence, an HTML
        # email) carries the separators escaped, so the character before 'node-id'
        # is ';' rather than '&'. Anchoring on '&' alone silently drops the id and
        # the pinned frame degrades to a broad link.
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('https://www.figma.com/design/AbC123/Flow?type=design&amp;node-id=12-345&amp;m=dev')
        $r.Json.nodeId | Should -Be '12:345'
    }

    It 'reports a malformed node id as null instead of forwarding it' {
        $r = Invoke-FigmaScript 'figma-parse-links.ps1' @('https://www.figma.com/design/AbC123/Flow?node-id=not-a-node')
        $r.Json.nodeId | Should -Be $null
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
