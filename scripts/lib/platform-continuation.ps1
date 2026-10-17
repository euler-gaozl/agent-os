# Additive management capability; historical engine names and replay stay fixed.
function Assert-ContinuationDescriptor([System.Collections.IDictionary]$Descriptor){
    if(-not $Descriptor.Contains('continuation_management')){return}
    $value=$Descriptor.continuation_management
    if($value -isnot [System.Collections.IDictionary] -or -not $value.Contains('format') -or ($value.format -isnot [int] -and $value.format -isnot [long]) -or $value.format -ne 1){throw 'Invalid continuation capability.'}
    if(-not $Descriptor.Contains('role') -or $Descriptor.role -isnot [string]){throw 'Invalid continuation service role.'}
    $expected=switch -CaseSensitive ($Descriptor.role){
        worker {@{format=1;provides='native-model-revision-guard-v1'}}
        runtime {@{format=1;provides='failed-run-continuation-v1';requires='native-model-revision-guard-v1'}}
        control {@{format=1;requires='failed-run-continuation-v1'}}
        default {throw 'Continuation capability belongs only to Runtime, Worker or Console.'}
    }
    if($Descriptor.role -isnot [string] -or $value.Count -ne $expected.Count){throw 'Invalid continuation capability fields.'}
    foreach($key in $expected.Keys){
        if(-not $value.Contains($key) -or ($key -ne 'format' -and ($value[$key] -isnot [string] -or $value[$key] -cne $expected[$key]))){throw 'Invalid continuation capability protocol.'}
    }
}
function Assert-ContinuationPolicy([System.Collections.IDictionary]$Runtime,[System.Collections.IDictionary]$Worker,[System.Collections.IDictionary]$Control,[System.Collections.IDictionary]$Facts){
    foreach($item in @(@{descriptor=$Runtime;role='runtime'},@{descriptor=$Worker;role='worker'},@{descriptor=$Control;role='control'})){
        if($item.descriptor.role -isnot [string] -or $item.descriptor.role -cne $item.role){throw 'Invalid continuation service combination.'}
        Assert-ContinuationDescriptor $item.descriptor
    }
    foreach($key in @('schema_ready','has_receipts')){if(-not $Facts.Contains($key) -or $Facts[$key] -isnot [bool]){throw 'Missing continuation database facts.'}}
    $runtimeCap=$Runtime.Contains('continuation_management');$workerCap=$Worker.Contains('continuation_management');$controlCap=$Control.Contains('continuation_management')
    if($Runtime['final_execution'] -and -not $runtimeCap){throw 'Final Runtime requires durable continuation management.'}
    if($runtimeCap -and -not $workerCap){throw 'Continuation requires revision-aware Workers; upgrade all Workers first or refuse Worker rollback.'}
    if($controlCap -and -not $runtimeCap){throw 'Continuation Console requires Runtime action and durable receipts; upgrade Runtime first.'}
    if($runtimeCap -and -not $Facts.schema_ready){throw 'Continuation requires the Runtime Owner receipt migration before activation.'}
    if($Facts.has_receipts -and -not $runtimeCap){throw 'Retained continuation receipts require a Runtime that can read their decisions; downgrade refused.'}
}
function Get-ContinuationFacts([hashtable]$Layout){
    . (Join-Path $PSScriptRoot 'platform-recovery.ps1')
    $catalog=Read-ReleaseCatalog $Layout
    $config=Get-BoundRuntimeConfiguration $Layout $catalog
    $connection=Get-DatabaseConnection $config.DATABASE_URL
    try{return Get-ContinuationDatabaseFacts $Layout $connection}finally{$config=$null;$connection=$null}
}
function Get-ContinuationDatabaseFacts([hashtable]$Layout,[hashtable]$Connection){
    try{
        # On downgrade the caller has stopped Runtime. Observe its backends before
        # reading receipts so a late COMMIT cannot disappear between the two checks.
        $clientCount=(Invoke-RecoverySQL $Layout.postgres_bin $Connection 'SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND usename=current_user AND pid<>pg_backend_pid()').Trim()
        if($clientCount -cnotmatch '^(0|[1-9][0-9]*)$'){throw 'Invalid Runtime database client count.'}
        $clients=[long]$clientCount
        $sql=@'
BEGIN READ ONLY;
SET LOCAL statement_timeout='10000';
WITH relation AS (SELECT to_regclass('public.run_continuation_receipts') AS oid),
columns(name,type) AS (VALUES ('request_id','text'),('run_id','text'),('request_hash','text'),('expected_failure_version','text'),('http_status','integer'),('response','jsonb'),('created_at','timestamp with time zone'))
SELECT jsonb_build_object('exists',r.oid IS NOT NULL,'schema_ready',CASE WHEN r.oid IS NULL THEN false ELSE
 has_table_privilege(current_user,r.oid,'SELECT') AND has_table_privilege(current_user,r.oid,'INSERT')
 AND NOT EXISTS(SELECT 1 FROM columns c WHERE NOT EXISTS(SELECT 1 FROM pg_attribute a WHERE a.attrelid=r.oid AND a.attname=c.name AND NOT a.attisdropped AND a.attnotnull AND format_type(a.atttypid,a.atttypmod)=c.type))
 AND EXISTS(SELECT 1 FROM pg_constraint k WHERE k.conrelid=r.oid AND k.contype='p' AND k.conkey=ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid=r.oid AND attname='request_id')]::smallint[])
 END)::text FROM relation r;
