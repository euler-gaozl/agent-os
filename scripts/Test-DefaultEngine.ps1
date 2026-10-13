param([string]$CrashRoot='',[string]$CrashPoint='',[switch]$HoldCheckpoint,[ValidateSet('source','resident')][string]$Candidate='source')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-processes','platform-releases','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$candidateEngine=if($Candidate -ceq 'resident'){Get-ResidentEngineName}else{Get-SourceEngineName}
function Check([bool]$Value,[string]$Name){if(-not $Value){throw $Name};$checks.Add($Name)}
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Name){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};if($message -notmatch $Pattern){throw ($Name+': unexpected outcome '+$message)};$checks.Add($Name)}
if($CrashRoot){
    if(-not(Test-PathWithin $CrashRoot 'D:\workspace\agent-platform\local\evidence')){throw 'Invalid configuration fixture root.'}
    $layout=Get-PlatformLayout $repo (Join-Path $CrashRoot 'layout.json')
    $lock=Enter-PlatformMaintenance $layout.state_root
    try{
        $checkpoint={param($point) if($point -ceq $CrashPoint){
            if($HoldCheckpoint){
                Write-PlatformJson (Join-Path $CrashRoot 'fault-held.json') @{pid=$PID;point=$point}
                $gate=[Threading.ManualResetEvent]::new($false)
                try{$null=$gate.WaitOne(60000)}finally{$gate.Dispose()}
            }
            [Environment]::Exit(199)
        }}
        if($CrashPoint -in @('reverting','prior_configuration_written','recovery_ready')){Restore-PendingEngineConfiguration $layout $PSScriptRoot $lock 3 $checkpoint|Out-Null}
        else{Set-DefaultEngine $layout $Candidate $PSScriptRoot $lock 3 $checkpoint|Out-Null}
    }finally{$lock.Dispose()}
    throw 'Configuration crash point was not reached.'
}
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('default-engine-'+[guid]::NewGuid().ToString('N'))
New-ProtectedDirectory $proof
$layout=@{format=1;project_root=$repo;state_root=(Join-Path $proof 'run');release_root=(Join-Path $proof 'releases');config_root=(Join-Path $proof 'config');log_root=(Join-Path $proof 'logs');layout_path=(Join-Path $proof 'layout.json');database_root=(Join-Path $proof 'unused-db');harness_root=(Join-Path $proof 'unused-harness');console_web_root=(Join-Path $proof 'unused-console');futures_web_root=(Join-Path $proof 'unused-futures');postgres_bin='D:\workspace\.tools\postgresql\pgsql\bin'}
foreach($path in @($layout.state_root,$layout.release_root,$layout.log_root,$layout.config_root)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
Write-PlatformJson $layout.layout_path $layout
$checks=[Collections.Generic.List[string]]::new();$lock=$null;$started=$false;$dbCreated=$false;$roleCreated=$false
$script:activeFaultChild=$null
$fixture='D:\workspace\agent-platform\local\evidence\p2-first-services-85be4f84e89f47ad935b6ed8882093c0\postgres'
$pg=$layout.postgres_bin;$dbName='engine_'+[guid]::NewGuid().ToString('N');$roleName='reader_'+[guid]::NewGuid().ToString('N')
$admin=@{host='127.0.0.1';port=55591;user='p2_fixture';password='fixture-only';database='postgres'}
$result=@{passed=$false;paid_model_calls=0;scope='Real Windows synthetic HTTP Runtime/two Workers and disposable PostgreSQL owner state table; real configuration journal and process crashes, no actual agent/model execution';checks=@()}
$result.candidate_engine=$candidateEngine
function Save-Catalog {Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog}
function Assert-Default([string]$Engine){
    $catalog=Read-ReleaseCatalog $layout
    $config=Get-BoundRuntimeConfiguration $layout $catalog
    if((Get-SubmissionEngine $config) -cne $Engine){throw 'Unexpected effective Runtime default'}
    $response=Invoke-RestMethod ($runtimeURL+'/fixture/engine') -Headers @{Authorization='Bearer fixture-runtime'} -NoProxy -TimeoutSec 3
    $actual=if($response.engine){$response.engine}else{'dsh-0.2.0-rc.2-evidence-v1'}
    if($actual -cne $Engine){throw 'Live fixture process did not load the intended default'}
    Wait-ReleaseReady $layout runtime 1 $catalog.services.runtime.current 3
}
function Close-FaultChild {
    if($null -eq $script:activeFaultChild){return}
    # Use the exact process handle we started, never a recycled PID lookup.
    $script:activeFaultChild.Refresh()
    if(-not $script:activeFaultChild.HasExited){
        $script:activeFaultChild.Kill()
        if(-not $script:activeFaultChild.WaitForExit(10000)){throw 'Fault child exit could not be confirmed; preserve fixture'}
    }
    $script:activeFaultChild.Dispose();$script:activeFaultChild=$null
}
function Crash([string]$Point,[string]$Label,[switch]$TimeoutProbe){
    $arguments=@('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-CrashRoot',('"'+$proof+'"'),'-CrashPoint',$Point,'-Candidate',$Candidate)
    if($TimeoutProbe){$arguments+='-HoldCheckpoint'}
    $script:activeFaultChild=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof ($Label+'.out.log')) -RedirectStandardError (Join-Path $proof ($Label+'.err.log'))
    if($TimeoutProbe){
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while(-not(Test-Path -LiteralPath (Join-Path $proof 'fault-held.json'))){
            if($script:activeFaultChild.WaitForExit(100) -or $watch.ElapsedMilliseconds -gt 20000){throw 'Fault child did not reach the held checkpoint'}
        }
        $held=Get-Content -LiteralPath (Join-Path $proof 'fault-held.json') -Raw|ConvertFrom-Json
        if($held.pid -ne $script:activeFaultChild.Id -or $held.point -cne $Point){throw 'Unexpected held checkpoint owner'}
    }
    $deadline=if($TimeoutProbe){250}else{45000}
    if(-not $script:activeFaultChild.WaitForExit($deadline)){
        Close-FaultChild
        throw 'Configuration fault child deadline exceeded; child terminated and exit confirmed'
    }
    $exitCode=$script:activeFaultChild.ExitCode
    Close-FaultChild
    if($exitCode -ne 199){throw ('Configuration fault was not reached: '+$Point)}
}
try{
    & (Join-Path $pg 'pg_ctl.exe') -D $fixture status *> (Join-Path $proof 'prior-pg.log')
    if($LASTEXITCODE -ne 3){throw 'Disposable PostgreSQL must be stopped'}
    $pgStart=Start-Process -FilePath (Join-Path $pg 'pg_ctl.exe') -ArgumentList @('-D',$fixture,'-l',(Join-Path $proof 'postgres.log'),'-o','"-h 127.0.0.1 -p 55591"','start','-w') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof 'pg-start.out.log') -RedirectStandardError (Join-Path $proof 'pg-start.err.log')
    if(-not $pgStart.WaitForExit(15000) -or $pgStart.ExitCode){throw 'Fixture PostgreSQL startup failed'};$started=$true
    $null=Invoke-RecoverySQL $pg $admin ('CREATE DATABASE '+(Quote-PgIdentifier $dbName));$dbCreated=$true
    $null=Invoke-RecoverySQL $pg $admin ('CREATE ROLE '+(Quote-PgIdentifier $roleName)+' LOGIN');$roleCreated=$true
    $dbAdmin=$admin.Clone();$dbAdmin.database=$dbName
    $migration=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $repo) 'agent-os-runtime/runtime/working_state.sql') -Raw
    $null=Invoke-RecoverySQL $pg $dbAdmin ('CREATE TABLE runs(id text PRIMARY KEY,engine text,status text); '+$migration+' GRANT SELECT ON runs TO '+(Quote-PgIdentifier $roleName)+'; GRANT SELECT,INSERT ON run_working_states TO '+(Quote-PgIdentifier $roleName))
    $binary=Join-Path $layout.release_root 'fixture.exe'
    $env:GOCACHE='D:\workspace\.tools\gocache';$env:GOPATH='D:\workspace\.tools\gopath';$env:GOWORK='off';$env:GOTOOLCHAIN='local'
    & 'D:\workspace\.tools\go\bin\go.exe' build -trimpath -o $binary (Join-Path $PSScriptRoot 'fixtures/windows-release/main.go')
    if($LASTEXITCODE){throw 'Synthetic service build failed'}
    $portListener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$portListener.Start();$runtimePort=$portListener.LocalEndpoint.Port;$portListener.Stop()
    $runtimeURL='http://127.0.0.1:'+$runtimePort
    $dsn='postgres://'+$roleName+':fixture-only@127.0.0.1:55591/'+$dbName+'?sslmode=disable'
    $marker=Join-Path $proof 'source-unready.marker'
    $runtimeConfig=@{SERVICE_TOKEN='fixture-runtime';SERVICE_PEERS=(@{worker=(Get-BytesHash ([Text.Encoding]::UTF8.GetBytes('fixture-worker')))}|ConvertTo-Json -Compress);DATABASE_URL=$dsn;LISTEN=('127.0.0.1:'+$runtimePort);unready_source_marker=$marker}
    $runtimePath=Join-Path $layout.config_root 'services/runtime.json';Write-PlatformJson $runtimePath $runtimeConfig
    $workerConfig=@{SERVICE_TOKEN='fixture-worker';DATABASE_URL=$dsn;RUNTIME_URL=$runtimeURL}
    $workerPath=Join-Path $layout.config_root 'services/worker.json';Write-PlatformJson $workerPath $workerConfig
    Write-PlatformJson (Join-Path $layout.config_root 'dev.json') @{DATABASE_URL=$dsn}
    $initialConfig=[IO.File]::ReadAllBytes($runtimePath)
    foreach($path in @('node.exe','harness/runner.mjs','source/source-runner.mjs')){Write-PlatformText (Join-Path $layout.release_root $path) 'synthetic nonfunctional runtime asset'}
    New-Item -ItemType Directory -Path (Join-Path $layout.release_root 'harness/node_modules')|Out-Null
    $oldContract=@{http='agentos-http-v0.6-notes-lifecycle';data='execution-v0.6-notes-lifecycle';engines=@();tools=@()}
    $newContract=@{http='agentos-http-v0.7-source-state-v1';data='execution-v0.7-working-state';engines=@();tools=@()}
    $runtimeMetadata=@{format=1;engine=(Get-SourceEngineName);execution_protocol='runtime-execution-v1';state_protocol='source-state-recovery-v1';submission_protocol='source-root-default-v1';preview_protocol='source-recovery-preview-v1'}
    $workerMetadata=@{format=1;engine=(Get-SourceEngineName);execution_protocol='runtime-execution-v1';state_protocol='source-state-recovery-v1';manifest_sha256=('a'*64);harness_commit=('b'*40)}
    $residentRuntime=$null;$residentWorker=$null
    $workerAssets=@{binary='fixture.exe';node='node.exe';harness='harness';source_harness='source'}
    if($Candidate -ceq 'resident'){
        $residentRuntime=$runtimeMetadata.Clone();$residentRuntime.engine=Get-ResidentEngineName
        $residentWorker=$workerMetadata.Clone();$residentWorker.engine=Get-ResidentEngineName
        Write-PlatformText (Join-Path $layout.release_root 'resident/source-runner.mjs') 'synthetic resident asset'
        $workerAssets.resident_harness='resident'
    }
    $runtimeRef=New-ReleaseDescriptor $layout runtime @{binary='fixture.exe'} $newContract @{kind='synthetic';dirty=$false} $runtimeMetadata $residentRuntime
    $runtimeOld=New-ReleaseDescriptor $layout runtime @{binary='fixture.exe'} $oldContract @{kind='synthetic';dirty=$false}
    $workerRef=New-ReleaseDescriptor $layout worker $workerAssets $oldContract @{kind='synthetic';dirty=$false} $workerMetadata $residentWorker
    $workerOld=New-ReleaseDescriptor $layout worker @{binary='fixture.exe';node='node.exe';harness='harness'} $oldContract @{kind='synthetic';dirty=$false}
    foreach($ref in @($runtimeRef,$runtimeOld)){$ref.config_sha256=Get-BytesHash $initialConfig}
    foreach($ref in @($workerRef,$workerOld)){$ref.config_sha256=(Get-FileHash -LiteralPath $workerPath).Hash.ToLowerInvariant()}
    $catalog=@{format=2;generation=1;services=@{runtime=@{current=$runtimeRef;previous=$runtimeOld;pending=$null};worker=@{current=$workerRef;previous=$workerOld;pending=$null}}};Save-Catalog
    $lock=Enter-PlatformMaintenance $layout.state_root
    & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service @('runtime','worker') -Workers 2 -MaintenanceLock $lock
    Assert-Default 'dsh-0.2.0-rc.2-evidence-v1'
    $workersBefore=Get-ReleaseProcessSnapshot $layout runtime
    $lock.Dispose();$lock=$null
    & (Join-Path $PSScriptRoot 'Platform.ps1') set-engine -Engine $Candidate -LayoutPath $layout.layout_path | Out-Null
    $lock=Enter-PlatformMaintenance $layout.state_root
    Assert-Default $candidateEngine
    $checks.Add('public_platform_entry_changes_selected_default')
    $null=Set-DefaultEngine $layout historical $PSScriptRoot $lock 3
    Assert-Default 'dsh-0.2.0-rc.2-evidence-v1'
    Check (Test-ReleaseSnapshotsEqual $workersBefore (Get-ReleaseProcessSnapshot $layout runtime)) 'source_historical_round_trip_preserves_both_worker_processes'
    $catalog=Read-ReleaseCatalog $layout
    Check ($catalog.services.runtime.previous.config_sha256 -ceq $catalog.services.runtime.current.config_sha256) 'only_default_field_migration_rebinds_compatible_prior_code_configuration'
    Reject {Set-DefaultEngine $layout historical $PSScriptRoot $lock 3} 'already the default' 'duplicate_default_change_refused'
    $null=Invoke-RecoverySQL $pg $dbAdmin "INSERT INTO runs VALUES('active','dsh-0.2.0-rc.2-evidence-v1','queued')"
    Reject {Set-DefaultEngine $layout $Candidate $PSScriptRoot $lock 3} 'Execution work is active' 'active_work_refused_before_preparing_configuration'
    $null=Invoke-RecoverySQL $pg $dbAdmin 'DELETE FROM runs'
    Reject {Set-DefaultEngine $layout $Candidate $PSScriptRoot $lock 3 {param($point) if($point -eq 'prepared'){$null=Invoke-RecoverySQL $pg $dbAdmin "INSERT INTO runs VALUES('late','dsh-0.2.0-rc.2-evidence-v1','queued')"}}} 'Execution work is active' 'submission_arriving_before_runtime_stop_restores_prior_configuration'
    Assert-Default 'dsh-0.2.0-rc.2-evidence-v1'
    Check ((Invoke-RecoverySQL $pg $dbAdmin 'SELECT count(*) FROM runs').Trim() -ceq '1') 'late_task_is_preserved_during_configuration_recovery'
    $null=Invoke-RecoverySQL $pg $dbAdmin 'DELETE FROM runs'
    Write-PlatformText $marker 'fixture source candidate unhealthy'
    Reject {Set-DefaultEngine $layout $Candidate $PSScriptRoot $lock 1} 'did not become ready' 'unhealthy_candidate_restores_previous_runtime_configuration'
    Remove-Item -LiteralPath $marker
    Assert-Default 'dsh-0.2.0-rc.2-evidence-v1'
    # Actual live launch bindings must agree, even when /readyz is healthy.
    $originalWorker=[IO.File]::ReadAllBytes($workerPath)
    foreach($case in @('database','endpoint','identity')){
        & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $layout.layout_path -Service worker -MaintenanceLock $lock
        $changed=[Text.Encoding]::UTF8.GetString($originalWorker)|ConvertFrom-Json -AsHashtable
        if($case -eq 'database'){$changed.DATABASE_URL=$dsn.Replace($dbName,'different_db')}
        if($case -eq 'endpoint'){$changed.RUNTIME_URL='http://127.0.0.1:1'}
        if($case -eq 'identity'){$changed.SERVICE_TOKEN='wrong-fixture-identity'}
        Write-PlatformJson $workerPath $changed
        $catalog=Read-ReleaseCatalog $layout;$catalog.services.worker.current.config_sha256=(Get-FileHash -LiteralPath $workerPath).Hash.ToLowerInvariant();Save-Catalog
        & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service worker -Workers 2 -MaintenanceLock $lock
        Wait-ReleaseReady $layout worker 2 $catalog.services.worker.current 3
        $pattern=switch($case){database {'different execution database'};endpoint {'endpoint does not match'};identity {'does not recognize'}}
        Reject {Assert-SourceWorkersReady $layout (Read-ReleaseCatalog $layout) 3 $candidateEngine} $pattern ('mismatched_worker_'+$case+'_denied')
        & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $layout.layout_path -Service worker -MaintenanceLock $lock
        [IO.File]::WriteAllBytes($workerPath,$originalWorker)
        $catalog=Read-ReleaseCatalog $layout;$catalog.services.worker.current.config_sha256=Get-BytesHash $originalWorker;Save-Catalog
        & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service worker -Workers 2 -MaintenanceLock $lock
    }
    $workersBefore=Get-ReleaseProcessSnapshot $layout runtime
    $lock.Dispose();$lock=$null
    Reject {Crash 'prepared' 'deadline-probe' -TimeoutProbe} 'child terminated and exit confirmed' 'timed_out_fault_child_terminated_before_fixture_cleanup'
    Check ($null -eq $script:activeFaultChild) 'timed_out_child_handle_closed_after_confirmed_exit'
    $lock=Enter-PlatformMaintenance $layout.state_root
    $null=Invoke-ReleaseChange $layout runtime recover $null $PSScriptRoot $lock 3
    Assert-Default 'dsh-0.2.0-rc.2-evidence-v1'
    Check (Test-ReleaseSnapshotsEqual $workersBefore (Get-ReleaseProcessSnapshot $layout runtime)) 'timeout_preserves_database_journal_and_workers_for_recovery'
    $lock.Dispose();$lock=$null
    foreach($point in @('prepared','stopped','configuration_replaced','configuration_written','started','ready','committed','reverting','prior_configuration_written','recovery_ready')){
        $recoveryFault=$point -in @('reverting','prior_configuration_written','recovery_ready')
        Crash $(if($recoveryFault){'started'}else{$point}) $point
        if($recoveryFault){Crash $point ($point+'-second')}
        $lock=Enter-PlatformMaintenance $layout.state_root
        $catalog=Read-ReleaseCatalog $layout
        if($point -eq 'committed'){
            Check (-not $catalog.services.runtime.pending) 'commit_crash_leaves_no_pending_configuration'
            Assert-Default $candidateEngine
            Reject {Invoke-ReleaseChange $layout runtime recover $null $PSScriptRoot $lock 3} 'No pending release' 'recovery_cannot_rewind_committed_configuration'
            $null=Set-DefaultEngine $layout historical $PSScriptRoot $lock 3
        }else{
            Check ([bool]$catalog.services.runtime.pending.configuration) ('durable_configuration_journal_at_'+$point)
            Reject {Assert-NoPendingRelease $catalog} 'Unfinished release' ('ordinary_maintenance_blocked_at_'+$point)
            $null=Invoke-ReleaseChange $layout runtime recover $null $PSScriptRoot $lock 3
        }
        Assert-Default 'dsh-0.2.0-rc.2-evidence-v1'
        Check (Test-ReleaseSnapshotsEqual $workersBefore (Get-ReleaseProcessSnapshot $layout runtime)) ('configuration_crash_'+$point+'_recovers_without_worker_restart')
        $lock.Dispose();$lock=$null
    }
    # Verify refuse-before-stop when a pending operation encounters unrelated
    # config edits or corrupt encrypted recovery material, then repair fixtures.
    Crash 'started' 'tamper-fixture'
    $lock=Enter-PlatformMaintenance $layout.state_root
    $catalog=Read-ReleaseCatalog $layout;$pending=$catalog.services.runtime.pending
    $priorVault=Join-Path (Get-EngineChangeDirectory $layout $pending.id) 'prior.dpapi'
    $vault=[IO.File]::ReadAllBytes($priorVault);[IO.File]::WriteAllBytes($priorVault,[byte[]]@(1,2,3))
    $before=Get-ReleaseProcessSnapshot $layout
    Reject {Invoke-ReleaseChange $layout runtime recover $null $PSScriptRoot $lock 3} 'Cannot unlock recovery vault' 'corrupt_configuration_vault_refused_before_stop'
    Check (Test-ReleaseSnapshotsEqual $before (Get-ReleaseProcessSnapshot $layout)) 'corrupt_vault_preserves_live_candidate_and_workers'
    [IO.File]::WriteAllBytes($priorVault,$vault)
    $saved=[IO.File]::ReadAllBytes($runtimePath);[IO.File]::AppendAllText($runtimePath,' ')
    Reject {Invoke-ReleaseChange $layout runtime recover $null $PSScriptRoot $lock 3} 'neither recorded version' 'unrelated_manual_configuration_not_overwritten'
    Check (Test-ReleaseSnapshotsEqual $before (Get-ReleaseProcessSnapshot $layout)) 'manual_drift_refusal_preserves_processes'
    [IO.File]::WriteAllBytes($runtimePath,$saved)
    $null=Invoke-ReleaseChange $layout runtime recover $null $PSScriptRoot $lock 3
    Assert-Default 'dsh-0.2.0-rc.2-evidence-v1'
    # No source tasks were created: policy permits dropping source Workers,
    # then rolling Runtime code back despite the initial default being absent.
    $null=Invoke-ReleaseChange $layout worker rollback $null $PSScriptRoot $lock 3
    $null=Invoke-ReleaseChange $layout runtime rollback $null $PSScriptRoot $lock 3
    $catalog=Read-ReleaseCatalog $layout
    Check ($catalog.services.runtime.current.id -ceq $runtimeOld.id) 'source_then_historical_retains_safe_prior_code_rollback'
    Assert-Default 'dsh-0.2.0-rc.2-evidence-v1'
    $result.passed=$true
}catch{$result.failure=$_.Exception.Message;throw}
finally{
    $cleanupSafe=$true
    try{Close-FaultChild}catch{$cleanupSafe=$false;$result.passed=$false;$result.cleanup_failure='Fault child exit unconfirmed; services and database preserved'}
    if($cleanupSafe){
        try{
            if(-not $lock){$lock=Enter-PlatformMaintenance $layout.state_root}
            & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $layout.layout_path -MaintenanceLock $lock
            if((Read-PlatformProcesses $layout).Count -ne 0){throw 'Fixture process records remain'}
        }catch{$cleanupSafe=$false;$result.passed=$false;$result.cleanup_failure='Synthetic service cleanup incomplete; database preserved'}
        finally{if($lock){$lock.Dispose();$lock=$null}}
    }
    if($started -and $cleanupSafe){
        try{
            if($dbCreated){$null=Invoke-RecoverySQL $pg $admin ('DROP DATABASE '+(Quote-PgIdentifier $dbName))}
            if($roleCreated){$null=Invoke-RecoverySQL $pg $admin ('DROP ROLE '+(Quote-PgIdentifier $roleName))}
            & (Join-Path $pg 'pg_ctl.exe') -D $fixture stop -m fast -w *> (Join-Path $proof 'pg-stop.log');$result.fixture_stop_exit=$LASTEXITCODE
            if($LASTEXITCODE){throw 'Disposable PostgreSQL stop failed'}
        }catch{$cleanupSafe=$false;$result.passed=$false;$result.database_cleanup_failure='Disposable database cleanup incomplete; preserve remaining fixture state'}
    }
    $result.cleanup_complete=$cleanupSafe
    $entries=Read-PlatformProcesses $layout;$result.remaining_instance_records=$entries.Count
    $result.checks=@($checks.ToArray());Write-PlatformJson (Join-Path $proof 'result.json') $result
    Write-Output ('Default engine evidence: '+$proof)
}
if(-not $result.passed){throw 'Default engine verification incomplete'}
