function New-OllamaProcessStartInfo {
    param([Parameter(Mandatory=$true)][string]$ExecutablePath, [Parameter(Mandatory=$true)][pscustomobject]$Config)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $ExecutablePath
    $info.Arguments = 'serve'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    # Undrained redirected streams can fill their OS pipe buffers and block
    # the server during model loading. Inherit the controller's streams.
    $info.RedirectStandardOutput = $false
    $info.RedirectStandardError = $false
    foreach ($entry in $Config.OllamaEnvironment.GetEnumerator()) { $info.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value }
    return $info
}

function Test-OfficialOllamaExecutable {
    param([string]$Path, [string]$CommandPath)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($CommandPath -and $resolved -eq [IO.Path]::GetFullPath($CommandPath)) { return $true }
    $officialRoot = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
    return $resolved.StartsWith(([IO.Path]::GetFullPath($officialRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -in @('ollama.exe','ollama app.exe')
}

function Test-ManagedProcessIdentity {
    param($Process, $State)
    if (-not $Process -or -not $State) { return $false }
    $samePath = [string]$Process.Path -and ([IO.Path]::GetFullPath([string]$Process.Path) -eq [IO.Path]::GetFullPath([string]$State.ExecutablePath))
    $actual = $Process.StartTime.ToUniversalTime()
    $expected = [datetime]::Parse([string]$State.StartedAtUtc).ToUniversalTime()
    return $samePath -and ([math]::Abs(($actual - $expected).TotalSeconds) -lt 1)
}

function Wait-OllamaReady {
    param([uri]$BaseUri, [timespan]$Timeout)
    $deadline = [datetime]::UtcNow.Add($Timeout)
    $last = $null
    do {
        try { $null = Invoke-RestMethod -Uri ([uri]::new($BaseUri, '/api/version')) -Method Get -TimeoutSec 3; return }
        catch { $last = $_.Exception.Message; Start-Sleep -Milliseconds 500 }
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Ollama readiness timed out: $last"
}

function Start-ManagedOllama {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][pscustomobject]$Config)
    $ollama = Get-Command ollama -ErrorAction Stop
    $owner = Get-PortOwner -Port $Config.OllamaPort
    if ($owner) {
        if (-not (Test-OfficialOllamaExecutable -Path $owner.ExecutablePath -CommandPath $ollama.Source)) {
            throw "Port $($Config.OllamaPort) is owned by unrecognized PID $($owner.Pid) at '$($owner.ExecutablePath)'."
        }
        $current = Get-Process -Id $owner.Pid -ErrorAction Stop
        if (-not (Test-ManagedProcessIdentity -Process $current -State $owner)) { throw 'The Ollama port owner changed during validation.' }
        Stop-Process -Id $owner.Pid -ErrorAction Stop
        $current.WaitForExit(10000) | Out-Null
    }
    if (-not (Test-Path $Config.Paths.StateDirectory)) { New-Item -ItemType Directory -Path $Config.Paths.StateDirectory -Force | Out-Null }
    $info = New-OllamaProcessStartInfo -ExecutablePath $ollama.Source -Config $Config
    $process = [Diagnostics.Process]::Start($info)
    $state = [ordered]@{ Pid=$process.Id; StartedAtUtc=$process.StartTime.ToUniversalTime().ToString('o'); ExecutablePath=$ollama.Source; Model=$Config.Model.OllamaName }
    $state | ConvertTo-Json | Set-Content -LiteralPath $Config.Paths.RuntimeStatePath -Encoding UTF8
    try {
        Wait-OllamaReady -BaseUri ([uri]$Config.OllamaBaseUri) -Timeout ([timespan]::FromSeconds($Config.StartupTimeoutSeconds))
        (Get-Process -Id $process.Id -ErrorAction Stop).PriorityClass = 'High'
        [pscustomobject]@{Started=$true;Pid=$process.Id;StartedAtUtc=$state.StartedAtUtc;ExecutablePath=$state.ExecutablePath;Model=$state.Model}
    } catch {
        if (-not $process.HasExited) { $process.Kill() }
        Remove-Item -LiteralPath $Config.Paths.RuntimeStatePath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Initialize-OllamaModel {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][pscustomobject]$Config)
    $body = [ordered]@{
        model=$Config.Model.OllamaName
        messages=@(@{role='user';content='Reply with OK.'})
        stream=$false
        keep_alive=-1
        options=@{num_ctx=[int]$Config.Model.ContextLength}
    } | ConvertTo-Json -Depth 6 -Compress
    $response = Invoke-RestMethod -Uri "$($Config.OllamaBaseUri)/api/chat" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $Config.StartupTimeoutSeconds
    [pscustomobject]@{Loaded=$true;Model=$Config.Model.OllamaName;ContextLength=$Config.Model.ContextLength;Response=$response}
}

function Get-OllamaResidency {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ModelName)
    $ollama = (Get-Command ollama -ErrorAction Stop).Source
    $result = Invoke-NativeCapture -FilePath $ollama -Arguments @('ps')
    if ($result.ExitCode -ne 0) { throw "Unable to inspect Ollama residency: $($result.Output)" }
    $line = @($result.Output -split "`r?`n") | Where-Object { $_ -match [regex]::Escape($ModelName) } | Select-Object -First 1
    if (-not $line) { throw "Model '$ModelName' is not loaded." }
    $processor = if ($line -match '(\d+%)\s+GPU') { "$($Matches[1]) GPU" } else { 'CPU/GPU split' }
    $context = if ($line -match '(?:^|\s)(102400)(?:\s|$)') { [int]$Matches[1] } elseif ($line -match '(?:^|\s)(\d{4,6})(?:\s|$)') { [int]$Matches[1] } else { 0 }
    $full = $processor -eq '100% GPU' -and $context -eq 102400
    if (-not $full) { throw "Performance validation failed for '$ModelName': processor '$processor', context $context; expected 100% GPU and 102400." }
    [pscustomobject]@{ContextLength=$context;Processor=$processor;FullyGpuResident=$true}
}

function Stop-ManagedOllama {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][pscustomobject]$Config)
    if (-not (Test-Path -LiteralPath $Config.Paths.RuntimeStatePath)) { return [pscustomobject]@{Stopped=$false;Reason='No managed state'} }
    $state = Get-Content -LiteralPath $Config.Paths.RuntimeStatePath -Raw | ConvertFrom-Json
    $process = Get-Process -Id $state.Pid -ErrorAction SilentlyContinue
    if (-not (Test-ManagedProcessIdentity -Process $process -State $state)) { return [pscustomobject]@{Stopped=$false;Reason='Managed PID identity mismatch'} }
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollama -and $state.Model) { $null = Invoke-NativeCapture -FilePath $ollama.Source -Arguments @('stop',[string]$state.Model) }
    Stop-Process -Id $state.Pid -ErrorAction Stop
    Remove-Item -LiteralPath $Config.Paths.RuntimeStatePath -Force
    [pscustomobject]@{Stopped=$true;Pid=[int]$state.Pid}
}
