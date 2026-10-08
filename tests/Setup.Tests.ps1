$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1') -Force

Describe 'Idempotent secure setup' {
    InModuleScope OllamaStack {
        It 'generates distinct URL-safe cryptographic secrets with requested entropy' {
            $one = New-StackSecret -ByteCount 32 -Prefix 'sk-'
            $two = New-StackSecret -ByteCount 32 -Prefix 'sk-'
            $one | Should Match '^sk-[A-Za-z0-9_-]{43}$'
            $one | Should Not Be $two
        }

        It 'writes and reads a dotenv atomically without leaving a temporary file' {
            $path = Join-Path $TestDrive '.env.local'
            Write-DotEnvAtomic -Path $path -Values ([ordered]@{ B='two'; A='one' })
            (Read-DotEnv -Path $path).A | Should Be 'one'
            (Read-DotEnv -Path $path).B | Should Be 'two'
            (Test-Path ($path + '.tmp')) | Should Be $false
        }

        It 'preserves all generated secrets when setup environment is ensured twice' {
            $config = Get-StackConfiguration -RootPath (Join-Path $TestDrive 'repo') -Model devstral
            $first = Ensure-StackEnvironment -Config $config
            $second = Ensure-StackEnvironment -Config $config
            $second.LITELLM_MASTER_KEY | Should Be $first.LITELLM_MASTER_KEY
            $second.LITELLM_SALT_KEY | Should Be $first.LITELLM_SALT_KEY
            $second.POSTGRES_PASSWORD | Should Be $first.POSTGRES_PASSWORD
        }

        It 'plans only enabled inbound allow rules for Ollama or TCP 11434 and one narrow replacement' {
            Mock Get-NetFirewallRule { @(
                [pscustomobject]@{Name='broad';DisplayName='Ollama LAN';Enabled='True';Direction='Inbound';Action='Allow'},
                [pscustomobject]@{Name='outbound';DisplayName='Ollama outbound';Enabled='True';Direction='Outbound';Action='Allow'},
                [pscustomobject]@{Name='other';DisplayName='Other';Enabled='True';Direction='Inbound';Action='Allow'}
            ) }
            Mock Get-FirewallRulePortFilter {
                param($Rule)
                if ($Rule.Name -eq 'other') { [pscustomobject]@{Protocol='TCP';LocalPort='11434'} }
                else { [pscustomobject]@{Protocol='TCP';LocalPort='Any'} }
            }
            $plan = Get-FirewallPlan -Config ([pscustomobject]@{GatewayPort=4000})
            $plan.DisableRules.Count | Should Be 2
            $plan.NewRule.Protocol | Should Be 'TCP'
            $plan.NewRule.LocalPort | Should Be 4000
            $plan.NewRule.Profile | Should Be 'Private'
            $plan.NewRule.RemoteAddress | Should Be 'LocalSubnet'
        }

        It 'returns an exact elevation command before any mutation and contains no secret' {
            Mock Test-IsAdministrator { $false }
            $config = Get-StackConfiguration -RootPath 'C:\stack' -Model devstral
            $result = Invoke-StackSetup -Config $config
            $result.RequiresElevation | Should Be $true
            $result.ElevationCommand | Should Be "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File `"C:\stack\ollama-stack.ps1`" -Action Setup -Model devstral'"
            ($result | ConvertTo-Json -Depth 5) | Should Not Match 'POSTGRES_PASSWORD|LITELLM_MASTER_KEY|LITELLM_SALT_KEY'
        }
    }
}

Describe 'Windows Firewall cmdlet compatibility' {
    It 'uses only parameters supported by the installed firewall cmdlets' {
        $sourcePath = Join-Path $repoRoot 'src\OllamaStack\Setup.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
        $commands = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Get-NetFirewallPortFilter', 'Set-NetFirewallPortFilter')
        }, $true)
        foreach ($command in $commands) {
            $metadata = Get-Command $command.GetCommandName()
            foreach ($element in $command.CommandElements) {
                if ($element -is [Management.Automation.Language.CommandParameterAst]) {
                    $metadata.Parameters.ContainsKey($element.ParameterName) | Should Be $true
                }
            }
        }
    }
}
