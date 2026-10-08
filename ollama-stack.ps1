[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Setup','Start','Stop','Status','Benchmark')][string]$Action,
    [ValidateSet('devstral','qwen','ministral')][string]$Model='ministral',
    [switch]$InstallPrerequisites
)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
Import-Module (Join-Path $root 'src\OllamaStack\OllamaStack.psd1') -Force
$config=Get-StackConfiguration -RootPath $root -Model $Model
switch($Action){
    Setup { Invoke-StackSetup -Config $config -InstallPrerequisites:$InstallPrerequisites }
    Start { Invoke-StackStart -Config $config }
    Stop { Invoke-StackStop -Config $config }
    Status { Get-StackStatus -Config $config }
    Benchmark { Invoke-StackBenchmark -Config $config }
}
