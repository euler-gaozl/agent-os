param([ValidateRange(1,16)][int]$Workers=2,[string[]]$Service=@(),[switch]$Migrate,[string]$LayoutPath='',[IO.FileStream]$MaintenanceLock=$null,[string]$PendingOperation='')
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-processes.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root $MaintenanceLock
try {
Assert-NoPendingOwnerMigration $layout
$manifestPath=Join-Path $layout.state_root 'processes.json'
$indexPath=Join-Path $layout.release_root 'current.json'
if(-not(Test-Path -LiteralPath $indexPath)){throw 'Run scripts/Build-Services.ps1 first.'}
$catalog=Read-ReleaseCatalog $layout
if($Migrate){throw 'Startup requires a separately coordinated owner schema/configuration migration; it cannot execute the retired shared migrator.'}
if($PendingOperation){if(-not $MaintenanceLock -or $Service.Count -ne 1 -or $Migrate){throw 'Pending startup is only allowed for the locked single-service release operation.'}}
else{Assert-NoPendingRelease $catalog}
$all=@('registry','runtime','storage','sandbox','toolhub','knowledge','indexer','sources','control','futures','worker')
$selected=if($Service.Count){$Service}else{$all}
foreach($role in $selected){if($role -notin ($all+@('telemetry'))){throw ('Unknown service '+$role)}}
$selected=@(($all+@('telemetry'))|Where-Object{$_ -in $selected})
foreach($role in $selected){if(-not(Test-Path -LiteralPath (Join-Path $layout.config_root ('services/'+$role+'.json')))){throw ('Missing registered service configuration: '+$role+'. Restore it from the verified backup; ordinary startup will not run a migration.')}}
$adminConfig=Join-Path $layout.config_root 'dev.json'
if(-not(Test-Path -LiteralPath $adminConfig)){throw 'Initialize local PostgreSQL first.'}
$settings=Get-Content -LiteralPath $adminConfig -Raw|ConvertFrom-Json
$uri=[uri]$settings.DATABASE_URL
if($uri.Host -eq '127.0.0.1' -and $uri.Port -eq 55432){$held=if($MaintenanceLock){$MaintenanceLock}else{$maintenance};& (Join-Path $PSScriptRoot 'Start-Database.ps1') -LayoutPath $LayoutPath -MaintenanceLock $held}
$releases=@{};foreach($role in $selected){$releases[$role]=Get-PlatformRelease $layout $role $PendingOperation -Verify}
if('knowledge' -in $selected){Assert-KnowledgeArchiveDeployment $layout $releases.knowledge.descriptor}
if($catalog.format -eq 2){
 $accessRoles=@($selected|Where-Object{$_ -in @('worker','telemetry')})
 if($accessRoles.Count){$accessOverrides=@{};foreach($role in $accessRoles){$accessOverrides[$role]=$releases[$role].descriptor};Assert-ExecutionAccessDeployment $layout $accessRoles $accessOverrides}
}
if($catalog.format -eq 2 -and @($selected|Where-Object{$_ -in @('runtime','control')}).Count){
 $receiptOverrides=@{};foreach($role in @('runtime','control')){if($releases.ContainsKey($role)){$receiptOverrides[$role]=$releases[$role].descriptor}}
 Assert-ReceiptManagementDeployment $layout $receiptOverrides
}
if($catalog.format -eq 2 -and @($selected|Where-Object{$_ -in @('runtime','worker')}).Count){
 $executionOverrides=@{};foreach($role in @('runtime','worker')){if($releases.ContainsKey($role)){$executionOverrides[$role]=$releases[$role].descriptor}}
 Assert-SourceExecutionDeployment $layout $executionOverrides
}
if($catalog.format -eq 2 -and @($selected|Where-Object{$_ -in @('registry','runtime','control')}).Count){
 $modelOverrides=@{};foreach($role in @('registry','runtime','control')){if($releases.ContainsKey($role)){$modelOverrides[$role]=$releases[$role].descriptor}}
 Assert-ModelManagementDeployment $layout $modelOverrides
}
if($catalog.format -eq 2 -and @($selected|Where-Object{$_ -in @('runtime','worker','control')}).Count){
 $continuationOverrides=@{};foreach($role in @('runtime','worker','control')){if($releases.ContainsKey($role)){$continuationOverrides[$role]=$releases[$role].descriptor}}
 Assert-ContinuationDeployment $layout $continuationOverrides
}
$previous=Read-PlatformProcesses $layout
$knownRoots='D:\workspace\agent-platform\ops\managed-roots.json'
if(Test-Path -LiteralPath $knownRoots){
 foreach($known in @(Get-Content -LiteralPath $knownRoots -Raw|ConvertFrom-Json)){
  if($known.state_root -eq $layout.state_root){continue}
  if(-not(Test-PathWithin $known.state_root 'D:\workspace')){throw 'Invalid registered process state root.'}
  $otherManifest=Join-Path $known.state_root 'processes.json';if(-not(Test-Path -LiteralPath $otherManifest)){continue}
  foreach($entry in @(Get-Content -LiteralPath $otherManifest -Raw|ConvertFrom-Json -AsHashtable)){
   if($entry.role -notin $selected){continue}
   $p=Get-PlatformProcess $entry
   Initialize-PlatformJobs
   $members=@(if($entry['job_name'] -and $entry['job_created']){[AgentOS.Maintenance.WindowsJob]::Members($entry.job_name)};foreach($child in @($entry['legacy_children']|Where-Object{$_})){$live=Get-PlatformProcess $child;if($live){$live.Id}})
   if($p -or $members.Count -or $entry['legacy_stop_intent'] -or (-not $entry['job_name'] -and -not $p)){throw ('Service running or stop unresolved in another registered layout: '+$entry.role)}
  }
 }
}
foreach($entry in $previous){if($entry.role -notin $selected){continue};$state=Get-PlatformInstanceState $entry $layout;if($state.process -or $state.members.Count -or $state.requires_stop){throw ('Service, descendants or unfinished stop present: '+$entry.role+'. Complete stop for only that service before restarting.')}}
$previous=@($previous|Where-Object{$_['role'] -notin $selected})
if('worker' -in $selected){
 $nodeCommand=$releases.worker.assets.node
 if(-not(Get-Command $nodeCommand -ErrorAction SilentlyContinue)){throw 'Worker requires the Node 24 executable captured in its verified release bundle.'}
 if(-not(Test-Path -LiteralPath (Join-Path $releases.worker.assets.harness 'node_modules'))){throw 'The Worker release is missing its installed dependencies. Build a complete bundle before starting.'}
}
foreach($ui in @('control','futures')){if($ui -in $selected){if(-not(Test-Path -LiteralPath (Join-Path $releases[$ui].assets.web 'index.html'))){throw ('Build frontend before starting '+$ui)}}}
$ports=@{control=8090;toolhub=8091;storage=8092;sandbox=8093;runtime=8094;knowledge=8095;registry=8096;indexer=8097;futures=8098;sources=8101}
$started=@();$null=New-Item -ItemType Directory -Force -Path $layout.log_root
$launchRoot=Join-Path $layout.config_root 'launches'
if(-not(Test-Path -LiteralPath $launchRoot)){
 . (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
 New-ProtectedDirectory $launchRoot
}
try{
 foreach($role in $selected){
  $count=if($role -eq 'worker'){$Workers}else{1}
  if($ports.ContainsKey($role)){if(Get-NetTCPConnection -State Listen -LocalPort $ports[$role] -ErrorAction SilentlyContinue){throw ('Port occupied for '+$role)}}
  $release=$releases[$role];$binary=$release.assets.binary
  $config=Join-Path $layout.config_root ('services/'+$role+'.json');if(-not(Test-Path -LiteralPath $config)){throw ('Missing service config '+$role)}
  for($i=0;$i -lt $count;$i++){
   $identifier=[Guid]::NewGuid().ToString('N');$instance=$role+'-'+$identifier
   $launchConfig=Join-Path $launchRoot ($instance+'.json')
   $configBytes=[IO.File]::ReadAllBytes($config)
   $configHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($configBytes)).ToLower()
   if($release.format -eq 2 -and $release.reference['config_sha256'] -cne $configHash){throw ('Configuration differs from the registered deployment for '+$role+'. Reconcile the planned configuration change before startup.')}
   try{$effective=[Text.Encoding]::UTF8.GetString($configBytes)|ConvertFrom-Json -AsHashtable}catch{throw ('Invalid service configuration: '+$role)}
   $effective.INSTANCE_ID=$instance
   if($role -eq 'worker'){
    $effective.DSH_RUNNER=Join-Path $release.assets.harness 'runner.mjs';$effective.AGENTOS_NODE=$release.assets.node
    foreach($profile in (Get-SourceEngineProfiles)){
     if($effective[$profile.environment]){throw 'Managed Worker source runner comes from the verified release asset, not service configuration.'}
     if($release.assets[$profile.asset]){$effective[$profile.environment]=Join-Path $release.assets[$profile.asset] 'source-runner.mjs'}
    }
   }
   if($role -eq 'control'){$effective.WEB_DIR=$release.assets.web}
   if($role -eq 'futures'){$effective.FUTURES_WEB_DIR=$release.assets.web}
   Write-PlatformJson $launchConfig $effective
   $entry=@{pid=0;role=$role;id=$instance;started_at=$null;binary=$binary;status='launching';intent_at=[datetime]::UtcNow.ToString('o');job_name=('Global\AgentOS-'+$identifier);launch_config=$launchConfig;launch_config_sha256=(Get-FileHash -LiteralPath $launchConfig -Algorithm SHA256).Hash.ToLower();source_config_sha256=$configHash;release_reference=$release.reference}
   $effective=$null;[Array]::Clear($configBytes,0,$configBytes.Length)
   $started+=@($entry)
   Write-PlatformJson $manifestPath @($previous+$started)
   Start-PlatformInstance $entry $layout {Write-PlatformJson $manifestPath @($previous+$started)}
   Write-PlatformJson $manifestPath @($previous+$started)
  }
 }
 Start-Sleep -Milliseconds 800
 foreach($entry in $started){if(-not(Get-PlatformProcess $entry)){throw ('Service exited: '+$entry.role+'; inspect its log')}}
 Write-Output ('Started '+$started.Count+' independent service processes. Console http://127.0.0.1:8090 | Futures http://127.0.0.1:8098')
}catch{
 $failure=$_
 foreach($entry in $started){Stop-PlatformInstance $entry $layout {Write-PlatformJson $manifestPath @($previous+$started)}}
 Write-PlatformJson $manifestPath @($previous)
 throw $failure
}

} finally { if($maintenance){$maintenance.Dispose()} }
