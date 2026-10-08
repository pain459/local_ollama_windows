function New-StackSecret {
    [CmdletBinding()]
    param([int]$ByteCount = 32, [string]$Prefix = '')
    if ($ByteCount -lt 16) { throw 'Secrets must contain at least 16 random bytes.' }
    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $encoded = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    return $Prefix + $encoded
}

function Read-DotEnv {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $values = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) { $values[$parts[0].Trim()] = $parts[1] }
    }
    return $values
}

function Write-DotEnvAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = $Path + '.tmp'
    $lines = foreach ($key in ($Values.Keys | Sort-Object)) {
        $value = [string]$Values[$key]
        if ($key -notmatch '^[A-Z][A-Z0-9_]*$' -or $value -match "[`r`n]") { throw "Invalid dotenv value for '$key'." }
        "$key=$value"
    }
    [IO.File]::WriteAllLines($temporary, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        $backup = $Path + '.replace-backup'
        try { [IO.File]::Replace($temporary, $Path, $backup, $true) }
        finally { if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force } }
    } else {
        Move-Item -LiteralPath $temporary -Destination $Path
    }
}

function Ensure-StackEnvironment {
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)
    $values = Read-DotEnv -Path $Config.Paths.EnvFile
    if (-not $values.Contains('LITELLM_MASTER_KEY')) { $values.LITELLM_MASTER_KEY = New-StackSecret -ByteCount 32 -Prefix 'sk-' }
    if (-not $values.Contains('LITELLM_SALT_KEY')) { $values.LITELLM_SALT_KEY = New-StackSecret -ByteCount 32 -Prefix 'sk-' }
    if (-not $values.Contains('POSTGRES_PASSWORD')) { $values.POSTGRES_PASSWORD = New-StackSecret -ByteCount 32 }
    $values.DATABASE_URL = "postgresql://litellm:$($values.POSTGRES_PASSWORD)@postgres:5432/litellm"
    Write-DotEnvAtomic -Path $Config.Paths.EnvFile -Values $values
    return $values
}

function Get-FirewallRulePortFilter {
    param($Rule)
    Get-NetFirewallPortFilter -AssociatedNetFirewallRule $Rule -ErrorAction SilentlyContinue
}

function Get-FirewallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)
    $disable = @()
    foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        if ([string]$rule.Enabled -ne 'True' -or [string]$rule.Direction -ne 'Inbound' -or [string]$rule.Action -ne 'Allow') { continue }
        $port = Get-FirewallRulePortFilter -Rule $rule
        if ($rule.DisplayName -match 'Ollama' -or ($port -and [string]$port.Protocol -eq 'TCP' -and [string]$port.LocalPort -eq '11434')) {
            $disable += [pscustomobject]@{ Name=$rule.Name; DisplayName=$rule.DisplayName; Enabled=[string]$rule.Enabled }
        }
    }
    [pscustomobject]@{
        DisableRules=$disable
        NewRule=[pscustomobject]@{
            Name='LocalOllamaWindows-LiteLLM-4000'
            DisplayName='Local Ollama Windows: LiteLLM Private LAN'
            Direction='Inbound'; Action='Allow'; Protocol='TCP'; LocalPort=[int]$Config.GatewayPort
            Profile='Private'; RemoteAddress='LocalSubnet'
        }
    }
}

function Enable-StackFirewall {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject]$Plan)
    foreach ($rule in $Plan.DisableRules) { Disable-NetFirewallRule -Name $rule.Name -ErrorAction Stop | Out-Null }
    $new = $Plan.NewRule
    $existing = Get-NetFirewallRule -Name $new.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Set-NetFirewallRule -Name $new.Name -Enabled True -Profile $new.Profile -Direction $new.Direction -Action $new.Action -RemoteAddress $new.RemoteAddress -ErrorAction Stop | Out-Null
        Set-NetFirewallPortFilter -AssociatedNetFirewallRule $existing -Protocol $new.Protocol -LocalPort $new.LocalPort -ErrorAction Stop | Out-Null
    } else {
        New-NetFirewallRule -Name $new.Name -DisplayName $new.DisplayName -Enabled True -Profile $new.Profile -Direction $new.Direction -Action $new.Action -Protocol $new.Protocol -LocalPort $new.LocalPort -RemoteAddress $new.RemoteAddress -ErrorAction Stop | Out-Null
    }
}

