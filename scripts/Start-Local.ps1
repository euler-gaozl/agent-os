param([ValidateRange(1,16)][int]$Workers=2,[string[]]$Service=@(),[switch]$Migrate)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath=Join-Path $repoRoot '.state\processes.json'
$indexPath=Join-Path $repoRoot 'bin\current.json'
if(-not(Test-Path -LiteralPath $indexPath)){throw 'Run scripts/Build-Services.ps1 first.'}
$index=Get-Content -LiteralPath $indexPath -Raw|ConvertFrom-Json -AsHashtable
$adminConfig=Join-Path $repoRoot '.state\dev.json'
if(-not(Test-Path -LiteralPath $adminConfig)){throw 'Initialize local PostgreSQL first.'}
$settings=Get-Content -LiteralPath $adminConfig -Raw|ConvertFrom-Json
$uri=[uri]$settings.DATABASE_URL
if($uri.Host -eq '127.0.0.1' -and $uri.Port -eq 55432){& (Join-Path $PSScriptRoot 'Start-Database.ps1')}
$all=@('registry','runtime','storage','sandbox','toolhub','knowledge','indexer','sources','control','futures','worker')
$selected=if($Service.Count){$Service}else{$all}
foreach($role in $selected){if($role -notin ($all+@('telemetry'))){throw ('Unknown service '+$role)}}
$previous=@();if(Test-Path -LiteralPath $manifestPath){$previous=@(Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json)}
foreach($entry in $previous){if($entry.role -notin $selected){continue};$p=Get-Process -Id $entry.pid -ErrorAction SilentlyContinue;if($p -and $p.Path -eq $entry.binary -and $p.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks){throw ('Service already running: '+$entry.role+'. Stop only that service before restarting.')}}
$needConfig=-not(Test-Path -LiteralPath (Join-Path $repoRoot '.state\services\toolhub.json'))
if($Migrate -or $needConfig){if($previous.Count -gt 0){throw 'Stop all platform services before migrating.'};Push-Location $repoRoot;try{& $index['migrate-services'] --config $adminConfig;if($LASTEXITCODE -ne 0){throw 'Service migration failed; old data retained.'}}finally{Pop-Location}}
if('worker' -in $selected){
 $workerConfig=Get-Content (Join-Path $repoRoot '.state/services/worker.json') -Raw|ConvertFrom-Json
 $nodeCommand=if($workerConfig.AGENTOS_NODE){$workerConfig.AGENTOS_NODE}else{'node'}
 if(-not(Get-Command $nodeCommand -ErrorAction SilentlyContinue)){throw 'Worker requires Node 24; configure AGENTOS_NODE in .state/dev.json and migrate.'}
 if(-not(Test-Path -LiteralPath (Join-Path $repoRoot 'harness/node_modules'))){throw 'Install pinned harness dependencies before starting workers.'}
}
foreach($ui in @('control','futures')){if($ui -in $selected){$dir=if($ui -eq 'control'){'web/dist'}else{'web/dist-futures'};if(-not(Test-Path -LiteralPath (Join-Path $repoRoot ($dir+'/index.html')))){throw ('Build frontend before starting '+$ui)}}}
$ports=@{control=8090;toolhub=8091;storage=8092;sandbox=8093;runtime=8094;knowledge=8095;registry=8096;indexer=8097;futures=8098;sources=8101}
$started=@();$savedInstance=$env:INSTANCE_ID
try{
 foreach($role in $selected){
  $count=if($role -eq 'worker'){$Workers}else{1}
  if($ports.ContainsKey($role)){if(Get-NetTCPConnection -State Listen -LocalPort $ports[$role] -ErrorAction SilentlyContinue){throw ('Port occupied for '+$role)}}
  $binary=[IO.Path]::GetFullPath($index[$role]);if(-not $binary.StartsWith((Join-Path $repoRoot 'bin')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Executable outside repository bin directory.'}
  $config=Join-Path $repoRoot ('.state\services\'+$role+'.json');if(-not(Test-Path -LiteralPath $config)){throw ('Missing service config '+$role)}
  for($i=0;$i -lt $count;$i++){
   $instance=$role+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8);$env:INSTANCE_ID=$instance
   $p=Start-Process -FilePath $binary -ArgumentList @('--config',('"'+$config+'"')) -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $repoRoot ('.state\'+$instance+'.stdout.log')) -RedirectStandardError (Join-Path $repoRoot ('.state\'+$instance+'.stderr.log'))
   $started += [pscustomobject]@{pid=$p.Id;role=$role;id=$instance;started_at=$p.StartTime.ToUniversalTime().ToString('o');binary=$binary}
   ConvertTo-Json -InputObject @($previous+$started)|Set-Content -LiteralPath $manifestPath -Encoding utf8
  }
 }
 Start-Sleep -Milliseconds 800
 foreach($entry in $started){if(-not(Get-Process -Id $entry.pid -ErrorAction SilentlyContinue)){throw ('Service exited: '+$entry.role+'; inspect its log')}}
 Write-Output ('Started '+$started.Count+' independent service processes. Console http://127.0.0.1:8090 | Futures http://127.0.0.1:8098')
}catch{
 foreach($entry in $started){$p=Get-Process -Id $entry.pid -ErrorAction SilentlyContinue;if($p -and $p.Path -eq $entry.binary -and $p.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks){Stop-Process -Id $entry.pid}}
 ConvertTo-Json -InputObject @($previous)|Set-Content -LiteralPath $manifestPath -Encoding utf8
 throw
}finally{$env:INSTANCE_ID=$savedInstance}
