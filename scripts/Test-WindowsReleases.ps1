param([string]$GoBinary='',[string]$CrashRoot='',[string]$CrashPoint='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-processes','platform-recovery','platform-releases','platform-release-operations','platform-release-baseline')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Expect-Rejection([scriptblock]$Action,[string]$Message){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};Assert $refused $Message}
if($CrashRoot){
    Assert (Test-PathWithin $CrashRoot 'D:\workspace\agent-platform\local\evidence') 'Invalid synthetic root.'
    $layout=Get-PlatformLayout $repo (Join-Path $CrashRoot 'layout.json')
    $target=Read-ReleaseJson (Join-Path $CrashRoot 'candidate.json')
    $lock=Enter-PlatformMaintenance $layout.state_root
    $action=if($CrashPoint -in @('reverting','recovery_ready')){'recover'}else{'update'}
    try{Invoke-ReleaseChange $layout telemetry $action $target $PSScriptRoot $lock 5 {param($point) if($point -ceq $CrashPoint){[Environment]::Exit(198)}}|Out-Null}finally{$lock.Dispose()}
    throw 'Fault injection point was not reached.'
}
$testRoot='D:\workspace\agent-platform\local\evidence\windows-releases-'+[guid]::NewGuid().ToString('N')
New-ProtectedDirectory $testRoot
$layout=@{format=1;project_root=$repo;state_root=(Join-Path $testRoot 'run');config_root=(Join-Path $testRoot 'config');release_root=(Join-Path $testRoot 'releases');log_root=(Join-Path $testRoot 'logs');database_root=(Join-Path $testRoot 'unused-postgres');postgres_bin='D:\workspace\.tools\postgresql\pgsql\bin';harness_root=(Join-Path $testRoot 'unused-harness');console_web_root=(Join-Path $testRoot 'unused-web');futures_web_root=(Join-Path $testRoot 'unused-futures');layout_path=(Join-Path $testRoot 'layout.json')}
foreach($directory in @($layout.state_root,$layout.config_root,$layout.release_root,$layout.log_root,(Join-Path $layout.config_root 'services'))){$null=New-Item -ItemType Directory -Path $directory -Force}
Write-PlatformJson $layout.layout_path $layout
$layout=Get-PlatformLayout $repo $layout.layout_path
Write-PlatformJson (Join-Path $layout.config_root 'dev.json') @{DATABASE_URL='postgres://synthetic@invalid:55555/unused'}
Write-PlatformJson (Join-Path $layout.config_root 'services/toolhub.json') @{fixture='prevents implicit migration'}
$configPath=Join-Path $layout.config_root 'services/telemetry.json'
Write-PlatformJson $configPath @{SERVICE_TOKEN='synthetic-fixture-token'}
if(-not $GoBinary){$GoBinary=if(Test-Path -LiteralPath 'D:\workspace\.tools\go\bin\go.exe'){'D:\workspace\.tools\go\bin\go.exe'}else{(Get-Command go).Source}}
$sourceBinary=Join-Path $testRoot 'fixture.exe';$cacheBefore=$env:GOCACHE;$goPathBefore=$env:GOPATH
try{$env:GOCACHE='D:\workspace\.tools\gocache';$env:GOPATH='D:\workspace\.tools\gopath';& $GoBinary build -trimpath -o $sourceBinary (Join-Path $PSScriptRoot 'fixtures/windows-release/main.go');if($LASTEXITCODE){throw 'Fixture build failed.'}}finally{$env:GOCACHE=$cacheBefore;$env:GOPATH=$goPathBefore}
$contract=@{http='synthetic-v1';data='none';engines=@();tools=@()}
$refs=@{}
foreach($version in @('old','new','unready')){
    $relative='bundles/'+$version+'/'+$version+'.exe';$path=Resolve-ReleasePath $layout.release_root $relative
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force;Copy-Item -LiteralPath $sourceBinary -Destination $path
    $refs[$version]=New-ReleaseDescriptor $layout telemetry @{binary=$relative} $contract @{kind='synthetic';dirty=$false}
    $refs[$version].config_sha256=(Get-FileHash -LiteralPath $configPath).Hash.ToLower()
}
Write-PlatformJson (Join-Path $layout.release_root 'current.json') @{format=2;generation=1;services=@{telemetry=@{current=$refs.old;previous=$null;pending=$null}}}
Write-PlatformJson (Join-Path $testRoot 'candidate.json') $refs.new
$checks=[Collections.Generic.List[string]]::new();$result=@{status='incomplete';scope='synthetic Windows service release, real processes and process crashes';provider_calls=0;database_connections=0;checks=@()}
$lock=$null
try{
    $lock=Enter-PlatformMaintenance $layout.state_root
    $observerId='observer-'+[guid]::NewGuid().ToString('N')
    $observerConfig=Join-Path $layout.config_root ('launches/'+$observerId+'.json')
    Write-PlatformJson $observerConfig @{SERVICE_TOKEN='synthetic-observer-token'}
    $observer=@{pid=0;started_at=$null;id=$observerId;role='observer';binary=(Resolve-ReleasePath $layout.release_root 'bundles/old/old.exe');job_name=('Global\AgentOS-'+[guid]::NewGuid().ToString('N'));intent_at=[datetime]::UtcNow.ToString('o');launch_config=$observerConfig;launch_config_sha256=(Get-FileHash -LiteralPath $observerConfig).Hash.ToLower()}
    Start-PlatformInstance $observer $layout {Write-PlatformJson (Join-Path $layout.state_root 'processes.json') @($observer)}
    Write-PlatformJson (Join-Path $layout.state_root 'processes.json') @($observer)
    & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service telemetry -MaintenanceLock $lock
    Wait-ReleaseReady $layout telemetry 1 $refs.old 5
    $null=Invoke-ReleaseChange $layout telemetry update $refs.new $PSScriptRoot $lock 5
    Assert ((Read-ReleaseCatalog $layout).services.telemetry.current.id -ceq $refs.new.id) 'Update did not commit.'
    $null=Invoke-ReleaseChange $layout telemetry rollback $null $PSScriptRoot $lock 5
    Assert ((Read-ReleaseCatalog $layout).services.telemetry.current.id -ceq $refs.old.id) 'Rollback did not restore prior release.'
    $checks.Add('real_process_update_and_rollback')
    Expect-Rejection {Invoke-ReleaseChange $layout telemetry update $refs.unready $PSScriptRoot $lock 1} 'Unready candidate was accepted.'
    $catalog=Read-ReleaseCatalog $layout;Assert (-not $catalog.services.telemetry.pending -and $catalog.services.telemetry.current.id -ceq $refs.old.id) 'Failed release did not restore old catalog.'
    Wait-ReleaseReady $layout telemetry 1 $refs.old 5
    $checks.Add('readiness_failure_restores_prior_process_and_catalog')
    $priorDigest=(Get-FileHash -LiteralPath (Join-Path $layout.release_root 'current.json')).Hash
    $badContract=@{http='synthetic-v2';data='none';engines=@();tools=@()}
    $bad=New-ReleaseDescriptor $layout telemetry @{binary='bundles/new/new.exe'} $badContract @{kind='synthetic';dirty=$false}
    Expect-Rejection {Invoke-ReleaseChange $layout telemetry update $bad $PSScriptRoot $lock 2} 'Incompatible candidate accepted.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $layout.release_root 'current.json')).Hash -ceq $priorDigest) 'Refusal changed catalog.'
    [IO.File]::AppendAllText($configPath,' ')
    Expect-Rejection {Invoke-ReleaseChange $layout telemetry update $refs.new $PSScriptRoot $lock 2} 'Changed config accepted.'
    Write-PlatformJson $configPath @{SERVICE_TOKEN='synthetic-fixture-token'}
    $checks.Add('incompatible_contract_and_changed_configuration_refused_before_stop')
    $configSaved=Join-Path $layout.config_root 'telemetry-config.saved'
    [IO.File]::Move($configPath,$configSaved)
    try{Expect-Rejection {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service telemetry -MaintenanceLock $lock} 'Missing registered configuration was not refused.'}finally{[IO.File]::Move($configSaved,$configPath)}
    $toolhubMarker=Join-Path $layout.config_root 'services/toolhub.json';Remove-Item -LiteralPath $toolhubMarker
    # A missing legacy initialization marker must not invoke a migrator in v2.
    $null=Invoke-ReleaseChange $layout telemetry update $refs.new $PSScriptRoot $lock 5
    $null=Invoke-ReleaseChange $layout telemetry rollback $null $PSScriptRoot $lock 5
    Assert (-not(Test-Path -LiteralPath $toolhubMarker)) 'Ordinary startup unexpectedly generated configuration.'
    $checks.Add('missing_configuration_refused_and_legacy_marker_never_triggers_migration')
    $lock.Dispose();$lock=$null
    foreach($point in @('prepared','stopped','started','ready','committed','started-observer-exit','reverting','recovery_ready')){
        $recoveryFault=$point -in @('reverting','recovery_ready')
        $injection=if($point -eq 'started-observer-exit' -or $recoveryFault){'started'}else{$point}
        $pwsh=(Get-Process -Id $PID).Path
        $child=Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-CrashRoot',('"'+$testRoot+'"'),'-CrashPoint',$injection) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot ($point+'.stdout.log')) -RedirectStandardError (Join-Path $testRoot ($point+'.stderr.log'))
        Assert ($child.WaitForExit(30000)) 'Fault injection child timed out.'
        Assert ($child.ExitCode -eq 198) ('Fault was not reached: '+$point)
        if($recoveryFault){
            $child=Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-CrashRoot',('"'+$testRoot+'"'),'-CrashPoint',$point) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot ($point+'-second.stdout.log')) -RedirectStandardError (Join-Path $testRoot ($point+'-second.stderr.log'))
            Assert ($child.WaitForExit(30000) -and $child.ExitCode -eq 198) ('Recovery fault was not reached: '+$point)
        }
        $lock=Enter-PlatformMaintenance $layout.state_root
        $catalog=Read-ReleaseCatalog $layout
        if($point -eq 'started-observer-exit'){Stop-PlatformInstance $observer $layout {}}
        if($point -eq 'committed'){
            Assert (-not $catalog.services.telemetry.pending -and $catalog.services.telemetry.current.id -ceq $refs.new.id) 'Committed release was lost after launcher exit.'
            Expect-Rejection {Invoke-ReleaseChange $layout telemetry recover $null $PSScriptRoot $lock 5} 'Recovery rewound a committed release.'
            $null=Invoke-ReleaseChange $layout telemetry rollback $null $PSScriptRoot $lock 5
        }else{
            Assert ([bool]$catalog.services.telemetry.pending) 'Unfinished operation not persisted.'
            Expect-Rejection {Assert-NoPendingRelease $catalog} 'Pending operation did not block ordinary maintenance.'
            $recovery=Invoke-ReleaseChange $layout telemetry recover $null $PSScriptRoot $lock 5
            if($point -eq 'started-observer-exit'){
                $proof=@($recovery|Where-Object{$_ -is [System.Collections.IDictionary]})[-1]
                Assert (-not $proof.non_target_unchanged -and $proof.non_target_unchanged_during_recovery) 'Recovery falsely claimed historical non-target identity was unchanged.'
                Assert (-not (Read-ReleaseCatalog $layout).services.telemetry.pending) 'Dead unrelated process permanently blocked target recovery.'
                $oldObserverId=$observer.id;$observer.id='observer-'+[guid]::NewGuid().ToString('N')
                $observer.launch_config=Join-Path $layout.config_root ('launches/'+$observer.id+'.json')
                Write-PlatformJson $observer.launch_config @{SERVICE_TOKEN='synthetic-observer-token'}
                $observer.launch_config_sha256=(Get-FileHash -LiteralPath $observer.launch_config).Hash.ToLower()
                $observer.pid=0;$observer.started_at=$null;$observer.job_created=$false;$observer.job_name='Global\AgentOS-'+[guid]::NewGuid().ToString('N');$observer.intent_at=[datetime]::UtcNow.ToString('o')
                $observedEntries=@((Read-PlatformProcesses $layout)|Where-Object id -ne $oldObserverId)+@($observer)
                Start-PlatformInstance $observer $layout {Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $observedEntries}
                Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $observedEntries
            }
        }
        Wait-ReleaseReady $layout telemetry 1 $refs.old 5
        $lock.Dispose();$lock=$null
        $checks.Add('launcher_crash_'+$point+'_recovered_from_catalog')
    }
    $lock=Enter-PlatformMaintenance $layout.state_root
    # Complete artifact archive includes a Worker dependency junction and Web
    # bytes, even when only telemetry is running in this synthetic deployment.
    foreach($path in @('bundles/worker/harness/node_modules/.pnpm/pkg','bundles/worker/harness/node_modules','bundles/control/web')){$null=New-Item -ItemType Directory -Force -Path (Join-Path $layout.release_root $path)}
    foreach($path in @('bundles/worker/worker.exe','bundles/worker/node.exe','bundles/worker/harness/runner.mjs','bundles/worker/harness/node_modules/.pnpm/pkg/index.js','bundles/control/control.exe','bundles/control/web/index.html')){Write-PlatformText (Join-Path $layout.release_root $path) 'synthetic retained bytes'}
    $null=New-Item -ItemType Junction -Path (Join-Path $layout.release_root 'bundles/worker/harness/node_modules/pkg') -Target (Join-Path $layout.release_root 'bundles/worker/harness/node_modules/.pnpm/pkg')
    $workerRef=New-ReleaseDescriptor $layout worker @{binary='bundles/worker/worker.exe';node='bundles/worker/node.exe';harness='bundles/worker/harness'} $contract @{kind='synthetic'}
    $webRef=New-ReleaseDescriptor $layout control @{binary='bundles/control/control.exe';web='bundles/control/web'} $contract @{kind='synthetic'}
    $catalog=Read-ReleaseCatalog $layout;$catalog.services.worker=@{current=$workerRef;previous=$null;pending=$null};$catalog.services.control=@{current=$webRef;previous=$null;pending=$null};Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog
    $export=Export-ReleaseCatalog $layout (Join-Path $testRoot 'archive')
    $restored=Restore-ReleaseCatalog (Join-Path $testRoot 'archive') (Join-Path $testRoot 'restored')
    Assert ($export.references -eq 4 -and $restored.references -eq 4 -and $restored.links -eq 1) 'Current/previous and dependency archive incomplete.'
    $checks.Add('complete_current_previous_worker_links_and_web_restored')
    $null=Assert-HarnessEquivalent (Join-Path $layout.release_root 'bundles/worker/harness') (Join-Path $testRoot 'restored/bundles/worker/harness')
    Write-PlatformText (Join-Path $layout.release_root 'bundles/worker/harness/node_modules/.pnpm/pkg/index.js') 'tampered'
    Expect-Rejection {Read-ReleaseDescriptor $layout $workerRef -Verify} 'Modified dependency accepted.'
    Expect-Rejection {Assert-HarnessEquivalent (Join-Path $layout.release_root 'bundles/worker/harness') (Join-Path $testRoot 'restored/bundles/worker/harness')} 'Modified installed dependency accepted as baseline.'
    Expect-Rejection {Get-ReleaseInventory $layout.release_root @{binary='../outside.exe'}} 'Escaping path accepted.'
    $null=New-Item -ItemType Junction -Path (Join-Path $layout.release_root 'escape') -Target $testRoot
    Expect-Rejection {Get-ReleaseInventory $layout.release_root @{binary='escape/fixture.exe'}} 'Reparse ancestor accepted.'
    $checks.Add('dependency_tamper_path_escape_and_reparse_ancestor_refused')
    & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $layout.layout_path -Service telemetry -MaintenanceLock $lock
    $null=Invoke-ReleaseChange $layout telemetry update $refs.new $PSScriptRoot $lock 5
    $remaining=Read-PlatformProcesses $layout
    Assert (@($remaining|Where-Object role -eq 'telemetry').Count -eq 0) 'Updating a disabled service started it.'
    Assert ([bool](Get-PlatformProcess $observer)) 'Unrelated observer changed during release tests.'
    $checks.Add('inactive_service_stays_inactive_after_update')
    $checks.Add('non_target_identity_preserved_except_explicit_exit_fault_reported_as_drift')
    $result.status='passed'
}catch{$result.status='failed';$result.failure=$_.Exception.Message;throw}
finally{
    try{
        if(-not $lock){$lock=Enter-PlatformMaintenance $layout.state_root}
        & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $layout.layout_path -MaintenanceLock $lock
    }catch{$result.status='cleanup_failed';Write-Warning 'Synthetic release process cleanup needs inspection.'}
    finally{if($lock){$lock.Dispose()}}
    $result.checks=@($checks.ToArray());$result.finished_at=[datetime]::UtcNow.ToString('o');Write-PlatformJson (Join-Path $testRoot 'result.json') $result
    Write-Output ('Release evidence: '+(Join-Path $testRoot 'result.json'))
}
if($result.status -ne 'passed'){throw 'Release verification did not pass.'}
