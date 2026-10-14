# One exact host policy changes here: MCP_ALLOWED_HOSTS for Runtime/ToolHub,
# SOURCE_ALLOWED_HOSTS for Sources. Existing function names remain compatible.
# The service release journal owns commit/recovery; configurations use DPAPI.
function Get-NetworkHostProfile([string]$Role,[string]$Policy='network'){
    if($Policy -ceq 'receipt-exports'){
        if($Role -cne 'runtime'){throw 'Receipt projections belong to Runtime.'}
        return @{key='APP_RECEIPT_EXPORTS';scope='receipt-exports';action='configure-receipt-exports';kind='receipt_configuration'}
    }
    if($Policy -cne 'network'){throw 'Unknown service configuration policy.'}
    if($Role -ceq 'sources'){return @{key='SOURCE_ALLOWED_HOSTS';scope='source-hosts';action='configure-source-hosts';kind='source_configuration'}}
    if($Role -cin @('runtime','toolhub')){return @{key='MCP_ALLOWED_HOSTS';scope='mcp-hosts';action='configure-mcp-hosts';kind='mcp_configuration'}}
    throw 'Host policy is owned by runtime, toolhub or sources.'
}
function ConvertTo-SourceHosts([string[]]$Hosts){
    if($Hosts.Count -eq 0 -or $Hosts.Count -gt 32){throw 'Sources needs 1 to 32 exact public DNS host names.'}
    foreach($item in $Hosts){
        $address=$null
        if($item.Length -gt 253 -or $item -cnotmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' -or [Net.IPAddress]::TryParse($item,[ref]$address) -or $item -match '\.(localhost|local|internal|test|invalid|example)$'){
            throw 'Sources entries must be lowercase exact public DNS hosts, without URLs, ports, wildcards or IP literals.'
        }
    }
    if(@($Hosts|Sort-Object -Unique).Count -ne $Hosts.Count){throw 'Duplicate Sources host.'}
    return (@($Hosts|Sort-Object) -join ',')
}
function ConvertTo-ReceiptExports([string]$Value){
    if(-not $Value -or $Value.Length -gt 32768){throw 'Receipt projection configuration must be a bounded JSON array.'}
    try{$rules=ConvertFrom-Json -InputObject $Value -AsHashtable -NoEnumerate}catch{throw 'Invalid receipt projection JSON.'}
    if($rules -isnot [array] -or $rules.Count -gt 16){throw 'Receipt projection configuration needs at most 16 entries.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($rule in $rules){
        if($rule -isnot [System.Collections.IDictionary] -or $rule.Count -ne 5){throw 'Invalid receipt projection fields.'}
        foreach($key in @('app','id','tool')){if($rule[$key] -isnot [string] -or $rule[$key] -cnotmatch '^[a-zA-Z0-9_-]{1,120}$'){throw 'Invalid receipt projection identifier.'}}
        if(-not $seen.Add($rule.app+'/'+$rule.id)){throw 'Duplicate receipt projection.'}
        foreach($key in @('input_path','output_path')){
            $path=$rule[$key]
            if($path -isnot [array] -or $path.Count -lt 1 -or $path.Count -gt 8){throw 'Receipt projections require explicit JSON string paths.'}
            foreach($part in $path){if($part -isnot [string] -or $part -cnotmatch '^[a-zA-Z0-9_-]{1,120}$'){throw 'Invalid receipt projection path.'}}
        }
    }
    return ConvertTo-Json -InputObject $rules -Depth 8 -Compress
}
function Assert-ReceiptProjectionConfiguration([hashtable]$Layout,[System.Collections.IDictionary]$Configuration){
    if([string]$Configuration.LISTEN -cnotmatch '^127\.0\.0\.1:[0-9]{1,5}$'){throw 'Receipt projection verification needs the managed loopback Runtime.'}
    $uri='http://'+$Configuration.LISTEN+'/v1/receipt-projections'
    try{$reply=Invoke-RestMethod $uri -Headers @{Authorization=('Bearer '+$Configuration.SERVICE_TOKEN)} -NoProxy -TimeoutSec 5}
    catch{throw 'Runtime does not expose the required receipt projection protocol; install the supporting Runtime first.'}
    $expected=Get-BytesHash ([Text.Encoding]::UTF8.GetBytes([string]$Configuration['APP_RECEIPT_EXPORTS']))
    if($reply.protocol -cne 'app-receipt-projection-v1' -or $reply.configuration_sha256 -cne $expected){throw 'Runtime receipt projection protocol or loaded configuration digest differs.'}
}
function ConvertTo-NetworkHosts([string]$Role,[string[]]$Hosts,[string]$Policy='network'){
    if($Policy -ceq 'receipt-exports'){
        $null=Get-NetworkHostProfile $Role $Policy
        if($Hosts.Count -ne 1){throw 'Expected one receipt projection JSON array.'}
        return ConvertTo-ReceiptExports $Hosts[0]
    }
    if($Role -ceq 'sources'){return ConvertTo-SourceHosts $Hosts}
    $null=Get-NetworkHostProfile $Role
    return ConvertTo-MCPHosts $Hosts
}
function Get-MCPManagedRoots([hashtable]$Layout){
    $roots=@($Layout)
    $path='D:\workspace\agent-platform\ops\managed-roots.json'
    if(Test-Path -LiteralPath $path){$roots+=@(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable)}
    return ,$roots
}
function Assert-MCPIngressStopped([hashtable]$Layout){
    foreach($root in (Get-MCPManagedRoots $Layout)){
        foreach($key in @('state_root','release_root')){if(-not $root[$key] -or -not(Test-PathWithin ([IO.Path]::GetFullPath($root[$key])) 'D:\workspace')){throw 'Invalid registered MCP maintenance root.'}}
        foreach($entry in (Read-PlatformProcesses $root)){
            if($entry.role -notin @('control','futures','worker')){continue}
            if(-not(Test-PathWithin $entry.binary $root.release_root)){throw 'Managed ingress binary is outside its registered root.'}
            $process=Get-PlatformProcess $entry
            Initialize-PlatformJobs
            if($entry['job_name'] -and $entry.job_name -cnotmatch '^Global\\AgentOS-[a-f0-9]{32}$'){throw 'Invalid ingress Job identity.'}
            $members=@(if($entry['job_name'] -and $entry['job_created']){[AgentOS.Maintenance.WindowsJob]::Members($entry.job_name)};foreach($child in @($entry['legacy_children']|Where-Object{$_})){$live=Get-PlatformProcess $child;if($live){$live.Id}})
            if($process -or $members.Count -or $entry['legacy_stop_intent'] -or (-not $entry['job_name'] -and -not $process)){throw 'Stop managed Console, Futures and Workers in every registered layout before MCP configuration or recovery.'}
        }
    }
}
function Assert-MCPExecutionIdle([hashtable]$Layout,[System.Collections.IDictionary]$Configuration){
    # Quiescence's older parser ignores query; restrict to its safe intersection
    # with the actual pgx DSN before it is used for this maintenance operation.
    $connection=Get-ExecutionAccessConnection $Configuration
    try{if($connection.schema -cne 'public'){throw 'MCP execution schema must be public.'};Assert-ExecutionQuiescent $Layout $Configuration}
    finally{$connection=$null}
}
function Assert-MCPInstanceConfiguration([hashtable]$Layout,[string]$Role,[System.Collections.IDictionary]$Reference,[System.Collections.IDictionary]$Configuration){
    $profile=Get-NetworkHostProfile $Role
    $descriptor=Read-ReleaseDescriptor $Layout $Reference -Verify
    foreach($entry in @((Read-PlatformProcesses $Layout)|Where-Object role -eq $Role)){
        $state=Get-PlatformInstanceState $entry $Layout
        if(-not $state.process -or $state.requires_stop -or $entry['source_config_sha256'] -cne $Reference.config_sha256 -or -not $entry['launch_config'] -or -not $entry['release_reference'] -or $entry.release_reference.id -cne $Reference.id -or $entry.binary -cne (Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary)){throw 'Live MCP consumer is not bound to its registered configuration.'}
        $launch=Read-ReleaseJson $entry.launch_config
        $expectedKeys=@($Configuration.Keys|Where-Object{$_ -cne 'INSTANCE_ID'});$actualKeys=@($launch.Keys|Where-Object{$_ -cne 'INSTANCE_ID'})
        if(@(Compare-Object $expectedKeys $actualKeys).Count){throw 'Live MCP consumer configuration differs from its registered configuration.'}
        foreach($key in @($expectedKeys)+@($profile.key)){if([string]$launch[$key] -cne [string]$Configuration[$key]){throw 'Live MCP consumer configuration differs from its registered configuration.'}}
    }
}
function ConvertTo-MCPHosts([string[]]$Hosts){
    if($Hosts.Count -gt 32){throw 'At most 32 exact MCP host:port entries are allowed.'}
    $normalized=@()
    foreach($item in $Hosts){
        if($item -cnotmatch '^(?:[a-z0-9][a-z0-9.-]*|\[[0-9a-f:]+\]):[0-9]{1,5}$'){throw 'MCP entries must be lowercase exact host:port values, without URLs or wildcards.'}
        try{$uri=[uri]('http://'+$item)}catch{throw 'Invalid MCP host:port.'}
        if($uri.Port -lt 1 -or $uri.Port -gt 65535 -or ($uri.Host+':'+$uri.Port) -cne $item -or $uri.Host.EndsWith('.')){throw 'Invalid or noncanonical MCP host:port.'}
        $normalized+=$item
    }
    if(@($normalized|Sort-Object -Unique).Count -ne $normalized.Count){throw 'Duplicate MCP host:port.'}
    return (@($normalized|Sort-Object) -join ',')
}
function Get-MCPChangeDirectory([hashtable]$Layout,[string]$ID){
    if($ID -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid MCP configuration operation identity.'}
    $root=Join-Path $Layout.config_root 'mcp-changes';$path=Join-Path $root $ID
    Assert-ReleasePhysicalPath $root $path
    return $path
}
function Read-MCPChange([hashtable]$Layout,[string]$Role,[System.Collections.IDictionary]$Pending){
    $policy=if($Pending.action -ceq 'configure-receipt-exports'){'receipt-exports'}else{'network'}
    $profile=Get-NetworkHostProfile $Role $policy
    if($Pending.action -cne $profile.action -or $Pending.configuration.format -ne 1 -or $Pending.configuration.scope -cne $profile.scope -or $Pending.configuration.role -cne $Role -or $Pending.replicas -ne 1){throw 'Invalid network host configuration journal.'}
    foreach($key in @('id','sha256','manifest')){if($Pending.prior[$key] -cne $Pending.target[$key]){throw 'MCP configuration cannot replace code.'}}
    if($Pending.prior.config_sha256 -ceq $Pending.target.config_sha256){throw 'MCP configuration versions are identical.'}
    $descriptor=Read-ReleaseDescriptor $Layout $Pending.prior -Verify
    if($descriptor.role -cne $Role){throw 'MCP configuration role differs from the release.'}
    $directory=Get-MCPChangeDirectory $Layout $Pending.id;$result=@{}
    foreach($version in @('prior','target')){
        $path=Join-Path $directory ($version+'.dpapi');Assert-ReleasePhysicalPath $directory $path
        $bytes=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes($path))
        if((Get-BytesHash $bytes) -cne $Pending[$version].config_sha256){throw 'Saved MCP configuration digest differs.'}
        try{$config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable}catch{throw 'Invalid saved MCP configuration.'}
        foreach($value in $config.Values){if($value -isnot [string]){throw 'Service configuration values must be strings.'}}
        $result[$version]=@{bytes=$bytes;config=$config}
    }
    $keys=@($result.prior.config.Keys|Where-Object{$_ -cne $profile.key})
    $nextKeys=@($result.target.config.Keys|Where-Object{$_ -cne $profile.key})
    if(@(Compare-Object $keys $nextKeys).Count){throw 'MCP migration changed unrelated keys.'}
    foreach($key in $keys){if($result.prior.config[$key] -cne $result.target.config[$key]){throw 'MCP migration changed unrelated configuration.'}}
    $next=[string]$result.target.config[$profile.key]
    $values=if($policy -ceq 'receipt-exports'){@($next)}else{@(if($next){$next.Split(',')})}
    if($next -cne (ConvertTo-NetworkHosts $Role $values $policy) -or $next -ceq [string]$result.prior.config[$profile.key]){throw 'Service policy did not change or is not canonical.'}
    if($Pending.configuration['previous_after']){
        $before=$Pending.configuration.previous_before;$after=$Pending.configuration.previous_after
        if(-not $before){throw 'Missing prior-code binding.'}
        foreach($key in @('id','sha256','manifest')){if($before[$key] -cne $after[$key]){throw 'Prior code changed during MCP configuration.'}}
        if($before.config_sha256 -cne $Pending.prior.config_sha256 -or $after.config_sha256 -cne $Pending.target.config_sha256){throw 'Invalid prior-code configuration binding.'}
    }
    return $result
}
function Write-MCPConfiguration([hashtable]$Layout,[string]$Role,[byte[]]$Bytes){
    $null=Get-NetworkHostProfile $Role
    $path=Join-Path $Layout.config_root ('services/'+$Role+'.json');Assert-ReleasePhysicalPath $Layout.config_root $path
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllBytes($temporary,$Bytes);[IO.File]::Move($temporary,$path,$true)}
    finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
