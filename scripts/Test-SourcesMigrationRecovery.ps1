param([Parameter(Mandatory)][string]$Binary,[string]$ChildLayout='',[string]$ChildPlan='',[string]$CrashPoint='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-recovery','platform-processes','platform-releases','platform-sources-migration')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$admin=Get-DatabaseConnection 'postgres://p2_fixture:fixture-only@127.0.0.1:55591/postgres?sslmode=disable'
if($ChildLayout){
 if(-not(Test-PathWithin $ChildLayout 'D:\workspace\agent-platform\local\evidence')){throw 'Invalid fixture layout'}
 $layout=Get-PlatformLayout $repo $ChildLayout;$plan=Read-RecoveryJson $ChildPlan;$connection=$admin.Clone();$connection.database=$plan.database
 $lock=Enter-PlatformMaintenance $layout.state_root
 try{
  $baseline=@{fingerprints=(Get-DatabaseFingerprints $layout.postgres_bin $connection)}
  $journal=New-OwnerMigrationJournal $layout sources-capture-v1 $baseline $lock
  $checkpoint={param($point) if($point -ceq $CrashPoint){Write-OwnerMigrationJson (Join-Path $layout.state_root 'fault-ready.json') @{point=$point;operation=$journal.id};Start-Sleep -Seconds 45;throw 'Parent did not inject the fault'}}
  $null=Invoke-SourcesMigrationMutation $layout $connection $plan $baseline $lock $checkpoint
  throw 'Crash point was not reached'
 }finally{$lock.Dispose()}
}
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('sources-migration-recovery-'+[guid]::NewGuid().ToString('N'))
New-ProtectedDirectory $proof
$rootLayout=Get-PlatformLayout $repo;$lock=$null;$child=$null;$layout=$null;$ownedJournal=$false
$checks=[Collections.Generic.List[string]]::new();$databases=[Collections.Generic.List[string]]::new();$roles=[Collections.Generic.List[string]]::new()
$result=@{passed=$false;checks_passed=$false;cleanup_passed=$false;provider_calls=0;github_actions_runs=0;formal_database_writes=0;scope='Actual Sources migration executable, PostgreSQL and coordinator process kill; fixture records, no live capture'}
$binaryHash=(Get-FileHash -LiteralPath $Binary).Hash.ToLowerInvariant()
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw ('Failed: '+$Name)};$checks.Add($Name)}
function New-Fixture([string]$Name,[switch]$Delay,[switch]$WithToolHub){
 $id=[guid]::NewGuid().ToString('N');$dbName='srcmig_'+$id;$role='srcrole_'+$id
 $null=Invoke-RecoverySQL $rootLayout.postgres_bin $admin ('CREATE DATABASE '+(Quote-PgIdentifier $dbName))
 $databases.Add($dbName)
 $null=Invoke-RecoverySQL $rootLayout.postgres_bin $admin ('CREATE ROLE '+(Quote-PgIdentifier $role)+' LOGIN')
 $roles.Add($role)
 $connection=$admin.Clone();$connection.database=$dbName
 $oldSchema=(& git -C (Join-Path (Split-Path -Parent $repo) 'agent-os-sources') show '82a90ce5b2ca620d15932b03aab9b4d3feb93bd0:sources/schema.sql') -join "`n"
 if($LASTEXITCODE -ne 0 -or $oldSchema -match 'extraction_version'){throw 'Legacy schema fixture not available'}
 $null=Invoke-RecoverySQL $rootLayout.postgres_bin $connection ("CREATE SCHEMA sources; SET search_path=sources;"+$oldSchema)
 $null=Invoke-RecoverySQL $rootLayout.postgres_bin $connection @'
INSERT INTO sources.source_blobs VALUES('fixture-hash',convert_to('旧记录保留：原始响应','UTF8'));
INSERT INTO sources.source_captures(id,url,hash,media_type,title,content,links,fetched_at) VALUES
('0123456789abcdef0123456789abcdef','https://example.invalid/evidence','fixture-hash','text/plain','历史资料','豆粕库存，旧记录。','[{"url":"https://example.invalid/reference","text":"原文"}]','2026-10-09T12:00:00Z');
CREATE TABLE public.unrelated_fixture(id int PRIMARY KEY, content text);
INSERT INTO public.unrelated_fixture VALUES(1,'foreign domain must remain unchanged');
'@
 if($Delay){$null=Invoke-RecoverySQL $rootLayout.postgres_bin $connection @'
CREATE FUNCTION public.migration_delay() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(4); END $$;
CREATE EVENT TRIGGER migration_delay ON ddl_command_start WHEN TAG IN ('ALTER TABLE') EXECUTE FUNCTION public.migration_delay();
'@}
 if($WithToolHub){
  $toolSchema=(& git -C (Join-Path (Split-Path -Parent $repo) 'agent-os-toolhub') show '98f8fecc5a139b3f1b0e4d76f4a11c9d8e0c0d07:toolhub/schema.sql') -join "`n"
  if($LASTEXITCODE -ne 0){throw 'ToolHub schema fixture not available'}
  $null=Invoke-RecoverySQL $rootLayout.postgres_bin $connection ('CREATE SCHEMA toolhub; SET search_path=toolhub;'+$toolSchema)
  $null=Invoke-RecoverySQL $rootLayout.postgres_bin $connection @'
INSERT INTO toolhub.assets(kind,id,revision,spec,definition_hash) VALUES('skill','fixture',1,'{}','fixture-hash');
INSERT INTO toolhub.asset_state(kind,id,revision) VALUES('skill','fixture',1);
INSERT INTO toolhub.asset_files(kind,id,revision,path,hash,body) VALUES('skill','fixture',1,'SKILL.md','fixture-hash',convert_to('original','UTF8'));
'@
 }
 $local=$rootLayout.Clone();$base=Join-Path $proof $Name
 foreach($key in @('state_root','config_root','log_root','release_root','harness_root','console_web_root','futures_web_root')){$local[$key]=Join-Path $base $key;$null=New-Item -ItemType Directory -Path $local[$key] -Force}
 $local.database_root='D:\workspace\agent-platform\local\evidence\p2-first-services-85be4f84e89f47ad935b6ed8882093c0\postgres'
 $local.layout_path=Join-Path $base 'layout.json';Write-PlatformJson $local.layout_path $local
 return @{layout=$local;connection=$connection;role=$role}
}
function Rehearse-Fixture($Fixture){
 $local=$Fixture.layout;$connection=$Fixture.connection
 $before=Get-DatabaseFingerprints $local.postgres_bin $connection
 $plan=@{format=1;operation='sources-capture-v1';binary=$Binary;binary_sha256=$binaryHash;sources_role=$Fixture.role;database=$connection.database;database_metadata=(Get-DatabaseMetadata $local.postgres_bin $connection);before_schema_sha256=(Get-DatabaseSchemaHash $local.postgres_bin $connection)}
 $journal=New-OwnerMigrationJournal $local sources-capture-v1 @{fingerprints=$before} $lock
 $script:layout=$local;$script:ownedJournal=$true
 $journal=Set-OwnerMigrationPhase $local $journal.id mutation_requested $lock
 Invoke-OwnedMigrationProcess $local $journal.id $Binary $binaryHash $connection $Fixture.role $lock
 Wait-SourcesMigrationQuiescent $local $connection
 $plan.after_schema_sha256=Get-DatabaseSchemaHash $local.postgres_bin $connection
 $null=Assert-SourcesMigrationContents $local $connection $before
 $journal=Set-OwnerMigrationPhase $local $journal.id validating $lock
 $journal=Set-OwnerMigrationPhase $local $journal.id validated $lock
 $null=Complete-OwnerMigrationJournal $local $journal.id $lock;$script:ownedJournal=$false
 Remove-OwnerMigrationCredentials $local $journal.id
 # Rewind only this synthetic column/ACL change to exercise the same real
 # command after parent death. Formal migrations never perform this down step.
 $null=Invoke-RecoverySQL $local.postgres_bin $connection ('ALTER TABLE sources.source_captures DROP COLUMN extraction_version; REVOKE USAGE ON SCHEMA sources FROM '+(Quote-PgIdentifier $Fixture.role)+'; REVOKE ALL ON sources.source_blobs,sources.source_captures FROM '+(Quote-PgIdentifier $Fixture.role))
 # PostgreSQL can retain explicit owner ACLs after REVOKE. The old state used
 # for fault injection is measured now, not asserted equal to a guessed dump.
 $plan.before_schema_sha256=Get-DatabaseSchemaHash $local.postgres_bin $connection
 $planPath=Join-Path $local.state_root 'plan.json';Write-OwnerMigrationJson $planPath $plan
 return @{plan=$plan;path=$planPath}
}
try{
 $lock=Enter-PlatformMaintenance $rootLayout.state_root;Assert-NoPendingOwnerMigration $rootLayout
 foreach($point in @('before_sql','owner_started','owner_exited_before_validation')){
  $fixture=New-Fixture $point -Delay:($point -ceq 'owner_started');$layout=$fixture.layout;$connection=$fixture.connection
  $rehearsal=Rehearse-Fixture $fixture;$plan=$rehearsal.plan
  $lock.Dispose();$lock=$null
  $child=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-Binary',('"'+$Binary+'"'),'-ChildLayout',('"'+$layout.layout_path+'"'),'-ChildPlan',('"'+$rehearsal.path+'"'),'-CrashPoint',$point) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $layout.log_root 'coordinator.stdout') -RedirectStandardError (Join-Path $layout.log_root 'coordinator.stderr')
  $marker=Join-Path $layout.state_root 'fault-ready.json';$deadline=[datetime]::UtcNow.AddSeconds(25)
  while(-not(Test-Path -LiteralPath $marker)){if($child.HasExited){throw 'Fixture coordinator exited before fault checkpoint'};if([datetime]::UtcNow -ge $deadline){throw 'Fixture checkpoint timed out'};Start-Sleep -Milliseconds 30}
  $ownedJournal=$true;$journal=Read-OwnerMigrationJournal $layout
  if($point -ceq 'owner_started'){
   $live=Read-OwnerProcess $layout $journal.id
   Check ((Get-PlatformInstanceState $live.entry $live.layout).members.Count -gt 0) 'migration_child_is_alive_before_parent_kill'
  }
  $child.Kill();Check ($child.WaitForExit(10000)) ($point+'_parent_actually_killed');$child.Dispose();$child=$null
  $lock=Enter-PlatformMaintenance $layout.state_root
  $journal=Read-OwnerMigrationJournal $layout
  $baseline=Read-ReleaseJson (Join-Path $layout.state_root ('migrations/'+$journal.id+'/baseline.json'))
  if($point -ceq 'owner_started'){
   $orphan=Read-OwnerProcess $layout $journal.id
   Check ((Get-PlatformInstanceState $orphan.entry $orphan.layout).members.Count -gt 0) 'owned_child_survives_parent_and_remains_discoverable'
  }
  $validation=Invoke-SourcesMigrationMutation $layout $connection $plan $baseline $lock
  Check ($validation.all_prior_fields_unchanged -and $validation.legacy_extraction_unrecorded) ($point+'_legacy_and_foreign_records_preserved')
  Check ($validation.executed -eq ($point -cne 'owner_exited_before_validation')) ($point+'_recovery_decides_replay_from_database')
  Check ($validation.schema_matches_rehearsal) ($point+'_exact_schema_and_permissions_match')
  $record=Read-OwnerProcess $layout $journal.id
  Check ((Get-PlatformInstanceState $record.entry $record.layout).members.Count -eq 0) ($point+'_no_owned_process_remains')
  $null=Complete-OwnerMigrationJournal $layout $journal.id $lock;$ownedJournal=$false
  Remove-OwnerMigrationCredentials $layout $journal.id
  Remove-OwnerMigrationCredentials $layout $journal.id
  Check (-not(Test-Path -LiteralPath $record.entry.launch_config)) ($point+'_plaintext_configuration_retired')
 }
 $fixture=New-Fixture 'refusals' -WithToolHub;$layout=$fixture.layout;$connection=$fixture.connection;$rehearsal=Rehearse-Fixture $fixture;$plan=$rehearsal.plan
 $saved=Get-DatabaseFingerprints $layout.postgres_bin $connection;$stable=Get-SourcesToolHubStableState $layout $connection
 $null=Invoke-RecoverySQL $layout.postgres_bin $connection "UPDATE toolhub.asset_state SET health='healthy',checked_at=now(),check_fence=check_fence+1; INSERT INTO toolhub.asset_audit(kind,id,revision,action,actor,details) VALUES('skill','fixture',1,'checked','fixture','{}');"
 Assert-SourcesBackupContents $layout $connection $saved (Get-DatabaseFingerprints $layout.postgres_bin $connection) $stable
 $checks.Add('only_health_probe_changes_allowed_since_backup')
 foreach($edit in @(
  @{name='skill_definition';sql="UPDATE toolhub.assets SET spec=jsonb_build_object('changed',true)";undo="UPDATE toolhub.assets SET spec='{}'"},
  @{name='skill_attachment';sql="UPDATE toolhub.asset_files SET body=convert_to('changed','UTF8')";undo="UPDATE toolhub.asset_files SET body=convert_to('original','UTF8')"},
  @{name='enabled_state';sql='UPDATE toolhub.asset_state SET enabled=true';undo='UPDATE toolhub.asset_state SET enabled=false'},
  @{name='operator_audit';sql="INSERT INTO toolhub.asset_audit(kind,id,revision,action,actor,details) VALUES('skill','fixture',1,'activation_changed','fixture','{}')";undo="DELETE FROM toolhub.asset_audit WHERE action='activation_changed'"}
 )){
  $null=Invoke-RecoverySQL $layout.postgres_bin $connection $edit.sql
  $refused=$false;try{Assert-SourcesBackupContents $layout $connection $saved (Get-DatabaseFingerprints $layout.postgres_bin $connection) $stable}catch{if($_.Exception.Message -notmatch 'changed since backup'){throw};$refused=$true}
  Check $refused ($edit.name+'_changed_since_backup_refused')
  $null=Invoke-RecoverySQL $layout.postgres_bin $connection $edit.undo
 }
 $baseline=@{fingerprints=(Get-DatabaseFingerprints $layout.postgres_bin $connection)}
 $journal=New-OwnerMigrationJournal $layout sources-capture-v1 @{mode='formal-sources-migration';restart_roles=@('sources','worker');restart_workers=2} $lock;$ownedJournal=$true
 $journal=Set-SourcesStoppedBaseline $layout $journal.id $baseline $lock
 $fixed=Read-SourcesStoppedBaseline $layout $journal
 Check ($fixed.fingerprints.Count -eq $baseline.fingerprints.Count) 'separate_stopped_baseline_bound_to_pre_stop_journal'
 $null=Invoke-RecoverySQL $layout.postgres_bin $connection 'ALTER TABLE public.unrelated_fixture ADD COLUMN unexpected int;'
 $refused=$false;try{$null=Invoke-SourcesMigrationMutation $layout $connection $plan $baseline $lock}catch{if($_.Exception.Message -notmatch 'neither recorded old state'){throw};$refused=$true}
 Check $refused 'unexpected_foreign_schema_refuses_replay_and_keeps_gate'
 Check (-not (Read-OwnerProcess $layout $journal.id)) 'schema_refusal_launches_no_migration_process'
 $null=Invoke-RecoverySQL $layout.postgres_bin $connection 'ALTER TABLE public.unrelated_fixture DROP COLUMN unexpected;'
 $changed=$plan.Clone();$changed.binary_sha256='0'*64
 $refused=$false;try{$null=Invoke-SourcesMigrationMutation $layout $connection $changed $baseline $lock}catch{if($_.Exception.Message -notmatch 'executable differs'){throw};$refused=$true}
 Check $refused 'changed_owner_executable_refused'
 $null=Invoke-SourcesMigrationMutation $layout $connection $plan $baseline $lock
 $null=Complete-OwnerMigrationJournal $layout $journal.id $lock;$ownedJournal=$false
 Remove-OwnerMigrationCredentials $layout $journal.id
 $env:PGHOSTADDR='192.0.2.1';$env:PGDATABASE='not_the_fixture'
 try{Check ((Invoke-RecoverySQL $layout.postgres_bin $connection 'SELECT current_database()').Trim() -ceq $connection.database) 'explicit_recovery_target_ignores_inherited_libpq_override'}finally{Remove-Item Env:PGHOSTADDR,Env:PGDATABASE -ErrorAction SilentlyContinue}
 $result.checks_passed=$true
}catch{$result.failure=$_.Exception.Message;$result.failure_stack=$_.ScriptStackTrace;throw}
finally{
 try{
  if($child -and -not $child.HasExited){$child.Kill();$null=$child.WaitForExit(10000)}
  if(-not $lock){$lock=Enter-PlatformMaintenance $rootLayout.state_root}
  $pending=Get-OwnerMigrationJournalPath $rootLayout
  if(Test-Path -LiteralPath $pending){
   $raw=Read-RecoveryJson $pending
   if(-not(Test-PathWithin $raw.state_root $proof)){throw 'Cannot clean a journal outside this fixture'}
   Stop-OwnerMigrationProcess $layout $raw.id
   Move-Item -LiteralPath $pending -Destination (Join-Path $proof 'retained-fixture-journal.json')
  }
  foreach($db in $databases){$null=Invoke-RecoverySQL $rootLayout.postgres_bin $admin ('DROP DATABASE '+(Quote-PgIdentifier $db)+' WITH (FORCE)')}
  foreach($role in $roles){$null=Invoke-RecoverySQL $rootLayout.postgres_bin $admin ('DROP ROLE '+(Quote-PgIdentifier $role))}
  $result.cleanup_passed=$true
 }catch{$result.cleanup_failure=$_.Exception.Message}
 finally{
  if($lock){$lock.Dispose()}
  $result.checks=@($checks);$result.passed=$result.checks_passed -and $result.cleanup_passed
  $result.binary_sha256=$binaryHash
  Write-OwnerMigrationJson (Join-Path $proof 'result.json') $result
  Write-Output ('Sources migration recovery evidence: '+$proof)
 }
}
if(-not $result.passed){throw 'Sources migration recovery did not pass'}
