param([Parameter(Mandatory)][string]$SourceArtifact,[Parameter(Mandatory)][string]$ResidentArtifact,[Parameter(Mandatory)][string]$BudgetArtifact,[Parameter(Mandatory)][string]$NativeArtifact,[Parameter(Mandatory)][string]$FinalArtifact)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-releases','platform-recovery')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('source-release-policy-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $proof
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Value,[string]$Name){if(-not $Value){throw $Name};$checks.Add($Name)}
function Reject([scriptblock]$Action,[string]$Name){$denied=$false;try{& $Action|Out-Null}catch{$denied=$true};Check $denied $Name}
function Clone($Value){return ($Value|ConvertTo-Json -Depth 12|ConvertFrom-Json -AsHashtable)}
$oldContract=@{http='agentos-http-v0.6-notes-lifecycle';data='execution-v0.6-notes-lifecycle';engines=@();tools=@('note_save')}
$newContract=Clone $oldContract;$newContract.http='agentos-http-v0.7-source-state-v1';$newContract.data='execution-v0.7-working-state'
$runtimeOld=@{role='runtime';assets=@{binary='runtime.exe'};contract=$oldContract}
$runtimeNew=@{role='runtime';assets=@{binary='runtime.exe'};contract=$newContract;source_execution=@{format=1;engine=(Get-SourceEngineName);execution_protocol='runtime-execution-v1';state_protocol='source-state-recovery-v1';submission_protocol='source-root-default-v1';preview_protocol='source-recovery-preview-v1'}}
$workerOld=@{role='worker';assets=@{binary='worker.exe';node='node.exe';harness='harness'};contract=$oldContract}
$facts=@{source_runs=0;resumable_source_runs=0;resident_runs=0;resumable_resident_runs=0;budget_runs=0;resumable_budget_runs=0;native_runs=0;resumable_native_runs=0;final_runs=0;resumable_final_runs=0;working_state_ready=$false}
$result=@{passed=$false;paid_model_calls=0;scope='Release compatibility policy, real pinned source artifact copy/export/restore, plus real PostgreSQL metadata probe on synthetic tables; no service activation';checks=@()}
$fixture='D:\workspace\agent-platform\local\evidence\p2-first-services-85be4f84e89f47ad935b6ed8882093c0\postgres'
$pg='D:\workspace\.tools\postgresql\pgsql\bin';$started=$false;$dbCreated=$false;$roleCreated=$false
$dbName='release_'+[guid]::NewGuid().ToString('N');$roleName='reader_'+[guid]::NewGuid().ToString('N')
$admin=@{host='127.0.0.1';port=55591;user='p2_fixture';password='fixture-only';database='postgres'}
try{
    Assert-SourceExecutionPolicy $runtimeOld $workerOld '' $facts;$checks.Add('historical_pair_without_state_migration_allowed')
    Check (Test-SourceRuntimeTransition $runtimeOld $runtimeNew) 'reviewed_additive_upgrade_recognized'
    Check (Test-SourceRuntimeTransition $runtimeNew $runtimeOld) 'reviewed_additive_downgrade_requires_live_policy'
    $future=Clone $runtimeNew;$future.contract.data='unreviewed-v8'
    Check (-not(Test-SourceRuntimeTransition $runtimeOld $future)) 'future_data_transition_denied'
    Reject {Assert-SourceExecutionPolicy $runtimeNew $workerOld '' $facts} 'missing_migration_denied'
    $facts.working_state_ready=$true
    Assert-SourceExecutionPolicy $runtimeNew $workerOld '' $facts;$checks.Add('new_runtime_can_precede_source_worker_when_default_is_historical')
    Reject {Assert-SourceExecutionPolicy $runtimeNew $workerOld (Get-SourceEngineName) $facts} 'source_default_without_capable_worker_denied'
    Reject {Assert-SourceExecutionPolicy $runtimeNew $workerOld 'unknown-engine' $facts} 'unknown_submission_default_denied'
    $pinFile=Join-Path (Split-Path -Parent $repo) 'agent-os-worker/worker/source-harness-lock.json'
    $destination=Join-Path $proof 'releases/bundles/worker/source-harness'
    $source=Copy-PinnedSourceHarness $SourceArtifact $destination $pinFile
    $workerNew=Clone $workerOld;$workerNew.assets.source_harness='bundles/worker/source-harness';$workerNew.source_execution=$source
    Assert-SourceExecutionPolicy $runtimeNew $workerNew (Get-SourceEngineName) $facts;$checks.Add('compatible_migrated_pair_accepts_source_default')
    Reject {Assert-SourceExecutionPolicy $runtimeOld $workerNew '' $facts} 'source_worker_requires_runtime_protocol'
    $facts.source_runs=2;$facts.resumable_source_runs=1
    Reject {Assert-SourceExecutionPolicy $runtimeNew $workerOld '' $facts} 'resumable_source_task_blocks_last_worker_rollback'
    $facts.resumable_source_runs=0
    Assert-SourceExecutionPolicy $runtimeNew $workerOld '' $facts;$checks.Add('terminal_history_allows_worker_downgrade_with_old_default')
    Reject {Assert-SourceExecutionPolicy $runtimeOld $workerOld '' $facts} 'retained_source_history_blocks_runtime_downgrade'
    $bad=Clone $workerNew;$null=$bad.Remove('source_execution')
    Reject {Assert-SourceExecutionDescriptor $bad} 'unattested_source_asset_denied'
    $bad=Clone $runtimeNew;$bad.source_execution.state_protocol='unknown'
    Reject {Assert-SourceExecutionDescriptor $bad} 'wrong_runtime_state_protocol_denied'
    $badFacts=Clone $facts;$badFacts.source_runs=-1
    Reject {Assert-SourceExecutionPolicy $runtimeNew $workerNew '' $badFacts} 'invalid_probe_facts_denied'
    $residentPin=Join-Path (Split-Path -Parent $repo) 'agent-os-worker/worker/resident-harness-lock.json'
    $resident=Copy-PinnedSourceHarness $ResidentArtifact (Join-Path $proof 'releases/bundles/worker/resident-harness') $residentPin (Get-ResidentEngineName)
    $runtimeDual=Clone $runtimeNew;$runtimeDual.resident_execution=Clone $runtimeNew.source_execution;$runtimeDual.resident_execution.engine=Get-ResidentEngineName
    $workerDual=Clone $workerNew;$workerDual.resident_execution=$resident;$workerDual.assets.resident_harness='bundles/worker/resident-harness'
    Assert-SourceExecutionPolicy $runtimeDual $workerNew (Get-SourceEngineName) $facts;$checks.Add('dual_runtime_can_precede_dual_worker_without_changing_v1_default')
    Reject {Assert-SourceExecutionPolicy $runtimeNew $workerDual (Get-SourceEngineName) $facts} 'dual_worker_cannot_precede_resident_runtime_even_with_v1_default'
    Reject {Assert-SourceExecutionPolicy $runtimeDual $workerNew (Get-ResidentEngineName) $facts} 'resident_default_requires_resident_worker'
    Assert-SourceExecutionPolicy $runtimeDual $workerDual (Get-ResidentEngineName) $facts;$checks.Add('verified_dual_pair_accepts_resident_default')
    $facts.resident_runs=1;$facts.resumable_resident_runs=1
    Reject {Assert-SourceExecutionPolicy $runtimeDual $workerNew (Get-SourceEngineName) $facts} 'resumable_resident_task_blocks_v1_worker_rollback'
    $facts.resumable_resident_runs=0
    Assert-SourceExecutionPolicy $runtimeDual $workerNew (Get-SourceEngineName) $facts;$checks.Add('terminal_resident_history_allows_worker_v1_rollback_with_v1_default')
    Reject {Assert-SourceExecutionPolicy $runtimeNew $workerNew (Get-SourceEngineName) $facts} 'terminal_resident_history_blocks_runtime_v1_rollback'
    $residentOnly=Clone $workerDual;$null=$residentOnly.Remove('source_execution');$null=$residentOnly.assets.Remove('source_harness')
    Assert-SourceExecutionPolicy $runtimeDual $residentOnly (Get-ResidentEngineName) $facts;$checks.Add('resident_only_worker_does_not_claim_unbundled_v1_engine')
    $facts.resumable_source_runs=1
    Reject {Assert-SourceExecutionPolicy $runtimeDual $residentOnly (Get-ResidentEngineName) $facts} 'resident_only_worker_refuses_resumable_v1_tasks'
    $facts.resumable_source_runs=0
    foreach($key in @('resident_runs','resumable_resident_runs')){
        $badFacts=Clone $facts;$null=$badFacts.Remove($key)
        Reject {Assert-SourceExecutionPolicy $runtimeNew $workerNew '' $badFacts} ('missing_'+$key+'_denied_even_for_v1_pair')
        foreach($value in @(-1,'0',0.5)){
            $badFacts=Clone $facts;$badFacts[$key]=$value
            Reject {Assert-SourceExecutionPolicy $runtimeDual $workerDual '' $badFacts} ('invalid_'+$key+'_'+[string]$value+'_denied')
        }
    }
    $badFacts=Clone $facts;$badFacts.resumable_resident_runs=2
    Reject {Assert-SourceExecutionPolicy $runtimeDual $workerDual '' $badFacts} 'resident_resumable_count_cannot_exceed_total'
    $bad=Clone $workerDual;$null=$bad.Remove('resident_execution')
    Reject {Assert-SourceExecutionDescriptor $bad} 'unattested_resident_asset_denied'
    $bad=Clone $workerDual;$null=$bad.assets.Remove('resident_harness')
    Reject {Assert-SourceExecutionDescriptor $bad} 'resident_capability_without_artifact_denied'
    $bad=Clone $workerDual;$bad.resident_execution.engine=Get-SourceEngineName
    Reject {Assert-SourceExecutionDescriptor $bad} 'resident_capability_cannot_alias_v1'
    $bad=Clone $runtimeDual;$bad.resident_execution.preview_protocol='unknown'
    Reject {Assert-SourceExecutionDescriptor $bad} 'resident_runtime_requires_management_protocols'
    Reject {Copy-PinnedSourceHarness $ResidentArtifact (Join-Path $proof 'wrong-v1') $pinFile} 'resident_bytes_cannot_satisfy_v1_pin'
    Reject {Copy-PinnedSourceHarness $SourceArtifact (Join-Path $proof 'wrong-v2') $residentPin (Get-ResidentEngineName)} 'v1_bytes_cannot_satisfy_resident_pin'
    $budgetPin=Join-Path (Split-Path -Parent $repo) 'agent-os-worker/worker/budget-harness-lock.json'
    $budget=Copy-PinnedSourceHarness $BudgetArtifact (Join-Path $proof 'releases/bundles/worker/budget-harness') $budgetPin (Get-BudgetEngineName)
    $runtimeTriple=Clone $runtimeDual;$runtimeTriple.budget_execution=Clone $runtimeNew.source_execution
    $runtimeTriple.budget_execution.engine=Get-BudgetEngineName;$runtimeTriple.budget_execution.model_receipt_protocol='budget-model-receipt-v1'
    $workerTriple=Clone $workerDual;$workerTriple.budget_execution=$budget;$workerTriple.assets.budget_harness='bundles/worker/budget-harness'
    Assert-SourceExecutionPolicy $runtimeTriple $workerDual (Get-SourceEngineName) $facts;$checks.Add('budget_runtime_can_precede_worker_with_v1_default')
    Reject {Assert-SourceExecutionPolicy $runtimeDual $workerTriple (Get-SourceEngineName) $facts} 'budget_worker_cannot_precede_runtime'
    Reject {Assert-SourceExecutionPolicy $runtimeTriple $workerDual (Get-BudgetEngineName) $facts} 'budget_default_requires_budget_worker'
    Assert-SourceExecutionPolicy $runtimeTriple $workerTriple (Get-BudgetEngineName) $facts;$checks.Add('triple_pair_accepts_budget_default')
    $facts.budget_runs=1;$facts.resumable_budget_runs=1
    Reject {Assert-SourceExecutionPolicy $runtimeTriple $workerDual (Get-SourceEngineName) $facts} 'resumable_budget_task_blocks_worker_downgrade'
    $facts.resumable_budget_runs=0
    Assert-SourceExecutionPolicy $runtimeTriple $workerDual (Get-SourceEngineName) $facts;$checks.Add('terminal_budget_history_allows_worker_downgrade_with_v1_default')
    Reject {Assert-SourceExecutionPolicy $runtimeDual $workerDual (Get-SourceEngineName) $facts} 'terminal_budget_history_blocks_runtime_downgrade'
    foreach($key in @('budget_runs','resumable_budget_runs')){
        $badFacts=Clone $facts;$null=$badFacts.Remove($key)
        Reject {Assert-SourceExecutionPolicy $runtimeNew $workerNew '' $badFacts} ('missing_'+$key+'_denied_even_for_v1_pair')
        foreach($value in @(-1,'0',0.5)){
            $badFacts=Clone $facts;$badFacts[$key]=$value
            Reject {Assert-SourceExecutionPolicy $runtimeTriple $workerTriple '' $badFacts} ('invalid_'+$key+'_'+[string]$value+'_denied')
        }
    }
    $badFacts=Clone $facts;$badFacts.resumable_budget_runs=2
    Reject {Assert-SourceExecutionPolicy $runtimeTriple $workerTriple '' $badFacts} 'budget_resumable_count_cannot_exceed_total'
    foreach($role in @('runtime','worker')){
        $bad=Clone $(if($role -eq 'runtime'){$runtimeTriple}else{$workerTriple});$null=$bad.budget_execution.Remove('model_receipt_protocol')
        Reject {Assert-SourceExecutionDescriptor $bad} ($role+'_budget_receipt_protocol_required')
    }
    $bad=Clone $runtimeTriple;$null=$bad.Remove('resident_execution')
    Reject {Assert-SourceExecutionDescriptor $bad} 'budget_runtime_retains_resident_protocol'
    $bad=Clone $workerTriple;$null=$bad.assets.Remove('budget_harness')
    Reject {Assert-SourceExecutionDescriptor $bad} 'budget_capability_requires_artifact'
    $bad=Clone $workerTriple;$null=$bad.Remove('budget_execution')
    Reject {Assert-SourceExecutionDescriptor $bad} 'budget_asset_requires_provenance'
    Reject {Copy-PinnedSourceHarness $ResidentArtifact (Join-Path $proof 'wrong-v3') $budgetPin (Get-BudgetEngineName)} 'resident_bytes_cannot_satisfy_budget_pin'
    $nativePin=Join-Path (Split-Path -Parent $repo) 'agent-os-worker/worker/native-harness-lock.json'
    $native=Copy-PinnedSourceHarness $NativeArtifact (Join-Path $proof 'releases/bundles/worker/native-harness') $nativePin (Get-NativeEngineName)
    $runtimeQuad=Clone $runtimeTriple;$runtimeQuad.native_execution=Clone $runtimeNew.source_execution
    $runtimeQuad.native_execution.engine=Get-NativeEngineName;$runtimeQuad.native_execution.model_receipt_protocol='native-model-receipt-v2'
    $workerQuad=Clone $workerTriple;$workerQuad.native_execution=$native;$workerQuad.assets.native_harness='bundles/worker/native-harness'
    Assert-SourceExecutionPolicy $runtimeQuad $workerTriple (Get-BudgetEngineName) $facts;$checks.Add('native_runtime_precedes_native_worker')
    Reject {Assert-SourceExecutionPolicy $runtimeTriple $workerQuad (Get-BudgetEngineName) $facts} 'native_worker_requires_native_runtime'
    Reject {Assert-SourceExecutionPolicy $runtimeQuad $workerTriple (Get-NativeEngineName) $facts} 'native_default_requires_native_worker'
    Assert-SourceExecutionPolicy $runtimeQuad $workerQuad (Get-NativeEngineName) $facts;$checks.Add('four_engine_pair_accepts_native_default')
    $nativeOnly=Clone $workerQuad;$null=$nativeOnly.Remove('budget_execution');$null=$nativeOnly.assets.Remove('budget_harness')
    Reject {Assert-SourceExecutionPolicy $runtimeQuad $nativeOnly (Get-NativeEngineName) $facts} 'native_default_retains_legacy_agent_execution'
    $facts.native_runs=1;$facts.resumable_native_runs=1
    Reject {Assert-SourceExecutionPolicy $runtimeQuad $workerTriple (Get-BudgetEngineName) $facts} 'resumable_native_task_blocks_worker_downgrade'
    $facts.resumable_native_runs=0
    Assert-SourceExecutionPolicy $runtimeQuad $workerTriple (Get-BudgetEngineName) $facts;$checks.Add('terminal_native_history_allows_worker_downgrade_with_legacy_default')
    Reject {Assert-SourceExecutionPolicy $runtimeTriple $workerTriple (Get-BudgetEngineName) $facts} 'retained_native_history_blocks_runtime_downgrade'
    foreach($role in @('runtime','worker')){
        $bad=Clone $(if($role -eq 'runtime'){$runtimeQuad}else{$workerQuad});$bad.native_execution.model_receipt_protocol='budget-model-receipt-v1'
        Reject {Assert-SourceExecutionDescriptor $bad} ($role+'_native_requires_protocol_2')
    }
    $bad=Clone $runtimeQuad;$null=$bad.Remove('budget_execution')
    Reject {Assert-SourceExecutionDescriptor $bad} 'native_runtime_retains_v3'
    $bad=Clone $workerQuad;$null=$bad.assets.Remove('native_harness')
    Reject {Assert-SourceExecutionDescriptor $bad} 'native_capability_requires_artifact'
    $bad=Clone $workerQuad;$null=$bad.Remove('native_execution')
    Reject {Assert-SourceExecutionDescriptor $bad} 'native_asset_requires_provenance'
    foreach($key in @('native_runs','resumable_native_runs')){
        $badFacts=Clone $facts;$null=$badFacts.Remove($key)
        Reject {Assert-SourceExecutionPolicy $runtimeQuad $workerQuad '' $badFacts} ('missing_'+$key+'_denied')
        foreach($value in @(-1,'0',0.5)){
            $badFacts=Clone $facts;$badFacts[$key]=$value
            Reject {Assert-SourceExecutionPolicy $runtimeQuad $workerQuad '' $badFacts} ('invalid_'+$key+'_'+[string]$value+'_denied')
        }
    }
    Reject {Copy-PinnedSourceHarness $BudgetArtifact (Join-Path $proof 'wrong-v4') $nativePin (Get-NativeEngineName)} 'budget_bytes_cannot_satisfy_native_pin'
    $finalPin=Join-Path (Split-Path -Parent $repo) 'agent-os-worker/worker/final-harness-lock.json'
    $final=Copy-PinnedSourceHarness $FinalArtifact (Join-Path $proof 'releases/bundles/worker/final-harness') $finalPin (Get-FinalEngineName)
    $runtimeFive=Clone $runtimeQuad;$runtimeFive.final_execution=Clone $runtimeQuad.native_execution
    $runtimeFive.final_execution.engine=Get-FinalEngineName;$runtimeFive.final_execution.final_output_protocol='receipt-field-v1';$runtimeFive.final_execution.continuation_protocol='final-model-continuation-v1'
    $workerFive=Clone $workerQuad;$workerFive.final_execution=$final;$workerFive.assets.final_harness='bundles/worker/final-harness'
    Assert-SourceExecutionPolicy $runtimeFive $workerQuad (Get-NativeEngineName) $facts;$checks.Add('final_Runtime_can_upgrade_first_with_native_default')
    Reject {Assert-SourceExecutionPolicy $runtimeQuad $workerFive (Get-NativeEngineName) $facts} 'final_Worker_requires_final_Runtime'
    Reject {Assert-SourceExecutionPolicy $runtimeFive $workerQuad (Get-FinalEngineName) $facts} 'final_default_requires_final_Worker'
    Assert-SourceExecutionPolicy $runtimeFive $workerFive (Get-FinalEngineName) $facts;$checks.Add('five_engine_pair_accepts_final_default')
    foreach($profile in @('budget','native')){
        $bad=Clone $workerFive;$null=$bad.Remove($profile+'_execution');$null=$bad.assets.Remove($profile+'_harness')
        Reject {Assert-SourceExecutionPolicy $runtimeFive $bad (Get-FinalEngineName) $facts} ('final_default_retains_'+$profile+'_fallback')
    }
    $facts.final_runs=2;$facts.resumable_final_runs=1
    Reject {Assert-SourceExecutionPolicy $runtimeFive $workerQuad (Get-NativeEngineName) $facts} 'resumable_final_task_blocks_Worker_rollback'
    $facts.resumable_final_runs=0
    Assert-SourceExecutionPolicy $runtimeFive $workerQuad (Get-NativeEngineName) $facts;$checks.Add('terminal_final_history_allows_Worker_rollback')
    Reject {Assert-SourceExecutionPolicy $runtimeQuad $workerQuad (Get-NativeEngineName) $facts} 'terminal_final_history_blocks_Runtime_rollback'
    foreach($field in @('model_receipt_protocol','final_output_protocol','continuation_protocol')){
        $bad=Clone $runtimeFive;$null=$bad.final_execution.Remove($field)
        Reject {Assert-SourceExecutionDescriptor $bad} ('final_Runtime_requires_'+$field)
    }
    foreach($profile in @('source','resident','budget','native')){
        $bad=Clone $runtimeFive;$null=$bad.Remove($profile+'_execution')
        Reject {Assert-SourceExecutionDescriptor $bad} ('final_Runtime_retains_'+$profile)
    }
    foreach($key in @('final_runs','resumable_final_runs')){
        $badFacts=Clone $facts;$null=$badFacts.Remove($key)
        Reject {Assert-SourceExecutionPolicy $runtimeQuad $workerQuad '' $badFacts} ('missing_'+$key+'_denied')
        foreach($value in @(-1,'0',0.5)){
            $badFacts=Clone $facts;$badFacts[$key]=$value
            Reject {Assert-SourceExecutionPolicy $runtimeFive $workerFive '' $badFacts} ('invalid_'+$key+'_'+[string]$value+'_denied')
        }
    }
    $badFacts=Clone $facts;$badFacts.resumable_final_runs=3
    Reject {Assert-SourceExecutionPolicy $runtimeFive $workerFive '' $badFacts} 'final_resumable_cannot_exceed_total'
    $bad=Clone $workerFive;$null=$bad.Remove('final_execution')
    Reject {Assert-SourceExecutionDescriptor $bad} 'final_asset_requires_provenance'
    $bad=Clone $workerFive;$null=$bad.assets.Remove('final_harness')
    Reject {Assert-SourceExecutionDescriptor $bad} 'final_capability_requires_artifact'
    Reject {Copy-PinnedSourceHarness $NativeArtifact (Join-Path $proof 'wrong-v5') $finalPin (Get-FinalEngineName)} 'native_bytes_cannot_satisfy_final_pin'
    $layout=@{release_root=(Join-Path $proof 'releases')}
    $launchRuntime=@{DATABASE_URL='postgres://runtime:fixture-only@127.0.0.1:55591/release?sslmode=disable&search_path=public';LISTEN='127.0.0.1:18094';SERVICE_PEERS=('{"worker":"'+[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('fixture-only')))+'"}')}
    $launch=@{DATABASE_URL='postgres://worker:fixture-only@127.0.0.1:55591/release?sslmode=disable&search_path=public';RUNTIME_URL='http://127.0.0.1:18094';SERVICE_TOKEN='fixture-only';AGENTOS_NODE=(Resolve-ReleasePath $layout.release_root $workerFive.assets.node)}
    foreach($p in (Get-SourceEngineProfiles)){$launch[$p.environment]=Join-Path (Resolve-ReleasePath $layout.release_root $workerFive.assets[$p.asset]) 'source-runner.mjs'}
    Assert-SourceWorkerLaunch $layout $workerFive $launch $launchRuntime;$checks.Add('actual_launch_binding_accepts_five_pinned_runners')
    foreach($key in @('DSH_FINAL_RUNNER','DSH_NATIVE_RUNNER','DSH_BUDGET_RUNNER','AGENTOS_NODE','RUNTIME_URL','DATABASE_URL','SERVICE_TOKEN')){
        $bad=Clone $launch;$bad[$key]='wrong-fixture-target'
        Reject {Assert-SourceWorkerLaunch $layout $workerFive $bad $launchRuntime} ('launch_rejects_wrong_'+$key)
    }
    foreach($relative in @('bundles/worker/worker.exe','bundles/worker/node.exe','bundles/worker/harness/runner.mjs','bundles/runtime/runtime.exe')){Write-PlatformText (Join-Path $layout.release_root $relative) 'synthetic non-executable inventory marker'}
    $workerAssets=@{binary='bundles/worker/worker.exe';node='bundles/worker/node.exe';harness='bundles/worker/harness';source_harness='bundles/worker/source-harness';resident_harness='bundles/worker/resident-harness';budget_harness='bundles/worker/budget-harness'}
    $workerAssets.native_harness='bundles/worker/native-harness'
    $workerAssets.final_harness='bundles/worker/final-harness'
    $workerRef=New-ReleaseDescriptor $layout worker $workerAssets $oldContract @{kind='synthetic';dirty=$false} $source $resident -BudgetExecution $budget -NativeExecution $native -FinalExecution $final
    $runtimeRef=New-ReleaseDescriptor $layout runtime @{binary='bundles/runtime/runtime.exe'} $newContract @{kind='synthetic';dirty=$false} $runtimeNew.source_execution $runtimeDual.resident_execution -BudgetExecution $runtimeTriple.budget_execution -NativeExecution $runtimeQuad.native_execution -FinalExecution $runtimeFive.final_execution
    Write-PlatformJson (Join-Path $layout.release_root 'current.json') @{format=2;generation=1;services=@{worker=@{current=$workerRef;previous=$null;pending=$null};runtime=@{current=$runtimeRef;previous=$null;pending=$null}}}
    $export=Export-ReleaseCatalog $layout (Join-Path $proof 'archive')
    $restored=Restore-ReleaseCatalog (Join-Path $proof 'archive') (Join-Path $proof 'restored')
    Check ($export.files -eq $restored.files -and $restored.references -eq 2) 'source_artifact_included_in_full_release_backup_restore'
    $restoredLayout=@{release_root=(Join-Path $proof 'restored')}
    $null=Read-ReleaseDescriptor $restoredLayout $workerRef -Verify
    $restoredRuntime=Read-ReleaseDescriptor $restoredLayout $runtimeRef -Verify
    Check ($restoredRuntime.resident_execution.engine -ceq (Get-ResidentEngineName)) 'resident_protocol_provenance_survives_release_restore'
    Check ($restoredRuntime.budget_execution.model_receipt_protocol -ceq 'budget-model-receipt-v1') 'budget_receipt_protocol_survives_release_restore'
    Check ($restoredRuntime.native_execution.model_receipt_protocol -ceq 'native-model-receipt-v2') 'native_receipt_protocol_survives_release_restore'
    Check ($restoredRuntime.final_execution.continuation_protocol -ceq 'final-model-continuation-v1' -and $restoredRuntime.final_execution.final_output_protocol -ceq 'receipt-field-v1') 'final_protocols_survive_release_restore'
    $finalRunner=Join-Path $restoredLayout.release_root 'bundles/worker/final-harness/source-runner.mjs'
    $finalBytes=[IO.File]::ReadAllBytes($finalRunner);Write-PlatformText $finalRunner 'tampered final fixture'
    Reject {Read-ReleaseDescriptor $restoredLayout $workerRef -Verify} 'restored_final_runner_tamper_denied'
    [IO.File]::WriteAllBytes($finalRunner,$finalBytes)
    $nativeRunner=Join-Path $restoredLayout.release_root 'bundles/worker/native-harness/source-runner.mjs'
    $nativeBytes=[IO.File]::ReadAllBytes($nativeRunner)
    Write-PlatformText $nativeRunner 'tampered native fixture'
    Reject {Read-ReleaseDescriptor $restoredLayout $workerRef -Verify} 'restored_native_runner_tamper_denied'
    [IO.File]::WriteAllBytes($nativeRunner,$nativeBytes)
    $budgetRunner=Join-Path $restoredLayout.release_root 'bundles/worker/budget-harness/source-runner.mjs'
    $budgetBytes=[IO.File]::ReadAllBytes($budgetRunner)
    Write-PlatformText $budgetRunner 'tampered budget fixture'
    Reject {Read-ReleaseDescriptor $restoredLayout $workerRef -Verify} 'restored_budget_runner_tamper_denied'
    [IO.File]::WriteAllBytes($budgetRunner,$budgetBytes)
    $residentRunner=Join-Path $restoredLayout.release_root 'bundles/worker/resident-harness/source-runner.mjs'
    $runnerBytes=[IO.File]::ReadAllBytes($residentRunner)
    Write-PlatformText $residentRunner 'tampered resident fixture'
    Reject {Read-ReleaseDescriptor $restoredLayout $workerRef -Verify} 'restored_resident_runner_tamper_denied'
    [IO.File]::WriteAllBytes($residentRunner,$runnerBytes)
    Write-PlatformText (Join-Path $restoredLayout.release_root 'bundles/worker/source-harness/source-runner.mjs') 'tampered fixture'
    Reject {Read-ReleaseDescriptor $restoredLayout $workerRef -Verify} 'restored_source_runner_tamper_denied'
    Reject {Copy-PinnedSourceHarness (Join-Path $restoredLayout.release_root 'bundles/worker/source-harness') (Join-Path $proof 'bad-copy') $pinFile} 'source_copy_refuses_manifest_content_mismatch'

    & (Join-Path $pg 'pg_ctl.exe') -D $fixture status *> (Join-Path $proof 'prior-status.log')
    if($LASTEXITCODE -ne 3){throw 'Disposable PostgreSQL must be stopped before this fixture'}
    $pgStart=Start-Process -FilePath (Join-Path $pg 'pg_ctl.exe') -ArgumentList @('-D',$fixture,'-l',(Join-Path $proof 'postgres.log'),'-o','"-h 127.0.0.1 -p 55591"','start','-w') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof 'start.out.log') -RedirectStandardError (Join-Path $proof 'start.err.log')
    if(-not $pgStart.WaitForExit(15000) -or $pgStart.ExitCode){throw 'Fixture PostgreSQL startup failed'};$started=$true
    $null=Invoke-RecoverySQL $pg $admin ('CREATE DATABASE '+(Quote-PgIdentifier $dbName));$dbCreated=$true
    $null=Invoke-RecoverySQL $pg $admin ('CREATE ROLE '+(Quote-PgIdentifier $roleName)+' LOGIN');$roleCreated=$true
    $dbAdmin=Clone $admin;$dbAdmin.database=$dbName
    $null=Invoke-RecoverySQL $pg $dbAdmin ("CREATE TABLE runs(id text PRIMARY KEY,engine text,status text); GRANT SELECT ON runs TO "+(Quote-PgIdentifier $roleName)+"; INSERT INTO runs VALUES('one','dsh-source-639ed015-state-v1','completed'),('two','dsh-source-639ed015-state-v1','failed'),('three','dsh-source-639ed015-state-v1','cancelled'),('old','dsh-0.2.0-rc.2-evidence-v1','queued');")
    $probeLayout=@{postgres_bin=$pg;config_root=(Join-Path $proof 'config')}
    Write-PlatformJson (Join-Path $probeLayout.config_root 'services/runtime.json') @{DATABASE_URL=('postgres://'+$roleName+':fixture-only@127.0.0.1:55591/'+$dbName+'?sslmode=disable')}
    $actual=Get-SourceExecutionFacts $probeLayout
    Check ($actual.source_runs -eq 3 -and $actual.resumable_source_runs -eq 1 -and -not $actual.working_state_ready) 'restricted_sql_probe_counts_failed_as_resumable_and_detects_missing_table'
    Check ($actual.resident_runs -eq 0 -and $actual.resumable_resident_runs -eq 0) 'restricted_probe_explicitly_reports_absent_resident_history'
    Check ($actual.budget_runs -eq 0 -and $actual.resumable_budget_runs -eq 0) 'restricted_probe_explicitly_reports_absent_budget_history'
    $null=Invoke-RecoverySQL $pg $dbAdmin "INSERT INTO runs VALUES('v2-done','dsh-source-639ed015-resident-v2','completed'),('v2-cancel','dsh-source-639ed015-resident-v2','cancelled'),('v2-fail','dsh-source-639ed015-resident-v2','failed'),('v2-unknown','dsh-source-639ed015-resident-v2','waiting_unknown')"
    $actual=Get-SourceExecutionFacts $probeLayout
    Check ($actual.source_runs -eq 3 -and $actual.resumable_source_runs -eq 1 -and $actual.resident_runs -eq 4 -and $actual.resumable_resident_runs -eq 2) 'restricted_probe_separates_versions_and_preserves_failed_unknown_recoverability'
    $null=Invoke-RecoverySQL $pg $dbAdmin "INSERT INTO runs VALUES('v3-done','dsh-source-639ed015-budget-v3','completed'),('v3-cancel','dsh-source-639ed015-budget-v3','cancelled'),('v3-fail','dsh-source-639ed015-budget-v3','failed'),('v3-unknown','dsh-source-639ed015-budget-v3','waiting_unknown')"
    $actual=Get-SourceExecutionFacts $probeLayout
    Check ($actual.budget_runs -eq 4 -and $actual.resumable_budget_runs -eq 2 -and $actual.resident_runs -eq 4) 'restricted_probe_counts_budget_failed_unknown_as_resumable'
    Check ($actual.native_runs -eq 0 -and $actual.resumable_native_runs -eq 0) 'restricted_probe_reports_absent_native_history'
    $null=Invoke-RecoverySQL $pg $dbAdmin "INSERT INTO runs VALUES('v4-done','dsh-source-639ed015-native-v4','completed'),('v4-cancel','dsh-source-639ed015-native-v4','cancelled'),('v4-fail','dsh-source-639ed015-native-v4','failed'),('v4-unknown','dsh-source-639ed015-native-v4','waiting_unknown')"
    $actual=Get-SourceExecutionFacts $probeLayout
    Check ($actual.native_runs -eq 4 -and $actual.resumable_native_runs -eq 2 -and $actual.budget_runs -eq 4) 'restricted_probe_counts_native_failed_unknown_as_resumable'
    Check ($actual.final_runs -eq 0 -and $actual.resumable_final_runs -eq 0) 'restricted_probe_reports_absent_final_history'
    $null=Invoke-RecoverySQL $pg $dbAdmin "INSERT INTO runs VALUES('v5-done','dsh-source-639ed015-final-v5','completed'),('v5-cancel','dsh-source-639ed015-final-v5','cancelled'),('v5-fail','dsh-source-639ed015-final-v5','failed'),('v5-unknown','dsh-source-639ed015-final-v5','waiting_unknown')"
    $actual=Get-SourceExecutionFacts $probeLayout
    Check ($actual.final_runs -eq 4 -and $actual.resumable_final_runs -eq 2 -and $actual.native_runs -eq 4) 'restricted_probe_counts_final_failed_unknown_as_resumable'
    $null=Invoke-RecoverySQL $pg $dbAdmin ('CREATE TABLE run_working_states(revision bigint); GRANT SELECT ON run_working_states TO '+(Quote-PgIdentifier $roleName))
    Check (-not (Get-SourceExecutionFacts $probeLayout).working_state_ready) 'read_only_state_grant_is_not_migration_readiness'
    $null=Invoke-RecoverySQL $pg $dbAdmin ('GRANT INSERT ON run_working_states TO '+(Quote-PgIdentifier $roleName))
    Check (-not (Get-SourceExecutionFacts $probeLayout).working_state_ready) 'incomplete_table_with_read_write_grants_denied'
    $null=Invoke-RecoverySQL $pg $dbAdmin 'DROP TABLE run_working_states'
    $migration=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $repo) 'agent-os-runtime/runtime/working_state.sql') -Raw
    $null=Invoke-RecoverySQL $pg $dbAdmin ($migration+' GRANT SELECT,INSERT ON run_working_states TO '+(Quote-PgIdentifier $roleName))
    $actual=Get-SourceExecutionFacts $probeLayout
    Check $actual.working_state_ready 'owner_migration_columns_types_and_unique_keys_verified'
    $null=Invoke-RecoverySQL $pg $dbAdmin 'ALTER TABLE run_working_states DROP CONSTRAINT run_working_states_run_id_operation_id_key'
    Check (-not (Get-SourceExecutionFacts $probeLayout).working_state_ready) 'missing_idempotency_unique_key_denied'
    $null=Invoke-RecoverySQL $pg $dbAdmin 'ALTER TABLE run_working_states ADD UNIQUE(run_id,operation_id); ALTER TABLE run_working_states ALTER COLUMN receipt DROP NOT NULL'
    Check (-not (Get-SourceExecutionFacts $probeLayout).working_state_ready) 'nullable_receipt_column_denied'
    $null=Invoke-RecoverySQL $pg $dbAdmin 'ALTER TABLE run_working_states ALTER COLUMN receipt SET NOT NULL; ALTER TABLE run_working_states ALTER COLUMN body TYPE text'
    Check (-not (Get-SourceExecutionFacts $probeLayout).working_state_ready) 'wrong_state_body_type_denied'
    $null=Invoke-RecoverySQL $pg $dbAdmin ('DROP TABLE run_working_states; '+$migration+' GRANT SELECT,INSERT ON run_working_states TO '+(Quote-PgIdentifier $roleName))
    Check (Get-SourceExecutionFacts $probeLayout).working_state_ready 'restored_owner_schema_is_ready'
    $result.probe=$actual;$result.passed=$true
}catch{$result.failure=$_.Exception.Message;throw}
finally{
    if($started){
        try{if($dbCreated){$null=Invoke-RecoverySQL $pg $admin ('DROP DATABASE '+(Quote-PgIdentifier $dbName))};if($roleCreated){$null=Invoke-RecoverySQL $pg $admin ('DROP ROLE '+(Quote-PgIdentifier $roleName))}}
        catch{$result.passed=$false;$result.cleanup_failure='Disposable database or role cleanup failed'}
        & (Join-Path $pg 'pg_ctl.exe') -D $fixture stop -m fast -w *> (Join-Path $proof 'stop.log');$result.fixture_stop_exit=$LASTEXITCODE
        if($LASTEXITCODE){$result.passed=$false}
    }
    $result.checks=@($checks.ToArray());Write-PlatformJson (Join-Path $proof 'result.json') $result
    Write-Output ('Source release policy evidence: '+$proof)
}
if(-not $result.passed){throw 'Source release policy verification incomplete'}
