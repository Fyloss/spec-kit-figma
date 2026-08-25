# Pester tests for figma-extract-values.ps1 — mirrors tests/figma-extract-values.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment

    # Declared here, not inside Describe: Pester 5 runs It blocks in a scope that
    # only sees functions defined by a file-level BeforeAll.
    function Write-ValueSnapshot {
        param([string]$Workspace)
        $snap = Join-Path $Workspace '.figma/cache/context-snapshot.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
        $json = @'
{"fileId":"AbC123","lastModified":"2026-08-14T09:12:33Z","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"SummaryCard","type":"FRAME",
 "layoutMode":"VERTICAL","paddingTop":24,"paddingRight":16,"paddingBottom":24,"paddingLeft":70,
 "itemSpacing":12,"primaryAxisAlignItems":"MIN","counterAxisAlignItems":"CENTER","cornerRadius":8,
 "absoluteBoundingBox":{"width":360,"height":240},"children":[
  {"id":"12:346","name":"Title","type":"TEXT","style":{"fontFamily":"Inter","fontWeight":600,
   "fontSize":18,"lineHeightPx":24,"letterSpacing":0,"textAlignHorizontal":"LEFT","textAlignVertical":"TOP"},
   "styles":{"text":"S:abc123"}},
  {"id":"12:347","name":"Spacer","type":"RECTANGLE","absoluteBoundingBox":{"width":328,"height":70}},
  {"id":"12:348","name":"Empty group","type":"GROUP"}]}}}}}
'@
        Set-Content -LiteralPath $snap -Value $json -Encoding utf8
        return $snap
    }
}

Describe 'figma-extract-values.ps1' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        $script:snap = Write-ValueSnapshot $ws
    }

    It 'emits every length WITH its unit, never as a bare number' {
        # A bare 70 is what lets a length be re-read as a scale index downstream.
        $r = Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws
        $r.ExitCode | Should -Be 0
        $d = $r.Stdout | ConvertFrom-Json
        $d.nodes[0].facts.paddingLeft | Should -Be '70px'
        $d.nodes[0].facts.itemSpacing | Should -Be '12px'
    }

    It 'extracts the layout facts verbatim' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $d.nodes[0].facts.layoutMode | Should -Be 'VERTICAL'
        $d.nodes[0].facts.counterAxisAlignItems | Should -Be 'CENTER'
        $d.nodes[0].facts.width | Should -Be '360px'
    }

    It 'extracts typography and the Design System style id' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $t = $d.nodes | Where-Object { $_.id -eq '12:346' }
        $t.facts.fontSize | Should -Be '18px'
        $t.facts.lineHeightPx | Should -Be '24px'
        $t.facts.fontWeight | Should -Be 600
        $t.facts.styles.text | Should -Be 'S:abc123'
    }

    It 'drops a node carrying no design value' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $d.totalNodes | Should -Be 4
        $d.rowCount | Should -Be 3
        @($d.nodes | Where-Object { $_.id -eq '12:348' }).Count | Should -Be 0
    }

    It 'never fabricates a 0px Figma did not send' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $spacer = $d.nodes | Where-Object { $_.id -eq '12:347' }
        $spacer.facts.PSObject.Properties.Name | Should -Not -Contain 'paddingTop'
    }

    It 'renders both markdown tables and the unit warning' {
        $r = Invoke-FigmaScript 'figma-extract-values.ps1' @('--format', 'markdown') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match 'Layout values'
        $r.Stdout | Should -Match 'Typography values'
        $r.Stdout | Should -Match '70px'
        $r.Stdout | Should -Match 'never pass a raw px number to a scale-indexed helper'
    }

    It 'restricts the digest with --node' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @('--node', '99:999') -Workspace $ws).Stdout | ConvertFrom-Json
        $d.rowCount | Should -Be 0
    }

    It 'truncates with --max-rows and says so' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @('--max-rows', '1') -Workspace $ws).Stdout | ConvertFrom-Json
        $d.truncated | Should -BeTrue
        @($d.nodes).Count | Should -Be 1
        $md = (Invoke-FigmaScript 'figma-extract-values.ps1' @('--max-rows', '1', '--format', 'markdown') -Workspace $ws).Stdout
        $md | Should -Match 'Truncated'
    }

    It 'yields an empty digest for a snapshot with no deep-fetched node' {
        Set-Content -LiteralPath $snap -Value '{"fileId":"AbC123","pages":[]}'
        $r = Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws
        $r.ExitCode | Should -Be 0
        ($r.Stdout | ConvertFrom-Json).rowCount | Should -Be 0
    }

    It 'treats a missing snapshot as a hard error' {
        Remove-Item -LiteralPath $snap -Force
        (Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws).ExitCode | Should -Be 1
    }

    It 'rejects an invalid --format and --max-rows' {
        (Invoke-FigmaScript 'figma-extract-values.ps1' @('--format', 'yaml') -Workspace $ws).ExitCode | Should -Be 1
        (Invoke-FigmaScript 'figma-extract-values.ps1' @('--max-rows', '0') -Workspace $ws).ExitCode | Should -Be 1
    }

    It 'puts the extracted values into the rendered spec section' {
        Install-SectionTemplates $ws
        $r = Invoke-FigmaScript 'figma-render-section.ps1' @('--phase', 'spec') -Workspace $ws
        $r.ExitCode | Should -Be 0
        $content = Get-Content $r.Stdout.Trim() -Raw
        $content | Should -Match 'Layout values'
        $content | Should -Match '70px'
    }
}

