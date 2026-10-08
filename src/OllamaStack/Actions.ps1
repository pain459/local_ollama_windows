function Set-StackHighPerformance {
    $active=Invoke-NativeCapture -FilePath 'powercfg.exe' -Arguments @('/getactivescheme')
    $previous=if($active.Output -match '([0-9a-fA-F-]{36})'){$Matches[1]}else{$null}
    $high=Invoke-NativeCapture -FilePath 'powercfg.exe' -Arguments @('/list')
    $target=if($high.Output -match '([0-9a-fA-F-]{36})\s+\(High performance\)'){$Matches[1]}else{$null}
    $changed=$false
    if($target -and $target -ne $previous){$set=Invoke-NativeCapture -FilePath 'powercfg.exe' -Arguments @('/setactive',$target);$changed=$set.ExitCode -eq 0}
    [pscustomobject]@{Previous=$previous;Changed=$changed}
}
function Restore-StackPowerScheme { param([string]$Scheme) if($Scheme){$null=Invoke-NativeCapture -FilePath 'powercfg.exe' -Arguments @('/setactive',$Scheme)} }

function Invoke-StackStart {
    [CmdletBinding()]param([pscustomobject]$Config)
    $pre=Get-HostPreflight -Config $Config
    if(-not $pre.CanStart){throw "Start refused: $($pre.Errors -join '; ')"}
    $power=$null;$ollamaStarted=$false;$gatewayStarted=$false
    try{
        $power=Set-StackHighPerformance
        $ollama=Start-ManagedOllama -Config $Config;$ollamaStarted=$ollama.Started
        $null=Initialize-OllamaModel -Config $Config
        $residency=Get-OllamaResidency -ModelName $Config.Model.OllamaName
        $gateway=Start-GatewayStack -Config $Config;$gatewayStarted=$gateway.Started
        $smoke=Invoke-GatewaySmokeTest -Config $Config
        $state=Get-Content $Config.Paths.RuntimeStatePath -Raw|ConvertFrom-Json
        $state|Add-Member NoteProperty PreviousPowerScheme $power.Previous -Force
        $state|Add-Member NoteProperty PowerChanged $power.Changed -Force
        $state|Add-Member NoteProperty GatewayStarted $gatewayStarted -Force
        $state|Add-Member NoteProperty LanIPv4 $pre.Adapter.IPv4Address -Force
        $state|ConvertTo-Json -Depth 8|Set-Content $Config.Paths.RuntimeStatePath -Encoding UTF8
        [pscustomobject]@{Succeeded=$true;ApiUrl="http://$($pre.Adapter.IPv4Address):4000/v1";DashboardUrl="http://$($pre.Adapter.IPv4Address):4000/ui";Model=$Config.Model.Alias;ContextLength=$residency.ContextLength;Processor=$residency.Processor;ClientKeyPath=$Config.Paths.ClientKeyPath}
    }catch{
        if($gatewayStarted){try{$null=Stop-GatewayStack -Config $Config}catch{}}
        if($ollamaStarted){try{$null=Stop-ManagedOllama -Config $Config}catch{}}
        if($power -and $power.Changed){Restore-StackPowerScheme -Scheme $power.Previous}
        throw
    }
}

function Invoke-StackStop {
    [CmdletBinding()]param([pscustomobject]$Config)
    $state=$null;if(Test-Path $Config.Paths.RuntimeStatePath){$state=Get-Content $Config.Paths.RuntimeStatePath -Raw|ConvertFrom-Json}
    $gateway=try{Stop-GatewayStack -Config $Config}catch{[pscustomobject]@{Stopped=$false;Reason=$_.Exception.Message}}
    $ollama=Stop-ManagedOllama -Config $Config
    if($state -and $state.PowerChanged){Restore-StackPowerScheme -Scheme $state.PreviousPowerScheme}
    [pscustomobject]@{Stopped=$true;Gateway=$gateway;Ollama=$ollama;PowerRestored=[bool]($state -and $state.PowerChanged)}
}

function Get-StackStatus {
    [CmdletBinding()]param([pscustomobject]$Config)
    $adapter=Get-ActiveLanAdapter
    $state=$null;if(Test-Path $Config.Paths.RuntimeStatePath){$state=Get-Content $Config.Paths.RuntimeStatePath -Raw|ConvertFrom-Json}
    $gateway=try{Get-GatewayStatus -Config $Config}catch{[pscustomobject]@{Healthy=$false}}
    $residency=try{Get-OllamaResidency -ModelName $Config.Model.OllamaName}catch{[pscustomobject]@{ContextLength=0;Processor='Not loaded';FullyGpuResident=$false}}
    $firewall=Get-NetFirewallRule -Name 'LocalOllamaWindows-LiteLLM-4000' -ErrorAction SilentlyContinue
    [pscustomobject]@{Adapter=$adapter.Name;MacAddress=$adapter.MacAddress;IPv4Address=$adapter.IPv4Address;NetworkCategory=$adapter.NetworkCategory;AddressChanged=[bool]($state -and $state.LanIPv4 -and $state.LanIPv4 -ne $adapter.IPv4Address);OllamaHealthy=$residency.FullyGpuResident;LiteLLMHealthy=$gateway.Healthy;PostgreSQLHealthy=$gateway.Healthy;OwnedPid=if($state){$state.Pid}else{$null};Model=$Config.Model.Alias;ContextLength=$residency.ContextLength;Processor=$residency.Processor;FirewallPrivateLocalSubnet=[bool]($firewall -and [string]$firewall.Enabled -eq 'True' -and [string]$firewall.Profile -match 'Private');ApiUrl="http://$($adapter.IPv4Address):4000/v1";DashboardUrl="http://$($adapter.IPv4Address):4000/ui";ClientConfigurationPath=$Config.Paths.ClientKeyPath}
}
