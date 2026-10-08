function ConvertFrom-OllamaStreamMetrics {
 param([string[]]$Lines,[double]$TimeToFirstTokenMilliseconds)
 $final=$null
 foreach($line in $Lines){if($line.Trim()){$event=$line|ConvertFrom-Json;if($event.done){$final=$event}}}
 if(-not $final){throw 'Ollama stream did not contain a final metrics event.'}
 [pscustomobject]@{LoadMilliseconds=[math]::Round($final.load_duration/1e6,2);TimeToFirstTokenMilliseconds=[math]::Round($TimeToFirstTokenMilliseconds,2);PromptTokensPerSecond=if($final.prompt_eval_duration){[math]::Round($final.prompt_eval_count/($final.prompt_eval_duration/1e9),2)}else{0};OutputTokensPerSecond=if($final.eval_duration){[math]::Round($final.eval_count/($final.eval_duration/1e9),2)}else{0};TotalMilliseconds=[math]::Round($final.total_duration/1e6,2)}
}
function Get-PeakVramMiB {
 $r=Invoke-NativeCapture -FilePath 'nvidia-smi' -Arguments @('--query-compute-apps=used_memory','--format=csv,noheader,nounits')
 if($r.ExitCode -ne 0){return 0};$values=@($r.Output -split "`r?`n"|ForEach-Object{if($_ -match '^\s*(\d+)') {[int]$Matches[1]}});if($values){return ($values|Measure-Object -Maximum).Maximum};0
}
function Unload-OllamaModel {param([string]$ModelName)$ollama=(Get-Command ollama -ErrorAction Stop).Source;$null=Invoke-NativeCapture -FilePath $ollama -Arguments @('stop',$ModelName)}
function Measure-OllamaModel {
 [CmdletBinding()]param([pscustomobject]$Config,[string]$Model)
 $res=Get-OllamaResidency -ModelName $Config.Model.OllamaName -ExpectedContextLength $Config.Model.ContextLength
 if(-not $res.FullyGpuResident){throw "Benchmark refused CPU offload for '$Model'."}
 Add-Type -AssemblyName System.Net.Http
 $client=New-Object Net.Http.HttpClient
 try{
  $payload=@{model=$Config.Model.OllamaName;messages=@(@{role='user';content='Implement a small safe function and explain its edge cases.'});stream=$true;keep_alive=-1;options=@{num_ctx=[int]$Config.Model.ContextLength}}|ConvertTo-Json -Depth 6 -Compress
  $content=New-Object Net.Http.StringContent($payload,[Text.Encoding]::UTF8,'application/json')
  $watch=[Diagnostics.Stopwatch]::StartNew();$request=New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post,"$($Config.OllamaBaseUri)/api/chat");$request.Content=$content
  $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result;$response.EnsureSuccessStatusCode()|Out-Null
  $reader=New-Object IO.StreamReader($response.Content.ReadAsStreamAsync().Result);$lines=@();$ttft=$null
  while(-not $reader.EndOfStream){$line=$reader.ReadLine();if($line){$lines+=$line;$e=$line|ConvertFrom-Json;if(-not $ttft -and $e.message.content){$ttft=$watch.Elapsed.TotalMilliseconds}}}
  $watch.Stop();$metrics=ConvertFrom-OllamaStreamMetrics -Lines $lines -TimeToFirstTokenMilliseconds $ttft
  [pscustomobject]@{Model=$Model;ContextLength=$res.ContextLength;FullyGpuResident=$res.FullyGpuResident;LoadMilliseconds=$metrics.LoadMilliseconds;TimeToFirstTokenMilliseconds=$metrics.TimeToFirstTokenMilliseconds;PromptTokensPerSecond=$metrics.PromptTokensPerSecond;OutputTokensPerSecond=$metrics.OutputTokensPerSecond;TotalMilliseconds=$metrics.TotalMilliseconds;PeakVramMiB=Get-PeakVramMiB}
 }finally{$client.Dispose()}
}
function Invoke-StackBenchmark {
 [CmdletBinding()]param([pscustomobject]$Config)
 if(-not(Test-Path $Config.Paths.BenchmarkDirectory)){New-Item -ItemType Directory $Config.Paths.BenchmarkDirectory -Force|Out-Null}
 $results=@();$previous=$null
 foreach($name in @('devstral','qwen')){
  if($previous){Unload-OllamaModel -ModelName $previous.OllamaName}
  $model=Get-ModelConfiguration $name;Unload-OllamaModel -ModelName $model.OllamaName
  $modelConfig=Get-StackConfiguration -RootPath $Config.RootPath -Model $name
  $null=Initialize-OllamaModel -Config $modelConfig
  $results+=Measure-OllamaModel -Config $modelConfig -Model $name;$previous=$model
 }
 $path=Join-Path $Config.Paths.BenchmarkDirectory ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')+'.json')
 @($results)|ConvertTo-Json -Depth 5|Set-Content $path -Encoding UTF8
 return @($results)
}
