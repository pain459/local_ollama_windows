function Get-ComposeArguments {
    param([pscustomobject]$Config, [string[]]$Command)
    @('compose','--project-name',$Config.ComposeProject,'--env-file',$Config.Paths.EnvFile,'-f',$Config.Paths.ComposeFile) + $Command
}

function Invoke-Compose {
    param([pscustomobject]$Config, [string[]]$Arguments)
    $docker = (Get-Command docker -ErrorAction Stop).Source
    Invoke-NativeCapture -FilePath $docker -Arguments $Arguments
}

function Invoke-LiteLLMRequest {
    param([pscustomobject]$Config, [string]$Path, [string]$Method='Get', [string]$ApiKey, [string]$Body)
    $headers = @{}
    if ($ApiKey) { $headers.Authorization = "Bearer $ApiKey" }
    $parameters = @{ Uri="$($Config.GatewayBaseUri)$Path"; Method=$Method; Headers=$headers; TimeoutSec=15 }
    if ($Body) { $parameters.ContentType='application/json'; $parameters.Body=$Body }
    Invoke-RestMethod @parameters
}

function Start-GatewayStack {
    [CmdletBinding()]
    param([pscustomobject]$Config, [switch]$SkipWait)
    $arguments = Get-ComposeArguments -Config $Config -Command @('up','-d')
    $result = Invoke-Compose -Config $Config -Arguments $arguments
    if ($result.ExitCode -ne 0) { throw "Compose startup failed: $($result.Output)" }
    if (-not $SkipWait) { Wait-GatewayReady -Config $Config }
    [pscustomobject]@{Started=$true;Project=$Config.ComposeProject}
}

function Wait-GatewayReady {
    [CmdletBinding()]
    param([pscustomobject]$Config)
    $envValues = Read-DotEnv -Path $Config.Paths.EnvFile
    $deadline = [datetime]::UtcNow.AddSeconds($Config.StartupTimeoutSeconds)
    $last = 'no response'
    do {
        try { $null = Invoke-LiteLLMRequest -Config $Config -Path '/health/readiness' -ApiKey $envValues['LITELLM_MASTER_KEY']; return }
        catch { $last = $_.Exception.Message; if ($Config.StartupTimeoutSeconds -gt 0) { Start-Sleep -Milliseconds 500 } }
    } while ([datetime]::UtcNow -lt $deadline)
    throw "LiteLLM readiness timed out; last failure: $last"
}

function Test-LiteLLMClientKey {
    param([pscustomobject]$Config, [string]$Key)
    try {
        $response = Invoke-LiteLLMRequest -Config $Config -Path '/v1/models' -ApiKey $Key
        if (-not $response.PSObject.Properties['data']) { return $false }
        $visible = @($response.data | ForEach-Object { [string]$_.id })
        return $visible.Count -eq 1 -and $visible[0] -eq $Config.Model.Alias
    } catch { return $false }
}

function Ensure-LiteLLMClientKey {
    [CmdletBinding()]
    param([pscustomobject]$Config)
    if (Test-Path -LiteralPath $Config.Paths.ClientKeyPath) {
        $existing = (Get-Content -LiteralPath $Config.Paths.ClientKeyPath -Raw).Trim()
        if ($existing -and (Test-LiteLLMClientKey -Config $Config -Key $existing)) { return $existing }
    }
    $environment = Read-DotEnv -Path $Config.Paths.EnvFile
    $keyAlias = 'local-coding-client-' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
    $body = @{models=@($Config.Model.Alias);key_alias=$keyAlias} | ConvertTo-Json -Compress
    $generated = Invoke-LiteLLMRequest -Config $Config -Path '/key/generate' -Method Post -ApiKey $environment['LITELLM_MASTER_KEY'] -Body $body
    if (-not $generated.key -or [string]$generated.key -notmatch '^sk-') { throw 'LiteLLM did not return a valid virtual key.' }
    if (-not (Test-Path $Config.Paths.StateDirectory)) { New-Item -ItemType Directory -Path $Config.Paths.StateDirectory -Force | Out-Null }
    [IO.File]::WriteAllText($Config.Paths.ClientKeyPath, [string]$generated.key, (New-Object Text.UTF8Encoding($false)))
    return [string]$generated.key
}

function Test-UnauthenticatedGatewayRejection {
    param([pscustomobject]$Config)
    try { $null = Invoke-WebRequest -UseBasicParsing -Uri "$($Config.GatewayBaseUri)/v1/models" -TimeoutSec 10; return $false }
    catch { return $_.Exception.Response.StatusCode.value__ -in @(401,403) }
}

