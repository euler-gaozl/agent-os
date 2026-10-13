# Opt-in Windows released-process measurement. Formal services and databases are
# untouched. Requires the already provisioned, stopped disposable PostgreSQL.
param([string]$FixtureRoot='D:\workspace\agent-platform\local\evidence\p2-first-services-85be4f84e89f47ad935b6ed8882093c0\postgres',[switch]$TimeoutFault)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
$layout=Get-PlatformLayout $project
$lock=Enter-PlatformMaintenance $layout.state_root
try {
$evidenceRoot=Join-Path (Split-Path -Parent $layout.state_root) 'evidence'
$proof=Join-Path $evidenceRoot ('resident-joint-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $proof,(Join-Path $proof 'bin'),(Join-Path $proof 'tmp')
$report=@{passed=$false;paid_model_calls=0;ci_runs=0;forced_gc=$false;timeout_fault=[bool]$TimeoutFault}
$report.source_hashes=@{};foreach($file in @('scripts/Test-ResidentJoint.ps1','scripts/Measure-ResidentProcesses.ps1','scripts/Summarize-ResidentProcesses.ps1','scripts/Stop-ResidentFixture.ps1','scripts/acceptance/resident/joint_test.go','scripts/fixtures/resident-controller/main.go','scripts/lib/windows-job.cs')){$report.source_hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant()}
$go='D:\workspace\.tools\go\bin\go.exe';$pgctl=Join-Path $layout.postgres_bin 'pg_ctl.exe'
$started=$false;$sampler=$null
try {
 $FixtureRoot=(Resolve-Path -LiteralPath $FixtureRoot).Path
 if(-not(Test-PathWithin $FixtureRoot $evidenceRoot) -or $FixtureRoot -eq $layout.database_root){throw 'Disposable database must be inside evidence and separate from formal database'}
 $env:GOWORK='off';$env:GOPROXY='off';$env:GOTOOLCHAIN='local';$env:GOPATH='D:\workspace\.tools\gopath';$env:GOCACHE='D:\workspace\.tools\gocache';$env:TEMP=Join-Path $proof 'tmp';$env:TMP=$env:TEMP
 $catalog=Read-ReleaseCatalog $layout;Assert-NoPendingRelease $catalog
 $report.releases=@{}
 foreach($role in @('runtime','worker','storage')){
  $descriptor=Read-ReleaseDescriptor $layout $catalog.services[$role].current -Verify
  $report.releases[$role]=@{reference=$catalog.services[$role].current;provenance=$descriptor.provenance}
  [Environment]::SetEnvironmentVariable(('JOINT_'+$role.ToUpperInvariant()),(Resolve-ReleasePath $layout.release_root $descriptor.assets.binary))
  if($role -eq 'worker'){
   $env:JOINT_NODE=Resolve-ReleasePath $layout.release_root $descriptor.assets.node
   $env:JOINT_V1=Join-Path (Resolve-ReleasePath $layout.release_root $descriptor.assets.source_harness) 'source-runner.mjs'
   $env:JOINT_V2=Join-Path (Resolve-ReleasePath $layout.release_root $descriptor.assets.resident_harness) 'source-runner.mjs'
  }
  if($role -ne 'worker'){
   $owner=Join-Path (Split-Path -Parent $project) ('agent-os-'+$role)
   if(@(& git -C $owner status --porcelain).Count -or (& git -C $owner rev-parse HEAD).Trim() -ne $descriptor.provenance.commit){throw 'Migrator source must exactly match clean released owner'}
   $binary=Join-Path $proof ('bin/'+$role+'-migrate.exe')
   & $go -C $owner build -mod=vendor -trimpath -o $binary ./cmd/migrate *> (Join-Path $proof ($role+'-migrate-build.log'));if($LASTEXITCODE){throw 'Owner migration build failed'}
   [Environment]::SetEnvironmentVariable(('JOINT_'+$role.ToUpperInvariant()+'_MIGRATOR'),$binary)
  }
 }
 $report.catalog_before=(Get-FileHash -LiteralPath (Join-Path $layout.release_root 'current.json')).Hash
 $testBinary=Join-Path $proof 'bin/joint.test.exe';$controller=Join-Path $proof 'bin/controller.exe'
 & $go -C $project test -c -o $testBinary ./scripts/acceptance/resident *> (Join-Path $proof 'test-build.log');if($LASTEXITCODE){throw 'Test build failed'}
 & $go -C $project build -trimpath -o $controller ./scripts/fixtures/resident-controller *> (Join-Path $proof 'controller-build.log');if($LASTEXITCODE){throw 'Controller build failed'}
 & $pgctl -D $FixtureRoot status *> (Join-Path $proof 'postgres-prior.log');if($LASTEXITCODE -ne 3){throw 'Disposable PostgreSQL must already be stopped'}
 $pg=Start-Process -FilePath $pgctl -ArgumentList @('-D',$FixtureRoot,'-l',(Join-Path $proof 'postgres.log'),'-o','"-h 127.0.0.1 -p 55591"','start','-w') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof 'start.out.log') -RedirectStandardError (Join-Path $proof 'start.err.log')
 $started=$true
 if(-not $pg.WaitForExit(15000)){ $pg.Kill();$pg.WaitForExit();throw 'Fixture PostgreSQL startup timed out' }
 if($pg.ExitCode -ne 0){throw 'Fixture PostgreSQL startup failed'}
 $env:JOINT_DATABASE_URL='postgres://p2_fixture@127.0.0.1:55591/postgres?sslmode=disable';$env:JOINT_EVIDENCE=$proof
 $env:JOINT_TIMEOUT_FAULT=if($TimeoutFault){'1'}else{'0'}
 $sampler=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Measure-ResidentProcesses.ps1'),'-Evidence',$proof) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof 'sampler.out.log') -RedirectStandardError (Join-Path $proof 'sampler.err.log')
 if(-not ('AgentOS.Maintenance.WindowsJob' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'lib/windows-job.cs')}
 $timeout=if($TimeoutFault){'4s'}else{'8m'}
 $controllerConfig=Join-Path $proof 'controller.json'
 @{Go=$go;Binary=$testBinary;Directory=$project;Timeout=$timeout}|ConvertTo-Json|Set-Content -LiteralPath $controllerConfig
 $job=@{name=('Local\AgentOS-ResidentFixture-'+[guid]::NewGuid().ToString('N'));created=$false}
 $onCreated=[Action]{$job.created=$true;$job|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $proof 'job.json')}
 $vars=@{};Get-ChildItem Env:|Where-Object {$_.Name -match '^JOINT_' -or $_.Name -in @('PATH','SystemRoot','WINDIR','TEMP','TMP','LANG','GOWORK','GOPROXY','GOTOOLCHAIN','GOPATH','GOCACHE')}|ForEach-Object {$vars[$_.Name]=$_.Value}
 $environment=(@($vars.Keys|Sort-Object|ForEach-Object {$_+'='+$vars[$_]}) -join [char]0)+[char]0+[char]0
 $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $rootId=[AgentOS.Maintenance.WindowsJob]::Start($controller,$controllerConfig,$proof,$job.name,$owner,$environment,(Join-Path $proof 'test.jsonl'),(Join-Path $proof 'test.stderr.log'),$onCreated)
 $root=[Diagnostics.Process]::GetProcessById($rootId)
 if(-not $root.WaitForExit(510000)){throw 'Fixture controller deadline exceeded'}
 $exitReport=Get-Content -LiteralPath (Join-Path $proof 'controller-result.json') -Raw|ConvertFrom-Json
 if($null -eq $exitReport.exit_code -or $exitReport.exit_code -isnot [long]){throw 'Explicit controller exit status required'}
 $report.test_exit=$exitReport.exit_code
 $events=Get-Content -LiteralPath (Join-Path $proof 'test.jsonl')|ForEach-Object{$_|ConvertFrom-Json}
 if($TimeoutFault){
  if($report.test_exit -eq 0 -or -not @($events|Where-Object {$_.Output -match 'panic: test timed out after 4s'}).Count){throw 'Expected global test timeout was not observed'}
  $hold=Get-Content -LiteralPath (Join-Path $proof 'timeout-held-model.json') -Raw|ConvertFrom-Json
  $samples=Get-Content -LiteralPath (Join-Path $proof 'process-samples.jsonl')|ForEach-Object {$_|ConvertFrom-Json}
  $active=@($samples|Where-Object {$_.phase -eq 'single-20' -and ([datetime]$_.at).ToUniversalTime() -ge ([datetime]$hold.at).ToUniversalTime() -and @($_.processes|Where-Object role -eq 'node').Count})
  if(-not $active.Count){throw 'Fault did not hold an active measured Node request'}
  $report.fault_active_node=$active[-1]
 }else{
  if($report.test_exit -ne 0){throw 'Released-service acceptance failed'}
  if(@($events|Where-Object {$_.Action -eq 'pass' -and $_.Test -eq 'TestResidentReleasedServices'}).Count -ne 1 -or @($events|Where-Object Action -eq 'skip').Count){throw 'Joint acceptance did not execute fully'}
 }
 $report.passed=$true
}catch{$report.failure=$_.Exception.Message}finally{
 try{if($sampler){Set-Content -LiteralPath (Join-Path $proof 'sampler.stop') -Value 'stop';if(-not $sampler.WaitForExit(10000)){$sampler.Kill();throw 'sampler timeout'}elseif($sampler.ExitCode -ne 0){throw 'sampler failed'}}}catch{$report.passed=$false;$report.sampler_failure=$_.Exception.Message;try{if($sampler -and -not $sampler.HasExited){$sampler.Kill();$sampler.WaitForExit()}}catch{}}
 $clean=$false
 if($started){try{$report.cleanup=& (Join-Path $PSScriptRoot 'Stop-ResidentFixture.ps1') -Evidence $proof -PostgresBin $layout.postgres_bin;$clean=$report.cleanup.verified}catch{$report.passed=$false;$report.cleanup_failure=$_.Exception.Message}}
 if($started -and $clean){& $pgctl -D $FixtureRoot stop -m fast -w *> (Join-Path $proof 'postgres-stop.log');$report.fixture_stop_exit=$LASTEXITCODE;if($LASTEXITCODE){$report.passed=$false}}
 if($report.passed -and -not $TimeoutFault){try{& (Join-Path $PSScriptRoot 'Summarize-ResidentProcesses.ps1') -Evidence $proof}catch{$report.passed=$false;$report.measurement_failure=$_.Exception.Message}}
 if($TimeoutFault -and $report.passed -and $report.cleanup.databases_removed -ne 2){$report.passed=$false;$report.failure='Fault did not reach both fixture databases'}
 $report.catalog_after=(Get-FileHash -LiteralPath (Join-Path $layout.release_root 'current.json')).Hash
 if($report.catalog_before -and $report.catalog_before -ne $report.catalog_after){$report.passed=$false;$report.catalog_changed=$true}
 foreach($file in $report.source_hashes.Keys){if((Get-FileHash -LiteralPath (Join-Path $project $file)).Hash.ToLowerInvariant() -ne $report.source_hashes[$file]){$report.passed=$false;$report.source_changed_during_test=$true}}
 $report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $proof 'acceptance.json')
 Write-Output $proof
 [pscustomobject]@{passed=$report.passed;failure=$report.failure;test_exit=$report.test_exit;fixture_stop_exit=$report.fixture_stop_exit;sampler_failure=$report.sampler_failure}|ConvertTo-Json
}
}finally{$lock.Dispose()}
if(-not $report.passed){exit 1}
