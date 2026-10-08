function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ActiveLanAdapter {
    [CmdletBinding()]
    param()

    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop)
    $candidates = @()
    foreach ($route in $routes) {
        $ipConfig = Get-NetIPConfiguration -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
        $addresses = @($ipConfig.IPv4Address | ForEach-Object { $_.IPAddress })
        $address = $addresses | Where-Object {
            $_ -and $_ -notmatch '^127\.' -and $_ -notmatch '^169\.254\.' -and $_ -ne '0.0.0.0'
        } | Select-Object -First 1
        if (-not $address) { continue }
        if ($ipConfig.InterfaceAlias -match '^(vEthernet|Loopback)|Docker|WSL|Hyper-V') { continue }
        if ($ipConfig.NetAdapter.PSObject.Properties['HardwareInterface'] -and -not $ipConfig.NetAdapter.HardwareInterface) { continue }

        $profile = Get-NetConnectionProfile -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
        $routeMetric = [int]$route.RouteMetric
        if ($route.PSObject.Properties['InterfaceMetric']) { $routeMetric += [int]$route.InterfaceMetric }
        $candidates += [pscustomobject]@{
            InterfaceIndex = [int]$route.InterfaceIndex
            Name = [string]$ipConfig.InterfaceAlias
            MacAddress = [string]$ipConfig.NetAdapter.MacAddress
            IPv4Address = [string]$address
            NetworkCategory = [string]$profile.NetworkCategory
            RouteMetric = $routeMetric
        }
    }
    $selected = $candidates | Sort-Object RouteMetric, InterfaceIndex | Select-Object -First 1
    if (-not $selected) { throw 'No eligible physical LAN adapter with a routable IPv4 default route was found.' }
    return $selected
}

function Get-PortOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Port)

    $connection = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connection) { return $null }
    try {
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction Stop
        [pscustomobject]@{
            Pid = [int]$process.Id
            ExecutablePath = [string]$process.Path
            StartedAtUtc = $process.StartTime.ToUniversalTime().ToString('o')
            Port = $Port
        }
    } catch {
        [pscustomobject]@{
            Pid = [int]$connection.OwningProcess
            ExecutablePath = $null
            StartedAtUtc = $null
            Port = $Port
        }
    }
}

function Invoke-NativeCapture {
    param([string]$FilePath, [string[]]$Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 wraps native stderr as ErrorRecord objects.
        # Docker uses stderr for normal pull progress, so capture it and judge
        # success exclusively by the native process exit code.
        $ErrorActionPreference = 'Continue'
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
}

function Get-DockerAvailability {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) {
        return [pscustomobject]@{ CliPresent=$false; ComposePresent=$false; EngineReachable=$false; Error='Docker CLI is not installed or not on PATH.' }
    }
    try {
        $compose = Invoke-NativeCapture -FilePath $docker.Source -Arguments @('compose', 'version')
        $engine = Invoke-NativeCapture -FilePath $docker.Source -Arguments @('version', '--format', '{{.Server.Version}}')
        $composePresent = $compose.ExitCode -eq 0
        $engineReachable = $engine.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($engine.Output)
        $errorText = $null
        if (-not $composePresent) { $errorText = "Docker Compose is unavailable: $($compose.Output)" }
        elseif (-not $engineReachable) { $errorText = "Docker engine is unreachable: $($engine.Output)" }
        return [pscustomobject]@{ CliPresent=$true; ComposePresent=$composePresent; EngineReachable=$engineReachable; Error=$errorText }
    } catch {
        return [pscustomobject]@{ CliPresent=$true; ComposePresent=$false; EngineReachable=$false; Error=$_.Exception.Message }
    }
}

function Get-HostPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)

    $errors = New-Object System.Collections.Generic.List[string]
    $docker = Get-DockerAvailability
    if (-not ($docker.CliPresent -and $docker.ComposePresent -and $docker.EngineReachable)) {
        $errors.Add([string]$docker.Error)
        return [pscustomobject]@{
            CanStart=$false; CanExposeLan=$false; Adapter=$null; Docker=$docker
            GatewayPortOwner=$null; OllamaPortOwner=$null; Errors=$errors.ToArray()
        }
    }

    $adapter = $null
    try { $adapter = Get-ActiveLanAdapter } catch { $errors.Add($_.Exception.Message) }
    $canExpose = $adapter -and $adapter.NetworkCategory -eq 'Private'
    if ($adapter -and -not $canExpose) { $errors.Add("Active LAN adapter '$($adapter.Name)' uses the $($adapter.NetworkCategory) profile; Private is required.") }

    foreach ($tool in @('ollama', 'nvidia-smi')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $errors.Add("Required command '$tool' was not found.") }
    }
    $gatewayOwner = Get-PortOwner -Port $Config.GatewayPort
    $ollamaOwner = Get-PortOwner -Port $Config.OllamaPort
    if ($gatewayOwner) { $errors.Add("Port $($Config.GatewayPort) is owned by PID $($gatewayOwner.Pid) at '$($gatewayOwner.ExecutablePath)'.") }

    [pscustomobject]@{
        CanStart=($errors.Count -eq 0 -and $canExpose)
        CanExposeLan=[bool]$canExpose
        Adapter=$adapter
        Docker=$docker
        GatewayPortOwner=$gatewayOwner
        OllamaPortOwner=$ollamaOwner
        Errors=$errors.ToArray()
    }
}
