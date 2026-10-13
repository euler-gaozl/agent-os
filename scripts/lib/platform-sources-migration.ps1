. (Join-Path $PSScriptRoot 'platform-owner-process.ps1')
function Get-SourcesForeignSchemaHash([hashtable]$Layout,[hashtable]$Connection){
 $schema=Invoke-PostgresTool -PostgresBin $Layout.postgres_bin -Tool pg_dump -Connection $Connection -Arguments @('-w','--schema-only','--create','--exclude-schema=sources','-d',$Connection.database)
 return Get-BytesHash ([Text.Encoding]::UTF8.GetBytes((($schema -split '\r?\n'|Where-Object{$_ -notmatch '^\\(un)?restrict '}) -join "`n")))
}
function Get-SourcesToolHubStableState([hashtable]$Layout,[hashtable]$Connection){
 $state="SELECT encode(sha256(convert_to((to_jsonb(t)-ARRAY['health','report','checked_at','next_check_at','check_owner','check_fence','check_until','failures'])::text,'UTF8')),'hex') AS h FROM toolhub.asset_state t ORDER BY h;"
 $audit="SELECT encode(sha256(convert_to(to_jsonb(t)::text,'UTF8')),'hex') AS h FROM toolhub.asset_audit t WHERE action<>'checked' ORDER BY h;"
 return @{state=(Invoke-RecoverySQL $Layout.postgres_bin $Connection $state -HashOutput);audit=(Invoke-RecoverySQL $Layout.postgres_bin $Connection $audit -HashOutput)}
}
function Assert-SourcesBackupContents([hashtable]$Layout,[hashtable]$Connection,$Saved,$Live,[System.Collections.IDictionary]$StableToolHub){
 # Only heartbeat rows, health-check state/audits and their sequence may drift.
 # Definitions and attachments remain exact; enabled state and non-check audits
 # are compared separately, so an operator edit is never treated as a probe.
 $filter={-not($_.schema -ceq 'public' -and $_.table -ceq 'instances') -and -not($_.schema -ceq 'toolhub' -and $_.table -cin @('asset_state','asset_audit','asset_audit_seq_seq'))}
 $expected=@($Saved|Where-Object $filter);$actual=@($Live|Where-Object $filter)
 if($expected.Count -ne $actual.Count){throw 'Durable relations differ from the backup.'}
 for($i=0;$i -lt $expected.Count;$i++){foreach($key in @('schema','table','kind','rows','sha256')){if([string]$expected[$i].$key -cne [string]$actual[$i].$key){throw 'Durable data changed since backup; prepare a new backup and rehearsal.'}}}
 $current=Get-SourcesToolHubStableState $Layout $Connection
 foreach($key in @('state','audit')){if($current[$key] -cne $StableToolHub[$key]){throw 'ToolHub operator state changed since backup.'}}
}
function Set-SourcesStoppedBaseline([hashtable]$Layout,[string]$ID,[System.Collections.IDictionary]$Stopped,[IO.FileStream]$Lock){
 if(-not $Lock){throw 'Stopped baseline requires the held maintenance lock.'};$null=Enter-PlatformMaintenance $Layout.state_root $Lock
 $journal=Read-OwnerMigrationJournal $Layout
 if($journal.id -cne $ID -or $journal.operation -cne 'sources-capture-v1' -or $journal.phase -cne 'prepared' -or $journal['stopped_sha256']){throw 'Cannot replace a fixed stopped Sources baseline.'}
 $path=Join-Path $Layout.state_root ('migrations/'+$ID+'/stopped.json');Assert-ReleasePhysicalPath $Layout.state_root $path
 Write-OwnerMigrationJson $path $Stopped
 $journal.stopped_sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
 Write-OwnerMigrationJson (Get-OwnerMigrationJournalPath $Layout) $journal
 return $journal
}
function Read-SourcesStoppedBaseline([hashtable]$Layout,[System.Collections.IDictionary]$Journal){
 $path=Join-Path $Layout.state_root ('migrations/'+$Journal.id+'/stopped.json');Assert-ReleasePhysicalPath $Layout.state_root $path
 if($Journal['stopped_sha256'] -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $Journal.stopped_sha256){throw 'Stopped Sources baseline integrity differs.'}
 return Read-ReleaseJson $path
}
function Read-SourcesVerifiedBackup([string]$BackupDirectory,[string]$RestoreReport){
 $BackupDirectory=[IO.Path]::GetFullPath($BackupDirectory);$RestoreReport=[IO.Path]::GetFullPath($RestoreReport)
 if(-not(Test-PathWithin $BackupDirectory 'D:\workspace\agent-platform\local\backups') -or -not(Test-PathWithin $RestoreReport 'D:\workspace\agent-platform\local\restore-checks')){throw 'Expected a managed backup and restore report.'}
 Assert-ReleasePhysicalPath 'D:\workspace\agent-platform\local\backups' $BackupDirectory
 Assert-ReleasePhysicalPath 'D:\workspace\agent-platform\local\restore-checks' $RestoreReport
 $hash=(Get-FileHash (Join-Path $BackupDirectory 'manifest.json')).Hash.ToLowerInvariant()
 $protected=[Text.Encoding]::UTF8.GetString((Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $BackupDirectory 'manifest-digest.dpapi')))))
 $restore=Read-RecoveryJson $RestoreReport
 if($hash -cne $protected -or $restore.status -cne 'passed' -or $restore.isolated_cluster_stopped -ne $true -or $restore.backup_manifest_sha256 -cne $hash){throw 'Exact backup must have passed isolated recovery.'}
 $manifest=Read-RecoveryJson (Join-Path $BackupDirectory 'manifest.json')
 foreach($file in $manifest.files){$path=Resolve-ReleasePath $BackupDirectory $file.path;Assert-ReleasePhysicalPath $BackupDirectory $path;if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $file.sha256){throw 'Backup file changed.'}}
 return @{manifest=$manifest;hash=$hash;report_hash=(Get-FileHash -LiteralPath $RestoreReport).Hash.ToLowerInvariant()}
}
function Assert-SourcesMigrationDatabase([hashtable]$Layout,[hashtable]$Connection){
 if($Connection.host -cne '127.0.0.1'){throw 'Sources migration requires a loopback database.'}
 $facts=(Invoke-RecoverySQL $Layout.postgres_bin $Connection "SELECT json_build_object('database',current_database(),'user',current_user,'data_directory',current_setting('data_directory'),'port',inet_server_port(),'host',inet_server_addr())")|ConvertFrom-Json -AsHashtable
 foreach($key in @('database','user','port','host')){if([string]$facts[$key] -cne [string]$Connection[$key]){throw 'Sources migration database identity differs.'}}
 if([IO.Path]::GetFullPath($facts.data_directory) -ne $Layout.database_root){throw 'Sources migration directory differs.'}
}
function Wait-SourcesMigrationQuiescent([hashtable]$Layout,[hashtable]$Connection){
 $deadline=[datetime]::UtcNow.AddSeconds(10)
 do{try{Assert-NoDatabaseClients $Layout.postgres_bin $Connection @($Connection.database);return}catch{if([datetime]::UtcNow -ge $deadline){throw};Start-Sleep -Milliseconds 100}}while($true)
}
function Assert-SourcesMigrationContents([hashtable]$Layout,[hashtable]$Connection,$Before){
 $after=Get-DatabaseFingerprints $Layout.postgres_bin $Connection
 if(@($Before).Count -ne $after.Count){throw 'Sources migration changed the relation set.'}
 for($i=0;$i -lt $after.Count;$i++){
  $skipHash=$after[$i].schema -ceq 'sources' -and $after[$i].table -ceq 'source_captures'
  foreach($key in @('schema','table','kind','rows','sha256')){if($skipHash -and $key -eq 'sha256'){continue};if([string]$Before[$i].$key -cne [string]$after[$i].$key){throw 'Existing data changed during Sources migration.'}}
  if($skipHash){
   $projection=Invoke-RecoverySQL $Layout.postgres_bin $Connection "SELECT encode(sha256(convert_to((to_jsonb(t)-'extraction_version')::text,'UTF8')),'hex') AS h FROM sources.source_captures t ORDER BY h;" -HashOutput
   if($projection -cne $Before[$i].sha256){throw 'Existing Sources capture fields changed.'}
   if([long](Invoke-RecoverySQL $Layout.postgres_bin $Connection "SELECT count(*) FROM sources.source_captures WHERE extraction_version IS DISTINCT FROM 'unrecorded';").Trim() -ne 0){throw 'Historical extraction version was invented.'}
  }
 }
 return ,$after
}
function Read-SourcesMigrationPlan([string]$Path){
 if(-not(Test-PathWithin $Path 'D:\workspace\agent-platform\local\evidence')){throw 'Expected protected local rehearsal plan.'}
 Assert-ReleasePhysicalPath 'D:\workspace\agent-platform\local\evidence' $Path
 $digest=[Text.Encoding]::UTF8.GetString((Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes($Path+'.dpapi'))))
 if((Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() -cne $digest){throw 'Sources migration rehearsal changed.'}
 $plan=Read-RecoveryJson $Path
 if($plan.format -ne 1 -or $plan.operation -cne 'sources-capture-v1' -or $plan.passed -ne $true -or $plan.isolated_cluster_stopped -ne $true -or $plan.owner_repository -cne 'agent-os-sources'){throw 'Successful stopped Sources rehearsal required.'}
 if(-not(Test-PathWithin $plan.binary (Split-Path -Parent $Path)) -or (Get-FileHash -LiteralPath $plan.binary).Hash.ToLowerInvariant() -cne $plan.binary_sha256){throw 'Rehearsed Sources binary changed.'}
 Assert-ReleasePhysicalPath (Split-Path -Parent $Path) $plan.binary
 return $plan
}
function Invoke-SourcesMigrationMutation([hashtable]$Layout,[hashtable]$Connection,[System.Collections.IDictionary]$Plan,[System.Collections.IDictionary]$Baseline,[IO.FileStream]$Lock,[scriptblock]$Checkpoint={param($point)}){
 if(-not $Lock){throw 'Sources mutation requires the held maintenance lock.'}
 $null=Enter-PlatformMaintenance $Layout.state_root $Lock
 $journal=Read-OwnerMigrationJournal $Layout
 if($journal.operation -cne 'sources-capture-v1'){throw 'Unexpected migration operation.'}
 $recorded=Read-ReleaseJson (Join-Path $Layout.state_root ('migrations/'+$journal.id+'/baseline.json'))
 $Baseline=if($recorded['mode'] -ceq 'formal-sources-migration'){Read-SourcesStoppedBaseline $Layout $journal}else{$recorded}
 if($Connection.database -cne $Plan.database){throw 'Sources migration database differs from the plan.'}
 foreach($key in @('before_schema_sha256','after_schema_sha256','binary_sha256')){if($Plan[$key] -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid Sources migration plan hash.'}}
 if($Plan.before_schema_sha256 -ceq $Plan.after_schema_sha256){throw 'Sources capture migration must change its recorded schema.'}
 Assert-SourcesMigrationDatabase $Layout $Connection
 Stop-OwnerMigrationProcess $Layout $journal.id
 Wait-SourcesMigrationQuiescent $Layout $Connection
 if((Get-DatabaseMetadata $Layout.postgres_bin $Connection) -cne $Plan.database_metadata){throw 'Sources database ownership/settings changed.'}
 $schema=Get-DatabaseSchemaHash $Layout.postgres_bin $Connection;$executed=$false
 if($schema -ceq $Plan.before_schema_sha256){
  if($journal.phase -cnotin @('prepared','mutation_requested')){throw 'Validated Sources schema reverted unexpectedly.'}
  $before=Get-DatabaseFingerprints $Layout.postgres_bin $Connection
  if($before.Count -ne $Baseline.fingerprints.Count){throw 'Sources baseline relation set changed.'}
  for($i=0;$i -lt $before.Count;$i++){foreach($key in @('schema','table','kind','rows','sha256')){if([string]$before[$i].$key -cne [string]$Baseline.fingerprints[$i].$key){throw 'Sources stopped baseline data changed.'}}}
  if($journal.phase -ceq 'prepared'){$journal=Set-OwnerMigrationPhase $Layout $journal.id mutation_requested $Lock}
  & $Checkpoint 'before_sql'
  Invoke-OwnedMigrationProcess $Layout $journal.id $Plan.binary $Plan.binary_sha256 $Connection $Plan.sources_role $Lock $Checkpoint
  $executed=$true
  & $Checkpoint 'owner_exited_before_validation'
 }elseif($schema -cne $Plan.after_schema_sha256){throw 'Sources database is neither recorded old state nor rehearsed new state; keep writers stopped.'}
 if($journal.phase -ceq 'prepared'){throw 'Sources schema changed without recorded mutation intent.'}
 Wait-SourcesMigrationQuiescent $Layout $Connection
 $journal=Set-OwnerMigrationPhase $Layout $journal.id validating $Lock
 if((Get-DatabaseSchemaHash $Layout.postgres_bin $Connection) -cne $Plan.after_schema_sha256 -or (Get-DatabaseMetadata $Layout.postgres_bin $Connection) -cne $Plan.database_metadata){throw 'Sources migration differs from rehearsal.'}
 $after=Assert-SourcesMigrationContents $Layout $Connection $Baseline.fingerprints
 $journal=Set-OwnerMigrationPhase $Layout $journal.id validated $Lock
 return @{executed=$executed;schema_matches_rehearsal=$true;all_prior_fields_unchanged=$true;legacy_extraction_unrecorded=$true;relations=$after.Count;journal_id=$journal.id}
}
