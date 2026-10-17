# Reuse the verified-backup, stable-data and owned-process primitives. SQL and
# recovery states below belong only to the Runtime continuation migration.
. (Join-Path $PSScriptRoot 'platform-sources-migration.ps1')
function Get-RuntimeContinuationPriorSchemaHash([hashtable]$Layout,[hashtable]$Connection){
 $schema=Invoke-PostgresTool -PostgresBin $Layout.postgres_bin -Tool pg_dump -Connection $Connection -Arguments @('-w','--schema-only','--create','--exclude-table=public.run_continuation_receipts','-d',$Connection.database)
 return Get-BytesHash ([Text.Encoding]::UTF8.GetBytes((($schema -split '\r?\n'|Where-Object{$_ -notmatch '^\\(un)?restrict '}) -join "`n")))
}
function Assert-RuntimeContinuationMigrationContents([hashtable]$Layout,[hashtable]$Connection,$Before,[string]$RuntimeRole,[string]$WorkerRole){
 $after=Get-DatabaseFingerprints $Layout.postgres_bin $Connection
 $prior=@($after|Where-Object{-not($_.schema -ceq 'public' -and $_.table -ceq 'run_continuation_receipts')})
 $new=@($after|Where-Object{$_.schema -ceq 'public' -and $_.table -ceq 'run_continuation_receipts'})
 if($prior.Count -ne @($Before).Count -or $new.Count -ne 1 -or $new[0].kind -cne 'r' -or [long]$new[0].rows -ne 0){throw 'Runtime continuation relation set or new receipt contents differ.'}
 for($i=0;$i -lt $prior.Count;$i++){foreach($key in @('schema','table','kind','rows','sha256')){if([string]$Before[$i].$key -cne [string]$prior[$i].$key){throw 'Runtime continuation migration changed prior data.'}}}
 $runtime="'"+$RuntimeRole.Replace("'","''")+"'";$worker="'"+$WorkerRole.Replace("'","''")+"'"
 $acl=Invoke-RecoverySQL $Layout.postgres_bin $Connection @"
SELECT (NOT EXISTS (
 SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl,acldefault('r',c.relowner))) a
 WHERE c.oid='public.run_continuation_receipts'::regclass AND a.grantee<>c.relowner
 AND (a.grantee<>(SELECT oid FROM pg_roles WHERE rolname=$runtime) OR a.privilege_type NOT IN ('SELECT','INSERT') OR a.is_grantable)
) AND has_table_privilege($runtime,'public.run_continuation_receipts','SELECT')
AND has_table_privilege($runtime,'public.run_continuation_receipts','INSERT')
AND NOT has_table_privilege($runtime,'public.run_continuation_receipts','UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
AND NOT has_table_privilege($worker,'public.run_continuation_receipts','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'))::text;
"@
 if($acl.Trim() -cne 'true'){throw 'Runtime continuation receipt privileges differ.'}
 return ,$after
}
function Set-RuntimeContinuationStoppedBaseline([hashtable]$Layout,[string]$ID,[System.Collections.IDictionary]$Stopped,[IO.FileStream]$Lock){
 if(-not $Lock){throw 'Stopped baseline requires the held maintenance lock.'};$null=Enter-PlatformMaintenance $Layout.state_root $Lock
 $journal=Read-OwnerMigrationJournal $Layout
 if($journal.id -cne $ID -or $journal.operation -cne 'runtime-continuation-v1' -or $journal.phase -cne 'prepared' -or $journal['stopped_sha256']){throw 'Cannot replace a fixed stopped Runtime continuation baseline.'}
 $path=Join-Path $Layout.state_root ('migrations/'+$ID+'/stopped.json');Assert-ReleasePhysicalPath $Layout.state_root $path
 Write-OwnerMigrationJson $path $Stopped
 $journal.stopped_sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
 Write-OwnerMigrationJson (Get-OwnerMigrationJournalPath $Layout) $journal
 return $journal
}
function Read-RuntimeContinuationStoppedBaseline([hashtable]$Layout,[System.Collections.IDictionary]$Journal){
 $path=Join-Path $Layout.state_root ('migrations/'+$Journal.id+'/stopped.json');Assert-ReleasePhysicalPath $Layout.state_root $path
 if($Journal['stopped_sha256'] -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $Journal.stopped_sha256){throw 'Stopped Runtime continuation baseline integrity differs.'}
 return Read-ReleaseJson $path
}
function Read-RuntimeContinuationMigrationPlan([string]$Path){
 if(-not(Test-PathWithin $Path 'D:\workspace\agent-platform\local\evidence')){throw 'Expected protected local rehearsal plan.'}
 Assert-ReleasePhysicalPath 'D:\workspace\agent-platform\local\evidence' $Path
 $digest=[Text.Encoding]::UTF8.GetString((Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes($Path+'.dpapi'))))
 if((Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() -cne $digest){throw 'Runtime continuation migration rehearsal changed.'}
 $plan=Read-RecoveryJson $Path
 if($plan.format -ne 1 -or $plan.operation -cne 'runtime-continuation-v1' -or $plan.passed -ne $true -or $plan.isolated_cluster_stopped -ne $true -or $plan.owner_repository -cne 'agent-os-runtime'){throw 'Successful stopped Runtime continuation rehearsal required.'}
 if(-not(Test-PathWithin $plan.binary (Split-Path -Parent $Path)) -or (Get-FileHash -LiteralPath $plan.binary).Hash.ToLowerInvariant() -cne $plan.binary_sha256){throw 'Rehearsed Runtime continuation binary changed.'}
 Assert-ReleasePhysicalPath (Split-Path -Parent $Path) $plan.binary
 return $plan
}
function Invoke-RuntimeContinuationMigrationMutation([hashtable]$Layout,[hashtable]$Connection,[System.Collections.IDictionary]$Plan,[System.Collections.IDictionary]$Baseline,[IO.FileStream]$Lock,[scriptblock]$Checkpoint={param($point)}){
 if(-not $Lock){throw 'Runtime continuation mutation requires the held maintenance lock.'}
 $null=Enter-PlatformMaintenance $Layout.state_root $Lock
 $journal=Read-OwnerMigrationJournal $Layout
 if($journal.operation -cne 'runtime-continuation-v1'){throw 'Unexpected migration operation.'}
 $recorded=Read-ReleaseJson (Join-Path $Layout.state_root ('migrations/'+$journal.id+'/baseline.json'))
 foreach($key in @('database','runtime_role','worker_role')){if(-not $recorded[$key] -or $recorded[$key] -cne $Plan[$key]){throw 'Runtime continuation plan differs from its recorded identities.'}}
 $Baseline=if($recorded['mode'] -ceq 'formal-runtime-continuation-migration'){Read-RuntimeContinuationStoppedBaseline $Layout $journal}else{$recorded}
 if($Connection.database -cne $Plan.database){throw 'Runtime continuation migration database differs from the plan.'}
 foreach($key in @('before_schema_sha256','after_schema_sha256','binary_sha256')){if($Plan[$key] -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid Runtime continuation migration plan hash.'}}
 if($Plan.before_schema_sha256 -ceq $Plan.after_schema_sha256){throw 'Runtime continuation capture migration must change its recorded schema.'}
 Assert-SourcesMigrationDatabase $Layout $Connection
 Stop-OwnerMigrationProcess $Layout $journal.id
 Wait-SourcesMigrationQuiescent $Layout $Connection
 if((Get-DatabaseMetadata $Layout.postgres_bin $Connection) -cne $Plan.database_metadata){throw 'Runtime continuation database ownership/settings changed.'}
 $schema=Get-DatabaseSchemaHash $Layout.postgres_bin $Connection;$executed=$false
 if($schema -ceq $Plan.before_schema_sha256){
  if($journal.phase -cnotin @('prepared','mutation_requested')){throw 'Validated Runtime continuation schema reverted unexpectedly.'}
  $before=Get-DatabaseFingerprints $Layout.postgres_bin $Connection
  if($before.Count -ne $Baseline.fingerprints.Count){throw 'Runtime continuation baseline relation set changed.'}
  for($i=0;$i -lt $before.Count;$i++){foreach($key in @('schema','table','kind','rows','sha256')){if([string]$before[$i].$key -cne [string]$Baseline.fingerprints[$i].$key){throw 'Runtime continuation stopped baseline data changed.'}}}
  if($journal.phase -ceq 'prepared'){$journal=Set-OwnerMigrationPhase $Layout $journal.id mutation_requested $Lock}
  & $Checkpoint 'before_sql'
  Invoke-OwnedMigrationProcess $Layout $journal.id $Plan.binary $Plan.binary_sha256 $Connection $Plan.runtime_role $Lock $Checkpoint $Plan.worker_role
  $executed=$true
  & $Checkpoint 'owner_exited_before_validation'
 }elseif($schema -cne $Plan.after_schema_sha256){throw 'Runtime continuation database is neither recorded old state nor rehearsed new state; keep writers stopped.'}
 if($journal.phase -ceq 'prepared'){throw 'Runtime continuation schema changed without recorded mutation intent.'}
 Wait-SourcesMigrationQuiescent $Layout $Connection
 $journal=Set-OwnerMigrationPhase $Layout $journal.id validating $Lock
 if((Get-DatabaseSchemaHash $Layout.postgres_bin $Connection) -cne $Plan.after_schema_sha256 -or (Get-DatabaseMetadata $Layout.postgres_bin $Connection) -cne $Plan.database_metadata){throw 'Runtime continuation migration differs from rehearsal.'}
 $after=Assert-RuntimeContinuationMigrationContents $Layout $Connection $Baseline.fingerprints $Plan.runtime_role $Plan.worker_role
 $journal=Set-OwnerMigrationPhase $Layout $journal.id validated $Lock
 return @{executed=$executed;schema_matches_rehearsal=$true;all_prior_fields_unchanged=$true;receipt_minimum_privileges=$true;relations=$after.Count;journal_id=$journal.id}
}
