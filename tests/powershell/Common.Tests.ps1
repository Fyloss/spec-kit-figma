# Pester tests for the figma-common.ps1 helpers — mirrors tests/common.bats
# (API-base hardening, status classification, credential resolution).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
    Reset-FigmaEnvironment
    . (Join-Path (Get-ScriptsDir) 'figma-common.ps1')
    $script:Fixtures = Get-FixturesDir
}

Describe 'Get-FigmaApiBase' {
    BeforeEach { Reset-FigmaEnvironment }

    It 'defaults to the public Figma API' {
        Get-FigmaApiBase '/nonexistent.json' | Should -Be 'https://api.figma.com/v1'
    }

    It 'prefers the FIGMA_API_BASE env override without validation' {
        $env:FIGMA_API_BASE = 'http://127.0.0.1:4567'
        Get-FigmaApiBase '/nonexistent.json' | Should -Be 'http://127.0.0.1:4567'
    }

    It 'rejects a config apiBaseUrl outside *.figma.com (PAT exfiltration guard)' {
        $ws = New-TempWorkspace
        $cfg = Join-Path $ws 'config.json'
        Set-Content $cfg '{"figma":{"apiBaseUrl":"https://evil.example.com/v1"}}'
        { Get-FigmaApiBase $cfg } | Should -Throw
    }

    It 'rejects an http:// (non-TLS) config apiBaseUrl' {
        $ws = New-TempWorkspace
        $cfg = Join-Path $ws 'config.json'
        Set-Content $cfg '{"figma":{"apiBaseUrl":"http://api.figma.com/v1"}}'
        { Get-FigmaApiBase $cfg } | Should -Throw
    }

    It 'rejects a userinfo@ trick in the host' {
        $ws = New-TempWorkspace
        $cfg = Join-Path $ws 'config.json'
        Set-Content $cfg '{"figma":{"apiBaseUrl":"https://api.figma.com@evil.example.com/v1"}}'
        { Get-FigmaApiBase $cfg } | Should -Throw
    }

    It 'accepts a *.figma.com subdomain from the config' {
        $ws = New-TempWorkspace
        $cfg = Join-Path $ws 'config.json'
        Set-Content $cfg '{"figma":{"apiBaseUrl":"https://api.figma.com/v2"}}'
        Get-FigmaApiBase $cfg | Should -Be 'https://api.figma.com/v2'
    }
}

Describe 'Get-FigmaStatusClass' {
    It 'classifies <code> as <class>' -ForEach @(
        @{ code = '200'; class = 'OK' }
        @{ code = '204'; class = 'OK' }
        @{ code = '000'; class = 'NETWORK' }
        @{ code = '401'; class = 'AUTH' }
        @{ code = '403'; class = 'AUTH' }
        @{ code = '404'; class = 'NOT_FOUND' }
        @{ code = '429'; class = 'RATE_LIMIT' }
        @{ code = '503'; class = 'SERVER' }
        @{ code = '418'; class = 'UNKNOWN' }
    ) {
        Get-FigmaStatusClass $code | Should -Be $class
    }
}

Describe 'Get-FigmaErrorMessage' {
    It 'forbids the auth misdiagnosis on NETWORK failures' {
        $msg = Get-FigmaErrorMessage 'NETWORK' '/files/X' '000'
        $msg | Should -Match 'NOT a credentials problem'
    }

    It 'carries the projects:read scope hint for team paths' {
        $msg = Get-FigmaErrorMessage 'AUTH' '/teams/T1/projects' '403'
        $msg | Should -Match 'projects:read'
    }
}

Describe 'Get-FigmaEnvVarName / Get-FigmaToken' {
    BeforeEach { Reset-FigmaEnvironment }

    It 'defaults to FIGMA_PAT' {
        Get-FigmaEnvVarName '/nonexistent.json' | Should -Be 'FIGMA_PAT'
    }

    It 'uses secretName as the variable fallback in ci-secret mode' {
        $ws = New-TempWorkspace
        $cfg = Join-Path $ws 'config.json'
        Set-Content $cfg '{"figma":{"credentials":{"source":"ci-secret","secretName":"ORG_FIGMA_TOKEN"}}}'
        Get-FigmaEnvVarName $cfg | Should -Be 'ORG_FIGMA_TOKEN'
    }

    It 'prefers envVar over secretName in ci-secret mode' {
        $ws = New-TempWorkspace
        $cfg = Join-Path $ws 'config.json'
        Set-Content $cfg '{"figma":{"credentials":{"source":"ci-secret","secretName":"ORG_FIGMA_TOKEN","envVar":"FIGMA_PAT"}}}'
        Get-FigmaEnvVarName $cfg | Should -Be 'FIGMA_PAT'
    }

    It 'loads the token from the configured environment variable' {
        $env:FIGMA_PAT = 'figd_test_token'
        Get-FigmaToken '/nonexistent.json' | Should -Be 'figd_test_token'
    }

    It 'throws with the credential-store hint when no token source exists' {
        { Get-FigmaToken '/nonexistent.json' } | Should -Throw
    }

    It 'never falls back to a .env file' {
        $ws = New-TempWorkspace
        Set-Content (Join-Path $ws '.env') 'FIGMA_PAT=leaked'
        Push-Location $ws
        try { { Get-FigmaToken '/nonexistent.json' } | Should -Throw } finally { Pop-Location }
    }
}

Describe 'Resolve-FigmaContextSourceDecision' {
    It 'rest stays rest' {
        Resolve-FigmaContextSourceDecision 'rest' $false $true '' | Should -Be 'rest'
    }
    It 'mcp reachable stays mcp' {
        Resolve-FigmaContextSourceDecision 'mcp' $true $false '' | Should -Be 'mcp'
    }
    It 'mcp unreachable with fallback degrades to rest' {
        Resolve-FigmaContextSourceDecision 'mcp' $false $true 'http://x' | Should -Be 'rest'
    }
    It 'mcp unreachable without fallback throws' {
        { Resolve-FigmaContextSourceDecision 'mcp' $false $false 'http://x' } | Should -Throw
    }
    It 'an unknown engine defaults to rest' {
        Resolve-FigmaContextSourceDecision 'bogus' $false $true '' | Should -Be 'rest'
    }
}