COMMIT;
'@
        $shape=(Invoke-RecoverySQL $Layout.postgres_bin $Connection $sql).Trim()|ConvertFrom-Json -AsHashtable
        if($shape -isnot [System.Collections.IDictionary] -or $shape['exists'] -isnot [bool] -or $shape['schema_ready'] -isnot [bool]){throw 'Invalid continuation database facts.'}
        $hasReceipts=$false
        if($shape.exists){
            # A malformed/missing-permission table fails closed, including legacy rollback.
            if(-not $shape.schema_ready){throw 'Continuation receipt schema or permissions are invalid.'}
            $receiptState=(Invoke-RecoverySQL $Layout.postgres_bin $Connection 'SELECT EXISTS(SELECT 1 FROM public.run_continuation_receipts)::text').Trim()
            if($receiptState -cnotin @('true','false')){throw 'Invalid continuation receipt observation.'}
            $hasReceipts=$receiptState -ceq 'true'
        }
        return @{schema_ready=[bool]$shape.schema_ready;has_receipts=[bool]$hasReceipts;other_runtime_clients=$clients}
    }finally{$Connection=$null}
}
function Assert-ContinuationWorkers([hashtable]$Layout,[System.Collections.IDictionary]$Catalog){
    # Reuse the execution-domain binding checks for database, protected launch
    # configuration, process ownership and every current/pending release reference.
    $runtime=Get-BoundRuntimeConfiguration $Layout $Catalog
    $worker=Get-BoundExecutionConsumerConfiguration $Layout $Catalog worker
    try{Assert-ExecutionAccessTarget $runtime $worker worker}finally{$runtime=$null;$worker=$null}
    foreach($entry in @((Read-PlatformProcesses $Layout)|Where-Object role -eq worker)){
        $state=Get-PlatformInstanceState $entry $Layout
        if($state.requires_stop -or (-not $state.process -and $state.members.Count)){throw 'Continuation Worker ownership is unresolved.'}
        if(-not $state.process){continue}
        $descriptor=Read-ReleaseDescriptor $Layout $entry.release_reference -Verify
        if(-not $descriptor.Contains('continuation_management')){throw 'A live Worker lacks the model revision guard; upgrade every Worker before enabling continuation.'}
        Assert-ContinuationDescriptor $descriptor
    }
}
function Assert-ContinuationDeployment([hashtable]$Layout,[System.Collections.IDictionary]$Overrides=@{},[switch]$RuntimeStopped){
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -ne 2){return}
    $pair=@{}
    foreach($role in @('runtime','worker','control')){
        if($Overrides.Contains($role)){$pair[$role]=$Overrides[$role]}
        elseif($catalog.services.Contains($role)){$pair[$role]=Read-ReleaseDescriptor $Layout $catalog.services[$role].current -Verify}
        else{$pair[$role]=@{role=$role}}
    }
    foreach($descriptor in $pair.Values){Assert-ContinuationDescriptor $descriptor}
    $needsFacts=@($pair.Values|Where-Object {$_.Contains('continuation_management')}).Count -gt 0
    foreach($role in $Overrides.Keys){
        if($role -in @('runtime','worker','control') -and $catalog.services.Contains($role)){
            $current=Read-ReleaseDescriptor $Layout $catalog.services[$role].current -Verify
            if($current.Contains('continuation_management')){$needsFacts=$true}
        }
    }
    if(-not $needsFacts){Assert-ContinuationPolicy $pair.runtime $pair.worker $pair.control @{schema_ready=$false;has_receipts=$false};return}
    # Even a legacy target must not hide durable decisions created by a newer release.
    $facts=Get-ContinuationFacts $Layout
    if($RuntimeStopped -and $facts.other_runtime_clients -ne 0){throw 'Runtime database clients remain; cannot prove the receipt set is stable after stop.'}
    Assert-ContinuationPolicy $pair.runtime $pair.worker $pair.control $facts
    if($pair.runtime.Contains('continuation_management')){Assert-ContinuationWorkers $Layout $catalog}
    if($pair.control.Contains('continuation_management')){
        $runtimeConfig=Get-BoundRuntimeConfiguration $Layout $catalog
        $controlConfig=Get-BoundReceiptControlConfiguration $Layout $catalog
        try{Assert-ReceiptManagementTarget $runtimeConfig $controlConfig}finally{$runtimeConfig=$null;$controlConfig=$null}
    }
}
