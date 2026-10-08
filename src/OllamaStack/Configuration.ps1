function Get-ModelConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Model
    )

    $models = @{
        devstral = [pscustomobject]@{
            Name = 'devstral'
            Alias = 'local-devstral'
            OllamaName = 'devstral-small-2:24b'
            LiteLLMName = 'ollama_chat/devstral-small-2:24b'
            ContextLength = 102400
            SupportsThinking = $false
        }
        qwen = [pscustomobject]@{
            Name = 'qwen'
            Alias = 'local-coder'
            OllamaName = 'qwen3.8:27b'
            LiteLLMName = 'ollama_chat/qwen3.8:27b'
            ContextLength = 92160
            SupportsThinking = $true
        }
        ministral = [pscustomobject]@{
            Name = 'ministral'
            Alias = 'local-fast'
            OllamaName = 'ministral-3:14b'
            LiteLLMName = 'ollama_chat/ministral-3:14b'
            ContextLength = 102400
            SupportsThinking = $false
        }
    }

    $key = $Model.ToLowerInvariant()
    if (-not $models.ContainsKey($key)) {
        throw "Unsupported model '$Model'. Choose devstral, qwen, or ministral."
    }
    return $models[$key]
}

function Get-StackPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath
    )

    $root = [IO.Path]::GetFullPath($RootPath).TrimEnd('\')
    $state = Join-Path $root '.state'
    [pscustomobject]@{
        Root = $root
        EnvFile = Join-Path $root '.env.local'
        StateDirectory = $state
        LogsDirectory = Join-Path $root 'logs'
        BenchmarkDirectory = Join-Path $state 'benchmarks'
        RuntimeStatePath = Join-Path $state 'runtime.json'
        FirewallBackupPath = Join-Path $state 'firewall-backup.json'
        ImageLockPath = Join-Path $state 'image-lock.json'
        ClientKeyPath = Join-Path $state 'client-key'
        ComposeFile = Join-Path $root 'compose.yaml'
        LiteLLMConfig = Join-Path $root 'config\litellm.yaml'
    }
}

function Get-StackConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [ValidateSet('devstral', 'qwen', 'ministral')]
        [string]$Model = 'qwen'
    )

    $modelConfig = Get-ModelConfiguration -Model $Model
    [pscustomobject]@{
        RootPath = [IO.Path]::GetFullPath($RootPath).TrimEnd('\')
        Model = $modelConfig
        Models = @(
            Get-ModelConfiguration -Model 'devstral'
            Get-ModelConfiguration -Model 'qwen'
            Get-ModelConfiguration -Model 'ministral'
        )
        Paths = Get-StackPaths -RootPath $RootPath
        GatewayPort = 4000
        OllamaPort = 11434
        ComposeProject = 'local-ollama-windows'
        OllamaBaseUri = 'http://127.0.0.1:11434'
        GatewayBaseUri = 'http://127.0.0.1:4000'
        StartupTimeoutSeconds = 120
        OllamaEnvironment = [ordered]@{
            OLLAMA_HOST = '0.0.0.0:11434'
            OLLAMA_CONTEXT_LENGTH = [string]$modelConfig.ContextLength
            OLLAMA_FLASH_ATTENTION = '1'
            OLLAMA_KV_CACHE_TYPE = 'q8_0'
            OLLAMA_MAX_LOADED_MODELS = '1'
            OLLAMA_NUM_PARALLEL = '1'
            OLLAMA_KEEP_ALIVE = '-1'
            OLLAMA_MAX_QUEUE = '4'
        }
    }
}