function Invoke-GatewaySmokeTest {
    [CmdletBinding()]
    param([pscustomobject]$Config)
    if (-not (Test-UnauthenticatedGatewayRejection -Config $Config)) { throw 'Gateway accepted an unauthenticated model request.' }
    $key = Ensure-LiteLLMClientKey -Config $Config
    $thinkingRequested = [bool]$Config.Model.SupportsThinking
    $thinkingVerified = $false
    $usage = $null

    if ($thinkingRequested) {
        # Claude Code uses the Anthropic Messages protocol. Exercise that exact
        # path instead of sending a non-standard parameter to OpenAI chat.
        $request = @{
            model=$Config.Model.Alias
            messages=@(@{role='user';content='Think briefly, then reply with OK.'})
            max_tokens=2048
            thinking=@{type='enabled';budget_tokens=1024}
            stream=$false
        }
        $body = $request | ConvertTo-Json -Depth 6 -Compress
        $response = Invoke-LiteLLMRequest -Config $Config -Path '/v1/messages' -Method Post -ApiKey $key -Body $body
        $blocks = if ($response.PSObject.Properties['content']) { @($response.content) } else { @() }
        $finalTextVerified = $false
        foreach ($block in $blocks) {
            if ($block.PSObject.Properties['type'] -and [string]$block.type -eq 'thinking' -and
                $block.PSObject.Properties['thinking'] -and -not [string]::IsNullOrWhiteSpace([string]$block.thinking)) {
                $thinkingVerified = $true
            }
            if ($block.PSObject.Properties['type'] -and [string]$block.type -eq 'text' -and
                $block.PSObject.Properties['text'] -and -not [string]::IsNullOrWhiteSpace([string]$block.text)) {
                $finalTextVerified = $true
            }
        }
        if (-not $thinkingVerified) { throw "Authenticated Anthropic smoke test for '$($Config.Model.Alias)' returned no thinking block." }
        if (-not $finalTextVerified) { throw "Authenticated Anthropic smoke test for '$($Config.Model.Alias)' returned no final text block." }
        if ($response.PSObject.Properties['usage']) { $usage = $response.usage }
        if ($usage -and -not $usage.PSObject.Properties['total_tokens']) {
            $inputTokens = if ($usage.PSObject.Properties['input_tokens']) { [int]$usage.input_tokens } else { 0 }
            $outputTokens = if ($usage.PSObject.Properties['output_tokens']) { [int]$usage.output_tokens } else { 0 }
            $usage | Add-Member NoteProperty total_tokens ($inputTokens + $outputTokens)
        }
    } else {
        $request = @{model=$Config.Model.Alias;messages=@(@{role='user';content='Reply with OK.'});max_tokens=64;stream=$true;stream_options=@{include_usage=$true}}
        $body = $request | ConvertTo-Json -Depth 6 -Compress
        $response = Invoke-LiteLLMRequest -Config $Config -Path '/v1/chat/completions' -Method Post -ApiKey $key -Body $body
        if ($response -isnot [string] -and $response.PSObject.Properties['usage']) {
            $usage = $response.usage
        }
        if (-not $usage) {
            $streamText = @($response | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            foreach ($line in ($streamText -split "`r?`n")) {
                if ($line.StartsWith('data: {')) {
                    $item = $line.Substring(6) | ConvertFrom-Json
                    if ($item.PSObject.Properties['usage'] -and $item.usage) { $usage = $item.usage }
                }
            }
        }
    }
    if (-not $usage) { throw 'Authenticated streaming smoke test returned no token usage.' }
    [pscustomobject]@{Succeeded=$true;Model=$Config.Model.Alias;ThinkingRequested=$thinkingRequested;ThinkingVerified=$thinkingVerified;Usage=$usage;ClientKeyPath=$Config.Paths.ClientKeyPath}
}

function Get-GatewayStatus {
    param([pscustomobject]$Config)
    $args = Get-ComposeArguments -Config $Config -Command @('ps','--format','json')
    $result = Invoke-Compose -Config $Config -Arguments $args
    [pscustomobject]@{Healthy=($result.ExitCode -eq 0 -and $result.Output -match 'running|healthy');Details=$result.Output}
}

function Stop-GatewayStack {
    [CmdletBinding()]
    param([pscustomobject]$Config)
    $arguments = Get-ComposeArguments -Config $Config -Command @('stop')
    $result = Invoke-Compose -Config $Config -Arguments $arguments
    if ($result.ExitCode -ne 0) { throw "Compose stop failed: $($result.Output)" }
    [pscustomobject]@{Stopped=$true;Project=$Config.ComposeProject;DataPreserved=$true}
}
