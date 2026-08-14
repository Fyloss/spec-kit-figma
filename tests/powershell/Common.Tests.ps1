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

    It "surfaces the failing command's own error, not just 'not found'" {
        # A swallowed reason sends the user back to re-storing a PAT that is
        # already stored — the retrieval, not the token, is what broke.
        $env:FIGMA_PAT_COMMAND = 'figma-pat-tool-that-does-not-exist'
        $captured = New-Object System.IO.StringWriter
        $original = [Console]::Error
        [Console]::SetError($captured)
        try { { Get-FigmaToken '/nonexistent.json' } | Should -Throw }
        finally { [Console]::SetError($original) }
        $captured.ToString() | Should -Match 'figma-pat-tool-that-does-not-exist'
    }
}

Describe 'Get-FigmaSecretStoreHint' {
    # The Windows failure mode: a SecretStore vault left in its default password
    # mode needs an interactive unlock that an agent hook can never answer, so
    # every non-interactive Get-Secret lookup fails for a reason that has nothing
    # to do with the PAT.
    It 'names the no-password remedy for a SecretStore lookup' {
        $hint = Get-FigmaSecretStoreHint 'Get-Secret figma-pat -AsPlainText'
        $hint | Should -Match 'Set-SecretStoreConfiguration'
        $hint | Should -Match '-Authentication None'
        $hint | Should -Match '-Interaction None'
    }

    It 'reports the observed vault configuration when it could be read' {
        $hint = Get-FigmaSecretStoreHint 'Get-Secret figma-pat -AsPlainText' 'Password' 'Prompt'
        $hint | Should -Match 'Authentication=Password'
        $hint | Should -Match 'Interaction=Prompt'
    }

    It 'stays silent when the vault is already in no-password mode' {
        Get-FigmaSecretStoreHint 'Get-Secret figma-pat -AsPlainText' 'None' 'None' | Should -BeNullOrEmpty
    }

    It 'stays silent for a non-SecretStore command' {
        Get-FigmaSecretStoreHint 'security find-generic-password -s figma-pat -w' | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-FigmaCacheGc' {
    # The cache only ever grew: one links/<key>.json and one sections/<key>/ per
    # branch that ever ran a phase, one snapshots/<file>.json per Figma file ever
    # linked. Disk is not the point — a recycled branch name would hand a
    # brand-new feature the remembered links of the one that used the name before
    # it. 11520 minutes = 8 days, past the 7-day default retention window.
    BeforeEach {
        Reset-FigmaEnvironment
        $script:ws = New-TempWorkspace
        $env:SPECIFY_FEATURE = '003-redis-cache'
        Push-Location $script:ws
    }
    AfterEach { Pop-Location }

    It 'collects an orphaned feature key, and keeps one that owns a specs/ directory' {
        # specs/<key>/ is committed and outlives its branch: ownership decides
        # before age does.
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws 'specs/001-checkout')
        $live = Set-FakeLinksEntry -Workspace $ws -Key '001-checkout' -AgeMinutes 43200
        $orphan = Set-FakeLinksEntry -Workspace $ws -Key 'throwaway-spike' -AgeMinutes 11520
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $live | Should -BeTrue
        Test-Path -LiteralPath $orphan | Should -BeFalse
    }

    It 'never collects the feature of the run doing the sweep' {
        # /speckit.specify writes the links BEFORE the specs/ directory exists.
        $own = Set-FakeLinksEntry -Workspace $ws -Key '003-redis-cache' -AgeMinutes 43200
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $own | Should -BeTrue
    }

    It 'leaves a recent orphan alone until the window elapses' {
        $recent = Set-FakeLinksEntry -Workspace $ws -Key 'yesterdays-branch' -AgeMinutes 1440
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $recent | Should -BeTrue
    }

    It "drops an orphan's renders but never a live feature's" {
        # figma-verify-section reads "Figma applied to this run" from the EXISTENCE
        # of these files: collecting a live feature's turns a --strict gate
        # fail-open.
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ws 'specs/001-checkout')
        $live = Set-FakeSectionFor -Workspace $ws -Key '001-checkout' -AgeMinutes 43200
        $orphan = Set-FakeSectionFor -Workspace $ws -Key 'throwaway-spike' -AgeMinutes 11520
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $live | Should -BeTrue
        Test-Path -LiteralPath (Split-Path -Parent $orphan) | Should -BeFalse
    }

    It 'collects stored snapshots on age alone, sparing the current-run slot' {
        $old = Set-FakeStoredSnapshot -Workspace $ws -FileId 'OldFILE' -AgeMinutes 11520
        $fresh = Set-FakeStoredSnapshot -Workspace $ws -FileId 'FreshFILE' -AgeMinutes 10
        $slot = Join-Path $ws '.figma/cache/context-snapshot.json'
        Set-Content -LiteralPath $slot -Value '{"fileId":"F1"}'
        Set-FigmaFileAge -Path $slot -Minutes 43200
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $fresh | Should -BeTrue
        Test-Path -LiteralPath $slot | Should -BeTrue
    }

    It 'never collects a snapshot a longer freshness window still covers' {
        $env:FIGMA_SNAPSHOT_MAX_AGE_MINUTES = '43200'
        $stored = Set-FakeStoredSnapshot -Workspace $ws -FileId 'LongWindowFILE' -AgeMinutes 11520
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $stored | Should -BeTrue
    }

    It 'sweeps at most once a day, and =force overrides that' {
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath (Join-Path $ws '.figma/cache/.gc-stamp') | Should -BeTrue

        $orphan = Set-FakeLinksEntry -Workspace $ws -Key 'throwaway-spike' -AgeMinutes 11520
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $orphan | Should -BeTrue

        $env:FIGMA_CACHE_GC = 'force'
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $orphan | Should -BeFalse
    }

    It 'honours FIGMA_CACHE_GC=off and FIGMA_CACHE_RETENTION_DAYS' {
        $orphan = Set-FakeLinksEntry -Workspace $ws -Key 'throwaway-spike' -AgeMinutes 11520
        $env:FIGMA_CACHE_GC = 'off'
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $orphan | Should -BeTrue

        $env:FIGMA_CACHE_GC = 'force'
        $env:FIGMA_CACHE_RETENTION_DAYS = '30'
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $orphan | Should -BeTrue

        $env:FIGMA_CACHE_RETENTION_DAYS = '1'
        Invoke-FigmaCacheGc
        Test-Path -LiteralPath $orphan | Should -BeFalse
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
