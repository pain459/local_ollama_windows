$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1') -Force

Describe 'Windows host preflight' {
    InModuleScope OllamaStack {
        It 'reports an unrelated port owner with PID and executable path' {
            Mock Get-NetTCPConnection { param($State, $LocalPort, $ErrorAction) [pscustomobject]@{ OwningProcess = 4242; LocalPort = 11434 } }
            Mock Get-Process { param($Id, $ErrorAction) [pscustomobject]@{ Id = 4242; Path = 'C:\Other\server.exe'; StartTime = [datetime]'2026-01-01' } }
            $owner = Get-PortOwner -Port 11434
            $owner.Pid | Should Be 4242
            $owner.ExecutablePath | Should Be 'C:\Other\server.exe'
        }

        It 'chooses the eligible default route with the lowest combined metric' {
            Mock Get-NetRoute { @(
                [pscustomobject]@{ InterfaceIndex = 8; RouteMetric = 40; InterfaceMetric = 20; DestinationPrefix = '0.0.0.0/0' },
                [pscustomobject]@{ InterfaceIndex = 4; RouteMetric = 5; InterfaceMetric = 10; DestinationPrefix = '0.0.0.0/0' }
            ) }
            Mock Get-NetIPConfiguration {
                param($InterfaceIndex)
                [pscustomobject]@{
                    InterfaceIndex = $InterfaceIndex
                    InterfaceAlias = "Ethernet $InterfaceIndex"
                    NetAdapter = [pscustomobject]@{ MacAddress = "00-00-00-00-00-0$InterfaceIndex"; HardwareInterface = $true }
                    IPv4Address = [pscustomobject]@{ IPAddress = "192.168.1.$InterfaceIndex" }
                }
            }
            Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Private' } }
            (Get-ActiveLanAdapter).InterfaceIndex | Should Be 4
        }

        It 'rejects APIPA loopback and virtual-only routes' {
            Mock Get-NetRoute { @(
                [pscustomobject]@{ InterfaceIndex = 1; RouteMetric = 1; InterfaceMetric = 1 },
                [pscustomobject]@{ InterfaceIndex = 2; RouteMetric = 2; InterfaceMetric = 1 },
                [pscustomobject]@{ InterfaceIndex = 3; RouteMetric = 3; InterfaceMetric = 1 }
            ) }
            Mock Get-NetIPConfiguration {
                param($InterfaceIndex)
                if ($InterfaceIndex -eq 1) { return [pscustomobject]@{ InterfaceIndex=1; InterfaceAlias='Loopback'; NetAdapter=[pscustomobject]@{MacAddress='';HardwareInterface=$true}; IPv4Address=[pscustomobject]@{IPAddress='127.0.0.1'} } }
                if ($InterfaceIndex -eq 2) { return [pscustomobject]@{ InterfaceIndex=2; InterfaceAlias='Ethernet'; NetAdapter=[pscustomobject]@{MacAddress='aa';HardwareInterface=$true}; IPv4Address=[pscustomobject]@{IPAddress='169.254.4.2'} } }
                return [pscustomobject]@{ InterfaceIndex=3; InterfaceAlias='vEthernet (WSL)'; NetAdapter=[pscustomobject]@{MacAddress='bb';HardwareInterface=$false}; IPv4Address=[pscustomobject]@{IPAddress='172.20.1.1'} }
            }
            Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Private' } }
            { Get-ActiveLanAdapter } | Should Throw
        }

        It 'marks a Public route unsafe for LAN exposure' {
            Mock Get-DockerAvailability { [pscustomobject]@{CliPresent=$true;ComposePresent=$true;EngineReachable=$true;Error=$null} }
            Mock Get-ActiveLanAdapter { [pscustomobject]@{InterfaceIndex=4;Name='Ethernet';MacAddress='aa';IPv4Address='192.168.1.4';NetworkCategory='Public';RouteMetric=10} }
            Mock Get-PortOwner { $null }
            Mock Get-Command { [pscustomobject]@{ Source = 'tool.exe' } }
            $result = Get-HostPreflight ([pscustomobject]@{ GatewayPort=4000; OllamaPort=11434 })
            $result.CanExposeLan | Should Be $false
            $result.CanStart | Should Be $false
        }

        It 'fails cleanly when Docker engine access is denied' {
            Mock Get-DockerAvailability { [pscustomobject]@{CliPresent=$true;ComposePresent=$true;EngineReachable=$false;Error='Access denied'} }
            $result = Get-HostPreflight ([pscustomobject]@{ GatewayPort=4000; OllamaPort=11434 })
            $result.CanStart | Should Be $false
            $result.Errors -join ' ' | Should Match 'Access denied'
        }

        It 'returns startable for healthy private prerequisites and free gateway port' {
            Mock Get-DockerAvailability { [pscustomobject]@{CliPresent=$true;ComposePresent=$true;EngineReachable=$true;Error=$null} }
            Mock Get-ActiveLanAdapter { [pscustomobject]@{InterfaceIndex=4;Name='Ethernet';MacAddress='aa';IPv4Address='192.168.1.4';NetworkCategory='Private';RouteMetric=10} }
            Mock Get-PortOwner { $null }
            Mock Get-Command { [pscustomobject]@{ Source = 'tool.exe' } }
            (Get-HostPreflight ([pscustomobject]@{ GatewayPort=4000; OllamaPort=11434 })).CanStart | Should Be $true
        }
    }
}

Describe 'Native command capture' {
    InModuleScope OllamaStack {
        It 'captures informational stderr from a successful native command without throwing' {
            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Stop'
                $result = Invoke-NativeCapture -FilePath $env:ComSpec -Arguments @('/d', '/c', 'echo pull-progress 1>&2 & exit /b 0')
                $result.ExitCode | Should Be 0
                $result.Output | Should Match 'pull-progress'
            } finally {
                $ErrorActionPreference = $previous
            }
        }
    }
}
