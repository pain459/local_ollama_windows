$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1') -Force

Describe 'LiteLLM gateway lifecycle' {
    InModuleScope OllamaStack {
        It 'scopes start and stop to the fixed project and private env file without deleting volumes' {
            Mock Invoke-Compose { [pscustomobject]@{ExitCode=0;Output='ok'} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model ministral
            $null = Start-GatewayStack -Config $config -SkipWait
            $null = Stop-GatewayStack -Config $config
            Assert-MockCalled Invoke-Compose 1 -ParameterFilter { ($Arguments -join ' ') -match '--project-name local-ollama-windows' -and ($Arguments -join ' ') -match '--env-file' -and ($Arguments -join ' ') -match 'up -d' }
            Assert-MockCalled Invoke-Compose 1 -ParameterFilter { ($Arguments -join ' ') -match 'stop' -and ($Arguments -join ' ') -notmatch 'down|-v' }
        }

        It 'reports the last readiness failure on timeout' {
            Mock Invoke-LiteLLMRequest { throw 'database unavailable' }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            $config.StartupTimeoutSeconds = 0
            { Wait-GatewayReady -Config $config } | Should Throw 'database unavailable'
        }

        It 'reuses an existing valid client key without generating another' {
            $config = Get-StackConfiguration -RootPath $TestDrive -Model ministral
            New-Item -ItemType Directory -Path $config.Paths.StateDirectory -Force | Out-Null
            Set-Content -LiteralPath $config.Paths.ClientKeyPath -Value 'sk-existing-valid-client-key'
            Mock Invoke-LiteLLMRequest { [pscustomobject]@{data=@(
                [pscustomobject]@{id='local-fast'}
            )} }
            (Ensure-LiteLLMClientKey -Config $config) | Should Be 'sk-existing-valid-client-key'
            Assert-MockCalled Invoke-LiteLLMRequest 0 -ParameterFilter { $Path -eq '/key/generate' }
        }

        It 'rejects a client key whose visible model allowlist is stale' {
            Mock Invoke-LiteLLMRequest { [pscustomobject]@{data=@(
                [pscustomobject]@{id='local-coder'},
                [pscustomobject]@{id='local-qwen'},
                [pscustomobject]@{id='local-fast'}
            )} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model ministral
            (Test-LiteLLMClientKey -Config $config -Key 'sk-old') | Should Be $false
        }

        It 'accepts a client key restricted to the selected validated alias' {
            Mock Invoke-LiteLLMRequest { [pscustomobject]@{data=@(
                [pscustomobject]@{id='local-coder'}
            )} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model qwen
            (Test-LiteLLMClientKey -Config $config -Key 'sk-current') | Should Be $true
        }

        It 'generates one key restricted to the selected validated alias and stores it' {
            $config = Get-StackConfiguration -RootPath (Join-Path $TestDrive 'new') -Model qwen
            Mock Invoke-LiteLLMRequest { [pscustomobject]@{key='sk-new-client-key'} }
            $key = Ensure-LiteLLMClientKey -Config $config
            $key | Should Be 'sk-new-client-key'
            (Get-Content $config.Paths.ClientKeyPath -Raw).Trim() | Should Be 'sk-new-client-key'
            Assert-MockCalled Invoke-LiteLLMRequest 1 -ParameterFilter { $Body -match 'local-coder' -and $Body -notmatch 'local-qwen|local-devstral|local-fast' -and $Body -match 'local-coding-client-[a-f0-9]{12}' }
        }

        It 'requires unauthenticated model access to be rejected before authenticated smoke traffic' {
            Mock Test-UnauthenticatedGatewayRejection { $true }
            Mock Invoke-LiteLLMRequest { [pscustomobject]@{choices=@();usage=[pscustomobject]@{prompt_tokens=1;completion_tokens=1;total_tokens=2}} }
            Mock Ensure-LiteLLMClientKey { 'sk-client' }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            (Invoke-GatewaySmokeTest -Config $config).Usage.total_tokens | Should Be 2
        }

        It 'extracts usage from a streaming SSE response under StrictMode' {
            Mock Test-UnauthenticatedGatewayRejection { $true }
            Mock Ensure-LiteLLMClientKey { 'sk-client' }
            Mock Invoke-LiteLLMRequest { "data: {`"choices`":[{`"delta`":{`"content`":`"OK`"}}]}`n`ndata: {`"choices`":[],`"usage`":{`"prompt_tokens`":3,`"completion_tokens`":2,`"total_tokens`":5}}`n`ndata: [DONE]" }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model ministral
            (Invoke-GatewaySmokeTest -Config $config).Usage.total_tokens | Should Be 5
        }

        It 'sends a thinking request through the gateway for the primary coding model' {
            Mock Test-UnauthenticatedGatewayRejection { $true }
            Mock Ensure-LiteLLMClientKey { 'sk-client' }
            Mock Invoke-LiteLLMRequest { [pscustomobject]@{content=@([pscustomobject]@{type='thinking';thinking='Reasoning'},[pscustomobject]@{type='text';text='OK'});usage=[pscustomobject]@{input_tokens=3;output_tokens=2}} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model qwen
            $result = Invoke-GatewaySmokeTest -Config $config
            $result.ThinkingRequested | Should Be $true
            $result.ThinkingVerified | Should Be $true
            $result.Usage.total_tokens | Should Be 5
            Assert-MockCalled Invoke-LiteLLMRequest 1 -ParameterFilter { $Path -eq '/v1/messages' -and $Body -match '"type":"enabled"' -and $Body -match '"budget_tokens":1024' }
        }

        It 'rejects a gateway response with no Anthropic thinking block' {
            Mock Test-UnauthenticatedGatewayRejection { $true }
            Mock Ensure-LiteLLMClientKey { 'sk-client' }
            Mock Invoke-LiteLLMRequest { [pscustomobject]@{content=@([pscustomobject]@{type='text';text='OK'});usage=[pscustomobject]@{input_tokens=3;output_tokens=2}} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model qwen
            { Invoke-GatewaySmokeTest -Config $config } | Should Throw 'no thinking block'
        }

        It 'rejects Anthropic reasoning with no final answer' {
            Mock Test-UnauthenticatedGatewayRejection { $true }
            Mock Ensure-LiteLLMClientKey { 'sk-client' }
            Mock Invoke-LiteLLMRequest { [pscustomobject]@{content=@([pscustomobject]@{type='thinking';thinking='Reasoning'});usage=[pscustomobject]@{input_tokens=3;output_tokens=2}} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model qwen
            { Invoke-GatewaySmokeTest -Config $config } | Should Throw 'no final text block'
        }
    }
}
