# Read-only execution ACL compatibility. This does not perform or authorize a
# contraction, and never restores old grants when a rollback is refused.
function Assert-ExecutionAccessDescriptor([System.Collections.IDictionary]$Descriptor){
    if(-not $Descriptor.Contains('execution_access')){return}
    $value=$Descriptor.execution_access
    if($Descriptor.role -isnot [string] -or $Descriptor.role -cnotin @('worker','telemetry')){throw 'Execution access capability belongs only to Worker or Telemetry.'}
    if($value -isnot [System.Collections.IDictionary] -or $value.Count -ne 2 -or -not $value.Contains('format') -or -not $value.Contains('profile')){throw 'Invalid execution access capability.'}
    $expected=if($Descriptor.role -ceq 'worker'){'worker-minimal-v1'}else{'telemetry-http-v1'}
    if(($value.format -isnot [int] -and $value.format -isnot [long]) -or $value.format -ne 1 -or $value.profile -isnot [string] -or $value.profile -cne $expected){throw 'Unknown execution access capability.'}
}
function Get-DeclaredExecutionAccess([System.Collections.IDictionary]$Release){
    # Validate the raw JSON value before PowerShell can unwrap pipeline arrays.
    Assert-ExecutionAccessDescriptor $Release
    if($Release.Contains('execution_access')){return $Release.execution_access}
    return $null
}
function Invoke-ExecutionAccessProbe([string]$Program,[string[]]$Arguments,[string]$InputText='',[hashtable]$Connection=$null){
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Program;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
    $info.Environment.Clear()
    foreach($key in @('SystemRoot','WINDIR','TEMP','TMP')){if([Environment]::GetEnvironmentVariable($key)){$info.Environment[$key]=[Environment]::GetEnvironmentVariable($key)}}
    if($Connection){$info.Environment['PGPASSWORD']=$Connection.password;$info.Environment['PGCONNECT_TIMEOUT']='3';$info.Environment['PGAPPNAME']='agent-os-access-check';$info.Environment['PGSSLMODE']='disable'}
    foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try{
        $null=$process.Start();$started=$true
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if($InputText){$process.StandardInput.Write($InputText)};$process.StandardInput.Close()
        if(-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0){throw 'probe failed'}
        $value=$output.GetAwaiter().GetResult();$null=$errors.GetAwaiter().GetResult()
        if($value.Length -gt 8192){throw 'oversized probe'}
        return $value
    }catch{
        if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()}
        throw 'Execution access probe failed; no process output or connection values were printed.'
    }finally{$process.Dispose()}
}
function Assert-ExecutionAccessBinary([string]$Binary,[System.Collections.IDictionary]$Descriptor){
    Assert-ExecutionAccessDescriptor $Descriptor
    if(-not $Descriptor.Contains('execution_access')){return}
    try{$report=(Invoke-ExecutionAccessProbe $Binary @('--execution-access-profile')).Trim()|ConvertFrom-Json -AsHashtable}catch{throw 'Binary cannot attest its declared execution access capability.'}
    if($report -isnot [System.Collections.IDictionary] -or $report.Count -ne 3 -or -not $report.Contains('format') -or -not $report.Contains('profile') -or -not $report.Contains('role')){throw 'Binary execution access report is invalid.'}
    $actual=@{role=$report.role;execution_access=@{format=$report.format;profile=$report.profile}}
    Assert-ExecutionAccessDescriptor $actual
    if($actual.role -cne $Descriptor.role -or $report.profile -cne $Descriptor.execution_access.profile){throw 'Binary execution access report differs from its descriptor.'}
}
function Get-ExecutionAccessConnection([System.Collections.IDictionary]$Configuration){
    try{
        $value=$Configuration['DATABASE_URL']
        if($value -isnot [string] -or $value -cne $value.Trim() -or $value -match '%(?![0-9a-fA-F]{2})'){throw 'invalid'}
        $uri=[uri]$value
        if($uri.Scheme -cnotin @('postgres','postgresql') -or $uri.Host -cne '127.0.0.1' -or $uri.Port -lt 1 -or $uri.Port -gt 65535 -or $uri.Fragment){throw 'invalid'}
        $identity=$uri.UserInfo.Split(':',2)
        if($identity.Count -ne 2 -or -not $identity[0] -or -not $identity[1]){throw 'invalid'}
        $database=[uri]::UnescapeDataString($uri.AbsolutePath.TrimStart('/'))
        if($database -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$'){throw 'invalid'}
        $query=@{}
        foreach($part in $uri.Query.TrimStart('?').Split('&')){
            $pair=$part.Split('=',2);if($pair.Count -ne 2){throw 'invalid'}
            $key=[uri]::UnescapeDataString($pair[0]);$setting=[uri]::UnescapeDataString($pair[1])
            if($key -cnotin @('sslmode','search_path') -or $query.ContainsKey($key)){throw 'invalid'}
            $query[$key]=$setting
        }
        if($query['sslmode'] -cne 'disable' -or $query['search_path'] -cnotmatch '^[a-z_][a-z0-9_]*$'){throw 'invalid'}
        return @{host='127.0.0.1';port=$uri.Port;database=$database;user=[uri]::UnescapeDataString($identity[0]);password=[uri]::UnescapeDataString($identity[1]);schema=$query.search_path}
    }catch{throw 'Execution ACL checks require an explicit local PostgreSQL URL with only sslmode=disable and one search_path schema; values were not printed.'}
}
function Assert-ExecutionAccessTarget([System.Collections.IDictionary]$RuntimeConfig,[System.Collections.IDictionary]$ConsumerConfig,[string]$Role){
    $runtime=Get-ExecutionAccessConnection $RuntimeConfig;$consumer=Get-ExecutionAccessConnection $ConsumerConfig
    try{
        if($runtime.schema -cne 'public'){throw 'Runtime execution schema is not public.'}
        if($Role -ceq 'worker'){
            foreach($key in @('host','port','database','schema')){if($runtime[$key] -cne $consumer[$key]){throw 'Worker execution database differs from the bound Runtime.'}}
            if($runtime.user -ceq $consumer.user){throw 'Worker must use a distinct database login.'}
        }elseif($Role -cne 'telemetry'){throw 'Unknown execution consumer.'}
    }finally{$runtime=$null;$consumer=$null}
}
function Get-ExecutionAccessFacts([hashtable]$Layout,[string]$Role,[System.Collections.IDictionary]$Configuration){
    $connection=Get-ExecutionAccessConnection $Configuration
    if($Role -cnotin @('worker','telemetry')){throw 'Unknown execution consumer.'}
    # Identifiers cannot reach this substitution until the narrow URL parser
    # validates them. No user rows are selected, even for legacy probes.
    $sql=@'
BEGIN READ ONLY;
SET LOCAL statement_timeout='5000';
SET LOCAL search_path=pg_catalog;
WITH minimal(name,privilege) AS (VALUES
 ('runs','SELECT'),('runs','UPDATE'),('calls','SELECT'),('calls','INSERT'),('calls','UPDATE'),
 ('model_attempts','SELECT'),('model_attempts','INSERT'),('model_attempts','UPDATE'),
 ('harness_exchanges','SELECT'),('harness_exchanges','INSERT'),('harness_exchanges','UPDATE'),
 ('harness_archives','SELECT'),('harness_archives','INSERT'),('harness_archives','UPDATE'),('events','SELECT'),('events','INSERT')),
legacy(name) AS (VALUES ('runs'),('calls'),('model_attempts'),('harness_exchanges'),('harness_archives'),
 ('documents'),('note_roots'),('note_versions'),('note_audits'),('note_admin_receipts'),('business_runs'),('app_runs'),('instances'),('events')),
own_telemetry(name,privilege) AS (VALUES ('telemetry_inbox','SELECT'),('telemetry_inbox','INSERT'),('telemetry_inbox','UPDATE'),('telemetry_exports','SELECT'),('telemetry_exports','INSERT'))
SELECT jsonb_build_object(
 'format',1,'database',current_database(),'login',session_user,'effective_login',current_user,
 'schema_usage',coalesce(has_schema_privilege(current_user,to_regnamespace('__SCHEMA__'),'USAGE'),false),
 'leaf_identity',(SELECT NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls OR rolreplication)
    AND NOT EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid) FROM pg_roles r WHERE rolname=current_user),
 'worker_minimum',CASE WHEN has_schema_privilege(current_user,'public','USAGE') THEN NOT EXISTS(SELECT 1 FROM minimal WHERE NOT coalesce(has_table_privilege(current_user,to_regclass('public.'||name),privilege),false))
    AND coalesce(has_sequence_privilege(current_user,to_regclass('public.events_seq_seq'),'USAGE'),false)
    AND coalesce(has_sequence_privilege(current_user,to_regclass('public.events_seq_seq'),'SELECT'),false) ELSE false END,
 'worker_legacy',CASE WHEN has_schema_privilege(current_user,'public','USAGE') THEN NOT EXISTS(SELECT 1 FROM legacy WHERE NOT coalesce(has_table_privilege(current_user,to_regclass('public.'||name),'SELECT'),false)) ELSE false END,
 'telemetry_owned',CASE WHEN coalesce(has_schema_privilege(current_user,to_regnamespace('__SCHEMA__'),'USAGE'),false) THEN NOT EXISTS(SELECT 1 FROM own_telemetry WHERE NOT coalesce(has_table_privilege(current_user,to_regclass('__SCHEMA__.'||name),privilege),false)) ELSE false END,
 'telemetry_legacy',CASE WHEN has_schema_privilege(current_user,'public','USAGE') THEN coalesce(has_table_privilege(current_user,to_regclass('public.events'),'SELECT'),false)
    AND coalesce(has_table_privilege(current_user,to_regclass('public.events'),'UPDATE'),false) ELSE false END
)::text;
COMMIT;
'@
    $sql=$sql.Replace('__SCHEMA__',$connection.schema)
    try{
        $pgArguments=@('-X','-w','-h',$connection.host,'-p',[string]$connection.port,'-U',$connection.user,'-d',$connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-')
        $facts=(Invoke-ExecutionAccessProbe (Join-Path $Layout.postgres_bin 'psql.exe') $pgArguments $sql $connection).Trim()|ConvertFrom-Json -AsHashtable
        if($facts.database -cne $connection.database -or $facts.login -cne $connection.user -or $facts.effective_login -cne $connection.user){throw 'Database/login differs from the bound execution configuration.'}
        return $facts
    }finally{$connection=$null}
}
function Assert-ExecutionAccessPolicy([System.Collections.IDictionary]$Descriptor,[System.Collections.IDictionary]$Facts){
    Assert-ExecutionAccessDescriptor $Descriptor
    if($Descriptor.role -isnot [string] -or $Descriptor.role -cnotin @('worker','telemetry')){throw 'Unknown execution consumer.'}
    if(-not $Facts.Contains('format') -or ($Facts.format -isnot [int] -and $Facts.format -isnot [long]) -or $Facts.format -ne 1){throw 'Execution ACL facts are invalid.'}
    foreach($key in @('schema_usage','leaf_identity','worker_minimum','worker_legacy','telemetry_owned','telemetry_legacy')){if(-not $Facts.Contains($key) -or $Facts[$key] -isnot [bool]){throw 'Execution ACL facts are incomplete.'}}
    if(-not $Facts.schema_usage){throw 'Execution consumer schema USAGE permission is missing.'}
    if(-not $Facts.leaf_identity){throw 'Execution consumer must use a non-administrative leaf database identity.'}
    $modern=$Descriptor.Contains('execution_access')
    if($Descriptor.role -ceq 'worker'){
        if(-not $Facts.worker_minimum){throw 'Worker minimum execution permissions are missing.'}
        if(-not $modern -and -not $Facts.worker_legacy){throw 'Legacy Worker requires retired execution permissions; start or rollback refused.'}
    }else{
        if(-not $Facts.telemetry_owned){throw 'Telemetry owned-table permissions are missing.'}
        if(-not $modern -and -not $Facts.telemetry_legacy){throw 'Unattested Telemetry may require retired events permissions; start or rollback refused.'}
    }
}
function Get-BoundExecutionConsumerConfiguration([hashtable]$Layout,[System.Collections.IDictionary]$Catalog,[string]$Role){
    . (Join-Path $PSScriptRoot 'platform-processes.ps1')
    if($Role -cnotin @('worker','telemetry') -or -not $Catalog.services.Contains($Role)){throw 'Execution consumer configuration is not registered.'}
    $deployment=$Catalog.services[$Role]
    if($deployment['pending'] -and $deployment.pending['configuration']){throw 'Unknown pending execution consumer configuration migration.'}
    $bytes=[IO.File]::ReadAllBytes((Join-Path $Layout.config_root ('services/'+$Role+'.json')))
    try{
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if($deployment.current['config_sha256'] -cne $hash){throw 'Execution consumer configuration differs from its registered deployment.'}
        $config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable
    }finally{[Array]::Clear($bytes,0,$bytes.Length)}
    $allowed=@($deployment.current)
    if($deployment['pending']){$allowed+=@($deployment.pending.prior,$deployment.pending.target)}
    foreach($entry in @((Read-PlatformProcesses $Layout)|Where-Object role -eq $Role)){
        $state=Get-PlatformInstanceState $entry $Layout
        if($state.requires_stop -or (-not $state.process -and $state.members.Count)){throw 'Execution consumer process ownership is unresolved.'}
        if(-not $state.process){continue}
        if(-not $entry['job_name'] -or -not $entry['launch_config'] -or $entry['source_config_sha256'] -cne $hash){throw 'Live execution consumer configuration is not bound to its deployment.'}
        $reference=@($allowed|Where-Object{$entry['release_reference'] -and $_.id -ceq $entry.release_reference.id})
        if($reference.Count -eq 0){throw 'Live execution consumer does not belong to its registered deployment.'}
        $descriptor=Read-ReleaseDescriptor $Layout $reference[0] -Verify
        if($entry.binary -ne (Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary)){throw 'Live execution consumer binary differs from its deployment.'}
        $launch=Read-ReleaseJson $entry.launch_config
        try{if([string]$launch['DATABASE_URL'] -cne [string]$config['DATABASE_URL']){throw 'Live execution consumer database differs from its bound configuration.'}}finally{$launch=$null}
    }
    return $config
}
function Assert-ExecutionAccessDeployment([hashtable]$Layout,[string[]]$Roles,[System.Collections.IDictionary]$Overrides=@{}){
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -ne 2){throw 'Execution ACL compatibility requires a versioned catalog.'}
    if(-not $Roles.Count){throw 'Select execution consumers for ACL validation.'}
    $runtime=Get-BoundRuntimeConfiguration $Layout $catalog
    try{
        foreach($role in $Roles){
            if($role -cnotin @('worker','telemetry') -or -not $catalog.services.Contains($role)){throw 'Execution consumer is not registered.'}
            $descriptor=if($Overrides.Contains($role)){$Overrides[$role]}else{Read-ReleaseDescriptor $Layout $catalog.services[$role].current -Verify}
            if($descriptor.role -cne $role){throw 'Execution descriptor has the wrong role.'}
            $config=Get-BoundExecutionConsumerConfiguration $Layout $catalog $role
            try{
                Assert-ExecutionAccessTarget $runtime $config $role
                $facts=Get-ExecutionAccessFacts $Layout $role $config
                Assert-ExecutionAccessPolicy $descriptor $facts
                Assert-ExecutionAccessBinary (Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary) $descriptor
            }finally{$config=$null}
        }
    }finally{$runtime=$null}
}
