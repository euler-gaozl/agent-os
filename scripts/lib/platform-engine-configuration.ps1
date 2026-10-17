# The existing Runtime pending release is the sole commit journal. Config bytes
# are encrypted with DPAPI and never enter descriptors, logs or command lines.
. (Join-Path $PSScriptRoot 'platform-recovery.ps1')
function Get-SubmissionEngine([System.Collections.IDictionary]$Config){
    $engine=[string]$Config['DEFAULT_RUN_ENGINE']
    if(-not $engine){return 'dsh-0.2.0-rc.2-evidence-v1'}
    if($engine -cnotin @('dsh-0.2.0-rc.2-evidence-v1',(Get-SourceEngineName),(Get-ResidentEngineName),(Get-BudgetEngineName),(Get-NativeEngineName),(Get-FinalEngineName),(Get-GuardedEngineName))){throw 'Unknown submission engine in configuration.'}
    return $engine
}
function Get-EngineChangeDirectory([hashtable]$Layout,[string]$ID){
    if($ID -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid configuration operation identity.'}
    $root=Join-Path $Layout.config_root 'engine-changes'
    $path=Join-Path $root $ID
    Assert-ReleasePhysicalPath $root $path
    return $path
}
function Read-EngineChange([hashtable]$Layout,[System.Collections.IDictionary]$Pending){
    if($Pending.action -cne 'configure-default' -or $Pending.configuration.format -ne 1 -or $Pending.configuration.scope -cne 'runtime-default' -or $Pending.replicas -ne 1){throw 'Invalid Runtime configuration journal.'}
    if($Pending.prior.id -cne $Pending.target.id -or $Pending.prior.sha256 -cne $Pending.target.sha256 -or $Pending.prior.manifest -cne $Pending.target.manifest){throw 'Default-engine changes cannot replace Runtime code.'}
    if($Pending.prior.config_sha256 -ceq $Pending.target.config_sha256){throw 'Configuration change has identical versions.'}
    $descriptor=Read-ReleaseDescriptor $Layout $Pending.prior -Verify
    if($descriptor.role -cne 'runtime' -or -not $descriptor['source_execution']){throw 'Configuration change requires source-aware Runtime.'}
    $directory=Get-EngineChangeDirectory $Layout $Pending.id
    $result=@{}
    foreach($version in @('prior','target')){
        $path=Join-Path $directory ($version+'.dpapi');Assert-ReleasePhysicalPath $directory $path
        $bytes=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes($path))
        if((Get-BytesHash $bytes) -cne $Pending[$version].config_sha256){throw 'Saved Runtime configuration digest differs from the journal.'}
        try{$config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable}catch{throw 'Saved Runtime configuration is invalid.'}
        foreach($value in $config.Values){if($value -isnot [string]){throw 'Runtime configuration values must be strings.'}}
        $result[$version]=@{bytes=$bytes;config=$config}
    }
    $keys=@($result.prior.config.Keys|Where-Object{$_ -cne 'DEFAULT_RUN_ENGINE'})
    $nextKeys=@($result.target.config.Keys|Where-Object{$_ -cne 'DEFAULT_RUN_ENGINE'})
    if(@(Compare-Object $keys $nextKeys).Count){throw 'Default-engine migration changed unrelated configuration keys.'}
    foreach($key in $keys){if($result.prior.config[$key] -cne $result.target.config[$key]){throw 'Default-engine migration changed unrelated configuration.'}}
    if((Get-SubmissionEngine $result.prior.config) -ceq (Get-SubmissionEngine $result.target.config)){throw 'Default engine did not change.'}
    if($Pending.configuration['previous_after']){
        $before=$Pending.configuration.previous_before;$after=$Pending.configuration.previous_after
        if(-not $before -or $before.id -cne $after.id -or $before.sha256 -cne $after.sha256 -or $before.manifest -cne $after.manifest -or $before.config_sha256 -cne $Pending.prior.config_sha256 -or $after.config_sha256 -cne $Pending.target.config_sha256){throw 'Invalid prior-release configuration migration.'}
    }
    return $result
}
function Write-EngineConfiguration([hashtable]$Layout,[byte[]]$Bytes){
    $path=Join-Path $Layout.config_root 'services/runtime.json'
    Assert-ReleasePhysicalPath $Layout.config_root $path
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllBytes($temporary,$Bytes);[IO.File]::Move($temporary,$path,$true)}
    finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
