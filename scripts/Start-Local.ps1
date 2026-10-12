param([ValidateRange(1,16)][int]$Workers=2,[string[]]$Service=@(),[switch]$Migrate,[string]$LayoutPath='',[IO.FileStream]$MaintenanceLock=$null)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root $MaintenanceLock
try {
$manifestPath=Join-Path $layout.state_root 'processes.json'
$indexPath=Join-Path $layout.release_root 'current.json'
if(-not(Test-Path -LiteralPath $indexPath)){throw 'Run scripts/Build-Services.ps1 first.'}
$index=Get-Content -LiteralPath $indexPath -Raw|ConvertFrom-Json -AsHashtable
$adminConfig=Join-Path $layout.config_root 'dev.json'
if(-not(Test-Path -LiteralPath $adminConfig)){throw 'Initialize local PostgreSQL first.'}
$settings=Get-Content -LiteralPath $adminConfig -Raw|ConvertFrom-Json
$uri=[uri]$settings.DATABASE_URL
if($uri.Host -eq '127.0.0.1' -and $uri.Port -eq 55432){$held=if($MaintenanceLock){$MaintenanceLock}else{$maintenance};& (Join-Path $PSScriptRoot 'Start-Database.ps1') -LayoutPath $LayoutPath -MaintenanceLock $held}
$all=@('registry','runtime','storage','sandbox','toolhub','knowledge','indexer','sources','control','futures','worker')
$selected=if($Service.Count){$Service}else{$all}
foreach($role in $selected){if($role -notin ($all+@('telemetry'))){throw ('Unknown service '+$role)}}
$selected=@(($all+@('telemetry'))|Where-Object{$_ -in $selected})
$previous=@();if(Test-Path -LiteralPath $manifestPath){$previous=@(Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json)}
$knownRoots='D:\workspace\agent-platform\ops\managed-roots.json'
if(Test-Path -LiteralPath $knownRoots){
 foreach($known in @(Get-Content -LiteralPath $knownRoots -Raw|ConvertFrom-Json)){
  if($known.state_root -eq $layout.state_root){continue}
  if(-not(Test-PathWithin $known.state_root 'D:\workspace')){throw 'Invalid registered process state root.'}
  $otherManifest=Join-Path $known.state_root 'processes.json';if(-not(Test-Path -LiteralPath $otherManifest)){continue}
  foreach($entry in @(Get-Content -LiteralPath $otherManifest -Raw|ConvertFrom-Json)){
   if($entry.role -notin $selected){continue}
   $p=Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
   if($p -and $p.Path -eq $entry.binary -and $p.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks){throw ('Service already running in another registered layout: '+$entry.role)}
  }
 }
}
foreach($entry in $previous){if($entry.role -notin $selected){continue};$p=Get-Process -Id $entry.pid -ErrorAction SilentlyContinue;if($p -and $p.Path -eq $entry.binary -and $p.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks){throw ('Service already running: '+$entry.role+'. Stop only that service before restarting.')}}
$needConfig=-not(Test-Path -LiteralPath (Join-Path $layout.config_root 'services/toolhub.json'))
if($Migrate -or $needConfig){
 . (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
 Assert-AllDeploymentsQuiescent $layout
 Push-Location $repoRoot
 try{& $index['migrate-services'] --config $adminConfig --output (Join-Path $layout.config_root 'services');if($LASTEXITCODE -ne 0){throw 'Service migration failed; old data retained.'}}finally{Pop-Location}
}
if('worker' -in $selected){
 $workerConfig=Get-Content (Join-Path $layout.config_root 'services/worker.json') -Raw|ConvertFrom-Json -AsHashtable
 $nodeCommand=if($layout.ContainsKey('node_binary')){$layout.node_binary}elseif($workerConfig['AGENTOS_NODE']){$workerConfig['AGENTOS_NODE']}else{'node'}
 if(-not(Get-Command $nodeCommand -ErrorAction SilentlyContinue)){throw 'Worker requires Node 24; configure AGENTOS_NODE in .state/dev.json and migrate.'}
 if(-not(Test-Path -LiteralPath (Join-Path $layout.harness_root 'node_modules'))){throw 'Install pinned harness dependencies before starting workers.'}
}
foreach($ui in @('control','futures')){if($ui -in $selected){$dir=if($ui -eq 'control'){$layout.console_web_root}else{$layout.futures_web_root};if(-not(Test-Path -LiteralPath (Join-Path $dir 'index.html'))){throw ('Build frontend before starting '+$ui)}}}
$ports=@{control=8090;toolhub=8091;storage=8092;sandbox=8093;runtime=8094;knowledge=8095;registry=8096;indexer=8097;futures=8098;sources=8101}
$started=@();$null=New-Item -ItemType Directory -Force -Path $layout.log_root
try{
 foreach($role in $selected){
  $count=if($role -eq 'worker'){$Workers}else{1}
  if($ports.ContainsKey($role)){if(Get-NetTCPConnection -State Listen -LocalPort $ports[$role] -ErrorAction SilentlyContinue){throw ('Port occupied for '+$role)}}
  $binary=[IO.Path]::GetFullPath($index[$role]);if(-not(Test-PathWithin $binary $layout.release_root)){throw 'Executable outside managed release directory.'}
  $config=Join-Path $layout.config_root ('services/'+$role+'.json');if(-not(Test-Path -LiteralPath $config)){throw ('Missing service config '+$role)}
  for($i=0;$i -lt $count;$i++){
   $instance=$role+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
   $environment=@{INSTANCE_ID=$instance;DSH_RUNNER=(Join-Path $layout.harness_root 'runner.mjs');WEB_DIR=$layout.console_web_root;FUTURES_WEB_DIR=$layout.futures_web_root}
   if($role -eq 'worker' -and $layout.ContainsKey('node_binary')){$environment.AGENTOS_NODE=$layout.node_binary}
   $p=Start-Process -FilePath $binary -ArgumentList @('--config',('"'+$config+'"')) -WorkingDirectory $repoRoot -WindowStyle Hidden -Environment $environment -PassThru -RedirectStandardOutput (Join-Path $layout.log_root ($instance+'.stdout.log')) -RedirectStandardError (Join-Path $layout.log_root ($instance+'.stderr.log'))
   $started += [pscustomobject]@{pid=$p.Id;role=$role;id=$instance;started_at=$p.StartTime.ToUniversalTime().ToString('o');binary=$binary}
   Write-PlatformJson $manifestPath @($previous+$started)
  }
 }
 Start-Sleep -Milliseconds 800
 foreach($entry in $started){if(-not(Get-Process -Id $entry.pid -ErrorAction SilentlyContinue)){throw ('Service exited: '+$entry.role+'; inspect its log')}}
 Write-Output ('Started '+$started.Count+' independent service processes. Console http://127.0.0.1:8090 | Futures http://127.0.0.1:8098')
}catch{
 foreach($entry in $started){$p=Get-Process -Id $entry.pid -ErrorAction SilentlyContinue;if($p -and $p.Path -eq $entry.binary -and $p.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks){Stop-Process -Id $entry.pid}}
 Write-PlatformJson $manifestPath @($previous)
 throw
}

} finally { if($maintenance){$maintenance.Dispose()} }
