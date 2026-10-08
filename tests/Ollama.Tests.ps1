$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1') -Force

Describe 'Managed Ollama lifecycle' {
    InModuleScope OllamaStack {
        It 'builds all eight tuning variables into the child without mutating the parent' {
            $before = $env:OLLAMA_CONTEXT_LENGTH
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            $info = New-OllamaProcessStartInfo -ExecutablePath 'C:\Ollama\ollama.exe' -Config $config
            $info.EnvironmentVariables['OLLAMA_HOST'] | Should Be '0.0.0.0:11434'
            $info.EnvironmentVariables['OLLAMA_CONTEXT_LENGTH'] | Should Be '102400'
            $info.EnvironmentVariables['OLLAMA_FLASH_ATTENTION'] | Should Be '1'
            $info.EnvironmentVariables['OLLAMA_KV_CACHE_TYPE'] | Should Be 'q8_0'
            $info.EnvironmentVariables['OLLAMA_MAX_LOADED_MODELS'] | Should Be '1'
            $info.EnvironmentVariables['OLLAMA_NUM_PARALLEL'] | Should Be '1'
            $info.EnvironmentVariables['OLLAMA_KEEP_ALIVE'] | Should Be '-1'
            $info.EnvironmentVariables['OLLAMA_MAX_QUEUE'] | Should Be '4'
            $env:OLLAMA_CONTEXT_LENGTH | Should Be $before
        }

        It 'rejects an unknown process already listening on the Ollama port' {
            Mock Get-PortOwner { [pscustomobject]@{Pid=44;ExecutablePath='C:\Other\server.exe';StartedAtUtc='2026-01-01T00:00:00Z'} }
            Mock Get-Command { [pscustomobject]@{Source='C:\Ollama\ollama.exe'} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            { Start-ManagedOllama -Config $config } | Should Throw
        }

        It 'preloads the exact context indefinitely' {
            Mock Invoke-RestMethod { [pscustomobject]@{done=$true} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            $null = Initialize-OllamaModel -Config $config
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter { $Body -match '"num_ctx":102400' -and $Body -match '"keep_alive":-1' }
        }

        It 'accepts only exact 100 percent GPU residency and context 102400' {
            Mock Invoke-NativeCapture { [pscustomobject]@{ExitCode=0;Output="NAME ID SIZE PROCESSOR CONTEXT UNTIL`ndevstral-small-2:24b abc 22 GB 100% GPU 102400 Forever"} }
            $ok = Get-OllamaResidency -ModelName 'devstral-small-2:24b'
            $ok.FullyGpuResident | Should Be $true
            $ok.ContextLength | Should Be 102400
        }

        It 'rejects CPU split or a smaller context' {
            Mock Invoke-NativeCapture { [pscustomobject]@{ExitCode=0;Output="NAME ID SIZE PROCESSOR CONTEXT UNTIL`ndevstral-small-2:24b abc 22 GB 80%/20% CPU/GPU 65536 Forever"} }
            { Get-OllamaResidency -ModelName 'devstral-small-2:24b' } | Should Throw
        }

        It 'does not terminate a reused PID whose creation time or path differs' {
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            New-Item -ItemType Directory -Path $config.Paths.StateDirectory -Force | Out-Null
            @{Pid=99;StartedAtUtc='2020-01-01T00:00:00.0000000Z';ExecutablePath='C:\Ollama\ollama.exe';Model='devstral-small-2:24b'} | ConvertTo-Json | Set-Content $config.Paths.RuntimeStatePath
            Mock Get-Process { [pscustomobject]@{Id=99;Path='C:\Other\ollama.exe';StartTime=[datetime]'2026-01-01'} }
            Mock Stop-Process {}
            (Stop-ManagedOllama -Config $config).Stopped | Should Be $false
            Assert-MockCalled Stop-Process 0
        }

        It 'is idempotent when no managed state exists' {
            $config = Get-StackConfiguration -RootPath (Join-Path $TestDrive 'absent') -Model devstral
            (Stop-ManagedOllama -Config $config).Stopped | Should Be $false
        }
    }
}
