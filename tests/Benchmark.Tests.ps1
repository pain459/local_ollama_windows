$repoRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\OllamaStack\OllamaStack.psd1') -Force
$global:BenchmarkFixturePath=Join-Path $repoRoot 'tests\fixtures\ollama-stream.ndjson'
Describe 'Sequential model benchmark' {
 InModuleScope OllamaStack {
  It 'calculates rates and timings from the final Ollama event' {
   $lines=Get-Content $global:BenchmarkFixturePath
   $m=ConvertFrom-OllamaStreamMetrics -Lines $lines -TimeToFirstTokenMilliseconds 250
   $m.LoadMilliseconds|Should Be 2000
   $m.TotalMilliseconds|Should Be 8000
   $m.PromptTokensPerSecond|Should Be 20
   $m.OutputTokensPerSecond|Should Be 12.5
   $m.TimeToFirstTokenMilliseconds|Should Be 250
  }
  It 'fails immediately when residency is not fully GPU native' {
   Mock Get-OllamaResidency {[pscustomobject]@{FullyGpuResident=$false;ContextLength=102400;Processor='90% GPU'}}
   $config=Get-StackConfiguration -RootPath $TestDrive -Model devstral
   {Measure-OllamaModel -Config $config -Model devstral}|Should Throw
  }
  It 'runs devstral then qwen with an unload before every load and writes prompt-free JSON' {
   $script:order=@()
   Mock Unload-OllamaModel {param($ModelName)$script:order+="unload:$ModelName"}
   Mock Initialize-OllamaModel {$script:order+="load:$($Config.Model.Name)"}
   Mock Measure-OllamaModel {param($Config,$Model)$script:order+="measure:$Model";[pscustomobject]@{Model=$Model;ContextLength=102400;FullyGpuResident=$true;LoadMilliseconds=1;TimeToFirstTokenMilliseconds=2;PromptTokensPerSecond=3;OutputTokensPerSecond=4;TotalMilliseconds=5;PeakVramMiB=22000}}
   $config=Get-StackConfiguration -RootPath $TestDrive -Model devstral
   $results=Invoke-StackBenchmark -Config $config
   $results.Count|Should Be 2
   ($script:order -join ',')|Should Be 'unload:devstral-small-2:24b,load:devstral,measure:devstral,unload:devstral-small-2:24b,unload:qwen3.8:27b,load:qwen,measure:qwen'
   $file=Get-ChildItem $config.Paths.BenchmarkDirectory -Filter '*.json'|Select-Object -First 1
   $json=Get-Content $file.FullName -Raw
   $json|Should Not Match 'Implement a small safe function|"Prompt"\s*:|secret|sk-'
  }
 }
}