function Assert-ExecutionQuiescent([hashtable]$Layout,[System.Collections.IDictionary]$Config){
    $connection=Get-DatabaseConnection $Config.DATABASE_URL
    try{
        $count=Invoke-RecoverySQL $Layout.postgres_bin $connection "BEGIN READ ONLY; SET LOCAL statement_timeout='10000'; SELECT count(*) FROM public.runs WHERE status IN('queued','running','waiting_children'); COMMIT;"
        if($count.Trim() -cne '0'){throw 'Execution work is active; finish or reconcile it before changing the submission default.'}
    }finally{$connection=$null}
}
function Assert-SourceWorkersReady([hashtable]$Layout,[System.Collections.IDictionary]$Catalog,[int]$TimeoutSeconds,[string]$Engine=(Get-SourceEngineName)){
    $reference=$Catalog.services.worker.current
    $descriptor=Read-ReleaseDescriptor $Layout $reference -Verify
    $selected=@(Get-SourceEngineProfiles|Where-Object engine -CEQ $Engine)
    if($selected.Count -ne 1 -or -not $descriptor[$selected[0].metadata]){throw 'Source default requires an installed Worker for the selected engine.'}
    $configHash=Assert-ReleaseConfiguration $Layout worker $reference
    $entries=@((Read-PlatformProcesses $Layout)|Where-Object role -eq 'worker')
    if($entries.Count -lt 1 -or $entries.Count -gt 16){throw 'Source default requires at least one running managed source Worker.'}
    $runtimeConfig=Get-BoundRuntimeConfiguration $Layout $Catalog
    $runtimeConnection=Get-DatabaseConnection $runtimeConfig.DATABASE_URL
    $runtimeEntries=@((Read-PlatformProcesses $Layout)|Where-Object role -eq 'runtime')
    if($runtimeEntries.Count -ne 1){throw 'Source default requires exactly one local Runtime endpoint.'}
    $runtimeProcess=Get-PlatformProcess $runtimeEntries[0]
    if(-not $runtimeProcess){throw 'Source Runtime process is not running.'}
    $listeners=@(Get-NetTCPConnection -State Listen -OwningProcess $runtimeProcess.Id -ErrorAction SilentlyContinue|Where-Object{$_.LocalAddress -in @('127.0.0.1','0.0.0.0')})
    if($listeners.Count -ne 1){throw 'Source Runtime endpoint is ambiguous.'}
    try{$peers=$runtimeConfig.SERVICE_PEERS|ConvertFrom-Json -AsHashtable}catch{throw 'Runtime peer identity configuration is invalid.'}
    foreach($entry in $entries){
        $state=Get-PlatformInstanceState $entry $Layout
        if(-not $state.process -or $state.requires_stop -or $entry['source_config_sha256'] -cne $configHash){throw 'Worker configuration or process ownership is unresolved.'}
        $config=Read-ReleaseJson $entry.launch_config
        try{
            foreach($profile in (Get-SourceEngineProfiles)){
                $expected=if($descriptor.assets[$profile.asset]){Join-Path (Resolve-ReleasePath $Layout.release_root $descriptor.assets[$profile.asset]) 'source-runner.mjs'}else{''}
                if([string]$config[$profile.environment] -cne $expected){throw 'Live Worker is not using the selected source Harness.'}
            }
            if($config['AGENTOS_NODE'] -cne (Resolve-ReleasePath $Layout.release_root $descriptor.assets.node)){throw 'Live Worker is not using the selected source Harness.'}
            $connection=Get-DatabaseConnection $config.DATABASE_URL
            foreach($key in @('host','port','database')){if([string]$connection[$key] -cne [string]$runtimeConnection[$key]){throw 'Live Worker uses a different execution database.'}}
            $endpoint=if($config['RUNTIME_URL']){[string]$config.RUNTIME_URL}else{'http://127.0.0.1:8094'}
            try{$uri=[uri]$endpoint}catch{throw 'Live Worker Runtime endpoint is invalid.'}
            if($uri.Scheme -cne 'http' -or $uri.Host -cne '127.0.0.1' -or $uri.Port -ne $listeners[0].LocalPort -or $uri.AbsolutePath -cne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo){throw 'Live Worker Runtime endpoint does not match the owned local Runtime.'}
            if(-not $config['SERVICE_TOKEN'] -or $peers['worker'] -cne (Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($config.SERVICE_TOKEN)))){throw 'Runtime does not recognize the live Worker identity.'}
        }finally{$config=$null;$connection=$null}
    }
    Wait-ReleaseReady $Layout worker $entries.Count $reference $TimeoutSeconds
    $runtimeConfig=$null;$runtimeConnection=$null;$peers=$null
}
function Restore-PendingEngineConfiguration([hashtable]$Layout,[string]$Scripts,[IO.FileStream]$Lock,[int]$TimeoutSeconds=30,[scriptblock]$Checkpoint={param($point)}){
    Assert-NoPendingOwnerMigration $Layout
    $catalog=Read-ReleaseCatalog $Layout;$pending=$catalog.services.runtime['pending']
    if(-not $pending -or -not $pending['configuration']){throw 'No pending Runtime configuration change.'}
    $saved=Read-EngineChange $Layout $pending
    $before=Get-ReleaseProcessSnapshot $Layout runtime -AllowStopped
    # A disk file outside BOTH recorded versions is an unrelated manual change.
    # Preserve it for review instead of silently overwriting an unknown secret.
    $path=Join-Path $Layout.config_root 'services/runtime.json'
    if(Test-Path -LiteralPath $path){$hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();if($hash -cnotin @($pending.prior.config_sha256,$pending.target.config_sha256)){throw 'Runtime configuration is neither recorded version; recovery refused before stop.'}}
    $pending=Save-ReleasePhase $Layout runtime $pending.id 'reverting'
    & $Checkpoint 'reverting'
    & (Join-Path $Scripts 'Stop-Local.ps1') -LayoutPath $Layout.layout_path -Service runtime -MaintenanceLock $Lock
    Write-EngineConfiguration $Layout $saved.prior.bytes
    & $Checkpoint 'prior_configuration_written'
    & (Join-Path $Scripts 'Start-Local.ps1') -LayoutPath $Layout.layout_path -Service runtime -PendingOperation $pending.id -MaintenanceLock $Lock
    Wait-ReleaseReady $Layout runtime 1 $pending.prior $TimeoutSeconds
    $null=Save-ReleasePhase $Layout runtime $pending.id 'recovery_ready'
    & $Checkpoint 'recovery_ready'
    $after=Get-ReleaseProcessSnapshot $Layout runtime -AllowStopped
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.services.runtime.pending.id -cne $pending.id){throw 'Runtime configuration recovery identity changed.'}
    $catalog.services.runtime.pending=$null;$catalog.generation++
    Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
    return @{operation=$pending.id;outcome='restored_prior';role='runtime';kind='configuration';current=$pending.prior.id;default_run_engine=(Get-SubmissionEngine $saved.prior.config);non_target_unchanged=(Test-ReleaseSnapshotsEqual $pending.non_target $after);non_target_unchanged_during_recovery=(Test-ReleaseSnapshotsEqual $before $after);readiness='verified'}
}
function Set-DefaultEngine([hashtable]$Layout,[string]$Engine,[string]$Scripts,[IO.FileStream]$Lock,[int]$TimeoutSeconds=30,[scriptblock]$Checkpoint={param($point)}){
    Assert-NoPendingOwnerMigration $Layout
    $nextEngine=switch -CaseSensitive ($Engine){source {Get-SourceEngineName};resident {Get-ResidentEngineName};budget {Get-BudgetEngineName};native {Get-NativeEngineName};final {Get-FinalEngineName};guarded {Get-GuardedEngineName};historical {'dsh-0.2.0-rc.2-evidence-v1'};default {throw 'Choose source, resident, budget, native, final, guarded or historical.'}}
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -ne 2){throw 'Default changes require a versioned deployment.'}
    Assert-NoPendingRelease $catalog
    $prior=$catalog.services.runtime.current
    $runtime=Read-ReleaseDescriptor $Layout $prior -Verify
    $worker=Read-ReleaseDescriptor $Layout $catalog.services.worker.current -Verify
    if(-not $runtime['source_execution']){throw 'Install the source-aware Runtime before changing its default.'}
    $config=Get-BoundRuntimeConfiguration $Layout $catalog
    if((Get-SubmissionEngine $config) -ceq $nextEngine){throw 'The selected engine is already the default.'}
    $facts=Get-SourceExecutionFacts $Layout $config
    Assert-SourceExecutionPolicy $runtime $worker $nextEngine $facts
    Assert-ModelManagementDeployment $Layout -DefaultEngine $nextEngine
    Assert-ExecutionQuiescent $Layout $config
    $snapshot=Get-ReleaseProcessSnapshot $Layout
    if(@($snapshot|Where-Object role -eq 'runtime').Count -ne 1){throw 'Start exactly one managed Runtime before changing its default.'}
    Wait-ReleaseReady $Layout runtime 1 $prior $TimeoutSeconds
    if($Engine -cin @('source','resident','budget','native','final')){Assert-SourceWorkersReady $Layout $catalog $TimeoutSeconds $nextEngine}
    $bytes=[IO.File]::ReadAllBytes((Join-Path $Layout.config_root 'services/runtime.json'))
    if((Get-BytesHash $bytes) -cne $prior.config_sha256){throw 'Runtime configuration changed during preparation.'}
    $targetConfig=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable
    $targetConfig.DEFAULT_RUN_ENGINE=$nextEngine
    $targetBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $targetConfig -Depth 12))
    $target=@{};foreach($key in $prior.Keys){$target[$key]=$prior[$key]};$target.config_sha256=Get-BytesHash $targetBytes
    $id=[guid]::NewGuid().ToString('N');$directory=Get-EngineChangeDirectory $Layout $id
    New-ProtectedDirectory $directory
    [IO.File]::WriteAllBytes((Join-Path $directory 'prior.dpapi'),(Protect-RecoveryBytes $bytes))
    [IO.File]::WriteAllBytes((Join-Path $directory 'target.dpapi'),(Protect-RecoveryBytes $targetBytes))
    $pending=@{id=$id;action='configure-default';phase='prepared';prior=$prior;target=$target;replicas=1;non_target=@($snapshot|Where-Object role -ne 'runtime');configuration=@{format=1;scope='runtime-default'};started_at=[datetime]::UtcNow.ToString('o')}
    $previous=$catalog.services.runtime['previous']
    if($previous -and $previous['config_sha256'] -ceq $prior.config_sha256){
        # The sole changed field is understood by the source-aware Runtime;
        # legacy code may only be selected after the existing source policy
        # permits it. Keep the prior code's otherwise identical configuration
        # binding usable after a source -> historical round trip.
        $previousDescriptor=Read-ReleaseDescriptor $Layout $previous -Verify
        Assert-CompatibleRelease $previousDescriptor $runtime
        $previousAfter=@{};foreach($key in $previous.Keys){$previousAfter[$key]=$previous[$key]}
        $previousAfter.config_sha256=$target.config_sha256
        $pending.configuration.previous_before=$previous;$pending.configuration.previous_after=$previousAfter
    }
    $null=Read-EngineChange $Layout $pending
    $catalog.services.runtime.pending=$pending
    Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
    try{
        & $Checkpoint 'prepared'
        & (Join-Path $Scripts 'Stop-Local.ps1') -LayoutPath $Layout.layout_path -Service runtime -MaintenanceLock $Lock
        $null=Save-ReleasePhase $Layout runtime $id 'stopped'
        & $Checkpoint 'stopped'
        Assert-ExecutionQuiescent $Layout $config
        Write-EngineConfiguration $Layout $targetBytes
        & $Checkpoint 'configuration_replaced'
        $null=Save-ReleasePhase $Layout runtime $id 'configuration_written'
        & $Checkpoint 'configuration_written'
        & (Join-Path $Scripts 'Start-Local.ps1') -LayoutPath $Layout.layout_path -Service runtime -PendingOperation $id -MaintenanceLock $Lock
        $null=Save-ReleasePhase $Layout runtime $id 'started'
        & $Checkpoint 'started'
        Wait-ReleaseReady $Layout runtime 1 $target $TimeoutSeconds
        if($Engine -cin @('source','resident','budget','native','final')){Assert-SourceWorkersReady $Layout (Read-ReleaseCatalog $Layout) $TimeoutSeconds $nextEngine}
        Assert-ReleaseSnapshot $Layout runtime $pending.non_target
        $null=Save-ReleasePhase $Layout runtime $id 'ready'
        & $Checkpoint 'ready'
        $catalog=Read-ReleaseCatalog $Layout
        if($catalog.services.runtime.pending.id -cne $id){throw 'Runtime configuration operation changed before commit.'}
        if($pending.configuration['previous_after']){
            foreach($key in @('id','sha256','manifest','config_sha256')){if($catalog.services.runtime.previous[$key] -cne $pending.configuration.previous_before[$key]){throw 'Previous code release changed during configuration migration.'}}
            $catalog.services.runtime.previous=$pending.configuration.previous_after
        }
        $catalog.services.runtime.current=$target;$catalog.services.runtime.pending=$null;$catalog.generation++
        Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
        & $Checkpoint 'committed'
        return @{operation=$id;outcome='committed';role='runtime';kind='configuration';current=$target.id;default_run_engine=$nextEngine;non_target_unchanged=$true;readiness='verified'}
    }catch{
        $failure=$_;$observed=Read-ReleaseCatalog $Layout
        if($observed.services.runtime['pending']){
            try{$null=Restore-PendingEngineConfiguration $Layout $Scripts $Lock $TimeoutSeconds}
            catch{Write-Warning 'Runtime configuration recovery is incomplete; the pending journal is retained. Run release-recover for runtime after correcting the dependency.';throw}
        }
        throw $failure
    }finally{
        [Array]::Clear($bytes,0,$bytes.Length);[Array]::Clear($targetBytes,0,$targetBytes.Length);$config=$null;$targetConfig=$null
    }
}
