Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'Configuration.ps1')
. (Join-Path $PSScriptRoot 'Host.ps1')
. (Join-Path $PSScriptRoot 'Setup.ps1')

Export-ModuleMember -Function @(
    'Get-ModelConfiguration',
    'Get-StackPaths',
    'Get-StackConfiguration'
)