function Invoke-StackSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject]$Config, [switch]$InstallPrerequisites)

    if (-not (Test-IsAdministrator)) {
        $scriptPath = Join-Path $Config.RootPath 'ollama-stack.ps1'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Setup -Model $($Config.Model.Name)"
        if ($InstallPrerequisites) { $arguments += ' -InstallPrerequisites' }
        return [pscustomobject]@{
            Succeeded=$false; RequiresElevation=$true
            ElevationCommand="Start-Process powershell.exe -Verb RunAs -ArgumentList '$arguments'"
        }
    }

    $preflight = Get-HostPreflight -Config $Config
    if (-not $preflight.Docker.CliPresent -and $InstallPrerequisites) {
        $install = Invoke-NativeCapture -FilePath 'winget' -Arguments @('install','--exact','--id','Docker.DockerDesktop','--accept-package-agreements','--accept-source-agreements')
        return [pscustomobject]@{ Succeeded=$false; RequiresElevation=$false; RestartRequired=$true; Message='Docker Desktop installation was requested. Reboot if prompted, then rerun Setup.'; ExitCode=$install.ExitCode }
    }
    if (-not $preflight.CanStart) { throw "Host preflight failed: $($preflight.Errors -join '; ')" }

    foreach ($directory in @($Config.Paths.StateDirectory, $Config.Paths.LogsDirectory, $Config.Paths.BenchmarkDirectory)) {
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }
    $null = Ensure-StackEnvironment -Config $Config
    $plan = Get-FirewallPlan -Config $Config
    $plan.DisableRules | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Config.Paths.FirewallBackupPath -Encoding UTF8
    Enable-StackFirewall -Plan $plan

    $docker = (Get-Command docker -ErrorAction Stop).Source
    $base = @('compose','--project-name',$Config.ComposeProject,'--env-file',$Config.Paths.EnvFile,'-f',$Config.Paths.ComposeFile)
    $validate = Invoke-NativeCapture -FilePath $docker -Arguments ($base + @('config','--quiet'))
    if ($validate.ExitCode -ne 0) { throw "Compose validation failed: $($validate.Output)" }
    $pull = Invoke-NativeCapture -FilePath $docker -Arguments ($base + @('pull'))
    if ($pull.ExitCode -ne 0) { throw "Image pull failed: $($pull.Output)" }
    $imageLock = [ordered]@{}
    foreach ($image in @('ghcr.io/berriai/litellm:1.104.0','postgres:17.6-alpine')) {
        $inspect = Invoke-NativeCapture -FilePath $docker -Arguments @('image','inspect','--format','{{.Id}}',$image)
        if ($inspect.ExitCode -ne 0) { throw "Unable to inspect pinned image '$image'." }
        $imageLock[$image] = $inspect.Output.Trim()
    }
    $imageLock | ConvertTo-Json | Set-Content -LiteralPath $Config.Paths.ImageLockPath -Encoding UTF8

    $ollama = (Get-Command ollama -ErrorAction Stop).Source
    $models = Invoke-NativeCapture -FilePath $ollama -Arguments @('list')
    if ($models.Output -notmatch [regex]::Escape($Config.Model.OllamaName)) {
        $modelPull = Invoke-NativeCapture -FilePath $ollama -Arguments @('pull',$Config.Model.OllamaName)
        if ($modelPull.ExitCode -ne 0) { throw "Ollama model pull failed: $($modelPull.Output)" }
    }
    [pscustomobject]@{ Succeeded=$true; RequiresElevation=$false; Adapter=$preflight.Adapter; FirewallRule=$plan.NewRule.Name; ImageLockPath=$Config.Paths.ImageLockPath; EnvironmentPath=$Config.Paths.EnvFile }
}
