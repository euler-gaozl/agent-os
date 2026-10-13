param([Parameter(Mandatory)][string]$PlanPath,[ValidateSet('apply','recover')][string]$Action='apply',[string]$LayoutPath='',[string]$Operation='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-recovery','platform-processes','platform-releases','platform-release-operations','platform-sources-migration')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$layout=Get-PlatformLayout $repo $LayoutPath;$lock=Enter-PlatformMaintenance $layout.state_root
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('sources-migration-live-'+[guid]::NewGuid().ToString('N'))
$result=@{passed=$false;action=$Action;provider_calls=0;github_actions_runs=0;formal_schema_mutation=$false}
$restart=@();$workers=2;$stopAttempted=$false;$journal=$null;$completed=$false;$connection=$null;$consumer=$null
try{
 New-ProtectedDirectory $proof
 $PlanPath=[IO.Path]::GetFullPath($PlanPath);$plan=Read-SourcesMigrationPlan $PlanPath;$planHash=(Get-FileHash -LiteralPath $PlanPath).Hash.ToLowerInvariant()
 $result.plan=$PlanPath;$result.plan_sha256=$planHash
 $catalog=Read-ReleaseCatalog $layout;Assert-NoPendingRelease $catalog
 if($catalog.format -ne 2){throw 'Sources owner migration requires a versioned deployment.'}
 $catalogHash=(Get-FileHash -LiteralPath (Join-Path $layout.release_root 'current.json')).Hash.ToLowerInvariant()
 $configHashes=@{}
 foreach($path in @(Get-ChildItem -LiteralPath $layout.config_root -File -Filter '*.json') + @(Get-ChildItem -LiteralPath (Join-Path $layout.config_root 'services') -File -Filter '*.json')){
  $relative=[IO.Path]::GetRelativePath($layout.config_root,$path.FullName).Replace('\','/')
  $configHashes[$relative]=(Get-FileHash -LiteralPath $path.FullName).Hash.ToLowerInvariant()
 }
 $null=Assert-ReleaseConfiguration $layout sources $catalog.services.sources.current
 $source=Read-RecoveryJson (Join-Path $layout.config_root 'services/sources.json');$consumer=Get-ExecutionAccessConnection $source;$source=$null
 if($consumer.port -ne 55432 -or $consumer.database -cne $plan.database -or $consumer.user -cne $plan.sources_role -or $consumer.schema -cne 'sources'){throw 'Sources configuration differs from the rehearsed target.'}
 $dev=Read-RecoveryJson (Join-Path $layout.config_root 'dev.json')
 try{
  $uri=[uri]$dev.DATABASE_URL
  if($uri.Scheme -cnotin @('postgres','postgresql') -or $uri.Host -cne '127.0.0.1' -or $uri.Port -ne 55432 -or $uri.Query -cne '?sslmode=disable' -or $uri.Fragment){throw 'invalid'}
  $connection=Get-DatabaseConnection $dev.DATABASE_URL
 }catch{throw 'Sources migration requires the owned administrator endpoint; connection values were not printed.'}finally{$dev=$null;$uri=$null}
 $connection.database=$plan.database
 if(-not(Get-OwnedDatabase $layout 55432)){throw 'Expected owned PostgreSQL is not running.'}
 Assert-SourcesMigrationDatabase $layout $connection
 if($Action -ceq 'apply'){
  if($Operation){throw 'Operation is only accepted for recovery.'}
  Assert-NoPendingOwnerMigration $layout
  $backup=Read-SourcesVerifiedBackup $plan.backup_directory $plan.restore_report;$manifest=$backup.manifest
  if($backup.hash -cne $plan.backup_manifest_sha256 -or $backup.report_hash -cne $plan.restore_report_sha256 -or $manifest.source_root -cne $repo -or $manifest.source_layout.database_root -cne $layout.database_root){throw 'Restored backup no longer matches the rehearsed target.'}
  if((Get-FileHash -LiteralPath (Join-Path $plan.backup_directory 'release-catalog/files/current.json')).Hash.ToLowerInvariant() -cne $catalogHash){throw 'Current catalog differs from the restored backup.'}
  $plain=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $plan.backup_directory 'configuration.dpapi')))
  try{$vault=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($plain,0,$plain.Length)}
  if($vault.configuration_files.Count -ne $configHashes.Count){throw 'Configuration file set differs from the backup.'}
  foreach($relative in $vault.configuration_files.Keys){
   $bytes=[Convert]::FromBase64String($vault.configuration_files[$relative])
   try{if(-not $configHashes.ContainsKey($relative) -or $configHashes[$relative] -cne (Get-BytesHash $bytes)){throw 'Current configuration differs from the restored backup.'}}finally{[Array]::Clear($bytes,0,$bytes.Length)}
  };$vault=$null
  $bound=Get-BoundRuntimeConfiguration $layout $catalog;Assert-ExecutionQuiescent $layout $bound;$bound=$null
  $snapshot=Get-ReleaseProcessSnapshot $layout;$restart=@($snapshot.role|Sort-Object -Unique);$workers=[Math]::Max(1,@($snapshot|Where-Object role -eq worker).Count)
  # Persist original roles/counts BEFORE stopping the first instance. The
  # stopped data baseline is separately fixed before any DDL can be requested.
  $baseline=@{mode='formal-sources-migration';layout=$layout;catalog_sha256=$catalogHash;config_hashes=$configHashes;plan=$PlanPath;plan_sha256=$planHash;database=$connection.database;sources_role=$consumer.user;restart_roles=$restart;restart_workers=$workers}
  $journal=New-OwnerMigrationJournal $layout sources-capture-v1 $baseline $lock
  $stopAttempted=$true;& (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $LayoutPath -MaintenanceLock $lock
  Assert-AllDeploymentsQuiescent $layout
 }else{
  $pending=Get-OwnerMigrationJournalPath $layout
  if(Test-Path -LiteralPath $pending){$journal=Read-OwnerMigrationJournal $layout;if($Operation -and $journal.id -cne $Operation){throw 'Another migration is pending.'}}
  else{
   if($Operation -cnotmatch '^[a-f0-9]{32}$'){throw 'Completed recovery requires its recorded Operation ID.'}
   $journal=Read-ReleaseJson (Join-Path $layout.state_root ('migrations/'+$Operation+'/completed.json'));$completed=$true
   if($journal.id -cne $Operation -or $journal.phase -cne 'validated' -or $journal.state_root -cne $layout.state_root){throw 'Completed migration identity differs.'}
  }
  if($journal.operation -cne 'sources-capture-v1'){throw 'Another owner migration requires its own recovery.'}
  $baselinePath=Join-Path $layout.state_root ('migrations/'+$journal.id+'/baseline.json');Assert-ReleasePhysicalPath $layout.state_root $baselinePath
  if((Get-FileHash -LiteralPath $baselinePath).Hash.ToLowerInvariant() -cne $journal.baseline_sha256){throw 'Migration baseline integrity differs.'}
  $baseline=Read-ReleaseJson $baselinePath
  if($baseline.mode -cne 'formal-sources-migration' -or $baseline.plan -cne $PlanPath -or $baseline.plan_sha256 -cne $planHash -or $baseline.catalog_sha256 -cne $catalogHash -or $baseline.database -cne $connection.database -or $baseline.sources_role -cne $consumer.user){throw 'Recovery does not match the recorded plan, database or role.'}
  foreach($key in @('project_root','state_root','release_root','config_root','database_root')){if($baseline.layout[$key] -cne $layout[$key]){throw 'Recovery layout differs.'}}
  if($baseline.config_hashes.Count -ne $configHashes.Count){throw 'Recovery configuration file set differs.'}
  foreach($relative in $baseline.config_hashes.Keys){if($configHashes[$relative] -cne $baseline.config_hashes[$relative]){throw 'Recovery configuration differs.'}}
  $restart=@($baseline.restart_roles);$workers=$baseline.restart_workers
  if(-not $completed){$stopAttempted=$true;& (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $LayoutPath -MaintenanceLock $lock;Assert-AllDeploymentsQuiescent $layout}
 }
 $result.operation=$journal.id
 if(-not $completed){
  if($journal.phase -ceq 'prepared' -and -not $journal['stopped_sha256']){
   Wait-SourcesMigrationQuiescent $layout $connection
   if((Get-DatabaseSchemaHash $layout.postgres_bin $connection) -cne $plan.before_schema_sha256 -or (Get-DatabaseMetadata $layout.postgres_bin $connection) -cne $plan.database_metadata){throw 'Stopped schema differs from the rehearsed old state.'}
   $verified=Read-SourcesVerifiedBackup $plan.backup_directory $plan.restore_report
   if($verified.hash -cne $plan.backup_manifest_sha256 -or $verified.report_hash -cne $plan.restore_report_sha256){throw 'Stopped backup differs from rehearsal.'}
   $fingerprints=Get-DatabaseFingerprints $layout.postgres_bin $connection
   $backed=@($verified.manifest.databases|Where-Object name -CEQ $connection.database)
   if($backed.Count -ne 1){throw 'Database missing from the verified backup.'}
   Assert-SourcesBackupContents $layout $connection $backed[0].tables $fingerprints $plan.stable_toolhub
   $journal=Set-SourcesStoppedBaseline $layout $journal.id @{fingerprints=$fingerprints} $lock
  }
  $validation=Invoke-SourcesMigrationMutation $layout $connection $plan $baseline $lock
  $result.formal_schema_mutation=$validation.executed;$result.validation=$validation
  Write-OwnerMigrationJson (Join-Path $layout.state_root ('migrations/'+$journal.id+'/validation.json')) $validation
 }elseif((Get-DatabaseSchemaHash $layout.postgres_bin $connection) -cne $plan.after_schema_sha256 -or (Get-DatabaseMetadata $layout.postgres_bin $connection) -cne $plan.database_metadata){throw 'Completed schema changed; recovery cannot rerun DDL.'}
 $null=Invoke-RecoverySQL $layout.postgres_bin $consumer 'SELECT c.extraction_version,b.body FROM sources.source_captures c,sources.source_blobs b WHERE false;'
 $result.application_login_verified=$true
 if(-not $completed){$result.archived_journal=Complete-OwnerMigrationJournal $layout $journal.id $lock;$completed=$true}
 # SQL is now verified and the durable completed marker precedes writer startup.
 # A crash here is recoverable without comparing subsequently legitimate writes
 # with the old stopped baseline, or replaying DDL.
 Remove-OwnerMigrationCredentials $layout $journal.id
 $restart=@(@('registry','runtime','storage','sandbox','toolhub','knowledge','indexer','sources','control','futures','worker','telemetry')|Where-Object{$_ -in $restart})
 foreach($role in $restart){
  $count=if($role -ceq 'worker'){$workers}else{1};$entries=@((Read-PlatformProcesses $layout)|Where-Object role -CEQ $role)
  $running=@($entries|Where-Object {$state=Get-PlatformInstanceState $_ $layout;$state.process -and -not $state.requires_stop})
  if($running.Count -ne $count -or $entries.Count -ne $count){
   & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $LayoutPath -Service $role -MaintenanceLock $lock
   & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $LayoutPath -Service $role -Workers $workers -MaintenanceLock $lock
  }
  Wait-ReleaseReady $layout $role $count $catalog.services[$role].current 30
 }
 $result.restarted_roles=$restart;$result.restarted_workers=$workers;$result.authenticated_readiness=$true;$result.passed=$true
}catch{$result.failure=$_.Exception.Message;$result.failure_stack=$_.ScriptStackTrace}
finally{
 try{
  if($stopAttempted -and -not $journal -and -not(Test-Path -LiteralPath (Get-OwnerMigrationJournalPath $layout)) -and $restart.Count){
   try{& (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $LayoutPath -MaintenanceLock $lock;& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $LayoutPath -Service $restart -Workers $workers -MaintenanceLock $lock;$result.pre_mutation_restart=$true}catch{$result.restart_failure='Previous deployment did not resume; inspect the process manifest.'}
  }
  $connection=$null;$consumer=$null
  Write-OwnerMigrationJson (Join-Path $proof 'result.json') $result
 }finally{$lock.Dispose()}
 Write-Output ('Sources migration result: '+(Join-Path $proof 'result.json'))
}
if(-not $result.passed){throw 'Sources migration remains incomplete; use its recorded recovery inputs.'}
