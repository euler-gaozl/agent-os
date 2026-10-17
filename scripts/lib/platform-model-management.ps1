# Registry owns immutable Agent definitions. Check every retained revision before
# installing a reader that predates native model metadata; never rewrite history.
function Assert-ModelManagementDescriptor([System.Collections.IDictionary]$Descriptor){
    if(-not $Descriptor.Contains('model_management')){return}
    if($Descriptor.role -isnot [string]){throw 'Invalid model management role.'}
    $field=if($Descriptor.role -ceq 'registry'){'provides'}elseif($Descriptor.role -ceq 'control'){'requires'}else{throw 'Model management belongs only to Registry or Console.'}
    $v=$Descriptor.model_management
    $finalField=if($Descriptor.role -ceq 'registry'){'final_output'}else{'requires_final_output'}
    if($v -isnot [System.Collections.IDictionary] -or -not $v.Contains('format') -or -not $v.Contains($field)){throw 'Invalid model management capability.'}
    $expected=if($v.Contains($finalField)){3}else{2}
    if($v.Count -ne $expected -or ($expected -eq 3 -and ($v[$finalField] -isnot [string] -or $v[$finalField] -cne 'receipt-field-v1'))){throw 'Invalid final output management capability.'}
    if(($v.format -isnot [int] -and $v.format -isnot [long]) -or $v.format -ne 1 -or $v[$field] -isnot [string] -or $v[$field] -cne 'agent-model-native-v1'){throw 'Unknown model management capability.'}
}
function Assert-ModelManagementBinary([string]$Binary,[System.Collections.IDictionary]$Descriptor){
    Assert-ModelManagementDescriptor $Descriptor
    if(-not $Descriptor.Contains('model_management')){return}
    try{$actual=(Invoke-ExecutionAccessProbe $Binary @('--model-management-profile')).Trim()|ConvertFrom-Json -AsHashtable -NoEnumerate}catch{throw 'Binary cannot attest its model management capability.'}
    Assert-ModelManagementDescriptor @{role=$Descriptor.role;model_management=$actual}
    if($actual.Count -ne $Descriptor.model_management.Count){throw 'Binary model management capability differs from its descriptor.'}
    foreach($key in $Descriptor.model_management.Keys){if($actual[$key] -cne $Descriptor.model_management[$key]){throw 'Binary model management capability differs from its descriptor.'}}
}
function Get-DeclaredModelManagement([System.Collections.IDictionary]$Release){
    Assert-ModelManagementDescriptor $Release
    if($Release.Contains('model_management')){return $Release.model_management}
    return $null
}
function Test-FinalModelManagement([System.Collections.IDictionary]$Descriptor){
    if(-not $Descriptor.Contains('model_management')){return $false}
    $field=if($Descriptor.role -ceq 'registry'){'final_output'}else{'requires_final_output'}
    return $Descriptor.model_management[$field] -ceq 'receipt-field-v1'
}
function Assert-ModelManagementPolicy([System.Collections.IDictionary]$Registry,[System.Collections.IDictionary]$Control,[System.Collections.IDictionary]$Runtime,[System.Collections.IDictionary]$Facts,[bool]$NativeRuns,[string]$DefaultEngine,[bool]$HasControl=$true,[bool]$HasRuntime=$true,[bool]$FinalRuns=$false){
    if($Registry.role -cne 'registry' -or $Control.role -cne 'control' -or $Runtime.role -cne 'runtime'){throw 'Invalid model management service selection.'}
    Assert-ModelManagementDescriptor $Registry;Assert-ModelManagementDescriptor $Control
    if(($Facts['format'] -isnot [int] -and $Facts['format'] -isnot [long]) -or $Facts.format -ne 1){throw 'Invalid model management facts version.'}
    foreach($key in @('leaf_identity','native_agents','final_agents','invalid_agents')){if($Facts[$key] -isnot [bool]){throw 'Invalid model management facts type.'}}
    if(-not $Facts.leaf_identity -or $Facts.invalid_agents){throw 'Model compatibility rejects privileged identity or malformed Agent metadata.'}
    $newControl=$Control.Contains('model_management');$newRegistry=$Registry.Contains('model_management')
    if($Facts.native_agents -and (-not $newRegistry -or ($HasControl -and -not $newControl) -or ($HasRuntime -and -not $Runtime['native_execution']))){throw 'Retained Agent revisions require native model management; downgrade refused.'}
    if($newControl -and (-not $newRegistry -or -not $HasRuntime -or -not $Runtime['native_execution'])){throw 'Native Console requires capable Registry and Runtime. Upgrade those services before Console.'}
    if($HasControl -and ($NativeRuns -or $DefaultEngine -ceq (Get-NativeEngineName)) -and -not $newControl){throw 'Native tasks or default require the native Console transport; downgrade refused.'}
    $finalRegistry=Test-FinalModelManagement $Registry;$finalControl=Test-FinalModelManagement $Control
    if($finalRegistry -and $HasRuntime -and -not $Runtime['final_execution']){throw 'Final Registry requires capable Runtime before enabling final Agent writes.'}
    if($Facts.final_agents -and (-not $finalRegistry -or ($HasControl -and -not $finalControl) -or ($HasRuntime -and -not $Runtime['final_execution']))){throw 'Retained final Agent revisions require final-aware readers; downgrade refused.'}
    if($finalControl -and (-not $finalRegistry -or -not $HasRuntime -or -not $Runtime['final_execution'])){throw 'Final Console requires capable Registry and Runtime. Upgrade those services before Console.'}
    if($HasControl -and ($FinalRuns -or $DefaultEngine -cin @((Get-FinalEngineName),(Get-GuardedEngineName))) -and -not $finalControl){throw 'Final tasks or default require final Console transport; downgrade refused.'}
}
function Assert-LegacyConsoleWriterStopped([bool]$SelectingControl,[System.Collections.IDictionary]$Registry,[System.Collections.IDictionary]$Control,[bool]$RegistryRunning){
    # A save initiated by the old Console process can finish in Registry after
    # Console exits. Never infer write quiescence from stopping only the BFF.
    if($SelectingControl -and $Registry.Contains('model_management') -and -not $Control.Contains('model_management') -and $RegistryRunning){throw 'Stop Registry before starting or rolling back legacy Console; outstanding native writes must drain first.'}
    if($SelectingControl -and (Test-FinalModelManagement $Registry) -and -not (Test-FinalModelManagement $Control) -and $RegistryRunning){throw 'Stop Registry before starting or rolling back pre-final Console; outstanding final writes must drain first.'}
}
function Get-BoundModelRegistryConfiguration([hashtable]$Layout,[System.Collections.IDictionary]$Catalog){
    . (Join-Path $PSScriptRoot 'platform-processes.ps1')
    $deployment=$Catalog.services.registry
    if(-not $deployment -or ($deployment['pending'] -and $deployment.pending['configuration'])){throw 'Registry configuration is missing or has an unknown migration.'}
    $bytes=[IO.File]::ReadAllBytes((Join-Path $Layout.config_root 'services/registry.json'))
    try{
        $hash=[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($bytes))
        if($deployment.current['config_sha256'] -cne $hash){throw 'Registry configuration differs from its deployment.'}
        $config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable
    }finally{[Array]::Clear($bytes,0,$bytes.Length)}
    $allowed=@($deployment.current)
    if($deployment['pending']){$allowed+=@($deployment.pending.prior,$deployment.pending.target)}
    foreach($entry in @((Read-PlatformProcesses $Layout)|Where-Object role -eq 'registry')){
        $state=Get-PlatformInstanceState $entry $Layout
        if($state.requires_stop -or (-not $state.process -and $state.members.Count)){throw 'Registry process ownership is unresolved.'}
        if(-not $state.process){continue}
        if(-not $entry['job_name'] -or -not $entry['launch_config'] -or $entry['source_config_sha256'] -cne $hash){throw 'Live Registry configuration is not bound to its deployment.'}
        $reference=@($allowed|Where-Object{$entry['release_reference'] -and $_.id -ceq $entry.release_reference.id})
        if($reference.Count -eq 0){throw 'Live Registry does not belong to its deployment.'}
        $descriptor=Read-ReleaseDescriptor $Layout $reference[0] -Verify
        if($entry.binary -ne (Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary)){throw 'Live Registry binary differs from its deployment.'}
        $launch=Read-ReleaseJson $entry.launch_config
        try{foreach($key in @('DATABASE_URL','LISTEN')){if([string]$launch[$key] -cne [string]$config[$key]){throw 'Live Registry target differs from its bound configuration.'}}}finally{$launch=$null}
    }
    return $config
}
function Get-ModelManagementFacts([hashtable]$Layout,[System.Collections.IDictionary]$Configuration,[switch]$Stopped){
    $connection=Get-ExecutionAccessConnection $Configuration
    if($connection.schema -cne 'public'){throw 'Registry model compatibility requires the public schema.'}
    $sql=@'
BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY;
SET LOCAL statement_timeout='5000';
SET LOCAL search_path=pg_catalog;
__QUIESCENCE__
SELECT json_build_object('format',1,'database',current_database(),'login',session_user,'effective_login',current_user,
 'leaf_identity',(SELECT NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls OR rolreplication)
 AND NOT EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid) FROM pg_roles r WHERE rolname=current_user),
 'native_agents',EXISTS(SELECT 1 FROM public.resources WHERE kind='agent' AND spec#>'{model,limits}' IS NOT NULL AND spec#>'{model,limits}'<>'null'::jsonb),
 'final_agents',EXISTS(SELECT 1 FROM public.resources WHERE kind='agent' AND spec->'final_output' IS NOT NULL AND spec->'final_output'<>'null'::jsonb),
 'invalid_agents',EXISTS(SELECT 1 FROM public.resources WHERE kind='agent' AND
 (jsonb_typeof(spec) IS DISTINCT FROM 'object' OR jsonb_typeof(spec->'model') IS DISTINCT FROM 'object' OR
 (spec#>'{model,limits}' IS NOT NULL AND spec#>'{model,limits}'<>'null'::jsonb AND jsonb_typeof(spec#>'{model,limits}')<>'object') OR
 (spec->'final_output' IS NOT NULL AND spec->'final_output'<>'null'::jsonb AND
  (jsonb_typeof(spec->'final_output') IS DISTINCT FROM 'object' OR jsonb_typeof(spec#>'{model,limits}') IS DISTINCT FROM 'object' OR
   spec#>>'{final_output,protocol}' IS DISTINCT FROM 'receipt-field-v1' OR
   jsonb_typeof(spec#>'{final_output,tool}') IS DISTINCT FROM 'string' OR
   jsonb_typeof(spec#>'{final_output,input_field}') IS DISTINCT FROM 'string' OR
   jsonb_typeof(spec#>'{final_output,ready_path}') IS DISTINCT FROM 'array')))))::text;
COMMIT;
'@
    $barrier=if($Stopped){@'
DO $barrier$
DECLARE deadline timestamptz := clock_timestamp()+interval '4 seconds';
BEGIN
 LOOP
  PERFORM pg_stat_clear_snapshot();
  EXIT WHEN NOT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND usename=session_user AND pid<>pg_backend_pid());
  IF clock_timestamp()>=deadline THEN RAISE EXCEPTION 'Registry database sessions are still active'; END IF;
  PERFORM pg_sleep(0.05);
 END LOOP;
END $barrier$;
'@}else{''}
    try{
        $args=@('-X','-w','-h',$connection.host,'-p',[string]$connection.port,'-U',$connection.user,'-d',$connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-')
        $facts=(Invoke-ExecutionAccessProbe (Join-Path $Layout.postgres_bin 'psql.exe') $args ($sql.Replace('__QUIESCENCE__',$barrier)) $connection).Trim()|ConvertFrom-Json -AsHashtable
        if($facts.database -cne $connection.database -or $facts.login -cne $connection.user -or $facts.effective_login -cne $connection.user){throw 'Registry probe identity differs from its bound configuration.'}
        return $facts
    }finally{$connection=$null}
}
function Assert-ModelManagementTarget([System.Collections.IDictionary]$RegistryConfig,[System.Collections.IDictionary]$ControlConfig){
    # Reuse the exact local HTTP target validation, with Registry's own port.
    $listen=if($RegistryConfig.Contains('LISTEN')){$RegistryConfig.LISTEN}else{':8096'}
    $target=if($ControlConfig.Contains('REGISTRY_URL')){$ControlConfig.REGISTRY_URL}else{'http://127.0.0.1:8096'}
    Assert-ReceiptManagementTarget @{LISTEN=$listen} @{RUNTIME_URL=$target}
}
function Assert-ModelManagementDeployment([hashtable]$Layout,[System.Collections.IDictionary]$Overrides=@{},[switch]$RegistryStopped,[string]$DefaultEngine=''){
    . (Join-Path $PSScriptRoot 'platform-processes.ps1')
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -ne 2){return}
    $pair=@{}
    foreach($role in @('registry','control','runtime')){
        if($Overrides.Contains($role)){$pair[$role]=$Overrides[$role]}
        elseif($catalog.services.Contains($role)){$pair[$role]=Read-ReleaseDescriptor $Layout $catalog.services[$role].current -Verify}
        else{$pair[$role]=@{role=$role}}
    }
    $hasRegistry=$catalog.services.Contains('registry');$hasControl=$catalog.services.Contains('control');$hasRuntime=$catalog.services.Contains('runtime')
    if($pair.control['model_management'] -and (-not $hasRegistry -or -not $hasRuntime)){throw 'Native Console requires registered Registry and Runtime.'}
    if($pair.registry['model_management'] -and -not $hasRegistry){throw 'Native Registry configuration is not registered.'}
    # Pure execution layouts have no model-management reader to maintain.
    if(-not $hasRegistry -and -not $hasControl){return}
    $registry=if($hasRegistry){Get-BoundModelRegistryConfiguration $Layout $catalog}else{$null}
    $control=if($hasControl){Get-BoundReceiptControlConfiguration $Layout $catalog}else{$null}
    $runtime=if($hasRuntime){Get-BoundRuntimeConfiguration $Layout $catalog}else{$null}
    try{
        $live=@((Read-PlatformProcesses $Layout)|Where-Object{$_.role -eq 'registry' -and (Get-PlatformInstanceState $_ $Layout).process})
        if($RegistryStopped -and $live.Count){throw 'Registry is still running after stop.'}
        Assert-LegacyConsoleWriterStopped ($Overrides.Contains('control')) $pair.registry $pair.control ($live.Count -gt 0)
        $facts=if($hasRegistry){Get-ModelManagementFacts $Layout $registry -Stopped:($RegistryStopped -or $live.Count -eq 0)}else{@{format=1;leaf_identity=$true;native_agents=$false;final_agents=$false;invalid_agents=$false}}
        $runs=if($hasRuntime){Get-SourceExecutionFacts $Layout $runtime}else{@{native_runs=0;final_runs=0;guarded_runs=0}}
        foreach($key in @('native_runs','final_runs','guarded_runs')){if(-not $runs.Contains($key) -or ($runs[$key] -isnot [int] -and $runs[$key] -isnot [long]) -or $runs[$key] -lt 0){throw 'Invalid native/final run compatibility count.'}}
        $effectiveDefault=if($DefaultEngine){$DefaultEngine}elseif($runtime){[string]$runtime['DEFAULT_RUN_ENGINE']}else{''}
        Assert-ModelManagementPolicy $pair.registry $pair.control $pair.runtime $facts ($runs.native_runs -gt 0) $effectiveDefault $hasControl $hasRuntime (($runs.final_runs + $runs.guarded_runs) -gt 0)
        if($pair.control.Contains('model_management')){Assert-ModelManagementTarget $registry $control;Assert-ReceiptManagementTarget $runtime $control}
        foreach($role in @('registry','control')){if($pair[$role].Contains('model_management')){Assert-ModelManagementBinary (Resolve-ReleasePath $Layout.release_root $pair[$role].assets.binary) $pair[$role]}}
    }finally{$registry=$null;$control=$null;$runtime=$null}
}
