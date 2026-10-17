param([Parameter(Mandatory)][string]$BackupDirectory,[Parameter(Mandatory)][string]$RestoreReport,[string]$LayoutPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-recovery','platform-processes','platform-releases','platform-runtime-continuation-migration','service-sources')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$layout=Get-PlatformLayout $repo $LayoutPath;$lock=Enter-PlatformMaintenance $layout.state_root
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('runtime-continuation-plan-'+[guid]::NewGuid().ToString('N'))
$plan=@{format=1;operation='runtime-continuation-v1';passed=$false;isolated_cluster_stopped=$false;provider_calls=0;github_actions_runs=0;formal_database_writes=0}
$server=$null;$testLayout=$null;$journal=$null;$ownedJournal=$false;$admin=$null;$savedEnv=@{}
try{
 New-ProtectedDirectory $proof;Assert-NoPendingOwnerMigration $layout
 $BackupDirectory=[IO.Path]::GetFullPath($BackupDirectory);$RestoreReport=[IO.Path]::GetFullPath($RestoreReport)
 $backup=Read-SourcesVerifiedBackup $BackupDirectory $RestoreReport;$manifest=$backup.manifest
 $plain=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $BackupDirectory 'configuration.dpapi')))
 try{$vault=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($plain,0,$plain.Length)}
 $configs=@{}
 foreach($relative in @('dev.json','services/runtime.json','services/worker.json')){
  $bytes=[Convert]::FromBase64String($vault.configuration_files[$relative])
  try{$configs[$relative]=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($bytes,0,$bytes.Length)}
 };$vault=$null
 $admin=Get-DatabaseConnection $configs['dev.json'].DATABASE_URL;$consumer=Get-ExecutionAccessConnection $configs['services/runtime.json'];$worker=Get-ExecutionAccessConnection $configs['services/worker.json']
 if($consumer.schema -cne 'public' -or $worker.schema -cne 'public' -or $consumer.database -cne $worker.database -or $consumer.user -ceq $worker.user){throw 'Runtime continuation application schema differs.'}
 $owner=Get-SelectedServiceSource $repo runtime (Get-ServiceReleaseContract $repo runtime)
 $binary=Join-Path $proof 'runtime-migrate.exe';$go='D:\workspace\.tools\go\bin\go.exe'
 $buildEnv=@{GOWORK='off';GOPROXY='off';GOTOOLCHAIN='local';GOENV='off';GOFLAGS='';GOPATH='D:\workspace\.tools\gopath';GOCACHE='D:\workspace\.tools\gocache';TEMP='D:\workspace\agent-platform\local\tmp';TMP='D:\workspace\agent-platform\local\tmp'}
 foreach($key in $buildEnv.Keys){$savedEnv[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$buildEnv[$key])}
 & $go -C $owner.root build -mod=vendor -trimpath -o $binary ./cmd/migrate
 if($LASTEXITCODE){throw 'Runtime continuation owner migration build failed.'}
 $build=(& $go version -m -json $binary)|ConvertFrom-Json -AsHashtable
 $settings=@{};foreach($setting in $build.Settings){$settings[$setting.Key]=$setting.Value}
 if($build.Main.Path -cne 'github.com/euler-gaozl/agent-os-runtime' -or $build.Path -cne 'github.com/euler-gaozl/agent-os-runtime/cmd/migrate' -or $settings['vcs.revision'] -cne $owner.commit -or $settings['vcs.modified'] -cne 'false'){throw 'Runtime continuation migration build provenance differs.'}
 $null=Get-SelectedServiceSource $repo runtime (Get-ServiceReleaseContract $repo runtime)
 $data=Join-Path (Split-Path -Parent $RestoreReport) 'postgres';Assert-ReleasePhysicalPath 'D:\workspace\agent-platform\local\restore-checks' $data
 if(Test-Path -LiteralPath (Join-Path $data 'postmaster.pid')){throw 'Restored cluster must be stopped before rehearsal.'}
 $testLayout=$layout.Clone();$testLayout.database_root=$data;$testLayout.state_root=Join-Path $proof 'state'
 $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
 $server=Start-Process -FilePath (Join-Path $layout.postgres_bin 'postgres.exe') -ArgumentList @('-D',('"'+$data+'"'),'-h','127.0.0.1','-p',[string]$port) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof 'postgres.stdout.log') -RedirectStandardError (Join-Path $proof 'postgres.stderr.log')
 $admin.host='127.0.0.1';$admin.port=$port;$admin.database=$consumer.database
 $ready=$false
 for($i=0;$i -lt 60;$i++){if($server.HasExited){throw 'Rehearsal database exited'};try{Assert-SourcesMigrationDatabase $testLayout $admin;$ready=$true;break}catch{Start-Sleep -Milliseconds 200}}
 if(-not $ready){throw 'Rehearsal database identity could not be confirmed.'}
 $saved=@($manifest.databases|Where-Object name -CEQ $admin.database)
 if($saved.Count -ne 1 -or (Get-DatabaseSchemaHash $layout.postgres_bin $admin) -cne $saved[0].schema_sha256 -or (Get-DatabaseMetadata $layout.postgres_bin $admin) -cne $saved[0].metadata){throw 'Restored schema differs from backup.'}
 Wait-SourcesMigrationQuiescent $testLayout $admin
 $before=Get-DatabaseFingerprints $layout.postgres_bin $admin
 if($before.Count -ne $saved[0].tables.Count){throw 'Restored relation count differs.'}
 for($i=0;$i -lt $before.Count;$i++){foreach($key in @('schema','table','kind','rows','sha256')){if([string]$before[$i].$key -cne [string]$saved[0].tables[$i][$key]){throw 'Restored data differs from backup.'}}}
 $foreign=Get-RuntimeContinuationPriorSchemaHash $testLayout $admin;$stableToolHub=Get-SourcesToolHubStableState $testLayout $admin
 $hash=(Get-FileHash -LiteralPath $binary).Hash.ToLowerInvariant();$afterHash=''
 foreach($attempt in 1..2){
  $journal=New-OwnerMigrationJournal $testLayout runtime-continuation-v1 @{mode='isolated-runtime-continuation-rehearsal';layout=$testLayout;backup=$BackupDirectory;restore=$RestoreReport;fingerprints=$before;port=$port} $lock;$ownedJournal=$true
  $journal=Set-OwnerMigrationPhase $testLayout $journal.id mutation_requested $lock
  Invoke-OwnedMigrationProcess $testLayout $journal.id $binary $hash $admin $consumer.user $lock -WorkerRole $worker.user
  Wait-SourcesMigrationQuiescent $testLayout $admin
  $after=Assert-RuntimeContinuationMigrationContents $testLayout $admin $before $consumer.user $worker.user
  if((Get-RuntimeContinuationPriorSchemaHash $testLayout $admin) -cne $foreign -or (Get-DatabaseMetadata $layout.postgres_bin $admin) -cne $saved[0].metadata){throw 'Runtime continuation owner changed a foreign schema or database settings.'}
  $actualHash=Get-DatabaseSchemaHash $layout.postgres_bin $admin
  if(($attempt -eq 1 -and $actualHash -ceq $saved[0].schema_sha256) -or ($attempt -eq 2 -and $actualHash -cne $afterHash)){throw 'Runtime continuation migration is absent or not idempotent.'}
  $afterHash=$actualHash
  $journal=Set-OwnerMigrationPhase $testLayout $journal.id validating $lock
  $journal=Set-OwnerMigrationPhase $testLayout $journal.id validated $lock
  $null=Complete-OwnerMigrationJournal $testLayout $journal.id $lock;$ownedJournal=$false
  Remove-OwnerMigrationCredentials $testLayout $journal.id
 }
 $plan+=@{owner_repository=$owner.repository;owner_commit=$owner.commit;binary=$binary;binary_sha256=$hash;backup_directory=$BackupDirectory;backup_manifest_sha256=$backup.hash;restore_report=$RestoreReport;restore_report_sha256=$backup.report_hash;database=$admin.database;runtime_role=$consumer.user;worker_role=$worker.user;database_metadata=$saved[0].metadata;before_schema_sha256=$saved[0].schema_sha256;after_schema_sha256=$afterHash;prior_schema_sha256=$foreign;stable_toolhub=$stableToolHub;relations=$before.Count;legacy_data_unchanged=$true;receipt_minimum_privileges=$true;repeated_owner_migration_unchanged=$true}
 # Rewind only the empty new table in this already identity-checked isolated
 # restore. Formal migration has no down path. Then exercise interruption on
 # both sides of COMMIT through the same recovery implementation used live.
 $null=Assert-RuntimeContinuationMigrationContents $testLayout $admin $before $consumer.user $worker.user
 Assert-SourcesMigrationDatabase $testLayout $admin
 $null=Invoke-RecoverySQL $layout.postgres_bin $admin 'DROP TABLE public.run_continuation_receipts;'
 if((Get-DatabaseSchemaHash $layout.postgres_bin $admin) -cne $plan.before_schema_sha256){throw 'Isolated rewind did not restore the recorded old schema.'}
 $baseline=@{mode='isolated-runtime-continuation-recovery';database=$admin.database;runtime_role=$consumer.user;worker_role=$worker.user;fingerprints=$before}
 $journal=New-OwnerMigrationJournal $testLayout runtime-continuation-v1 $baseline $lock;$ownedJournal=$true
 foreach($point in @('before_sql','owner_exited_before_validation')){
  $injected=$false
  try{$null=Invoke-RuntimeContinuationMigrationMutation $testLayout $admin $plan $baseline $lock {param($observed) if($observed -ceq $point){throw ('injected:'+ $point)}}}
  catch{if($_.Exception.Message -cne ('injected:'+$point)){throw};$injected=$true}
  if(-not $injected -or (Read-OwnerMigrationJournal $testLayout).phase -cne 'mutation_requested'){throw 'Recovery checkpoint did not retain durable mutation intent.'}
 }
 # An unexpected schema must not be accepted as a committed Owner result.
 $null=Invoke-RecoverySQL $layout.postgres_bin $admin 'CREATE TABLE public.continuation_rehearsal_drift(id int);'
 $refused=$false
 try{$null=Invoke-RuntimeContinuationMigrationMutation $testLayout $admin $plan $baseline $lock}catch{if($_.Exception.Message -notmatch 'neither recorded old state'){throw};$refused=$true}
 if(-not $refused){throw 'Schema drift was not refused.'}
 $null=Invoke-RecoverySQL $layout.postgres_bin $admin 'DROP TABLE public.continuation_rehearsal_drift;'
 $recovered=Invoke-RuntimeContinuationMigrationMutation $testLayout $admin $plan $baseline $lock
 if($recovered.executed -or -not $recovered.schema_matches_rehearsal){throw 'Committed migration was replayed or failed to validate.'}
 $null=Complete-OwnerMigrationJournal $testLayout $journal.id $lock;$ownedJournal=$false
 Remove-OwnerMigrationCredentials $testLayout $journal.id
 $plan.recovery_checks=@('injected_before_sql','injected_after_commit','unexpected_schema_refused','committed_schema_not_replayed')
 $plan.recovery_fault_method='Exception checkpoints; actual Owner binary/PostgreSQL, not coordinator process kill'
 $plan.passed=$true
}catch{$plan.failure=$_.Exception.Message;$plan.failure_stack=$_.ScriptStackTrace}
finally{
 try{
  if($ownedJournal){Stop-OwnerMigrationProcess $testLayout $journal.id}
  if($server -and -not $server.HasExited){$null=Invoke-PostgresTool -PostgresBin $layout.postgres_bin -Tool pg_ctl -Arguments @('-D',$data,'-m','fast','-w','-t','20','stop')}
  if($server -and -not $server.WaitForExit(10000)){throw 'Isolated PostgreSQL did not stop.'}
  $plan.isolated_cluster_stopped=($null -ne $server -and $server.HasExited)
  if($ownedJournal){
   if(-not(Test-PathWithin $testLayout.state_root $proof) -or -not(Test-PathWithin $testLayout.database_root 'D:\workspace\agent-platform\local\restore-checks')){throw 'Rehearsal cleanup ownership differs.'}
   $retained=Read-OwnerMigrationJournal $testLayout
   if($retained.id -cne $journal.id){throw 'Rehearsal journal changed.'}
   Move-Item -LiteralPath (Get-OwnerMigrationJournalPath $testLayout) -Destination (Join-Path $proof 'aborted-isolated-rehearsal.json')
  }
 }catch{$plan.passed=$false;$plan.cleanup_failure=$_.Exception.Message}
 finally{
  $plan.passed=$plan.passed -and $plan.isolated_cluster_stopped
  foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key])}
  $admin=$null;$consumer=$null;$configs=$null
  try{
   $planPath=Join-Path $proof 'plan.json';Write-OwnerMigrationJson $planPath $plan
   [IO.File]::WriteAllBytes($planPath+'.dpapi',(Protect-RecoveryBytes ([Text.Encoding]::UTF8.GetBytes((Get-FileHash $planPath).Hash.ToLowerInvariant()))))
  }finally{$lock.Dispose()}
  Write-Output ('Runtime continuation migration rehearsal: '+$planPath)
 }
}
if(-not $plan.passed){throw 'Runtime continuation migration rehearsal did not pass.'}
