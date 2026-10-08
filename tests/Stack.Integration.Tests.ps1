$repoRoot=Split-Path -Parent $PSScriptRoot
$run=$env:RUN_STACK_INTEGRATION -eq '1'
Describe 'Live Ollama stack acceptance' -Tag Integration {
 It 'passes authenticated LAN-gateway and GPU-residency checks without printing keys' -Skip:(-not $run) {
  Import-Module (Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1') -Force
  $config=Get-StackConfiguration -RootPath $repoRoot -Model ministral
  {docker compose --project-name local-ollama-windows --env-file $config.Paths.EnvFile -f $config.Paths.ComposeFile config --quiet}|Should Not Throw
  $status=Get-StackStatus -Config $config
  $status.LiteLLMHealthy|Should Be $true
  $status.PostgreSQLHealthy|Should Be $true
  $status.ContextLength|Should Be 102400
  $status.Processor|Should Be '100% GPU'
  $status.Model|Should Be 'local-coder'
  $key=(Get-Content $config.Paths.ClientKeyPath -Raw).Trim()
  $headers=@{Authorization="Bearer $key"}
  $models=Invoke-RestMethod -Uri "$($config.GatewayBaseUri)/v1/models" -Headers $headers
  ($models.data.id -contains 'local-coder')|Should Be $true
  {Invoke-RestMethod -Uri "$($config.GatewayBaseUri)/v1/models" -ErrorAction Stop}|Should Throw
  $first=Invoke-StackStop -Config $config;$second=Invoke-StackStop -Config $config
  $first.Stopped|Should Be $true;$second.Stopped|Should Be $true
 }
}
