# Requires paths, releases and processes. The catalog is the transaction journal;
# evidence files are observations and never decide which version is committed.
. (Join-Path $PSScriptRoot 'platform-engine-configuration.ps1')
. (Join-Path $PSScriptRoot 'platform-mcp-configuration.ps1')
function Get-ReleaseProcessSnapshot([hashtable]$Layout,[string]$ExcludeRole='',[switch]$AllowStopped){
    $result=@()
    foreach($entry in (Read-PlatformProcesses $Layout)){
        if($entry.role -eq $ExcludeRole){continue}
        try{$state=Get-PlatformInstanceState $entry $Layout}
        catch{if(-not $AllowStopped){throw};$state=@{process=$null;requires_stop=$true}}
        if((-not $state.process -or $state.requires_stop) -and -not $AllowStopped){throw ('Reconcile the existing process before release: '+$entry.role)}
        $result+=@{id=$entry.id;role=$entry.role;pid=$(if($state.process){$state.process.Id}else{0});started_at=$(if($state.process){$state.process.StartTime.ToUniversalTime().ToString('o')}else{$null});binary=$entry.binary;launch_config_sha256=$entry['launch_config_sha256'];runtime_state=$(if($state.requires_stop){'unresolved'}elseif($state.process){'running'}else{'stopped'})}
    }
    return ,@($result|Sort-Object id)
}
function Test-ReleaseSnapshotsEqual($Left,$Right){
    $a=@($Left);$b=@($Right)
    if($a.Count -ne $b.Count){return $false}
    for($i=0;$i -lt $a.Count;$i++){foreach($key in @('id','role','pid','started_at','binary','launch_config_sha256','runtime_state')){if([string]$a[$i][$key] -cne [string]$b[$i][$key]){return $false}}}
    return $true
}
function Assert-ReleaseSnapshot([hashtable]$Layout,[string]$Role,$Expected){
    $actual=Get-ReleaseProcessSnapshot $Layout $Role;$expectedList=@($Expected)
    if($actual.Count -ne $expectedList.Count){throw 'Non-target service instance count changed during release.'}
    for($i=0;$i -lt $actual.Count;$i++){
        foreach($key in @('id','role','pid','started_at','binary','launch_config_sha256')){if([string]$actual[$i][$key] -cne [string]$expectedList[$i][$key]){throw 'Non-target service identity changed during release.'}}
    }
}
function Assert-ReleaseConfiguration([hashtable]$Layout,[string]$Role,[System.Collections.IDictionary]$Reference){
    $path=Join-Path $Layout.config_root ('services/'+$Role+'.json')
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
    if($Reference['config_sha256'] -cnotmatch '^[a-f0-9]{64}$' -or $Reference.config_sha256 -cne $hash){throw 'Configuration differs from this deployment. A separate configuration migration is required.'}
    return $hash
}
function Wait-ReleaseReady([hashtable]$Layout,[string]$Role,[int]$Replicas,[System.Collections.IDictionary]$Reference,[int]$TimeoutSeconds=30){
    $null=Assert-ReleaseConfiguration $Layout $Role $Reference
    $descriptor=Read-ReleaseDescriptor $Layout $Reference -Verify
    $expectedBinary=Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do{
        $entries=@((Read-PlatformProcesses $Layout)|Where-Object role -eq $Role)
        if($entries.Count -ne $Replicas){throw 'Release instance count differs from the requested replicas.'}
        $readyCount=0
        foreach($entry in $entries){
            if($entry.binary -ne $expectedBinary -or -not $entry['release_reference'] -or $entry.release_reference.id -cne $Reference.id){throw 'The started process does not belong to the selected release.'}
            $instance=Get-PlatformInstanceState $entry $Layout
            if(-not $instance.process){throw 'Release root exited before readiness.'}
            $listeners=@(Get-NetTCPConnection -State Listen -OwningProcess $instance.process.Id -ErrorAction SilentlyContinue|Where-Object{$_.LocalAddress -in @('127.0.0.1','0.0.0.0')})
            if(-not $listeners.Count){continue}
            if($listeners.Count -ne 1){throw 'Ambiguous service readiness listener.'}
            # Read only the validated launch snapshot and only send to a loopback
            # listener owned by this exact root. Never follow redirects.
            $config=Read-ReleaseJson $entry.launch_config
            $key=if($Role -eq 'control'){'ADMIN_TOKEN'}elseif($Role -eq 'futures'){'BUSINESS_TOKEN'}else{'SERVICE_TOKEN'}
            $token=$config[$key];if(-not $token -and $Role -eq 'futures'){$token=$config['ADMIN_TOKEN']};if(-not $token){$token=$config['SERVICE_TOKEN']}
            if(-not $token){throw 'Missing readiness identity.'}
            try{
                $response=Invoke-WebRequest ('http://127.0.0.1:'+$listeners[0].LocalPort+'/readyz') -Headers @{Authorization=('Bearer '+$token)} -NoProxy -MaximumRedirection 0 -TimeoutSec 2
                if($response.StatusCode -eq 200){$readyCount++}
            }catch{}finally{$token=$null;$config=$null}
        }
        if($readyCount -eq $Replicas){return}
        Start-Sleep -Milliseconds 250
    }while([datetime]::UtcNow -lt $deadline)
    throw 'Selected release did not become ready within the bounded timeout.'
}
function Save-ReleasePhase([hashtable]$Layout,[string]$Role,[string]$Operation,[string]$Phase){
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.services[$Role].pending.id -cne $Operation){throw 'Release operation changed unexpectedly.'}
    $catalog.services[$Role].pending.phase=$Phase
    Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
    return $catalog.services[$Role].pending
}
function Restore-PendingRelease([hashtable]$Layout,[string]$Role,[string]$Scripts,[IO.FileStream]$Lock,[int]$TimeoutSeconds=30,[scriptblock]$Checkpoint={param($point)}){
    Assert-NoPendingOwnerMigration $Layout
    $catalog=Read-ReleaseCatalog $Layout;$pending=$catalog.services[$Role]['pending']
    if(-not $pending){throw 'No pending release to recover.'}
    if($pending['configuration']){
        if($pending.action -cin @('configure-mcp-hosts','configure-source-hosts')){return Restore-PendingMCPConfiguration $Layout $Role $Scripts $Lock $TimeoutSeconds $Checkpoint}
        if($Role -cne 'runtime'){throw 'Unknown configuration migration role.'}
        return Restore-PendingEngineConfiguration $Layout $Scripts $Lock $TimeoutSeconds $Checkpoint
    }
    $othersBefore=Get-ReleaseProcessSnapshot $Layout $Role -AllowStopped
    # Validation happens before stopping anything. A missing/tampered old bundle
    # stays pending for repair; silently picking a third version is forbidden.
    $null=Read-ReleaseDescriptor $Layout $pending.prior -Verify
    $null=Assert-ReleaseConfiguration $Layout $Role $pending.prior
    if($Role -eq 'knowledge'){
        $priorDescriptor=Read-ReleaseDescriptor $Layout $pending.prior -Verify
        Assert-CompatibleRelease (Read-ReleaseDescriptor $Layout $pending.target -Verify) $priorDescriptor
        Assert-KnowledgeArchiveDeployment $Layout $priorDescriptor
    }
    if($Role -in @('worker','telemetry')){$priorDescriptor=Read-ReleaseDescriptor $Layout $pending.prior -Verify;Assert-ExecutionAccessDeployment $Layout @($Role) @{$Role=$priorDescriptor}}
    if($Role -in @('runtime','worker')){$priorDescriptor=Read-ReleaseDescriptor $Layout $pending.prior -Verify;Assert-SourceExecutionDeployment $Layout @{$Role=$priorDescriptor}}
    if($Role -in @('runtime','control')){$priorDescriptor=Read-ReleaseDescriptor $Layout $pending.prior -Verify;Assert-ReceiptManagementDeployment $Layout @{$Role=$priorDescriptor}}
    if($Role -in @('registry','runtime','control')){$priorDescriptor=Read-ReleaseDescriptor $Layout $pending.prior -Verify;Assert-ModelManagementDeployment $Layout @{$Role=$priorDescriptor}}
    $pending=Save-ReleasePhase $Layout $Role $pending.id 'reverting'
    & $Checkpoint 'reverting'
    & (Join-Path $Scripts 'Stop-Local.ps1') -LayoutPath $Layout.layout_path -Service @($Role) -MaintenanceLock $Lock
    if($Role -eq 'knowledge'){Assert-KnowledgeArchiveDeployment $Layout $priorDescriptor -Stopped}
    if($Role -in @('registry','runtime','control')){Assert-ModelManagementDeployment $Layout @{$Role=$priorDescriptor} -RegistryStopped:($Role -eq 'registry')}
    if($pending.replicas -gt 0){
        & (Join-Path $Scripts 'Start-Local.ps1') -LayoutPath $Layout.layout_path -Service @($Role) -Workers ([Math]::Max(1,$pending.replicas)) -PendingOperation $pending.id -MaintenanceLock $Lock
    }
    Wait-ReleaseReady $Layout $Role $pending.replicas $pending.prior $TimeoutSeconds
    $othersAfter=Get-ReleaseProcessSnapshot $Layout $Role -AllowStopped
    $othersUnchanged=Test-ReleaseSnapshotsEqual $pending.non_target $othersAfter
    $recoveryDidNotChangeOthers=Test-ReleaseSnapshotsEqual $othersBefore $othersAfter
    & $Checkpoint 'recovery_ready'
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.services[$Role].pending.id -cne $pending.id){throw 'Recovery operation changed unexpectedly.'}
    $catalog.services[$Role].pending=$null;$catalog.generation++
    Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
    if(-not $othersUnchanged){Write-Warning 'The prior target release is restored. Other service identities changed or stopped independently; inspect status and reconcile them separately.'}
    return @{operation=$pending.id;outcome='restored_prior';role=$Role;replicas=$pending.replicas;current=$pending.prior.id;non_target_unchanged=$othersUnchanged;non_target_unchanged_during_recovery=$recoveryDidNotChangeOthers;non_target_status=$othersAfter}
}
function Invoke-ReleaseChange([hashtable]$Layout,[string]$Role,[string]$Action,[System.Collections.IDictionary]$Target,[string]$Scripts,[IO.FileStream]$Lock,[int]$TimeoutSeconds=30,[scriptblock]$Checkpoint={param($point)}){
    Assert-NoPendingOwnerMigration $Layout
    if($Role -notin @('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources')){throw 'Select one deployable service; schema migration is a separate operation.'}
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -ne 2){throw 'Register and verify the release baseline first.'}
    if($Action -eq 'recover'){return Restore-PendingRelease $Layout $Role $Scripts $Lock $TimeoutSeconds $Checkpoint}
    Assert-NoPendingRelease $catalog
    $entry=$catalog.services[$Role];if(-not $entry){throw 'Service is not registered.'}
    if($Action -eq 'rollback'){$Target=$entry['previous']}
    elseif($Action -ne 'update'){throw 'Unknown release action.'}
    if(-not $Target){throw 'No target release is available.'}
    $prior=$entry.current
    if($prior.id -ceq $Target.id){throw 'Selected release is already current.'}
    $before=Read-ReleaseDescriptor $Layout $prior -Verify;$after=Read-ReleaseDescriptor $Layout $Target -Verify
    if($before.role -cne $Role -or $after.role -cne $Role){throw 'Descriptor does not match selected service.'}
    if($after.provenance['dirty']){throw 'Development builds cannot be activated as managed releases. Commit and rebuild first.'}
    Assert-CompatibleRelease $before $after
    if($Role -eq 'knowledge'){Assert-KnowledgeArchiveDeployment $Layout $after}
    if($Role -in @('worker','telemetry')){Assert-ExecutionAccessDeployment $Layout @($Role) @{$Role=$after}}
    if($Role -in @('runtime','control')){Assert-ReceiptManagementDeployment $Layout @{$Role=$after}}
    if($Role -in @('runtime','worker')){Assert-SourceExecutionDeployment $Layout @{$Role=$after}}
    if($Role -in @('registry','runtime','control')){Assert-ModelManagementDeployment $Layout @{$Role=$after}}
    $configHash=Assert-ReleaseConfiguration $Layout $Role $prior
    $targetBound=@{};foreach($key in $Target.Keys){$targetBound[$key]=$Target[$key]}
    if($targetBound['config_sha256'] -and $targetBound.config_sha256 -cne $configHash){throw 'Rollback configuration differs from the currently deployed configuration.'}
    $targetBound.config_sha256=$configHash
    $all=Get-ReleaseProcessSnapshot $Layout
    $targets=@($all|Where-Object role -eq $Role);$nonTarget=@($all|Where-Object role -ne $Role)
    $priorBinary=Resolve-ReleasePath $Layout.release_root $before.assets.binary
    foreach($running in @((Read-PlatformProcesses $Layout)|Where-Object role -eq $Role)){
        if($running.binary -ne $priorBinary -or ($running['release_reference'] -and $running.release_reference.id -cne $prior.id)){throw 'Running service differs from the committed release; reconcile its deployment before updating.'}
        if($running['source_config_sha256'] -and $running.source_config_sha256 -cne $configHash){throw 'Running service uses an older configuration than the registered deployment.'}
    }
    if(($Role -ne 'worker' -and $targets.Count -gt 1) -or $targets.Count -gt 16){throw 'Unsupported replica topology.'}
    $pending=@{id=[guid]::NewGuid().ToString('N');action=$Action;phase='prepared';prior=$prior;target=$targetBound;replicas=$targets.Count;non_target=$nonTarget;started_at=[datetime]::UtcNow.ToString('o')}
    $entry.pending=$pending
    Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
    try{
        & $Checkpoint 'prepared'
        & (Join-Path $Scripts 'Stop-Local.ps1') -LayoutPath $Layout.layout_path -Service @($Role) -MaintenanceLock $Lock
        $null=Save-ReleasePhase $Layout $Role $pending.id 'stopped'
        & $Checkpoint 'stopped'
        if($Role -eq 'knowledge'){Assert-KnowledgeArchiveDeployment $Layout $after -Stopped}
        if($Role -in @('registry','runtime','control')){Assert-ModelManagementDeployment $Layout @{$Role=$after} -RegistryStopped:($Role -eq 'registry')}
        if($pending.replicas -gt 0){
            & (Join-Path $Scripts 'Start-Local.ps1') -LayoutPath $Layout.layout_path -Service @($Role) -Workers ([Math]::Max(1,$pending.replicas)) -PendingOperation $pending.id -MaintenanceLock $Lock
        }
        & $Checkpoint 'started'
        Wait-ReleaseReady $Layout $Role $pending.replicas $targetBound $TimeoutSeconds
        Assert-ReleaseSnapshot $Layout $Role $nonTarget
        & $Checkpoint 'ready'
        $catalog=Read-ReleaseCatalog $Layout
        if($catalog.services[$Role].pending.id -cne $pending.id){throw 'Release operation changed before commit.'}
        $catalog.services[$Role].current=$targetBound;$catalog.services[$Role].previous=$prior;$catalog.services[$Role].pending=$null;$catalog.generation++
        Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
        & $Checkpoint 'committed'
        return @{operation=$pending.id;outcome='committed';role=$Role;replicas=$pending.replicas;current=$targetBound.id;previous=$prior.id;non_target_unchanged=$true;readiness=if($pending.replicas){'verified'}else{'not_started'}}
    }catch{
        $failure=$_
        # A crash/throw after catalog commit cannot undo it based on an old local
        # journal. A pending transaction, however, always restores its prior set.
        $observed=Read-ReleaseCatalog $Layout
        if($observed.services[$Role]['pending']){
            try{$null=Restore-PendingRelease $Layout $Role $Scripts $Lock $TimeoutSeconds}
            catch{Write-Warning 'Release recovery is incomplete; the pending operation is retained. Run release-recover after correcting the reported dependency.';throw}
        }
        throw $failure
    }
}
