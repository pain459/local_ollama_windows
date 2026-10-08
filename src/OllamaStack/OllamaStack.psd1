@{
    RootModule = 'OllamaStack.psm1'
    ModuleVersion = '1.0.0'
    GUID = '38a69ab8-70cd-46bf-9f94-79bfb5f2c770'
    Author = 'local-ollama-windows contributors'
    Description = 'Lifecycle controller for a LAN-only Ollama and LiteLLM stack.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-ModelConfiguration',
        'Get-StackPaths',
        'Get-StackConfiguration'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}