function Restore-PendingMCPConfiguration([hashtable]$Layout,[string]$Role,[string]$Scripts,[IO.FileStream]$Lock,[int]$TimeoutSeconds=30,[scriptblock]$Checkpoint={param($point)}){
    Assert-NoPendingOwnerMigration $Layout
    $catalog=Read-ReleaseCatalog $Layout;$pending=$catalog.services[$Role]['pending']
    if(-not $pending){throw 'No pending MCP configuration.'}
    $saved=Read-MCPChange $Layout $Role $pending
    foreach($entry in @((Read-PlatformProcesses $Layout)|Where-Object role -eq $Role)){
        $state=Get-PlatformInstanceState $entry $Layout
        if($state.process){
            $known=@(@('prior','target')|Where-Object{$pending[$_].config_sha256 -ceq $entry['source_config_sha256']})
            if($known.Count -ne 1){throw 'Live MCP recovery configuration is not a recorded version.'}
            Assert-MCPInstanceConfiguration $Layout $Role $pending[$known[0]] $saved[$known[0]].config
        }
    }
    Assert-MCPIngressStopped $Layout
    $execution=if($Role -ceq 'runtime'){$saved.prior.config}else{Get-BoundRuntimeConfiguration $Layout $catalog}
    Assert-MCPExecutionIdle $Layout $execution
    $before=Get-ReleaseProcessSnapshot $Layout $Role -AllowStopped
    $path=Join-Path $Layout.config_root ('services/'+$Role+'.json')
    if(Test-Path -LiteralPath $path){$hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();if($hash -cnotin @($pending.prior.config_sha256,$pending.target.config_sha256)){throw 'MCP configuration is neither recorded version; recovery refused before stop.'}}
    $pending=Save-ReleasePhase $Layout $Role $pending.id 'reverting'; & $Checkpoint 'reverting'
    & (Join-Path $Scripts 'Stop-Local.ps1') -LayoutPath $Layout.layout_path -Service $Role -MaintenanceLock $Lock
    Write-MCPConfiguration $Layout $Role $saved.prior.bytes; & $Checkpoint 'prior_configuration_written'
    & (Join-Path $Scripts 'Start-Local.ps1') -LayoutPath $Layout.layout_path -Service $Role -PendingOperation $pending.id -MaintenanceLock $Lock
    Wait-ReleaseReady $Layout $Role 1 $pending.prior $TimeoutSeconds
    if($pending.action -ceq 'configure-receipt-exports'){Assert-ReceiptProjectionConfiguration $Layout $saved.prior.config}
    $null=Save-ReleasePhase $Layout $Role $pending.id 'recovery_ready'; & $Checkpoint 'recovery_ready'
    $after=Get-ReleaseProcessSnapshot $Layout $Role -AllowStopped
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.services[$Role].pending.id -cne $pending.id){throw 'MCP recovery identity changed.'}
    $catalog.services[$Role].pending=$null;$catalog.generation++
    Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
    $policy=if($pending.action -ceq 'configure-receipt-exports'){'receipt-exports'}else{'network'}
    return @{operation=$pending.id;outcome='restored_prior';role=$Role;kind=(Get-NetworkHostProfile $Role $policy).kind;current=$pending.prior.id;non_target_unchanged=(Test-ReleaseSnapshotsEqual $pending.non_target $after);non_target_unchanged_during_recovery=(Test-ReleaseSnapshotsEqual $before $after);readiness='verified'}
}
function Set-ServiceMCPHosts([hashtable]$Layout,[string]$Role,[string[]]$Hosts,[string]$Scripts,[IO.FileStream]$Lock,[int]$TimeoutSeconds=30,[scriptblock]$Checkpoint={param($point)},[string]$Policy='network'){
    $profile=Get-NetworkHostProfile $Role $Policy
    $next=ConvertTo-NetworkHosts $Role $Hosts $Policy
    Assert-NoPendingOwnerMigration $Layout
    $catalog=Read-ReleaseCatalog $Layout;Assert-NoPendingRelease $catalog
    if($catalog.format -ne 2){throw 'MCP configuration needs a versioned deployment.'}
    $prior=$catalog.services[$Role].current;$descriptor=Read-ReleaseDescriptor $Layout $prior -Verify
    if($descriptor.role -cne $Role){throw 'MCP configuration release role mismatch.'}
    $null=Assert-ReleaseConfiguration $Layout $Role $prior
    $bytes=[IO.File]::ReadAllBytes((Join-Path $Layout.config_root ('services/'+$Role+'.json')))
    if((Get-BytesHash $bytes) -cne $prior.config_sha256){throw 'MCP configuration changed during preparation.'}
    $config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable
    if([string]$config[$profile.key] -ceq $next){throw 'Host policy is already selected.'}
    # Managed ingress and producers must be stopped for this maintenance window.
    # The operator must also exclude unmanaged direct API clients, as for backup.
    Assert-MCPIngressStopped $Layout
    Assert-MCPInstanceConfiguration $Layout $Role $prior $config
    $execution=Get-BoundRuntimeConfiguration $Layout $catalog
    Assert-MCPExecutionIdle $Layout $execution
    $snapshot=Get-ReleaseProcessSnapshot $Layout
    if(@($snapshot|Where-Object role -eq $Role).Count -ne 1){throw 'Start exactly one managed target service before configuring it.'}
    Wait-ReleaseReady $Layout $Role 1 $prior $TimeoutSeconds
    if($Policy -ceq 'receipt-exports'){Assert-ReceiptProjectionConfiguration $Layout $config}
    $targetConfig=$config.Clone();$targetConfig[$profile.key]=$next
    $targetBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $targetConfig -Depth 12))
    $target=$prior.Clone();$target.config_sha256=Get-BytesHash $targetBytes
    $id=[guid]::NewGuid().ToString('N');$directory=Get-MCPChangeDirectory $Layout $id
    New-ProtectedDirectory $directory
    [IO.File]::WriteAllBytes((Join-Path $directory 'prior.dpapi'),(Protect-RecoveryBytes $bytes))
    [IO.File]::WriteAllBytes((Join-Path $directory 'target.dpapi'),(Protect-RecoveryBytes $targetBytes))
    $pending=@{id=$id;action=$profile.action;phase='prepared';prior=$prior;target=$target;replicas=1;non_target=@($snapshot|Where-Object role -ne $Role);configuration=@{format=1;scope=$profile.scope;role=$Role};started_at=[datetime]::UtcNow.ToString('o')}
    $previous=$catalog.services[$Role]['previous']
    if($previous -and $previous['config_sha256'] -ceq $prior.config_sha256){
        Assert-CompatibleRelease (Read-ReleaseDescriptor $Layout $previous -Verify) $descriptor
        $previousAfter=$previous.Clone();$previousAfter.config_sha256=$target.config_sha256
        $pending.configuration.previous_before=$previous;$pending.configuration.previous_after=$previousAfter
    }
    $null=Read-MCPChange $Layout $Role $pending
    $catalog.services[$Role].pending=$pending;Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog
    try{
        & $Checkpoint 'prepared'
        & (Join-Path $Scripts 'Stop-Local.ps1') -LayoutPath $Layout.layout_path -Service $Role -MaintenanceLock $Lock
        $null=Save-ReleasePhase $Layout $Role $id 'stopped'; & $Checkpoint 'stopped'
        Assert-MCPIngressStopped $Layout
        Assert-MCPExecutionIdle $Layout $execution
        Write-MCPConfiguration $Layout $Role $targetBytes; & $Checkpoint 'configuration_replaced'
        $null=Save-ReleasePhase $Layout $Role $id 'configuration_written'; & $Checkpoint 'configuration_written'
        & (Join-Path $Scripts 'Start-Local.ps1') -LayoutPath $Layout.layout_path -Service $Role -PendingOperation $id -MaintenanceLock $Lock
        $null=Save-ReleasePhase $Layout $Role $id 'started'; & $Checkpoint 'started'
        Wait-ReleaseReady $Layout $Role 1 $target $TimeoutSeconds
        if($Policy -ceq 'receipt-exports'){Assert-ReceiptProjectionConfiguration $Layout $targetConfig}
        Assert-ReleaseSnapshot $Layout $Role $pending.non_target
        $null=Save-ReleasePhase $Layout $Role $id 'ready'; & $Checkpoint 'ready'
        $catalog=Read-ReleaseCatalog $Layout
        if($catalog.services[$Role].pending.id -cne $id){throw 'MCP operation changed before commit.'}
        if($pending.configuration['previous_after']){
            foreach($key in @('id','sha256','manifest','config_sha256')){if($catalog.services[$Role].previous[$key] -cne $pending.configuration.previous_before[$key]){throw 'Prior code changed before MCP commit.'}}
            $catalog.services[$Role].previous=$pending.configuration.previous_after
        }
        $catalog.services[$Role].current=$target;$catalog.services[$Role].pending=$null;$catalog.generation++
        Write-PlatformJson (Join-Path $Layout.release_root 'current.json') $catalog; & $Checkpoint 'committed'
        $report=@{operation=$id;outcome='committed';role=$Role;kind=$profile.kind;current=$target.id;non_target_unchanged=$true;readiness='verified'}
        if($Policy -ceq 'receipt-exports'){$report.policy_sha256=Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($next))}else{$report.allowed_hosts=$next}
        return $report
    }catch{
        $failure=$_;$observed=Read-ReleaseCatalog $Layout
        if($observed.services[$Role]['pending']){$null=Restore-PendingMCPConfiguration $Layout $Role $Scripts $Lock $TimeoutSeconds}
        throw $failure
    }finally{[Array]::Clear($bytes,0,$bytes.Length);[Array]::Clear($targetBytes,0,$targetBytes.Length);$config=$null;$targetConfig=$null;$execution=$null}
}
