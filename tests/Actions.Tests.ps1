$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1') -Force

Describe 'Stack action orchestration' {
    InModuleScope OllamaStack {
        It 'refuses startup on a Public network before mutation' {
            Mock Get-HostPreflight { [pscustomobject]@{CanStart=$false;CanExposeLan=$false;Errors=@('Public profile');Adapter=[pscustomobject]@{NetworkCategory='Public'}} }
            Mock Start-ManagedOllama {}
            $config=Get-StackConfiguration -RootPath $TestDrive -Model devstral
            { Invoke-StackStart -Config $config } | Should Throw
            Assert-MockCalled Start-ManagedOllama 0
        }
        It 'rolls back owned Ollama and restores power when gateway startup fails' {
            Mock Get-HostPreflight { [pscustomobject]@{CanStart=$true;CanExposeLan=$true;Errors=@();Adapter=[pscustomobject]@{IPv4Address='192.168.1.8';NetworkCategory='Private'}} }
            Mock Set-StackHighPerformance { [pscustomobject]@{Previous='old';Changed=$true} }
            Mock Start-ManagedOllama { [pscustomobject]@{Started=$true;Pid=7} }
            Mock Initialize-OllamaModel {}
            Mock Get-OllamaResidency { [pscustomobject]@{ContextLength=102400;Processor='100% GPU';FullyGpuResident=$true} }
            Mock Start-GatewayStack { throw 'gateway failed' }
            Mock Stop-ManagedOllama { [pscustomobject]@{Stopped=$true} }
            Mock Restore-StackPowerScheme {}
            $config=Get-StackConfiguration -RootPath $TestDrive -Model devstral
            { Invoke-StackStart -Config $config } | Should Throw
            Assert-MockCalled Stop-ManagedOllama 1
            Assert-MockCalled Restore-StackPowerScheme 1 -ParameterFilter {$Scheme -eq 'old'}
        }
        It 'reports an address change without exposing dotenv values' {
            $config=Get-StackConfiguration -RootPath $TestDrive -Model devstral
            New-Item -ItemType Directory $config.Paths.StateDirectory -Force | Out-Null
            @{LanIPv4='192.168.1.7';Pid=7;Model=$config.Model.OllamaName} | ConvertTo-Json | Set-Content $config.Paths.RuntimeStatePath
            Set-Content $config.Paths.EnvFile 'LITELLM_MASTER_KEY=sk-super-secret'
            Mock Get-ActiveLanAdapter { [pscustomobject]@{Name='Ethernet';IPv4Address='192.168.1.8';NetworkCategory='Private';MacAddress='aa'} }
            Mock Get-GatewayStatus { [pscustomobject]@{Healthy=$true} }
            Mock Get-OllamaResidency { [pscustomobject]@{ContextLength=102400;Processor='100% GPU';FullyGpuResident=$true} }
            Mock Get-NetFirewallRule { [pscustomobject]@{Enabled='True';Profile='Private'} }
            $status=Get-StackStatus -Config $config
            $status.AddressChanged | Should Be $true
            ($status | ConvertTo-Json -Depth 8) | Should Not Match 'sk-super-secret'
            $status.ApiUrl | Should Be 'http://192.168.1.8:4000/v1'
        }
        It 'revalidates GPU residency after the gateway thinking smoke request' {
            $script:order=@()
            $config=Get-StackConfiguration -RootPath $TestDrive -Model qwen
            New-Item -ItemType Directory $config.Paths.StateDirectory -Force | Out-Null
            @{Pid=7;StartedAtUtc='2026-10-08T00:00:00Z';ExecutablePath='C:\Ollama\ollama.exe';Model='qwen3.8:27b'} | ConvertTo-Json | Set-Content $config.Paths.RuntimeStatePath
            Mock Get-HostPreflight { [pscustomobject]@{CanStart=$true;Errors=@();Adapter=[pscustomobject]@{IPv4Address='192.168.1.8'}} }
            Mock Set-StackHighPerformance { [pscustomobject]@{Previous='old';Changed=$false} }
            Mock Start-ManagedOllama { [pscustomobject]@{Started=$false;Reused=$true;PreviousModel='qwen3.8:27b'} }
            Mock Initialize-OllamaModel { $script:order+='initialize' }
            Mock Get-OllamaResidency { $script:order+='residency';[pscustomobject]@{ContextLength=92160;Processor='100% GPU';FullyGpuResident=$true} }
            Mock Start-GatewayStack { [pscustomobject]@{Started=$true} }
            Mock Invoke-GatewaySmokeTest { $script:order+='smoke';[pscustomobject]@{Succeeded=$true} }
            $result=Invoke-StackStart -Config $config
            $result.Succeeded | Should Be $true
            ($script:order -join ',') | Should Be 'initialize,residency,smoke,residency'
            ((Get-Content $config.Paths.RuntimeStatePath -Raw | ConvertFrom-Json).Model) | Should Be 'qwen3.8:27b'
        }
        It 'preserves prior state and unloads the attempted model after any reused-start failure' -TestCases @(
            @{FailurePoint='initialize'}
            @{FailurePoint='first-residency'}
            @{FailurePoint='smoke'}
            @{FailurePoint='final-residency'}
        ) {
            param($FailurePoint)
            $script:residencyCalls=0
            $config=Get-StackConfiguration -RootPath $TestDrive -Model qwen
            New-Item -ItemType Directory $config.Paths.StateDirectory -Force | Out-Null
            @{Pid=7;StartedAtUtc='2026-10-08T00:00:00Z';ExecutablePath='C:\Ollama\ollama.exe';Model='ministral-3:14b'} | ConvertTo-Json | Set-Content $config.Paths.RuntimeStatePath
            Mock Get-HostPreflight { [pscustomobject]@{CanStart=$true;Errors=@();Adapter=[pscustomobject]@{IPv4Address='192.168.1.8'}} }
            Mock Set-StackHighPerformance { [pscustomobject]@{Previous='old';Changed=$false} }
            Mock Start-ManagedOllama { [pscustomobject]@{Started=$false;Reused=$true;PreviousModel='ministral-3:14b'} }
            Mock Initialize-OllamaModel { if($FailurePoint -eq 'initialize'){throw 'initialize failed'} }
            Mock Get-OllamaResidency {
                $script:residencyCalls++
                if(($FailurePoint -eq 'first-residency' -and $script:residencyCalls -eq 1) -or ($FailurePoint -eq 'final-residency' -and $script:residencyCalls -eq 2)){throw 'residency failed'}
                [pscustomobject]@{ContextLength=92160;Processor='100% GPU';FullyGpuResident=$true}
            }
            Mock Start-GatewayStack { [pscustomobject]@{Started=$true} }
            Mock Invoke-GatewaySmokeTest { if($FailurePoint -eq 'smoke'){throw 'smoke failed'};[pscustomobject]@{Succeeded=$true} }
            Mock Stop-GatewayStack { [pscustomobject]@{Stopped=$true} }
            Mock Unload-OllamaModel {}
            { Invoke-StackStart -Config $config } | Should Throw
            ((Get-Content $config.Paths.RuntimeStatePath -Raw | ConvertFrom-Json).Model) | Should Be 'ministral-3:14b'
            Assert-MockCalled Unload-OllamaModel 1 -ParameterFilter {$ModelName -eq 'qwen3.8:27b'}
        }
        It 'does not unload a target model that was already owned before a reused-start failure' {
            $script:sameModelUnloadCount=0
            $config=Get-StackConfiguration -RootPath $TestDrive -Model qwen
            New-Item -ItemType Directory $config.Paths.StateDirectory -Force | Out-Null
            @{Pid=7;StartedAtUtc='2026-10-08T00:00:00Z';ExecutablePath='C:\Ollama\ollama.exe';Model='qwen3.8:27b'} | ConvertTo-Json | Set-Content $config.Paths.RuntimeStatePath
            Mock Get-HostPreflight { [pscustomobject]@{CanStart=$true;Errors=@();Adapter=[pscustomobject]@{IPv4Address='192.168.1.8'}} }
            Mock Set-StackHighPerformance { [pscustomobject]@{Previous='old';Changed=$false} }
            Mock Start-ManagedOllama { [pscustomobject]@{Started=$false;Reused=$true;PreviousModel='qwen3.8:27b'} }
            Mock Initialize-OllamaModel {}
            Mock Get-OllamaResidency { [pscustomobject]@{ContextLength=92160;Processor='100% GPU';FullyGpuResident=$true} }
            Mock Start-GatewayStack { [pscustomobject]@{Started=$true} }
            Mock Invoke-GatewaySmokeTest { throw 'smoke failed' }
            Mock Stop-GatewayStack { [pscustomobject]@{Stopped=$true} }
            Mock Unload-OllamaModel { $script:sameModelUnloadCount++ }
            { Invoke-StackStart -Config $config } | Should Throw
            ((Get-Content $config.Paths.RuntimeStatePath -Raw | ConvertFrom-Json).Model) | Should Be 'qwen3.8:27b'
            $script:sameModelUnloadCount | Should Be 0
        }
    }
}
