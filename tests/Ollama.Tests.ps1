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

        It 'does not redirect server streams unless a consumer drains them' {
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            $info = New-OllamaProcessStartInfo -ExecutablePath 'C:\Ollama\ollama.exe' -Config $config
            $info.RedirectStandardOutput | Should Be $false
            $info.RedirectStandardError | Should Be $false
        }

        It 'rejects an unknown process already listening on the Ollama port' {
            Mock Get-PortOwner { [pscustomobject]@{Pid=44;ExecutablePath='C:\Other\server.exe';StartedAtUtc='2026-01-01T00:00:00Z'} }
            Mock Get-Command { [pscustomobject]@{Source='C:\Ollama\ollama.exe'} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            { Start-ManagedOllama -Config $config } | Should Throw
        }

        It 'recognizes a saved Ollama process when Windows hides its executable path' {
            $started = [datetime]'2026-10-08T15:55:01.9742106Z'
            $process = [pscustomobject]@{Id=26756;ProcessName='ollama';Path=$null;StartTime=$started.ToLocalTime()}
            $state = [pscustomobject]@{Pid=26756;ExecutablePath='C:\Users\Test\AppData\Local\Programs\Ollama\ollama.exe';StartedAtUtc=$started.ToString('o')}
            (Test-ManagedProcessIdentity -Process $process -State $state) | Should Be $true
        }

        It 'reuses an exact controller-owned Ollama process instead of requiring termination' {
            $config = Get-StackConfiguration -RootPath $TestDrive -Model qwen
            New-Item -ItemType Directory -Path $config.Paths.StateDirectory -Force | Out-Null
            $started = [datetime]'2026-10-08T15:55:01.9742106Z'
            @{Pid=26756;ExecutablePath='C:\Ollama\ollama.exe';StartedAtUtc=$started.ToString('o');Model='ministral-3:14b'} | ConvertTo-Json | Set-Content $config.Paths.RuntimeStatePath
            Mock Get-Command { [pscustomobject]@{Source='C:\Ollama\ollama.exe'} }
            Mock Get-PortOwner { [pscustomobject]@{Pid=26756;ExecutablePath=$null;StartedAtUtc=$null} }
            Mock Get-Process { [pscustomobject]@{Id=26756;ProcessName='ollama';Path=$null;StartTime=$started.ToLocalTime()} }
            Mock Stop-Process {}
            $result = Start-ManagedOllama -Config $config
            $result.Started | Should Be $false
            $result.Reused | Should Be $true
            $result.PreviousModel | Should Be 'ministral-3:14b'
            ((Get-Content $config.Paths.RuntimeStatePath -Raw | ConvertFrom-Json).Model) | Should Be 'ministral-3:14b'
            Assert-MockCalled Stop-Process 0
        }

        It 'preloads the exact context indefinitely' {
            Mock Invoke-RestMethod { [pscustomobject]@{done=$true} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model devstral
            $null = Initialize-OllamaModel -Config $config
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter { $Body -match '"num_ctx":102400' -and $Body -match '"keep_alive":-1' }
        }

        It 'requires observable thinking while preloading the primary coding model' {
            Mock Invoke-RestMethod { [pscustomobject]@{done=$true;message=[pscustomobject]@{thinking='I should reply briefly.';content='OK'}} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model qwen
            $result = Initialize-OllamaModel -Config $config
            $result.ThinkingVerified | Should Be $true
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter { $Body -match '"num_ctx":92160' -and $Body -match '"think":true' }
        }

        It 'rejects a claimed thinking model that returns no reasoning' {
            Mock Invoke-RestMethod { [pscustomobject]@{done=$true;message=[pscustomobject]@{content='OK'}} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model qwen
            { Initialize-OllamaModel -Config $config } | Should Throw 'did not return thinking output'
        }

        It 'rejects a thinking preload that returns reasoning without a final answer' {
            Mock Invoke-RestMethod { [pscustomobject]@{done=$true;message=[pscustomobject]@{thinking='Reasoning';content=''}} }
            $config = Get-StackConfiguration -RootPath $TestDrive -Model qwen
            { Initialize-OllamaModel -Config $config } | Should Throw 'did not return a final answer'
        }

        It 'accepts only exact 100 percent GPU residency and context 102400' {
            Mock Invoke-NativeCapture { [pscustomobject]@{ExitCode=0;Output="NAME ID SIZE PROCESSOR CONTEXT UNTIL`ndevstral-small-2:24b abc 22 GB 100% GPU 102400 Forever"} }
            $ok = Get-OllamaResidency -ModelName 'devstral-small-2:24b'
            $ok.FullyGpuResident | Should Be $true
            $ok.ContextLength | Should Be 102400
        }

        It 'normalizes variable spacing in the Ollama processor column' {
            Mock Invoke-NativeCapture { [pscustomobject]@{ExitCode=0;Output="NAME ID SIZE PROCESSOR CONTEXT UNTIL`nministral-3:14b abc 17 GB 100%    GPU 102400 Forever"} }
            $result = Get-OllamaResidency -ModelName 'ministral-3:14b'
            $result.Processor | Should Be '100% GPU'
            $result.FullyGpuResident | Should Be $true
        }

        It 'accepts the per-model measured Qwen context only when fully GPU resident' {
            Mock Invoke-NativeCapture { [pscustomobject]@{ExitCode=0;Output="NAME ID SIZE PROCESSOR CONTEXT UNTIL`nqwen3.8:27b abc 21 GB 100% GPU 92160 Forever"} }
            $result = Get-OllamaResidency -ModelName 'qwen3.8:27b' -ExpectedContextLength 92160
            $result.ContextLength | Should Be 92160
            $result.FullyGpuResident | Should Be $true
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
