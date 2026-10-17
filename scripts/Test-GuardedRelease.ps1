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
$facts=@{working_state_ready=$true};foreach($p in Get-SourceEngineProfiles){$facts[$p.runs]=0;$facts[$p.resumable]=0}
$proof=Join-Path (Split-Path -Parent $layout.state_root) ('evidence/guarded-release-'+[guid]::NewGuid().ToString('N'))
$v6Artifact=Resolve-ReleasePath $layout.release_root $worker.assets.guarded_harness
$v7Pin=Join-Path (Split-Path -Parent $root) 'agent-os-worker/worker/guarded-harness-lock.json'
$v6Pin=Join-Path (Split-Path -Parent $root) 'agent-os-worker/worker/guarded-v6-harness-lock.json'
$metadataV7=Copy-PinnedSourceHarness $Artifact (Join-Path $proof 'guarded-harness') $v7Pin (Get-GuardedEngineName)
$metadataV6=Copy-PinnedSourceHarness $v6Artifact (Join-Path $proof 'guarded-v6-harness') $v6Pin (Get-HistoricalGuardedEngineName)
$nextRuntime=Clone $runtime;$nextWorker=Clone $worker
$nextRuntime.guarded_execution=Clone $nextRuntime.final_execution
$nextRuntime.guarded_execution.engine=Get-GuardedEngineName;$nextRuntime.guarded_execution.tool_input_protocol=1
$nextRuntime.guarded_v6_execution=Clone $nextRuntime.final_execution
$nextRuntime.guarded_v6_execution.engine=Get-HistoricalGuardedEngineName;$nextRuntime.guarded_v6_execution.tool_input_protocol=1
$nextWorker.guarded_execution=$metadataV7;$nextWorker.assets.guarded_harness='guarded-harness'
$nextWorker.guarded_v6_execution=$metadataV6;$nextWorker.assets.guarded_v6_harness='guarded-v6-harness'
Assert-SourceExecutionPolicy $nextRuntime $worker (Get-FinalEngineName) $facts;Check $true 'Runtime first with final default and legacy v6 metadata'
Reject {Assert-SourceExecutionPolicy $runtime $nextWorker (Get-FinalEngineName) $facts} 'Worker requires Runtime capability'
Reject {Assert-SourceExecutionPolicy $nextRuntime $worker (Get-GuardedEngineName) $facts} 'v7 default requires v7 Worker'
Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-GuardedEngineName) $facts;Check $true 'Matching dual pair'
Check ((Get-SubmissionEngine @{DEFAULT_RUN_ENGINE=(Get-GuardedEngineName)}) -ceq (Get-GuardedEngineName)) 'v7 default recognized'
foreach($role in @('runtime','worker')){
 $candidate=if($role -eq 'runtime'){$nextRuntime}else{$nextWorker}
 foreach($field in @('tool_input_protocol','model_receipt_protocol','final_output_protocol')){
  $bad=Clone $candidate;$null=$bad.guarded_execution.Remove($field)
  Reject {Assert-SourceExecutionDescriptor $bad} ($role+' v7 requires '+$field)
  $bad=Clone $candidate;$null=$bad.guarded_v6_execution.Remove($field)
  Reject {Assert-SourceExecutionDescriptor $bad} ($role+' v6 requires '+$field)
 }
 $bad=Clone $candidate;$null=$bad.Remove('final_execution')
 Reject {Assert-SourceExecutionDescriptor $bad} ($role+' retains v5')
}
$facts.guarded_v6_runs=1;$facts.resumable_guarded_v6_runs=1
Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-GuardedEngineName) $facts;Check $true 'Resumable v6 is recoverable in dual pair'
$withoutV6=Clone $nextWorker;$null=$withoutV6.Remove('guarded_v6_execution');$null=$withoutV6.assets.Remove('guarded_v6_harness')
Reject {Assert-SourceExecutionPolicy $nextRuntime $withoutV6 (Get-GuardedEngineName) $facts} 'Resumable v6 requires packaged v6 Worker'
foreach($key in @('guarded_runs','resumable_guarded_runs','guarded_v6_runs','resumable_guarded_v6_runs')){
 $bad=Clone $facts;$null=$bad.Remove($key)
 Reject {Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-GuardedEngineName) $bad} ('Missing '+$key)
 foreach($value in @(-1,'0',0.5)){$bad=Clone $facts;$bad[$key]=$value;Reject {Assert-SourceExecutionPolicy $nextRuntime $nextWorker (Get-GuardedEngineName) $bad} ('Invalid '+$key)}
}
Reject {Copy-PinnedSourceHarness $Artifact (Join-Path $proof 'wrong-pin') (Join-Path (Split-Path -Parent $v7Pin) 'final-harness-lock.json') (Get-FinalEngineName)} 'guarded pin cannot satisfy v5 pin'
$registry=Read-ReleaseDescriptor $layout $catalog.services.registry.current -Verify
$console=Read-ReleaseDescriptor $layout $catalog.services.control.current -Verify
$modelFacts=@{format=1;leaf_identity=$true;native_agents=$true;final_agents=$true;invalid_agents=$false}
Reject {Assert-ModelManagementPolicy $registry $console $nextRuntime $modelFacts $true (Get-GuardedEngineName)} 'Old Console blocked for guarded default'
Reject {Assert-ModelManagementPolicy $registry $console $nextRuntime $modelFacts $true (Get-FinalEngineName) -GuardedRuns $true} 'Retained guarded work blocks Console rollback'
$console=Clone $console;$console.model_management.guarded_transport='guarded-v7'
Assert-ModelManagementPolicy $registry $console $nextRuntime $modelFacts $true (Get-GuardedEngineName);Check $true 'Guarded v7 Console allowed'
$console.model_management.guarded_transport='unknown'
Reject {Assert-ModelManagementDescriptor $console} 'Unknown guarded transport denied'
$report=@{passed=$true;checks=$count;scope='Dual guarded artifacts and installed release provenance; compatibility/default/rollback policy only, no service mutation';provider_calls=0}
Write-PlatformJson (Join-Path $proof 'result.json') $report
$report.proof=$proof;$report|ConvertTo-Json
