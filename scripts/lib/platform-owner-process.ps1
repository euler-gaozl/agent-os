# Migration programs use the same atomic named Windows jobs as services. The
# global migration journal blocks ordinary startup while the SQL outcome is
# unknown. Recovery stops this exact owned job before inspecting PostgreSQL.
function Get-OwnerProcessLayout([hashtable]$Layout,[string]$ID){
 if($ID -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid migration process identity.'}
 $root=Join-Path $Layout.state_root ('migrations/'+$ID+'/process')
 Assert-ReleasePhysicalPath $Layout.state_root $root
 return @{project_root=$Layout.project_root;state_root=$root;release_root=(Join-Path $root 'release');config_root=(Join-Path $root 'config');log_root=(Join-Path $root 'logs')}
}
function Read-OwnerProcess([hashtable]$Layout,[string]$ID,[switch]$AllowRetiredConfiguration){
 $owned=Get-OwnerProcessLayout $Layout $ID;$path=Join-Path $owned.state_root 'process.json'
 if(-not(Test-Path -LiteralPath $path)){return $null}
 $entry=Read-ReleaseJson $path
 if($entry.id -cne ('owner-'+$ID) -or $entry.role -cne 'owner-migration' -or $entry.job_name -cne ('Global\AgentOS-'+$ID) -or $entry.binary -cne (Join-Path $owned.release_root 'migrate.exe') -or $entry.launch_config -cne (Join-Path $owned.config_root ('launches/owner-'+$ID+'.json'))){throw 'Owner migration process identity differs.'}
 $verification=$entry
 if($AllowRetiredConfiguration -and -not(Test-Path -LiteralPath $entry.launch_config)){$verification=$entry.Clone();$verification.launch_config=''}
 Assert-InstancePaths $verification $owned
 if((Get-FileHash -LiteralPath $entry.binary).Hash.ToLowerInvariant() -cne $entry.binary_sha256){throw 'Owner migration executable changed.'}
 if($entry['attempt_id'] -cnotmatch '^[a-f0-9]{32}$'){throw 'Owner migration attempt identity differs.'}
 return @{entry=$entry;layout=$owned;path=$path}
}
function Stop-OwnerMigrationProcess([hashtable]$Layout,[string]$ID){
 $record=Read-OwnerProcess $Layout $ID
 if(-not $record){return}
 Stop-PlatformInstance $record.entry $record.layout {Write-OwnerMigrationJson $record.path $record.entry}
}
function Invoke-OwnedMigrationProcess([hashtable]$Layout,[string]$ID,[string]$Binary,[string]$Hash,[hashtable]$Connection,[string]$Role,[IO.FileStream]$Lock,[scriptblock]$Checkpoint={param($point)}){
 if(-not $Lock){throw 'Owner process requires the held maintenance lock.'}
 $null=Enter-PlatformMaintenance $Layout.state_root $Lock
 $journal=Read-OwnerMigrationJournal $Layout
 if($journal.id -cne $ID -or $journal.phase -cne 'mutation_requested'){throw 'Migration process requires a durable mutation intent.'}
 if((Get-FileHash -LiteralPath $Binary).Hash.ToLowerInvariant() -cne $Hash){throw 'Migration executable differs from rehearsal.'}
 $owned=Get-OwnerProcessLayout $Layout $ID
 $previous=Read-OwnerProcess $Layout $ID
 if($previous){
  Stop-OwnerMigrationProcess $Layout $ID
  # A replay gets a fresh journalled process generation, while the command and
  # config identity remain fixed. No existing named job is silently reused.
  $state=Get-PlatformInstanceState $previous.entry $previous.layout
  if($state.process -or $state.members.Count){throw 'Prior migration process is still active.'}
  Write-OwnerMigrationJson (Join-Path $owned.state_root ('attempts/'+$previous.entry.attempt_id+'.json')) $previous.entry
 }
 foreach($directory in @($owned.state_root,$owned.release_root,$owned.config_root,(Join-Path $owned.config_root 'launches'),$owned.log_root)){if(-not(Test-Path -LiteralPath $directory)){New-ProtectedDirectory $directory}}
 $target=Join-Path $owned.release_root 'migrate.exe'
 if(-not(Test-Path -LiteralPath $target)){Copy-Item -LiteralPath $Binary -Destination $target}
 if((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -cne $Hash){throw 'Owned migration artifact differs.'}
 $path=Join-Path $owned.state_root 'process.json';$configPath=Join-Path $owned.config_root ('launches/owner-'+$ID+'.json')
 $url='postgresql://'+[uri]::EscapeDataString($Connection.user)+':'+[uri]::EscapeDataString($Connection.password)+'@127.0.0.1:'+$Connection.port+'/'+[uri]::EscapeDataString($Connection.database)+'?sslmode=disable'
 try{Write-OwnerMigrationJson $configPath @{MIGRATION_DATABASE_URL=$url;ROLE=$Role}}finally{$url=$null}
 $attempt=[guid]::NewGuid().ToString('N')
 $entry=@{id=('owner-'+$ID);attempt_id=$attempt;role='owner-migration';binary=$target;binary_sha256=$Hash;launch_config=$configPath;launch_config_sha256=(Get-FileHash -LiteralPath $configPath).Hash.ToLowerInvariant();job_name=('Global\AgentOS-'+$ID);job_created=$false;pid=0;started_at=$null;intent_at=[datetime]::UtcNow.ToString('o');status='launching'}
 Write-OwnerMigrationJson $path $entry
 Initialize-PlatformJobs
 $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $created=[Action]{$entry.job_created=$true;Write-OwnerMigrationJson $path $entry}
 $pidValue=[AgentOS.Maintenance.WindowsJob]::Start($target,$configPath,$owned.project_root,$entry.job_name,$owner,(New-PlatformEnvironment),(Join-Path $owned.log_root ($attempt+'.stdout.log')),(Join-Path $owned.log_root ($attempt+'.stderr.log')),$created)
 $process=Get-Process -Id $pidValue -ErrorAction SilentlyContinue
 if($process -and -not $process.HasExited){$entry.pid=$process.Id;$entry.started_at=$process.StartTime.ToUniversalTime().ToString('o');$entry.status='running';Write-OwnerMigrationJson $path $entry}
 & $Checkpoint 'owner_started'
 $deadline=[datetime]::UtcNow.AddSeconds(150)
 do{
  $members=@([AgentOS.Maintenance.WindowsJob]::Members($entry.job_name))
  if(-not $members.Count){$entry.status='exited';Write-OwnerMigrationJson $path $entry;return}
  if([datetime]::UtcNow -ge $deadline){Stop-OwnerMigrationProcess $Layout $ID;throw 'Owner migration timed out; inspect SQL before retry.'}
  Start-Sleep -Milliseconds 100
 }while($true)
}
function Remove-OwnerMigrationCredentials([hashtable]$Layout,[string]$ID){
 if(Test-Path -LiteralPath (Get-OwnerMigrationJournalPath $Layout)){throw 'Retain migration credentials while an owner operation is pending.'}
 $completed=Read-ReleaseJson (Join-Path $Layout.state_root ('migrations/'+$ID+'/completed.json'))
 if($completed.id -cne $ID -or $completed.state_root -cne $Layout.state_root -or $completed.phase -cne 'validated'){throw 'Only a completed operation can retire its credentials.'}
 $record=Read-OwnerProcess $Layout $ID -AllowRetiredConfiguration
 if(-not $record){return}
 $verification=$record.entry.Clone()
 if(-not(Test-Path -LiteralPath $verification.launch_config)){$verification.launch_config=''}
 $state=Get-PlatformInstanceState $verification $record.layout
 if($state.process -or $state.members.Count){throw 'Cannot remove configuration from a live owner process.'}
 if(Test-Path -LiteralPath $record.entry.launch_config){Remove-Item -LiteralPath $record.entry.launch_config}
}
