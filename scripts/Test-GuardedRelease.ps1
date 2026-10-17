param([Parameter(Mandatory)][string]$Artifact)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($name in @('platform-paths','platform-releases','platform-processes','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$name+'.ps1'))}
$layout=Get-PlatformLayout $root
$catalog=Read-ReleaseCatalog $layout
$runtime=Read-ReleaseDescriptor $layout $catalog.services.runtime.current
$worker=Read-ReleaseDescriptor $layout $catalog.services.worker.current
function Clone($x){return ($x|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable)}
$count=0
function Check([bool]$v,[string]$name){if(-not $v){throw $name};$script:count++}
function Reject([scriptblock]$f,[string]$name){$rejected=$false;try{& $f|Out-Null}catch{$rejected=$true};Check $rejected $name}
$runtime=Clone $runtime;$worker=Clone $worker
$facts=@{working_state_ready=$true;guarded_v6_runs=0;resumable_guarded_v6_runs=0};foreach($p in Get-SourceEngineProfiles){$facts[$p.runs]=0;$facts[$p.resumable]=0}
$proof=Join-Path (Split-Path -Parent $layout.state_root) ('evidence/guarded-release-'+[guid]::NewGuid().ToString('N'))
$pin=Join-Path (Split-Path -Parent $root) 'agent-os-worker/worker/guarded-harness-lock.json'
$metadata=Copy-PinnedSourceHarness $Artifact (Join-Path $proof 'guarded-harness') $pin (Get-GuardedEngineName)
$nextRuntime=Clone $runtime;$nextWorker=Clone $worker
$nextRuntime.guarded_execution=Clone $nextRuntime.final_execution
$nextRuntime.guarded_execution.engine=Get-GuardedEngineName;$nextRuntime.guarded_execution.tool_input_protocol=1
$nextWorker.guarded_execution=$metadata;$nextWorker.assets.guarded_harness='guarded-harness'
Assert-SourceExecutionPolicy $nextRuntime $worker (Get-FinalEngineName) $facts;Check $true 'Runtime first with final default'
Reject {Assert-SourceExecutionPolicy $runtime $nextWorker (Get-FinalEngineName) $facts} 'Worker requires Runtime capability'
Reject {Assert-SourceExecutionPolicy $nextRuntime $worker (Get-GuardedEngineName) $facts} 'Default requires capable Worker'
Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-GuardedEngineName) $facts;Check $true 'Matching pair'
Check ((Get-SubmissionEngine @{DEFAULT_RUN_ENGINE=(Get-GuardedEngineName)}) -ceq (Get-GuardedEngineName)) 'Default recognized'
foreach($role in @('runtime','worker')){
 $candidate=if($role -eq 'runtime'){$nextRuntime}else{$nextWorker}
 foreach($field in @('tool_input_protocol','model_receipt_protocol','final_output_protocol')){
  $bad=Clone $candidate;$null=$bad.guarded_execution.Remove($field)
  Reject {Assert-SourceExecutionDescriptor $bad} ($role+' requires '+$field)
 }
 $bad=Clone $candidate;$null=$bad.Remove('final_execution')
 Reject {Assert-SourceExecutionDescriptor $bad} ($role+' retains v5')
}
$facts.guarded_runs=2;$facts.resumable_guarded_runs=1
Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-FinalEngineName) $facts;Check $true 'Active v7 pair remains valid'
$facts.guarded_v6_runs=2;$facts.resumable_guarded_v6_runs=1
Reject {Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-GuardedEngineName) $facts} 'Resumable v6 blocks v7 replacement'
$facts.resumable_guarded_v6_runs=0
Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-GuardedEngineName) $facts;Check $true 'Terminal v6 permits v7 replacement'
foreach($key in @('guarded_runs','resumable_guarded_runs','guarded_v6_runs','resumable_guarded_v6_runs')){
 $bad=Clone $facts;$null=$bad.Remove($key)
 Reject {Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-FinalEngineName) $bad} ('Missing '+$key)
 foreach($value in @(-1,'0',0.5)){$bad=Clone $facts;$bad[$key]=$value;Reject {Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-FinalEngineName) $bad} ('Invalid '+$key)}
}
Reject {Copy-PinnedSourceHarness $Artifact (Join-Path $proof 'wrong-pin') (Join-Path (Split-Path -Parent $pin) 'final-harness-lock.json') (Get-FinalEngineName)} 'guarded pin cannot satisfy v5 pin'
$registry=Read-ReleaseDescriptor $layout $catalog.services.registry.current -Verify
$console=Read-ReleaseDescriptor $layout $catalog.services.control.current -Verify
$modelFacts=@{format=1;leaf_identity=$true;native_agents=$true;final_agents=$true;invalid_agents=$false}
Reject {Assert-ModelManagementPolicy $registry $console $nextRuntime $modelFacts $true (Get-GuardedEngineName)} 'Old Console blocked for guarded default'
Reject {Assert-ModelManagementPolicy $registry $console $nextRuntime $modelFacts $true (Get-FinalEngineName) -GuardedRuns $true} 'Retained guarded work blocks Console rollback'
$console=Clone $console;$console.model_management.guarded_transport='guarded-v7'
Assert-ModelManagementPolicy $registry $console $nextRuntime $modelFacts $true (Get-GuardedEngineName);Check $true 'Guarded Console allowed'
$console.model_management.guarded_transport='unknown'
Reject {Assert-ModelManagementDescriptor $console} 'Unknown guarded transport denied'
$report=@{passed=$true;checks=$count;scope='Real pinned artifact and installed release provenance; compatibility/default/rollback policy only, no service mutation';provider_calls=0}
Write-PlatformJson (Join-Path $proof 'result.json') $report
$report.proof=$proof;$report|ConvertTo-Json
