param([Parameter(Mandatory)][string]$Evidence)
$ErrorActionPreference='Stop'
if(-not ('AgentOS.Maintenance.WindowsJob' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'lib/windows-job.cs')}
$observed=@{}
$output=Join-Path $Evidence 'process-samples.jsonl'
$stream=[IO.StreamWriter]::new($output,$false,[Text.UTF8Encoding]::new($false))
try {
 while(-not(Test-Path -LiteralPath (Join-Path $Evidence 'sampler.stop'))){
  if(Test-Path -LiteralPath (Join-Path $Evidence 'processes.json')){
   try{$roots=Get-Content -LiteralPath (Join-Path $Evidence 'processes.json') -Raw|ConvertFrom-Json -AsHashtable;$phase=Get-Content -LiteralPath (Join-Path $Evidence 'phase.json') -Raw|ConvertFrom-Json}catch{Start-Sleep -Milliseconds 100;continue}
   $job=Get-Content -LiteralPath (Join-Path $Evidence 'job.json') -Raw|ConvertFrom-Json
   $members=@([AgentOS.Maintenance.WindowsJob]::Members($job.name))
   foreach($name in $roots.Keys){$processId=[int]$roots[$name];if($processId -in $members -and -not $observed.ContainsKey($processId)){$p=Get-Process -Id $processId -ErrorAction SilentlyContinue;if($p){$expected=if($name -like 'joint-worker-*'){$env:JOINT_WORKER}else{[Environment]::GetEnvironmentVariable('JOINT_'+$name.ToUpperInvariant())};if($p.Path -ne $expected){throw 'Measured executable identity mismatch'};$observed[$processId]=@{name=$name;start=$p.StartTime.ToUniversalTime().Ticks;parent=0;binary=$p.Path}}}}
   $children=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {$_.ProcessId -in $members -and $_.ExecutablePath -eq $env:JOINT_NODE})
   foreach($child in $children){$processId=[int]$child.ProcessId;if(-not $observed.ContainsKey($processId)){$p=Get-Process -Id $processId -ErrorAction SilentlyContinue;if($p){$observed[$processId]=@{name='node';parent=[int]$child.ParentProcessId;start=$p.StartTime.ToUniversalTime().Ticks}}}}
   $rows=@(foreach($processId in $observed.Keys){$p=Get-Process -Id $processId -ErrorAction SilentlyContinue;if($p -and $p.StartTime.ToUniversalTime().Ticks -eq $observed[$processId].start){@{pid=$processId;role=$observed[$processId].name;parent=$observed[$processId].parent;working_set_bytes=$p.WorkingSet64;private_bytes=$p.PrivateMemorySize64;cpu_seconds=$p.TotalProcessorTime.TotalSeconds;started_ticks=$observed[$processId].start}}})
   $stream.WriteLine((@{at=[datetime]::UtcNow.ToString('o');phase=$phase.phase;processes=$rows}|ConvertTo-Json -Depth 5 -Compress));$stream.Flush()
  }
  Start-Sleep -Milliseconds 250
 }
}finally{$stream.Dispose();$ids=@{};foreach($key in $observed.Keys){$ids[[string]$key]=$observed[$key]};$ids|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $Evidence 'observed-processes.json')}
