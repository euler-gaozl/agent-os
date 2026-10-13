param([Parameter(Mandatory)][string]$SourceArtifact)
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
$facts=@{source_runs=0;resumable_source_runs=0;working_state_ready=$false}
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
    $layout=@{release_root=(Join-Path $proof 'releases')}
    foreach($relative in @('bundles/worker/worker.exe','bundles/worker/node.exe','bundles/worker/harness/runner.mjs','bundles/runtime/runtime.exe')){Write-PlatformText (Join-Path $layout.release_root $relative) 'synthetic non-executable inventory marker'}
    $workerAssets=@{binary='bundles/worker/worker.exe';node='bundles/worker/node.exe';harness='bundles/worker/harness';source_harness='bundles/worker/source-harness'}
    $workerRef=New-ReleaseDescriptor $layout worker $workerAssets $oldContract @{kind='synthetic';dirty=$false} $source
    $runtimeRef=New-ReleaseDescriptor $layout runtime @{binary='bundles/runtime/runtime.exe'} $newContract @{kind='synthetic';dirty=$false} $runtimeNew.source_execution
    Write-PlatformJson (Join-Path $layout.release_root 'current.json') @{format=2;generation=1;services=@{worker=@{current=$workerRef;previous=$null;pending=$null};runtime=@{current=$runtimeRef;previous=$null;pending=$null}}}
    $export=Export-ReleaseCatalog $layout (Join-Path $proof 'archive')
    $restored=Restore-ReleaseCatalog (Join-Path $proof 'archive') (Join-Path $proof 'restored')
    Check ($export.files -eq $restored.files -and $restored.references -eq 2) 'source_artifact_included_in_full_release_backup_restore'
    $restoredLayout=@{release_root=(Join-Path $proof 'restored')}
    $null=Read-ReleaseDescriptor $restoredLayout $workerRef -Verify
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
