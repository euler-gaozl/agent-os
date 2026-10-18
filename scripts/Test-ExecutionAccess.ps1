param([Parameter(Mandatory)][string]$WorkerBinary,[Parameter(Mandatory)][string]$TelemetryBinary,[Parameter(Mandatory)][string]$Migrator,[Parameter(Mandatory)][string]$Retirer,[string]$EvidenceRoot='D:\workspace\agent-platform\local\evidence',[IO.FileStream]$MaintenanceLock=$null)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
foreach($file in @('platform-paths','platform-lock','platform-releases','platform-processes','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$file+'.ps1'))}
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$proof=Join-Path $EvidenceRoot ('execution-access-release-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $proof
$layout=Get-PlatformLayout $repoRoot
foreach($key in @('state_root','config_root','database_root','log_root','release_root','harness_root','console_web_root','futures_web_root')){$layout[$key]=Join-Path $proof $key;$null=New-Item -ItemType Directory -Path $layout[$key]}
$layout.layout_path=Join-Path $proof 'layout.json';Write-PlatformJson $layout.layout_path $layout
$ownedLock=Enter-PlatformMaintenance $layout.state_root $MaintenanceLock
$held=if($MaintenanceLock){$MaintenanceLock}else{$ownedLock}
$checks=[Collections.Generic.List[string]]::new();$createdDB=$false;$createdRoles=[Collections.Generic.List[string]]::new()
$result=@{passed=$false;ci_runs=0;paid_model_calls=0;formal_database_writes=0;source_hashes=@{};scope='Actual restricted PostgreSQL LOGIN and ACL changes, real capability binaries, actual release/start refusal before side effects; no service activation, model or formal deployment'}
foreach($file in @('Test-ExecutionAccess.ps1','lib/platform-execution-access.ps1','lib/platform-releases.ps1','lib/platform-release-operations.ps1','Start-Local.ps1','Build-Services.ps1')){$result.source_hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file)).Hash}
$result.binary_hashes=@{};foreach($file in @($WorkerBinary,$TelemetryBinary,$Migrator,$Retirer)){$result.binary_hashes[$file]=(Get-FileHash -LiteralPath $file).Hash}
function Accept([scriptblock]$Action,[string]$Name){& $Action|Out-Null;$checks.Add($Name)}
function Deny([scriptblock]$Action,[string]$Name,[string]$Pattern){$denied=$false;try{& $Action|Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$denied=$true};if(-not $denied){throw ('Unexpected acceptance: '+$Name)};$checks.Add($Name)}
function SQL([hashtable]$Connection,[string]$Query){Invoke-ExecutionAccessProbe (Join-Path $layout.postgres_bin 'psql.exe') @('-X','-w','-h',$Connection.host,'-p',[string]$Connection.port,'-U',$Connection.user,'-d',$Connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-') $Query $Connection}
function DDLCommand([string]$Binary,[string[]]$Arguments){
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Binary;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $info.Environment.Clear();foreach($key in @('SystemRoot','WINDIR','TEMP','TMP')){if([Environment]::GetEnvironmentVariable($key)){$info.Environment[$key]=[Environment]::GetEnvironmentVariable($key)}}
 $info.Environment['MIGRATION_DATABASE_URL']=$fixtureURL;foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info
 try{$null=$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(30000) -or $p.ExitCode){throw 'Isolated migration command failed'};$null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()}finally{if(-not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
try{
 # Only an explicitly configured disposable test server is accepted. The target
 # database below is newly generated, never the database in TEST_DATABASE_URL.
 $admin=Get-ExecutionAccessConnection @{DATABASE_URL=$env:TEST_DATABASE_URL}
 if($admin.port -ne 55591 -or $admin.database -cne 'postgres' -or $admin.user -cne 'p2_fixture'){throw 'Expected the owned disposable test PostgreSQL'}
 $suffix=[guid]::NewGuid().ToString('N');$name='p2_access_'+$suffix
 $runtimeRole=$name+'_runtime';$workerRole=$name+'_worker';$telemetryRole=$name+'_telemetry'
 $roles=@($runtimeRole,$workerRole,$telemetryRole)
 foreach($role in $roles){SQL $admin ('CREATE ROLE '+$role+" LOGIN PASSWORD 'fixture-only'")|Out-Null;$createdRoles.Add($role)}
 SQL $admin ('CREATE DATABASE '+$name+' TEMPLATE template0')|Out-Null;$createdDB=$true
 $database=@{};foreach($key in $admin.Keys){$database[$key]=$admin[$key]};$database.database=$name
 $builder=[UriBuilder]::new($env:TEST_DATABASE_URL);$builder.Path='/'+$name;$fixtureURL=$builder.Uri.AbsoluteUri
 DDLCommand $Migrator @('--role',$runtimeRole,'--worker-role',$workerRole)
 SQL $database 'CREATE TABLE public.telemetry_inbox(seq bigint); CREATE TABLE public.telemetry_exports(seq bigint);'|Out-Null
 SQL $database ('GRANT ALL ON ALL TABLES IN SCHEMA public TO '+$workerRole+','+$telemetryRole+'; GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO '+$workerRole+','+$telemetryRole)|Out-Null
 $configs=@{}
 foreach($role in @('runtime','worker','telemetry')){
  $login=switch($role){runtime{$runtimeRole}worker{$workerRole}telemetry{$telemetryRole}}
  $url=[UriBuilder]::new($fixtureURL);$url.UserName=$login;$url.Password='fixture-only'
  $configs[$role]=@{DATABASE_URL=$url.Uri.AbsoluteUri}
  Write-PlatformJson (Join-Path $layout.config_root ('services/'+$role+'.json')) $configs[$role]
 }
 Write-PlatformJson (Join-Path $layout.config_root 'dev.json') @{DATABASE_URL=$fixtureURL}
 Copy-Item -LiteralPath $WorkerBinary -Destination (Join-Path $layout.release_root 'worker.exe')
 Copy-Item -LiteralPath $TelemetryBinary -Destination (Join-Path $layout.release_root 'telemetry.exe')
 Set-Content -LiteralPath (Join-Path $layout.release_root 'runtime.exe') -Value 'inert Runtime: never executed'
 Set-Content -LiteralPath (Join-Path $layout.release_root 'node.exe') -Value 'inert Node: never executed'
 $null=New-Item -ItemType Directory -Path (Join-Path $layout.release_root 'harness')
 Set-Content -LiteralPath (Join-Path $layout.release_root 'harness/runner.mjs') -Value 'inert Harness: never executed'
 $contract=@{http='fixture-v1';data='fixture-v1';tools=@();engines=@()};$provenance=@{kind='fixture';dirty=$false}
 $assets=@{worker=@{binary='worker.exe';node='node.exe';harness='harness'};telemetry=@{binary='telemetry.exe'}}
 $capabilities=@{worker=@{format=1;profile='worker-minimal-v1'};telemetry=@{format=1;profile='telemetry-http-v1'}}
 $old=@{};$modern=@{};$descriptors=@{}
 $catalog=@{format=2;generation=1;services=@{}}
 $runtimeRef=New-ReleaseDescriptor $layout runtime @{binary='runtime.exe'} $contract $provenance
 $runtimeRef.config_sha256=(Get-FileHash -LiteralPath (Join-Path $layout.config_root 'services/runtime.json')).Hash.ToLowerInvariant()
 $catalog.services.runtime=@{current=$runtimeRef;previous=$null;pending=$null}
 foreach($role in @('worker','telemetry')){
  $old[$role]=New-ReleaseDescriptor $layout $role $assets[$role] $contract $provenance
  $modern[$role]=New-ReleaseDescriptor $layout $role $assets[$role] $contract $provenance -ExecutionAccess $capabilities[$role]
  $hash=(Get-FileHash -LiteralPath (Join-Path $layout.config_root ('services/'+$role+'.json'))).Hash.ToLowerInvariant()
  $old[$role].config_sha256=$hash;$modern[$role].config_sha256=$hash
  $catalog.services[$role]=@{current=$old[$role];previous=$modern[$role];pending=$null}
  $descriptors[$role]=Read-ReleaseDescriptor $layout $modern[$role] -Verify
 }
 $catalogPath=Join-Path $layout.release_root 'current.json';Write-PlatformJson $catalogPath $catalog
 Accept {Assert-ExecutionAccessDeployment $layout @('worker','telemetry')} 'legacy_permissions_allow_untagged_releases'
 foreach($role in @('worker','telemetry')){Accept {Assert-ExecutionAccessDeployment $layout @($role) @{$role=$descriptors[$role]}} ($role+'_actual_binary_and_login_accepted')}
 Deny {Assert-ExecutionAccessBinary $WorkerBinary $descriptors.telemetry} 'wrong_binary_report_refused' 'differs'
 foreach($invalid in @($null,@{},@{format=2;profile='worker-minimal-v1'},@{format='1';profile='worker-minimal-v1'},@{format=1;profile='unknown'},@{format=1;profile=@('worker-minimal-v1')},@{format=1;profile='worker-minimal-v1';extra=1})){
  Deny {Assert-ExecutionAccessDescriptor @{role='worker';execution_access=$invalid}} ('malformed_profile_'+$checks.Count) 'capability'
 }
 foreach($json in @('null','[]','[null]','[{"format":1,"profile":"worker-minimal-v1"}]')){
  $release=('{"role":"worker","execution_access":'+$json+'}')|ConvertFrom-Json -AsHashtable
  Deny {Get-DeclaredExecutionAccess $release} ('raw_owner_metadata_'+$checks.Count) 'capability'
 }
 foreach($tail in @('&dbname=other','&database=other','&host=192.0.2.1','&user=other','&options=-crole=other','&service=other','&sslmode=disable','&search_path=other','&db%6eame=other','#fragment')){
  $bad=@{DATABASE_URL=($configs.worker.DATABASE_URL+$tail)}
  Deny {Get-ExecutionAccessConnection $bad} ('URL_override_'+$checks.Count) 'explicit local'
 }
 $wrong=@{DATABASE_URL=$configs.worker.DATABASE_URL.Replace('/'+$name+'?','/postgres?')}
 Deny {Assert-ExecutionAccessTarget $configs.runtime $wrong worker} 'worker_foreign_database_refused' 'database differs'
 $savedPG=$env:PGDATABASE;$savedHost=$env:PGHOSTADDR;$savedOptions=$env:PGOPTIONS
 try{$env:PGDATABASE='must_not_use';$env:PGHOSTADDR='192.0.2.1';$env:PGOPTIONS='-c role=missing';Accept {Assert-ExecutionAccessDeployment $layout @('worker','telemetry')} 'parent_PG_environment_cannot_redirect_probe'}finally{$env:PGDATABASE=$savedPG;$env:PGHOSTADDR=$savedHost;$env:PGOPTIONS=$savedOptions}
 $workerPath=Join-Path $layout.config_root 'services/worker.json'
 Write-PlatformJson $workerPath $wrong
 Deny {Assert-ExecutionAccessDeployment $layout @('worker')} 'unregistered_consumer_configuration_refused' 'configuration differs'
 Write-PlatformJson $workerPath $configs.worker
 foreach($permission in @(@{table='telemetry_inbox';verb='INSERT'},@{table='telemetry_inbox';verb='UPDATE'},@{table='telemetry_exports';verb='INSERT'})){
  SQL $database ('REVOKE '+$permission.verb+' ON public.'+$permission.table+' FROM '+$telemetryRole)|Out-Null
  Deny {Assert-ExecutionAccessDeployment $layout @('telemetry') @{telemetry=$descriptors.telemetry}} ('telemetry_missing_'+$permission.table+'_'+$permission.verb) 'owned-table permissions'
  SQL $database ('GRANT '+$permission.verb+' ON public.'+$permission.table+' TO '+$telemetryRole)|Out-Null
 }
 SQL $database ('REVOKE USAGE ON SCHEMA public FROM PUBLIC,'+$workerRole)|Out-Null
 Deny {Assert-ExecutionAccessDeployment $layout @('worker') @{worker=$descriptors.worker}} 'schema_usage_refused' 'schema USAGE'
 SQL $database ('GRANT USAGE ON SCHEMA public TO PUBLIC,'+$workerRole)|Out-Null
 # Contract actual Runtime tables through its independently built CLI. No
 # facade fixtures or mutation of the official service database are involved.
 DDLCommand $Retirer @('--role',$runtimeRole,'--worker-role',$workerRole,'--foreign-roles',$telemetryRole)
 foreach($role in @('worker','telemetry')){
  Accept {Assert-ExecutionAccessDeployment $layout @($role) @{$role=$descriptors[$role]}} ($role+'_modern_after_actual_retirement')
  Deny {Assert-ExecutionAccessDeployment $layout @($role)} ($role+'_untagged_after_retirement_refused') 'retired'
  $catalog.services[$role].current=$modern[$role];$catalog.services[$role].previous=$old[$role]
 };Write-PlatformJson $catalogPath $catalog
 $before=(Get-FileHash -LiteralPath $catalogPath).Hash
 foreach($role in @('worker','telemetry')){
  Deny {Invoke-ReleaseChange $layout $role update $old[$role] $PSScriptRoot $null} ($role+'_zero_instances_update_pre_stop_refusal') 'retired'
  Deny {Invoke-ReleaseChange $layout $role rollback $null $PSScriptRoot $null} ($role+'_zero_instances_rollback_pre_stop_refusal') 'retired'
  if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $before){throw 'Rejected release changed catalog'}
  $catalog.services[$role].pending=@{id=[guid]::NewGuid().ToString('N');phase='started';prior=$old[$role];target=$modern[$role];replicas=0;non_target=@()}
  Write-PlatformJson $catalogPath $catalog;$pendingHash=(Get-FileHash -LiteralPath $catalogPath).Hash
  Deny {Restore-PendingRelease $layout $role $PSScriptRoot $null} ($role+'_pending_incompatible_prior_preserved') 'retired'
  if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $pendingHash){throw 'Rejected recovery changed pending catalog'}
  $catalog.services[$role].pending=$null;$catalog.services[$role].current=$old[$role]
  Write-PlatformJson $catalogPath $catalog;$startHash=(Get-FileHash -LiteralPath $catalogPath).Hash
  Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service @($role) -MaintenanceLock $held} ($role+'_real_start_entry_refused') 'retired'
  if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $startHash -or (Test-Path -LiteralPath (Join-Path $layout.state_root 'processes.json')) -or (Test-Path -LiteralPath (Join-Path $layout.config_root 'launches'))){throw 'Rejected startup changed release/process/launch state'}
  $catalog.services[$role].current=$modern[$role];Write-PlatformJson $catalogPath $catalog;$before=(Get-FileHash -LiteralPath $catalogPath).Hash
 }
 $result.passed=$true
}catch{$result.failure=$_.Exception.Message;$result.failure_line=$_.InvocationInfo.ScriptLineNumber}finally{
 try{
  if($createdDB){SQL $admin ('DROP DATABASE '+$name+' WITH (FORCE)')|Out-Null;$result.database_dropped=$true}
  if($createdRoles.Count){foreach($role in $createdRoles){SQL $admin ('DROP ROLE '+$role)|Out-Null};$result.roles_dropped=$true}
 }catch{$result.passed=$false;$result.cleanup_failure=$_.Exception.Message}
 $result.checks=$checks.ToArray();$result|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $proof 'result.json')
 if($ownedLock){$ownedLock.Dispose()}
 Write-Output $proof;[pscustomobject]@{passed=$result.passed;checks=$checks.Count;failure=$result['failure'];line=$result['failure_line']}|ConvertTo-Json
}
if(-not $result.passed){exit 1}
exit 0
