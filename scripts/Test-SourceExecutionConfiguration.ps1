$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-recovery','platform-processes','platform-releases','platform-release-operations','platform-lock')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('source-runtime-configuration-'+[guid]::NewGuid().ToString('N'))
New-ProtectedDirectory $proof
$layout=@{format=1;project_root=$repo;state_root=(Join-Path $proof 'state');release_root=(Join-Path $proof 'releases');config_root=(Join-Path $proof 'config');log_root=(Join-Path $proof 'logs');layout_path=(Join-Path $proof 'layout.json');database_root=(Join-Path $proof 'unused-db');harness_root=(Join-Path $proof 'unused-harness');console_web_root=(Join-Path $proof 'unused-console');futures_web_root=(Join-Path $proof 'unused-futures');postgres_bin='D:\workspace\.tools\postgresql\pgsql\bin'}
foreach($path in @($layout.state_root,$layout.release_root,$layout.log_root,(Join-Path $layout.config_root 'launches'))){$null=New-Item -ItemType Directory -Path $path -Force}
Write-PlatformJson $layout.layout_path $layout
$checks=[Collections.Generic.List[string]]::new();$entries=@();$lock=$null
$result=@{passed=$false;paid_model_calls=0;database_connections=0;scope='Real Windows synthetic Runtime/Worker processes; production maintenance entrypoints must reject drift before stopping either process';checks=@()}
function Check([bool]$Value,[string]$Name){if(-not $Value){throw $Name};$checks.Add($Name)}
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Name){
    $message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message}
    Check ($message -match $Pattern) $Name
}
function Persist {Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $entries}
function Save-Catalog {Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog}
function Check-Unchanged([string]$Name){
    Check ((Get-FileHash -LiteralPath (Join-Path $layout.release_root 'current.json')).Hash -ceq $catalogHash -and (Get-FileHash -LiteralPath (Join-Path $layout.state_root 'processes.json')).Hash -ceq $processHash -and [bool](Get-PlatformProcess $entries[0]) -and [bool](Get-PlatformProcess $entries[1])) $Name
}
try{
    $binary=Join-Path $layout.release_root 'fixture.exe'
    $savedGo=@{};foreach($key in @('GOCACHE','GOPATH','GOWORK','GOTOOLCHAIN')){$savedGo[$key]=[Environment]::GetEnvironmentVariable($key)}
    try{
        $env:GOCACHE='D:\workspace\.tools\gocache';$env:GOPATH='D:\workspace\.tools\gopath';$env:GOWORK='off';$env:GOTOOLCHAIN='local'
        & 'D:\workspace\.tools\go\bin\go.exe' build -o $binary (Join-Path $PSScriptRoot 'fixtures/windows-instance/main.go')
        if($LASTEXITCODE){throw 'Synthetic process build failed'}
    }finally{foreach($key in $savedGo.Keys){[Environment]::SetEnvironmentVariable($key,$savedGo[$key])}}
    $contract=@{http='agentos-http-v0.6-notes-lifecycle';data='execution-v0.6-notes-lifecycle';engines=@();tools=@()}
    $runtimeContract=@{http='agentos-http-v0.7-source-state-v1';data='execution-v0.7-working-state';engines=@();tools=@()}
    $metadata=@{format=1;engine=(Get-SourceEngineName);execution_protocol='runtime-execution-v1';state_protocol='source-state-recovery-v1';submission_protocol='source-root-default-v1';preview_protocol='source-recovery-preview-v1'}
    foreach($relative in @('harness/runner.mjs','node.exe','source/source-runner.mjs')){Write-PlatformText (Join-Path $layout.release_root $relative) 'synthetic inventory marker, not a functional Harness'}
    $runtimeRef=New-ReleaseDescriptor $layout runtime @{binary='fixture.exe'} $runtimeContract @{kind='synthetic';dirty=$false} $metadata
    Copy-Item -LiteralPath $binary -Destination (Join-Path $layout.release_root 'prior.exe')
    $priorRef=New-ReleaseDescriptor $layout runtime @{binary='prior.exe'} $runtimeContract @{kind='synthetic';dirty=$false} $metadata
    $workerAssets=@{binary='fixture.exe';node='node.exe';harness='harness';source_harness='source'}
    $workerMetadata=@{format=1;engine=(Get-SourceEngineName);execution_protocol='runtime-execution-v1';state_protocol='source-state-recovery-v1';manifest_sha256=('a'*64);harness_commit=('b'*40)}
    $workerRef=New-ReleaseDescriptor $layout worker $workerAssets $contract @{kind='synthetic';dirty=$false} $workerMetadata
    $oldWorker=New-ReleaseDescriptor $layout worker @{binary='fixture.exe';node='node.exe';harness='harness'} $contract @{kind='synthetic';dirty=$false}
    $runtimeConfig=@{DEFAULT_RUN_ENGINE=(Get-SourceEngineName);DATABASE_URL='postgres://fixture:fixture@127.0.0.1:1/unused';report=(Join-Path $proof 'runtime-report.json')}
    $runtimePath=Join-Path $layout.config_root 'services/runtime.json'
    Write-PlatformJson $runtimePath $runtimeConfig
    Write-PlatformJson (Join-Path $layout.config_root 'services/worker.json') @{report=(Join-Path $proof 'worker-report.json')}
    Write-PlatformJson (Join-Path $layout.config_root 'dev.json') @{DATABASE_URL=$runtimeConfig.DATABASE_URL}
    $sourceBytes=[IO.File]::ReadAllBytes($runtimePath)
    foreach($role in @('runtime','worker')){
        $ref=if($role -eq 'runtime'){$runtimeRef}else{$workerRef}
        $ref.config_sha256=(Get-FileHash -LiteralPath (Join-Path $layout.config_root ('services/'+$role+'.json'))).Hash.ToLowerInvariant()
        $id=$role+'-'+[guid]::NewGuid().ToString('N');$launch=Join-Path $layout.config_root ('launches/'+$id+'.json')
        Copy-Item -LiteralPath (Join-Path $layout.config_root ('services/'+$role+'.json')) -Destination $launch
        $entry=@{pid=0;started_at=$null;id=$id;role=$role;binary=$binary;job_name=('Global\AgentOS-'+[guid]::NewGuid().ToString('N'));intent_at=[datetime]::UtcNow.ToString('o');launch_config=$launch;launch_config_sha256=(Get-FileHash -LiteralPath $launch).Hash.ToLowerInvariant();source_config_sha256=$ref.config_sha256;release_reference=$ref}
        $entries+=@($entry);Persist
        Start-PlatformInstance $entry $layout ${function:Persist};Persist
    }
    $priorRef.config_sha256=$runtimeRef.config_sha256
    $catalog=@{format=2;generation=1;services=@{runtime=@{current=$runtimeRef;previous=$priorRef;pending=$null};worker=@{current=$workerRef;previous=$oldWorker;pending=$null}}};Save-Catalog
    $bound=Get-BoundRuntimeConfiguration $layout $catalog
    Check ($bound.DEFAULT_RUN_ENGINE -ceq (Get-SourceEngineName)) 'matching_live_runtime_configuration_accepted'
    $bound=$null
    $lock=Enter-PlatformMaintenance $layout.state_root
    $runtimeConfig.DEFAULT_RUN_ENGINE='dsh-0.2.0-rc.2-evidence-v1';Write-PlatformJson $runtimePath $runtimeConfig
    $catalogHash=(Get-FileHash -LiteralPath (Join-Path $layout.release_root 'current.json')).Hash
    $processHash=(Get-FileHash -LiteralPath (Join-Path $layout.state_root 'processes.json')).Hash
    Reject {Invoke-ReleaseChange $layout worker rollback $null $PSScriptRoot $lock 1} 'Runtime configuration differs' 'worker_rollback_rejects_disk_default_drift_before_database_or_stop'
    Check-Unchanged 'worker_rollback_refusal_preserves_both_live_processes_and_journal'
    Reject {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service worker -MaintenanceLock $lock} 'Runtime configuration differs' 'worker_start_rejects_disk_default_drift'
    Check-Unchanged 'worker_start_refusal_preserves_both_live_processes_and_journal'
    $catalog.services.worker.pending=@{id=[guid]::NewGuid().ToString('N');prior=$workerRef;target=$oldWorker;phase='started';replicas=1;non_target=@()};Save-Catalog
    $catalogHash=(Get-FileHash -LiteralPath (Join-Path $layout.release_root 'current.json')).Hash
    Reject {Restore-PendingRelease $layout worker $PSScriptRoot $lock 1} 'Runtime configuration differs' 'worker_pending_recovery_rejects_disk_default_drift'
    Check-Unchanged 'pending_recovery_refusal_preserves_processes_and_pending_journal'
    $catalog.services.worker.pending=$null
    # A changed catalog binding alone is insufficient: the process still uses
    # the original protected launch snapshot and its original source hash.
    $savedRuntimeHash=$runtimeRef.config_sha256
    $runtimeRef.config_sha256=(Get-FileHash -LiteralPath $runtimePath).Hash.ToLowerInvariant();Save-Catalog
    Reject {Get-BoundRuntimeConfiguration $layout $catalog} 'Live Runtime configuration is not bound' 'catalog_only_configuration_rebind_does_not_change_live_process'
    $entries[0].source_config_sha256=$runtimeRef.config_sha256;Persist
    Reject {Get-BoundRuntimeConfiguration $layout $catalog} 'Live Runtime execution configuration differs' 'declared_source_hash_cannot_hide_different_effective_default'
    [IO.File]::WriteAllBytes($runtimePath,$sourceBytes);$runtimeRef.config_sha256=$savedRuntimeHash;$entries[0].source_config_sha256=$savedRuntimeHash;Persist;Save-Catalog
    $changedListener=[Text.Encoding]::UTF8.GetString($sourceBytes)|ConvertFrom-Json -AsHashtable
    $changedListener.LISTEN='127.0.0.1:18094';Write-PlatformJson $runtimePath $changedListener
    $runtimeRef.config_sha256=(Get-FileHash -LiteralPath $runtimePath).Hash.ToLowerInvariant();$entries[0].source_config_sha256=$runtimeRef.config_sha256;Persist;Save-Catalog
    Reject {Get-BoundRuntimeConfiguration $layout $catalog} 'Live Runtime execution configuration differs' 'declared_source_hash_cannot_hide_different_live_listener'
    [IO.File]::WriteAllBytes($runtimePath,$sourceBytes);$runtimeRef.config_sha256=$savedRuntimeHash;$entries[0].source_config_sha256=$savedRuntimeHash;Persist;Save-Catalog
    # A crash after starting the candidate must still allow recovery while the
    # committed catalog points to prior and the live binary belongs to target.
    $catalog.services.runtime.current=$priorRef;$catalog.services.runtime.pending=@{id=[guid]::NewGuid().ToString('N');prior=$priorRef;target=$runtimeRef;phase='started'};Save-Catalog
    $bound=Get-BoundRuntimeConfiguration $layout $catalog
    Check ($bound.DEFAULT_RUN_ENGINE -ceq (Get-SourceEngineName)) 'live_pending_target_with_valid_snapshot_is_accepted'
    $bound=$null
    [IO.File]::AppendAllText($entries[0].launch_config,' ')
    Reject {Get-BoundRuntimeConfiguration $layout $catalog} 'Launch configuration has changed' 'tampered_live_launch_snapshot_denied'
    [IO.File]::WriteAllBytes($entries[0].launch_config,$sourceBytes)
    $result.passed=$true
}catch{$result.failure=$_.Exception.Message;throw}
finally{
    foreach($entry in $entries){try{Stop-PlatformInstance $entry $layout ${function:Persist}}catch{$result.passed=$false;$result.cleanup_failure='Synthetic process cleanup failed'}}
    if($lock){$lock.Dispose()}
    $result.remaining_processes=@($entries|Where-Object{Get-PlatformProcess $_}).Count
    if($result.remaining_processes){$result.passed=$false}
    $result.checks=@($checks.ToArray());Write-PlatformJson (Join-Path $proof 'result.json') $result
    Write-Output ('Source configuration evidence: '+$proof)
}
if(-not $result.passed){throw 'Source configuration verification incomplete'}
