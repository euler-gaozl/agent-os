# Source-engine release policy. No configuration or database writes occur here.
function Get-SourceEngineName { return 'dsh-source-639ed015-state-v1' }
function Get-ResidentEngineName { return 'dsh-source-639ed015-resident-v2' }
function Get-BudgetEngineName { return 'dsh-source-639ed015-budget-v3' }
function Get-NativeEngineName { return 'dsh-source-639ed015-native-v4' }
function Get-SourceEngineProfiles {
    return @(
        @{engine=(Get-SourceEngineName);metadata='source_execution';asset='source_harness';environment='DSH_SOURCE_RUNNER';runs='source_runs';resumable='resumable_source_runs'},
        @{engine=(Get-ResidentEngineName);metadata='resident_execution';asset='resident_harness';environment='DSH_RESIDENT_RUNNER';runs='resident_runs';resumable='resumable_resident_runs'},
        @{engine=(Get-BudgetEngineName);metadata='budget_execution';asset='budget_harness';environment='DSH_BUDGET_RUNNER';runs='budget_runs';resumable='resumable_budget_runs'},
        @{engine=(Get-NativeEngineName);metadata='native_execution';asset='native_harness';environment='DSH_NATIVE_RUNNER';runs='native_runs';resumable='resumable_native_runs'}
    )
}
function Assert-SourceExecutionDescriptor([System.Collections.IDictionary]$Descriptor){
    foreach($profile in (Get-SourceEngineProfiles)){
    $source=$Descriptor[$profile.metadata];$asset=$Descriptor.assets[$profile.asset]
    if(-not $source){if($asset){throw 'Source Harness asset has no execution provenance.'};continue}
    if($source.format -ne 1 -or $source.engine -cne $profile.engine -or $source.execution_protocol -cne 'runtime-execution-v1'){throw 'Unsupported source execution metadata.'}
    if($profile.engine -ceq (Get-BudgetEngineName) -and $source['model_receipt_protocol'] -cne 'budget-model-receipt-v1'){throw 'Budget engine requires durable model receipt protocol 1.'}
    if($profile.engine -ceq (Get-NativeEngineName) -and $source['model_receipt_protocol'] -cne 'native-model-receipt-v2'){throw 'Native engine requires durable model receipt protocol 2.'}
    switch($Descriptor.role){
        runtime {
            if($asset -or $source.state_protocol -cne 'source-state-recovery-v1' -or $source.submission_protocol -cne 'source-root-default-v1' -or $source.preview_protocol -cne 'source-recovery-preview-v1' -or $Descriptor.contract.http -cne 'agentos-http-v0.7-source-state-v1' -or $Descriptor.contract.data -cne 'execution-v0.7-working-state'){throw 'Runtime source protocols are incomplete.'}
        }
        worker {
            if(-not $asset -or $source.state_protocol -cne 'source-state-recovery-v1' -or $source.manifest_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $source.harness_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'Worker source artifact provenance is incomplete.'}
        }
        default {throw 'Source execution capability belongs only to Runtime or Worker.'}
    }
    }
    if($Descriptor.role -ceq 'runtime' -and $Descriptor['resident_execution'] -and -not $Descriptor['source_execution']){throw 'Resident Runtime must retain the v1 source protocols.'}
    if($Descriptor.role -ceq 'runtime' -and $Descriptor['budget_execution'] -and (-not $Descriptor['source_execution'] -or -not $Descriptor['resident_execution'])){throw 'Budget Runtime must retain v1/v2 source protocols.'}
    if($Descriptor.role -ceq 'runtime' -and $Descriptor['native_execution'] -and (-not $Descriptor['source_execution'] -or -not $Descriptor['resident_execution'] -or -not $Descriptor['budget_execution'])){throw 'Native Runtime must retain v1/v2/v3 protocols.'}
}
function Test-SourceRuntimeTransition([System.Collections.IDictionary]$Previous,[System.Collections.IDictionary]$Next){
    if($Previous.role -cne 'runtime' -or $Next.role -cne 'runtime'){return $false}
    $old=$Previous;$new=$Next
    if($Previous.contract.data -ceq 'execution-v0.7-working-state'){$old=$Next;$new=$Previous}
    if($old.contract.http -cne 'agentos-http-v0.6-notes-lifecycle' -or $old.contract.data -cne 'execution-v0.6-notes-lifecycle' -or $new.contract.http -cne 'agentos-http-v0.7-source-state-v1' -or $new.contract.data -cne 'execution-v0.7-working-state' -or -not $new['source_execution']){return $false}
    Assert-SourceExecutionDescriptor $new
    $normalized=@{http=$old.contract.http;data=$old.contract.data;engines=$new.contract.engines;tools=$new.contract.tools}
    return (Get-ContractIdentity $old.contract) -ceq (Get-ContractIdentity $normalized)
}
function Assert-SourceExecutionPolicy([System.Collections.IDictionary]$Runtime,[System.Collections.IDictionary]$Worker,[string]$DefaultEngine,[System.Collections.IDictionary]$Facts){
    Assert-SourceExecutionDescriptor $Runtime;Assert-SourceExecutionDescriptor $Worker
    if(-not $DefaultEngine){$DefaultEngine='dsh-0.2.0-rc.2-evidence-v1'}
    if($DefaultEngine -cnotin @('dsh-0.2.0-rc.2-evidence-v1',(Get-SourceEngineName),(Get-ResidentEngineName),(Get-BudgetEngineName),(Get-NativeEngineName))){throw 'Unknown configured submission engine.'}
    if(-not $Facts.Contains('working_state_ready') -or $Facts.working_state_ready -isnot [bool]){throw 'Execution compatibility facts are incomplete.'}
    if($Runtime.contract.data -ceq 'execution-v0.7-working-state' -and -not $Runtime['source_execution']){throw 'New Runtime data contract lacks source protocol provenance.'}
    if($DefaultEngine -ceq (Get-NativeEngineName) -and -not $Worker['budget_execution']){throw 'Native default requires budget-v3 Worker support for frozen legacy Agent revisions.'}
    foreach($profile in (Get-SourceEngineProfiles)){
        foreach($key in @($profile.runs,$profile.resumable)){
            if(-not $Facts.Contains($key)){throw 'Execution compatibility facts are incomplete.'}
            if(($Facts[$key] -isnot [long] -and $Facts[$key] -isnot [int]) -or $Facts[$key] -lt 0){throw 'Invalid execution run count.'}
        }
        if($Facts[$profile.resumable] -gt $Facts[$profile.runs]){throw 'Invalid execution compatibility facts.'}
        $runtimeSource=[bool]$Runtime[$profile.metadata];$workerSource=[bool]$Worker[$profile.metadata]
        if($runtimeSource -and -not $Facts.working_state_ready){throw 'Run the additive Runtime working-state migration before selecting this release.'}
        if(($workerSource -or $DefaultEngine -ceq $profile.engine -or $Facts[$profile.runs] -gt 0) -and -not $runtimeSource){throw ('Retained tasks or Worker capability require Runtime support for '+$profile.engine+'; downgrade refused.')}
        if(($DefaultEngine -ceq $profile.engine -or $Facts[$profile.resumable] -gt 0) -and -not $workerSource){throw ('Default or resumable tasks require a pinned Worker for '+$profile.engine+'; rollback refused.')}
    }
}
function Get-SourceExecutionFacts([hashtable]$Layout,[System.Collections.IDictionary]$Configuration=$null){
    . (Join-Path $PSScriptRoot 'platform-recovery.ps1')
    $config=if($Configuration){$Configuration}else{Read-ReleaseJson (Join-Path $Layout.config_root 'services/runtime.json')}
    $connection=Get-DatabaseConnection $config.DATABASE_URL
    $sql=@'
BEGIN READ ONLY;
SET LOCAL statement_timeout='10000';
WITH state_table AS (SELECT to_regclass('public.run_working_states') AS oid),
required_columns(name,type) AS (VALUES
 ('run_id','text'),('revision','bigint'),('operation_id','text'),('request_hash','text'),
 ('source_rule_revision','bigint'),('source_owner','text'),('source_fence','bigint'),
 ('actor_agent','text'),('reason','text'),('body','jsonb'),('evidence','jsonb'),
 ('receipt','jsonb'),('created_at','timestamp with time zone')),
required_keys(names) AS (VALUES (ARRAY['run_id','revision']::text[]),(ARRAY['run_id','operation_id']::text[]))
SELECT jsonb_build_object(
 'source_runs',count(*) FILTER (WHERE engine='dsh-source-639ed015-state-v1'),
 'resumable_source_runs',count(*) FILTER (WHERE engine='dsh-source-639ed015-state-v1' AND status NOT IN('completed','cancelled')),
 'resident_runs',count(*) FILTER (WHERE engine='dsh-source-639ed015-resident-v2'),
 'resumable_resident_runs',count(*) FILTER (WHERE engine='dsh-source-639ed015-resident-v2' AND status NOT IN('completed','cancelled')),
 'budget_runs',count(*) FILTER (WHERE engine='dsh-source-639ed015-budget-v3'),
 'resumable_budget_runs',count(*) FILTER (WHERE engine='dsh-source-639ed015-budget-v3' AND status NOT IN('completed','cancelled')),
 'native_runs',count(*) FILTER (WHERE engine='dsh-source-639ed015-native-v4'),
 'resumable_native_runs',count(*) FILTER (WHERE engine='dsh-source-639ed015-native-v4' AND status NOT IN('completed','cancelled')),
 'working_state_ready',(SELECT CASE WHEN t.oid IS NULL THEN false ELSE
 has_table_privilege(current_user,t.oid,'SELECT') AND has_table_privilege(current_user,t.oid,'INSERT')
 AND NOT EXISTS(SELECT 1 FROM required_columns c WHERE NOT EXISTS(
  SELECT 1 FROM pg_attribute a WHERE a.attrelid=t.oid AND a.attname=c.name AND NOT a.attisdropped
  AND a.attnotnull AND format_type(a.atttypid,a.atttypmod)=c.type))
 AND NOT EXISTS(SELECT 1 FROM required_keys k WHERE NOT EXISTS(
  SELECT 1 FROM pg_index i WHERE i.indrelid=t.oid AND i.indisunique AND i.indisvalid AND i.indisready
  AND i.indimmediate AND i.indpred IS NULL AND i.indexprs IS NULL AND i.indnkeyatts=2
  AND (SELECT array_agg(a.attname::text ORDER BY p.ordinality)
   FROM unnest(i.indkey) WITH ORDINALITY p(attnum,ordinality)
   JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=p.attnum WHERE p.ordinality<=i.indnkeyatts)=k.names))
 END FROM state_table t)
)::text FROM public.runs;
COMMIT;
'@
    try{
        $json=Invoke-PostgresTool -PostgresBin $Layout.postgres_bin -Tool psql -Connection $connection -Arguments @('-X','-w','-A','-t','-q','-v','ON_ERROR_STOP=1','-d',$connection.database,'-f','-') -InputText $sql -TimeoutMs 15000
        return $json.Trim()|ConvertFrom-Json -AsHashtable
    }finally{$config=$null;$connection=$null}
}
function Get-BoundRuntimeConfiguration([hashtable]$Layout,[System.Collections.IDictionary]$Catalog){
    . (Join-Path $PSScriptRoot 'platform-processes.ps1')
    $deployment=$Catalog.services.runtime
    $path=Join-Path $Layout.config_root 'services/runtime.json'
    # Read/hash the same bytes. A file edited without a committed configuration
    # migration must never authorize removing the live Runtime's required Worker.
    $bytes=[IO.File]::ReadAllBytes($path)
    try{
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $bound=$deployment.current
        if($deployment['pending'] -and $deployment.pending['configuration']){
            $configurationKnown=$deployment.pending.configuration.scope -ceq 'runtime-default' -and $deployment.pending.action -ceq 'configure-default'
            $configurationKnown=$configurationKnown -or ($deployment.pending.configuration.scope -ceq 'mcp-hosts' -and $deployment.pending.action -ceq 'configure-mcp-hosts' -and $deployment.pending.configuration.role -ceq 'runtime')
            if($deployment.pending.configuration.format -ne 1 -or -not $configurationKnown){throw 'Unknown pending Runtime configuration operation.'}
            if($deployment.pending.phase -in @('configuration_written','started','ready')){$bound=$deployment.pending.target}
            elseif($deployment.pending.phase -notin @('prepared','stopped','reverting','recovery_ready')){throw 'Unknown Runtime configuration phase.'}
        }
        if($bound['config_sha256'] -cne $hash){throw 'Runtime configuration differs from its registered deployment; reconcile it before execution maintenance.'}
        $config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable
    }finally{[Array]::Clear($bytes,0,$bytes.Length)}
    $allowed=@($deployment.current)
    if($deployment['pending']){$allowed+=@($deployment.pending.prior,$deployment.pending.target)}
    foreach($entry in @((Read-PlatformProcesses $Layout)|Where-Object role -eq 'runtime')){
        $state=Get-PlatformInstanceState $entry $Layout
        if($state.requires_stop -or (-not $state.process -and $state.members.Count)){throw 'Runtime process ownership is unresolved; reconcile it before execution maintenance.'}
        if(-not $state.process){continue}
        if(-not $entry['job_name'] -or -not $entry['launch_config'] -or $entry['source_config_sha256'] -cne $hash){throw 'Live Runtime configuration is not bound to the registered deployment.'}
        $reference=@($allowed|Where-Object{$entry['release_reference'] -and $_.id -ceq $entry.release_reference.id})
        if($reference.Count -eq 0){throw 'Live Runtime does not belong to the current or pending deployment.'}
        $descriptor=Read-ReleaseDescriptor $Layout $reference[0] -Verify
        if($entry.binary -ne (Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary)){throw 'Live Runtime binary differs from its deployment.'}
        # Get-PlatformInstanceState validated the protected launch snapshot hash.
        # Check the values as well as the declared source hash, including the DB
        # whose tasks will be queried. No credentials are returned or logged.
        $launch=Read-ReleaseJson $entry.launch_config
        try{
            foreach($key in @('DEFAULT_RUN_ENGINE','DATABASE_URL','LISTEN','MCP_ALLOWED_HOSTS')){
                if([string]$launch[$key] -cne [string]$config[$key]){throw 'Live Runtime execution configuration differs from the registered configuration.'}
            }
        }finally{$launch=$null}
    }
    return $config
}
function Assert-SourceExecutionDeployment([hashtable]$Layout,[System.Collections.IDictionary]$Overrides=@{}){
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -ne 2){return}
    $descriptors=@{}
    foreach($role in @('runtime','worker')){
        if($Overrides.Contains($role)){$descriptors[$role]=$Overrides[$role]}
        else{
            if(-not $catalog.services.Contains($role)){throw 'Execution release pair is missing from the catalog.'}
            $descriptors[$role]=Read-ReleaseDescriptor $Layout $catalog.services[$role].current -Verify
        }
    }
    $config=Get-BoundRuntimeConfiguration $Layout $catalog
    try{
        $facts=Get-SourceExecutionFacts $Layout $config
        Assert-SourceExecutionPolicy $descriptors.runtime $descriptors.worker ([string]$config['DEFAULT_RUN_ENGINE']) $facts
    }finally{$config=$null}
}
function Copy-PinnedSourceHarness([string]$Artifact,[string]$Destination,[string]$PinFile,[string]$Engine=(Get-SourceEngineName)){
    if($Engine -cnotin @((Get-SourceEngineName),(Get-ResidentEngineName),(Get-BudgetEngineName),(Get-NativeEngineName))){throw 'Unknown source Harness engine.'}
    $artifactRoot=[IO.Path]::GetFullPath($Artifact)
    Assert-ReleasePhysicalPath (Split-Path -Parent ([IO.Path]::GetFullPath($PinFile))) $PinFile
    Assert-ReleasePhysicalPath (Split-Path -Parent ([IO.Path]::GetFullPath($Destination))) $Destination
    $pin=Read-ReleaseJson $PinFile
    if($pin.format -ne 1 -or $pin.engine -cne $Engine -or $pin.manifest_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $pin.commit -cnotmatch '^[a-f0-9]{40}$'){throw 'Invalid compiled source Harness pin.'}
    $manifestPath=Join-Path $artifactRoot 'dist/manifest.json'
    Assert-ReleasePhysicalPath $artifactRoot $manifestPath
    if((Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant() -cne $pin.manifest_sha256){throw 'Harness manifest differs from the selected Worker compiled pin.'}
    $manifest=Read-ReleaseJson $manifestPath
    if($manifest.source_engine -cne $pin.engine -or $manifest.upstream_commit -cne $pin.upstream_commit){throw 'Harness source provenance mismatch.'}
    if(Test-Path -LiteralPath $Destination){throw 'Source Harness destination must be new.'}
    $files=@{'source-runner.mjs'=$manifest.source_runner_sha256;'dist/kernel.mjs'=$manifest.kernel_sha256;'dist/THIRD_PARTY_NOTICES.txt'=$manifest.notices_sha256;'dist/manifest.json'=$pin.manifest_sha256}
    foreach($relative in $files.Keys){
        $inputPath=Resolve-ReleasePath $artifactRoot $relative
        Assert-ReleasePhysicalPath $artifactRoot $inputPath
        if($files[$relative] -cnotmatch '^[a-f0-9]{64}$' -or (Get-Item -LiteralPath $inputPath).PSIsContainer -or (Get-FileHash -LiteralPath $inputPath).Hash.ToLowerInvariant() -cne $files[$relative]){throw 'Source Harness file does not match its manifest.'}
    }
    $null=New-Item -ItemType Directory -Path (Join-Path $Destination 'dist') -Force
    foreach($relative in $files.Keys){
        $target=Resolve-ReleasePath $Destination $relative
        Copy-Item -LiteralPath (Resolve-ReleasePath $artifactRoot $relative) -Destination $target
        if((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -cne $files[$relative]){throw 'Copied source Harness content differs.'}
    }
    Copy-Item -LiteralPath $PinFile -Destination (Join-Path $Destination 'source-lock.json')
    $metadata=@{format=1;engine=$pin.engine;execution_protocol='runtime-execution-v1';state_protocol='source-state-recovery-v1';manifest_sha256=$pin.manifest_sha256;harness_commit=$pin.commit}
    if($Engine -ceq (Get-BudgetEngineName)){$metadata.model_receipt_protocol='budget-model-receipt-v1'}
    if($Engine -ceq (Get-NativeEngineName)){$metadata.model_receipt_protocol='native-model-receipt-v2'}
    return $metadata
}
