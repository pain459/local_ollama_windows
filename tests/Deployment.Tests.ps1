$repoRoot = Split-Path -Parent $PSScriptRoot
$composePath = Join-Path $repoRoot 'compose.yaml'
$configPath = Join-Path $repoRoot 'config\litellm.yaml'

Describe 'Pinned LiteLLM deployment' {
    It 'defines only the pinned gateway and database images with one published port' {
        Test-Path $composePath | Should Be $true
        $compose = Get-Content $composePath -Raw
        $compose | Should Match 'ghcr\.io/berriai/litellm:1\.104\.0'
        $compose | Should Match 'postgres:17\.6-alpine'
        $compose | Should Match '4000:4000'
        $compose | Should Not Match '5432:5432'
        $compose | Should Match '(?m)^name: local-ollama-windows$'
    }

    It 'keeps PostgreSQL private healthy and persistent' {
        $compose = Get-Content $composePath -Raw
        $compose | Should Match 'pg_isready'
        $compose | Should Match 'condition: service_healthy'
        $compose | Should Match 'postgres-data:/var/lib/postgresql/data'
        $compose | Should Match '(?m)^\s+internal: true$'
    }

    It 'runs one gateway worker with a read-only config and host gateway route' {
        $compose = Get-Content $composePath -Raw
        $compose | Should Match '/app/config\.yaml:ro'
        $compose | Should Match '--num_workers'
        $compose | Should Match "(?m)^\s+- '1'$"
        $compose | Should Match 'host\.docker\.internal:host-gateway'
    }

    It 'exposes all three local models through ollama_chat with zero prices and tool metadata' {
        Test-Path $configPath | Should Be $true
        $config = Get-Content $configPath -Raw
        foreach ($alias in @('local-coder', 'local-qwen', 'local-devstral')) {
            $config | Should Match ("model_name: " + [regex]::Escape($alias))
        }
        ([regex]::Matches($config, 'model: ollama_chat/')).Count | Should Be 3
        ([regex]::Matches($config, 'api_base: http://host\.docker\.internal:11434')).Count | Should Be 3
        ([regex]::Matches($config, 'input_cost_per_token: 0')).Count | Should Be 3
        ([regex]::Matches($config, 'output_cost_per_token: 0')).Count | Should Be 3
        ([regex]::Matches($config, 'supports_function_calling: true')).Count | Should Be 3
    }

    It 'redacts messages while retaining usage metadata' {
        $config = Get-Content $configPath -Raw
        $config | Should Match 'turn_off_message_logging: true'
        $config | Should Match 'redact_messages_in_exceptions: true'
        $config | Should Not Match 'store_prompts_in_spend_logs:\s*true'
    }
}
