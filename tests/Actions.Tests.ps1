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
    }
}
