param([Parameter(Mandatory)][string]$BackupDirectory,[Parameter(Mandatory)][string]$RestoreReport,[string]$LayoutPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-recovery','platform-processes','platform-releases','platform-sources-migration','service-sources')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$layout=Get-PlatformLayout $repo $LayoutPath;$lock=Enter-PlatformMaintenance $layout.state_root
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('sources-migration-plan-'+[guid]::NewGuid().ToString('N'))
$plan=@{format=1;operation='sources-capture-v1';passed=$false;isolated_cluster_stopped=$false;provider_calls=0;github_actions_runs=0;formal_database_writes=0}
$server=$null;$testLayout=$null;$journal=$null;$ownedJournal=$false;$admin=$null;$savedEnv=@{}
try{
 New-ProtectedDirectory $proof;Assert-NoPendingOwnerMigration $layout
 $BackupDirectory=[IO.Path]::GetFullPath($BackupDirectory);$RestoreReport=[IO.Path]::GetFullPath($RestoreReport)
 $backup=Read-SourcesVerifiedBackup $BackupDirectory $RestoreReport;$manifest=$backup.manifest
 $plain=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $BackupDirectory 'configuration.dpapi')))
 try{$vault=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($plain,0,$plain.Length)}
 $configs=@{}
 foreach($relative in @('dev.json','services/sources.json')){
  $bytes=[Convert]::FromBase64String($vault.configuration_files[$relative])
  try{$configs[$relative]=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($bytes,0,$bytes.Length)}
 };$vault=$null
 $admin=Get-DatabaseConnection $configs['dev.json'].DATABASE_URL;$consumer=Get-ExecutionAccessConnection $configs['services/sources.json']
 if($consumer.schema -cne 'sources'){throw 'Sources application schema differs.'}
 $owner=Get-SelectedServiceSource $repo sources (Get-ServiceReleaseContract $repo sources)
 $binary=Join-Path $proof 'sources-migrate.exe';$go='D:\workspace\.tools\go\bin\go.exe'
 $buildEnv=@{GOWORK='off';GOPROXY='off';GOTOOLCHAIN='local';GOENV='off';GOFLAGS='';GOPATH='D:\workspace\.tools\gopath';GOCACHE='D:\workspace\.tools\gocache';TEMP='D:\workspace\agent-platform\local\tmp';TMP='D:\workspace\agent-platform\local\tmp'}
 foreach($key in $buildEnv.Keys){$savedEnv[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$buildEnv[$key])}
 & $go -C $owner.root build -mod=vendor -trimpath -o $binary ./cmd/migrate
 if($LASTEXITCODE){throw 'Sources owner migration build failed.'}
 $build=(& $go version -m -json $binary)|ConvertFrom-Json -AsHashtable
 $settings=@{};foreach($setting in $build.Settings){$settings[$setting.Key]=$setting.Value}
 if($build.Main.Path -cne 'github.com/euler-gaozl/agent-os-sources' -or $build.Path -cne 'github.com/euler-gaozl/agent-os-sources/cmd/migrate' -or $settings['vcs.revision'] -cne $owner.commit -or $settings['vcs.modified'] -cne 'false'){throw 'Sources migration build provenance differs.'}
 $null=Get-SelectedServiceSource $repo sources (Get-ServiceReleaseContract $repo sources)
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
 $foreign=Get-SourcesForeignSchemaHash $testLayout $admin;$stableToolHub=Get-SourcesToolHubStableState $testLayout $admin
 $hash=(Get-FileHash -LiteralPath $binary).Hash.ToLowerInvariant();$afterHash=''
 foreach($attempt in 1..2){
  $journal=New-OwnerMigrationJournal $testLayout sources-capture-v1 @{mode='isolated-sources-rehearsal';layout=$testLayout;backup=$BackupDirectory;restore=$RestoreReport;fingerprints=$before;port=$port} $lock;$ownedJournal=$true
  $journal=Set-OwnerMigrationPhase $testLayout $journal.id mutation_requested $lock
  Invoke-OwnedMigrationProcess $testLayout $journal.id $binary $hash $admin $consumer.user $lock
  Wait-SourcesMigrationQuiescent $testLayout $admin
  $after=Assert-SourcesMigrationContents $testLayout $admin $before
  if((Get-SourcesForeignSchemaHash $testLayout $admin) -cne $foreign -or (Get-DatabaseMetadata $layout.postgres_bin $admin) -cne $saved[0].metadata){throw 'Sources owner changed a foreign schema or database settings.'}
  $actualHash=Get-DatabaseSchemaHash $layout.postgres_bin $admin
  if(($attempt -eq 1 -and $actualHash -ceq $saved[0].schema_sha256) -or ($attempt -eq 2 -and $actualHash -cne $afterHash)){throw 'Sources migration is absent or not idempotent.'}
  $afterHash=$actualHash
  $journal=Set-OwnerMigrationPhase $testLayout $journal.id validating $lock
  $journal=Set-OwnerMigrationPhase $testLayout $journal.id validated $lock
  $null=Complete-OwnerMigrationJournal $testLayout $journal.id $lock;$ownedJournal=$false
  Remove-OwnerMigrationCredentials $testLayout $journal.id
 }
 $plan+=@{owner_repository=$owner.repository;owner_commit=$owner.commit;binary=$binary;binary_sha256=$hash;backup_directory=$BackupDirectory;backup_manifest_sha256=$backup.hash;restore_report=$RestoreReport;restore_report_sha256=$backup.report_hash;database=$admin.database;sources_role=$consumer.user;database_metadata=$saved[0].metadata;before_schema_sha256=$saved[0].schema_sha256;after_schema_sha256=$afterHash;foreign_schema_sha256=$foreign;stable_toolhub=$stableToolHub;relations=$before.Count;legacy_data_unchanged=$true;repeated_owner_migration_unchanged=$true}
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
  Write-Output ('Sources migration rehearsal: '+$planPath)
 }
}
if(-not $plan.passed){throw 'Sources migration rehearsal did not pass.'}
