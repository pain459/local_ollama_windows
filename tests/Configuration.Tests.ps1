$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1'
Import-Module $manifest -Force

Describe 'Ollama stack configuration contract' {
    It 'maps devstral to its explicit quality alias at 102400 context' {
        $model = Get-ModelConfiguration -Model 'devstral'
        $model.Name | Should Be 'devstral'
        $model.Alias | Should Be 'local-devstral'
        $model.OllamaName | Should Be 'devstral-small-2:24b'
        $model.LiteLLMName | Should Be 'ollama_chat/devstral-small-2:24b'
        $model.ContextLength | Should Be 102400
        $model.SupportsThinking | Should Be $false
    }

    It 'maps Qwen to the primary thinking alias at its measured GPU-resident context' {
        $qwen = Get-ModelConfiguration -Model 'qwen'
        $qwen.Alias | Should Be 'local-coder'
        $qwen.OllamaName | Should Be 'qwen3.8:27b'
        $qwen.ContextLength | Should Be 92160
        $qwen.SupportsThinking | Should Be $true
    }

    It 'keeps Ministral as an explicitly non-thinking fast alias' {
        $fast = Get-ModelConfiguration -Model 'ministral'
        $fast.Alias | Should Be 'local-fast'
        $fast.OllamaName | Should Be 'ministral-3:14b'
        $fast.ContextLength | Should Be 102400
        $fast.SupportsThinking | Should Be $false
    }

    It 'defaults the stack to the fully GPU-resident thinking model' {
        $config = Get-StackConfiguration -RootPath $repoRoot
        $config.Model.Name | Should Be 'qwen'
        $config.Model.Alias | Should Be 'local-coder'
        $config.OllamaEnvironment.OLLAMA_CONTEXT_LENGTH | Should Be '92160'
    }

    It 'rejects an unknown model instead of silently changing it' {
        { Get-ModelConfiguration -Model 'unknown' } | Should Throw
    }

    It 'keeps every generated path below the supplied root' {
        $root = Join-Path $TestDrive 'repo'
        $rootBase = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $rootFull = $rootBase + '\'
        $paths = Get-StackPaths -RootPath $root
        foreach ($property in $paths.PSObject.Properties) {
            $resolved = [IO.Path]::GetFullPath([string]$property.Value)
            (($resolved -eq $rootBase) -or $resolved.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) | Should Be $true
        }
    }

    It 'returns fixed single-user performance and network settings' {
        $config = Get-StackConfiguration -RootPath $repoRoot -Model 'devstral'
        $config.GatewayPort | Should Be 4000
        $config.OllamaPort | Should Be 11434
        $config.ComposeProject | Should Be 'local-ollama-windows'
        $config.OllamaEnvironment.OLLAMA_CONTEXT_LENGTH | Should Be '102400'
        $config.OllamaEnvironment.OLLAMA_KV_CACHE_TYPE | Should Be 'q8_0'
        $config.OllamaEnvironment.OLLAMA_NUM_PARALLEL | Should Be '1'
    }

    It 'ignores generated secrets state logs and benchmark output' {
        $ignore = Get-Content (Join-Path $repoRoot '.gitignore') -Raw
        $ignore | Should Match '(?m)^\.env\.local$'
        $ignore | Should Match '(?m)^\.state/$'
        $ignore | Should Match '(?m)^logs/$'
        $ignore | Should Match '(?m)^benchmarks/$'
    }
}