Describe 'figma-extract-values.ps1 (source components)' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        $script:snap = Join-Path $ws '.figma/cache/context-snapshot.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
        $json = @'
{"fileId":"AbC123","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Card instance","type":"INSTANCE",
  "componentId":"90:1","paddingLeft":70,"absoluteBoundingBox":{"width":360,"height":240}}}}},
 "sources":{"nodes":{"90:1":{"document":{"id":"90:1","name":"DsCard","type":"COMPONENT",
  "layoutMode":"VERTICAL","paddingTop":24,"paddingLeft":16,"itemSpacing":12,
  "absoluteBoundingBox":{"width":360,"height":240}}}}}}
'@
        Set-Content -LiteralPath $snap -Value $json -Encoding utf8
    }

    It 'extracts and tags the source component behind an instance' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $d.sourceComponents[0].name | Should -Be 'DsCard'
        ($d.nodes | Where-Object { $_.id -eq '12:345' }).origin | Should -Be 'instance'
        ($d.nodes | Where-Object { $_.id -eq '90:1' }).origin | Should -Be 'source'
        # Both survive, so an override stays visible rather than silently merged.
        ($d.nodes | Where-Object { $_.id -eq '90:1' }).facts.paddingLeft | Should -Be '16px'
        ($d.nodes | Where-Object { $_.id -eq '12:345' }).facts.paddingLeft | Should -Be '70px'
    }

    It 'names the source components in markdown and says which to implement' {
        $md = (Invoke-FigmaScript 'figma-extract-values.ps1' @('--format', 'markdown') -Workspace $ws).Stdout
        $md | Should -Match 'Source components behind the linked instances'
        $md | Should -Match 'DsCard'
        $md | Should -Match '\| Origin \|'
    }

    It 'flags a same-file source component as "same file", not external' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $d.sourceComponents[0].fileKey | Should -BeNullOrEmpty
        $md = (Invoke-FigmaScript 'figma-extract-values.ps1' @('--format', 'markdown') -Workspace $ws).Stdout
        $md | Should -Match '\| DsCard \| `90:1` \| same file \|'
    }
}

Describe 'figma-extract-values.ps1 (cross-file source components)' {
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        $script:snap = Join-Path $ws '.figma/cache/context-snapshot.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
        $json = @'
{"fileId":"AbC123","pages":[],
 "nodes":{"nodes":{"12:345":{"document":{"id":"12:345","name":"Card instance","type":"INSTANCE",
  "componentId":"90:1","paddingLeft":70}}}},
 "sources":{"nodes":{"90:1":{"document":{"id":"90:1","name":"DsCard","type":"COMPONENT","paddingLeft":16}}},
  "externalFiles":{"90:1":"DSFILEKEY"}}}
'@
        Set-Content -LiteralPath $snap -Value $json -Encoding utf8
    }

    It 'flags a cross-file source component as external, with its owning file key' {
        $d = (Invoke-FigmaScript 'figma-extract-values.ps1' @() -Workspace $ws).Stdout | ConvertFrom-Json
        $d.sourceComponents[0].fileKey | Should -Be 'DSFILEKEY'
        $md = (Invoke-FigmaScript 'figma-extract-values.ps1' @('--format', 'markdown') -Workspace $ws).Stdout
        $md | Should -Match '\| DsCard \| `90:1` \| `DSFILEKEY` \(external\) \|'
        $md | Should -Match 'resolved from another Figma file'
    }
}
