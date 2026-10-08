$repoRoot=Split-Path -Parent $PSScriptRoot
$run=$env:RUN_STACK_INTEGRATION -eq '1'
Describe 'Live Ollama stack acceptance' -Tag Integration {
 It 'passes authenticated LAN-gateway and GPU-residency checks without printing keys' -Skip:(-not $run) {
  Import-Module (Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1') -Force
  $config=Get-StackConfiguration -RootPath $repoRoot
  {docker compose --project-name local-ollama-windows --env-file $config.Paths.EnvFile -f $config.Paths.ComposeFile config --quiet}|Should Not Throw
  $status=Get-StackStatus -Config $config
  $status.LiteLLMHealthy|Should Be $true
  $status.PostgreSQLHealthy|Should Be $true
  $status.ContextLength|Should Be 92160
  $status.Processor|Should Be '100% GPU'
  $status.Model|Should Be 'local-coder'
  $key=(Get-Content $config.Paths.ClientKeyPath -Raw).Trim()
  $headers=@{Authorization="Bearer $key"}
  $models=Invoke-RestMethod -Uri "$($config.GatewayBaseUri)/v1/models" -Headers $headers
  ($models.data.id -contains 'local-coder')|Should Be $true
  {Invoke-RestMethod -Uri "$($config.GatewayBaseUri)/v1/models" -ErrorAction Stop}|Should Throw
  $thinkingBody=@{model='local-coder';max_tokens=2048;thinking=@{type='enabled';budget_tokens=1024};messages=@(@{role='user';content='Think briefly, then reply with OK.'})}|ConvertTo-Json -Depth 6 -Compress
  $reply=Invoke-RestMethod -Uri "$($config.GatewayBaseUri)/v1/messages" -Method Post -Headers $headers -ContentType 'application/json' -Body $thinkingBody
  (@($reply.content|Where-Object{$_.type -eq 'thinking' -and $_.thinking}).Count -gt 0)|Should Be $true
  (@($reply.content|Where-Object{$_.type -eq 'text' -and $_.text}).Count -gt 0)|Should Be $true
  ([int]$reply.usage.input_tokens -gt 0)|Should Be $true
  ([int]$reply.usage.output_tokens -gt 0)|Should Be $true
  $postThinkingStatus=Get-StackStatus -Config $config
  $postThinkingStatus.ContextLength|Should Be 92160
  $postThinkingStatus.Processor|Should Be '100% GPU'
  $first=Invoke-StackStop -Config $config;$second=Invoke-StackStop -Config $config
  $first.Stopped|Should Be $true;$second.Stopped|Should Be $true
 }
}
