[CmdletBinding()]
param([Parameter(Mandatory)][string]$RegistryBinary,[Parameter(Mandatory)][string]$ConsoleBinary,[Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
foreach($file in @('platform-paths','platform-lock','platform-releases','platform-processes','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$file+'.ps1'))}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$proof=[IO.Path]::GetFullPath($EvidenceDirectory)
if(-not(Test-PathWithin $proof 'D:\workspace\agent-platform\local\evidence')){throw 'Fixture evidence must stay in the evidence root.'}
$null=New-Item -ItemType Directory -Path $proof
$layout=Get-PlatformLayout $repo
foreach($key in @('state_root','config_root','database_root','log_root','release_root','harness_root','console_web_root','futures_web_root')){$layout[$key]=Join-Path $proof $key;$null=New-Item -ItemType Directory -Path $layout[$key]}
$layout.layout_path=Join-Path $proof 'layout.json';Write-PlatformJson $layout.layout_path $layout
$lock=Enter-PlatformMaintenance $layout.state_root
$checks=[Collections.Generic.List[string]]::new();$created=$false;$roles=[Collections.Generic.List[string]]::new();$session=$null
$result=@{passed=$false;ci_runs=0;paid_model_calls=0;formal_changes=0;scope='Actual binary profile probes and production maintenance entrypoints with zero replicas, restricted PostgreSQL, synthetic resources/runs fixture tables, delayed COMMIT after client kill. Not live Agent execution or model metadata discovery.'}
function Accept([scriptblock]$Action,[string]$Name){& $Action|Out-Null;$checks.Add($Name)}
function Deny([scriptblock]$Action,[string]$Name,[string]$Pattern=''){$denied=$false;try{& $Action|Out-Null}catch{if($Pattern -and $_.Exception.Message -notmatch $Pattern){throw};$denied=$true};if(-not $denied){throw ('Unexpected acceptance: '+$Name)};$checks.Add($Name)}
function SQL([hashtable]$Connection,[string]$Query){Invoke-ExecutionAccessProbe (Join-Path $layout.postgres_bin 'psql.exe') @('-X','-w','-h',$Connection.host,'-p',[string]$Connection.port,'-U',$Connection.user,'-d',$Connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-') $Query $Connection}
function Save-Catalog {Write-PlatformJson $catalogPath $catalog}
function Start-SQL([hashtable]$Connection,[string]$Query){
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $layout.postgres_bin 'psql.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true;$info.Environment.Clear()
    foreach($key in @('SystemRoot','WINDIR','TEMP','TMP')){if([Environment]::GetEnvironmentVariable($key)){$info.Environment[$key]=[Environment]::GetEnvironmentVariable($key)}}
    $info.Environment['PGPASSWORD']=$Connection.password;$info.Environment['PGSSLMODE']='disable'
    foreach($arg in @('-X','-w','-h',$Connection.host,'-p',[string]$Connection.port,'-U',$Connection.user,'-d',$Connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-')){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$null=$p.Start()
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.StandardInput.Write($Query);$p.StandardInput.Close()
    return @{process=$p;stdout=$out;stderr=$err}
}
function Close-SQL($Session){if(-not $Session){return};try{if(-not $Session.process.HasExited){$Session.process.Kill();$null=$Session.process.WaitForExit(10000)};$null=$Session.stdout.GetAwaiter().GetResult();$null=$Session.stderr.GetAwaiter().GetResult()}finally{$Session.process.Dispose()}}
try{
    $admin=Get-ExecutionAccessConnection @{DATABASE_URL=$env:TEST_DATABASE_URL}
    if($admin.port -ne 55591 -or $admin.database -cne 'postgres' -or $admin.user -cne 'p2_fixture'){throw 'Isolated fixture PostgreSQL required.'}
    $name='model_'+[guid]::NewGuid().ToString('N');$app=$name+'_app';$reader=$name+'_runtime'
    foreach($role in @($app,$reader)){SQL $admin ('CREATE ROLE '+$role+" LOGIN PASSWORD 'fixture-only'")|Out-Null;$roles.Add($role)}
    SQL $admin ('CREATE DATABASE '+$name+' TEMPLATE template0')|Out-Null;$created=$true
    $database=@{};foreach($key in $admin.Keys){$database[$key]=$admin[$key]};$database.database=$name
    SQL $database "CREATE TABLE public.resources(kind text,id text,revision int,spec jsonb,PRIMARY KEY(kind,id,revision)); CREATE TABLE public.runs(engine text,status text); GRANT USAGE ON SCHEMA public TO $app,$reader; GRANT SELECT,INSERT ON public.resources TO $app; GRANT SELECT ON public.runs TO $reader;"|Out-Null
    $url="postgres://${app}:fixture-only@127.0.0.1:55591/${name}?sslmode=disable&search_path=public"
    $config=@{DATABASE_URL=$url;LISTEN='127.0.0.1:18096'}
    $configs=@{registry=$config;control=@{REGISTRY_URL='http://127.0.0.1:18096';RUNTIME_URL='http://127.0.0.1:18094'};runtime=@{DATABASE_URL=$url.Replace($app+':',$reader+':');LISTEN='127.0.0.1:18094';DEFAULT_RUN_ENGINE=(Get-BudgetEngineName)}}
    foreach($role in $configs.Keys){Write-PlatformJson (Join-Path $layout.config_root ('services/'+$role+'.json')) $configs[$role]}
    Write-PlatformJson (Join-Path $layout.config_root 'dev.json') @{DATABASE_URL=$env:TEST_DATABASE_URL}
    Copy-Item -LiteralPath $RegistryBinary -Destination (Join-Path $layout.release_root 'registry.exe')
    Copy-Item -LiteralPath $ConsoleBinary -Destination (Join-Path $layout.release_root 'control.exe')
    Set-Content -LiteralPath (Join-Path $layout.release_root 'inert.exe') -Value 'inert old fixture; must never execute'
    $null=New-Item -ItemType Directory -Path (Join-Path $layout.release_root 'web');Set-Content -LiteralPath (Join-Path $layout.release_root 'web/index.html') -Value 'fixture'
    $contract=@{http='fixture';data='fixture';tools=@();engines=@()};$provenance=@{kind='synthetic';dirty=$false}
    $registryOld=New-ReleaseDescriptor $layout registry @{binary='inert.exe'} $contract $provenance
    $registryNew=New-ReleaseDescriptor $layout registry @{binary='registry.exe'} $contract $provenance -ModelManagement @{format=1;provides='agent-model-native-v1'}
    $controlOld=New-ReleaseDescriptor $layout control @{binary='inert.exe';web='web'} $contract $provenance
    $controlNew=New-ReleaseDescriptor $layout control @{binary='control.exe';web='web'} $contract $provenance -ModelManagement @{format=1;requires='agent-model-native-v1'}
    $runtimeContract=@{http='agentos-http-v0.7-source-state-v1';data='execution-v0.7-working-state';tools=@();engines=@()}
    $profiles=@{}
    foreach($p in (Get-SourceEngineProfiles)){
        $v=@{format=1;engine=$p.engine;execution_protocol='runtime-execution-v1';state_protocol='source-state-recovery-v1';submission_protocol='source-root-default-v1';preview_protocol='source-recovery-preview-v1'}
        if($p.metadata -ceq 'budget_execution'){$v.model_receipt_protocol='budget-model-receipt-v1'}
        if($p.metadata -ceq 'native_execution'){$v.model_receipt_protocol='native-model-receipt-v2'}
        $profiles[$p.metadata]=$v
    }
    $runtime=New-ReleaseDescriptor $layout runtime @{binary='inert.exe'} $runtimeContract $provenance -SourceExecution $profiles.source_execution -ResidentExecution $profiles.resident_execution -BudgetExecution $profiles.budget_execution -NativeExecution $profiles.native_execution
    foreach($item in @(@{role='registry';refs=@($registryOld,$registryNew)},@{role='control';refs=@($controlOld,$controlNew)},@{role='runtime';refs=@($runtime)})){
        $hash=(Get-FileHash -LiteralPath (Join-Path $layout.config_root ('services/'+$item.role+'.json'))).Hash.ToLowerInvariant()
        foreach($ref in $item.refs){$ref.config_sha256=$hash}
    }
    $ro=Read-ReleaseDescriptor $layout $registryOld -Verify;$rn=Read-ReleaseDescriptor $layout $registryNew -Verify
    $co=Read-ReleaseDescriptor $layout $controlOld -Verify;$cn=Read-ReleaseDescriptor $layout $controlNew -Verify;$rt=Read-ReleaseDescriptor $layout $runtime -Verify
    $facts=@{format=1;leaf_identity=$true;native_agents=$false;invalid_agents=$false}
    Accept {Assert-ModelManagementPolicy $ro $co $rt $facts $false (Get-BudgetEngineName)} 'legacy_pair_remains_usable'
    Accept {Assert-ModelManagementPolicy $rn $co $rt $facts $false (Get-BudgetEngineName)} 'Registry_can_upgrade_before_Console'
    Deny {Assert-ModelManagementPolicy $ro $cn $rt $facts $false (Get-BudgetEngineName)} 'new_Console_old_Registry_rejected' 'requires capable'
    Deny {Assert-ModelManagementPolicy $rn $cn @{role='runtime'} $facts $false ''} 'new_Console_old_Runtime_rejected' 'requires capable'
    Deny {Assert-ModelManagementPolicy $rn $co $rt $facts $true ''} 'old_Console_retained_native_task_rejected' 'Native tasks'
    Deny {Assert-ModelManagementPolicy $rn $co $rt $facts $false (Get-NativeEngineName)} 'old_Console_native_default_rejected' 'Native tasks'
    foreach($bad in @($null,@{},@{format='1';provides='agent-model-native-v1'},@{format=1;provides='other'},@{format=1;requires='agent-model-native-v1'},@{format=1;provides='agent-model-native-v1';extra=0})){
        Deny {Assert-ModelManagementDescriptor @{role='registry';model_management=$bad}} ('invalid_profile_'+$checks.Count)
    }
    Deny {Get-DeclaredModelManagement @{role='registry';model_management=@(@{format=1;provides='agent-model-native-v1'})}} 'raw_owner_array_cannot_be_unwrapped'
    Deny {Assert-LegacyConsoleWriterStopped $true $rn $co $true} 'legacy_Console_selection_requires_Registry_stopped' 'Stop Registry'
    Accept {Assert-LegacyConsoleWriterStopped $false $rn $co $true} 'Registry_can_upgrade_with_unchanged_legacy_Console'
    Accept {Assert-LegacyConsoleWriterStopped $true $rn $co $false} 'legacy_Console_selection_after_Registry_stop_can_probe'
    Accept {Assert-ModelManagementBinary $RegistryBinary $rn;Assert-ModelManagementBinary $ConsoleBinary $cn} 'real_binary_profiles_match'
    Deny {Assert-ModelManagementBinary $ConsoleBinary $rn} 'wrong_binary_capability_rejected'
    Accept {Assert-ModelManagementTarget $config $configs.control} 'bound_Registry_target_accepted'
    foreach($target in @('http://127.0.0.1:8096','http://127.0.0.1:18096/','http://other.invalid:18096','http://user@127.0.0.1:18096','http://127.0.0.1:18096?q=x')){Deny {Assert-ModelManagementTarget $config @{REGISTRY_URL=$target}} ('wrong_Registry_target_'+$checks.Count)}
    $catalog=@{format=2;generation=1;services=@{registry=@{current=$registryNew;previous=$registryOld;pending=$null};control=@{current=$controlNew;previous=$controlOld;pending=$null};runtime=@{current=$runtime;previous=$null;pending=$null}}}
    $catalogPath=Join-Path $layout.release_root 'current.json';Save-Catalog
    Accept {Assert-ModelManagementDeployment $layout} 'bound_configuration_and_restricted_SQL_probe'
    $leaf=Get-ExecutionAccessConnection $config
    $writeNative="INSERT INTO public.resources VALUES('agent','history',1,'{`"model`":{`"limits`":{}}}');"
    SQL $database ($writeNative+" INSERT INTO public.resources VALUES('agent','history',2,'{`"model`":{}}');")|Out-Null
    $observed=Get-ModelManagementFacts $layout $config -Stopped
    if(-not $observed.native_agents -or $observed.invalid_agents){throw 'Old native revision hidden by latest legacy revision'};$checks.Add('all_historical_revisions_checked')
    $completeServices=$catalog.services
    try{
        $catalog.services=@{registry=@{current=$registryOld;previous=$null;pending=$null}};Save-Catalog
        Deny {Assert-ModelManagementDeployment $layout} 'Registry_only_old_reader_cannot_skip_history' 'Retained Agent'
        Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service registry -MaintenanceLock $lock} 'Registry_only_cold_start_checks_history' 'Retained Agent'
        $catalog.services.registry.current=$registryNew;Save-Catalog
        Accept {Assert-ModelManagementDeployment $layout} 'Registry_only_capable_reader_remains_independent'
        $catalog.services.runtime=$completeServices.runtime;$catalog.services.registry.current=$registryOld;Save-Catalog
        Deny {Assert-ModelManagementDeployment $layout} 'Registry_Runtime_without_Console_checks_history' 'Retained Agent'
    }finally{$catalog.services=$completeServices;Save-Catalog}
    Deny {Assert-ModelManagementDeployment $layout @{registry=$ro}} 'Registry_downgrade_with_native_history_refused' 'Retained Agent'
    Deny {Assert-ModelManagementDeployment $layout @{control=$co}} 'Console_downgrade_with_native_history_refused' 'Retained Agent'
    $catalog.services.registry.current=$registryOld;Save-Catalog
    Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service registry -MaintenanceLock $lock} 'cold_start_old_Registry_with_native_history_refused' 'Retained Agent'
    $catalog.services.registry.current=$registryNew;Save-Catalog
    $export=Join-Path $proof 'export';Export-ReleaseCatalog $layout $export|Out-Null
    $restored=Join-Path $proof 'restored';Restore-ReleaseCatalog $export $restored|Out-Null
    Accept {Assert-ModelManagementPolicy (Read-ReleaseDescriptor @{release_root=$restored} $registryNew -Verify) (Read-ReleaseDescriptor @{release_root=$restored} $controlNew -Verify) $rt $observed $false (Get-BudgetEngineName)} 'backup_restore_preserves_model_capability'
    $before=(Get-FileHash -LiteralPath $catalogPath).Hash
    Deny {Invoke-ReleaseChange $layout registry rollback $null $PSScriptRoot $lock} 'real_rollback_entrypoint_refuses_before_pending' 'Retained Agent'
    if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $before){throw 'Precheck changed catalog'}
    $catalog.services.registry.pending=@{id=[guid]::NewGuid().ToString('N');action='update';phase='started';prior=$registryOld;target=$registryNew;replicas=0;non_target=@()};Save-Catalog
    Deny {Restore-PendingRelease $layout registry $PSScriptRoot $lock} 'pending_recovery_cannot_remove_native_reader' 'Retained Agent'
    if(-not (Read-ReleaseCatalog $layout).services.registry.pending){throw 'Blocked recovery lost pending journal'}
    $catalog.services.registry.pending=$null;Save-Catalog
    SQL $database 'DELETE FROM public.resources;'|Out-Null
    # Disable the Console requirement solely in this zero-replica fixture so a
    # Registry downgrade can reach the post-stop retained-data check.
    $catalog.services.control.current=$controlOld;Save-Catalog
    $checkpoint={param($point) if($point -ceq 'stopped'){SQL $database $writeNative|Out-Null}}
    Deny {Invoke-ReleaseChange $layout registry rollback $null $PSScriptRoot $lock 5 $checkpoint} 'late_write_after_precheck_blocks_start_and_recovery' 'Retained Agent'
    if(-not (Read-ReleaseCatalog $layout).services.registry.pending){throw 'Unsafe auto recovery dropped its journal'}
    $catalog.services.registry.pending=$null;$catalog.services.control.current=$controlNew;Save-Catalog
    SQL $database 'DELETE FROM public.resources;'|Out-Null
    SQL $database @'
CREATE FUNCTION public.fixture_commit_delay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(2); RETURN NEW; END $$;
CREATE CONSTRAINT TRIGGER fixture_commit_delay AFTER INSERT ON public.resources DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fixture_commit_delay();
'@|Out-Null
    $session=Start-SQL $leaf ('BEGIN; '+$writeNative+' COMMIT;')
    $deadline=[datetime]::UtcNow.AddSeconds(5);$sleeping=$false
    do{$sleeping=[int](SQL $database "SELECT count(*) FROM pg_stat_activity WHERE usename='$app' AND wait_event='PgSleep';").Trim() -eq 1;if($sleeping){break};Start-Sleep -Milliseconds 20}while([datetime]::UtcNow -lt $deadline)
    if(-not $sleeping){throw 'Deferred COMMIT fault was not reached'}
    if((Get-ModelManagementFacts $layout $config).native_agents){throw 'Uncommitted fixture unexpectedly visible'}
    $session.process.Kill();if(-not $session.process.WaitForExit(10000) -or $session.process.ExitCode -eq 0){throw 'Client kill not proven'}
    if([int](SQL $database "SELECT count(*) FROM pg_stat_activity WHERE usename='$app' AND wait_event='PgSleep';").Trim() -ne 1){throw 'PostgreSQL backend did not survive client kill'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Deny {Invoke-ReleaseChange $layout control rollback $null $PSScriptRoot $lock} 'Console_rollback_waits_for_deferred_Registry_commit' 'Retained Agent'
    $result.backend_commit_wait_ms=$watch.ElapsedMilliseconds
    $observed=Get-ModelManagementFacts $layout $config -Stopped
    if(-not $observed.native_agents){throw 'Post-stop probe missed late COMMIT'};$checks.Add('killed_client_deferred_commit_detected_after_backend_drain')
    Close-SQL $session;$session=$null
    SQL $database 'DROP TRIGGER fixture_commit_delay ON public.resources; DROP FUNCTION public.fixture_commit_delay(); UPDATE public.resources SET spec=''[]''::jsonb;'|Out-Null
    Deny {Assert-ModelManagementDeployment $layout} 'malformed_retained_Agent_fails_closed' 'malformed Agent'
    SQL $database 'DELETE FROM public.resources;'|Out-Null
    $path=Join-Path $layout.config_root 'services/registry.json';$original=[IO.File]::ReadAllBytes($path)
    try{Write-PlatformJson $path @{DATABASE_URL=$config.DATABASE_URL;LISTEN='127.0.0.1:8096'};Deny {Assert-ModelManagementDeployment $layout} 'unregistered_Registry_configuration_rejected' 'configuration differs'}finally{[IO.File]::WriteAllBytes($path,$original)}
    $result.passed=$true
}catch{$result.failure=$_.Exception.Message;$result.failure_line=$_.InvocationInfo.ScriptLineNumber}finally{
    Close-SQL $session
    if($created){SQL $admin ('DROP DATABASE '+$name+' WITH (FORCE)')|Out-Null}
    foreach($role in $roles){SQL $admin ('DROP ROLE '+$role)|Out-Null}
    $lock.Dispose();$result.checks=$checks.ToArray();$result.source_hashes=@{}
    foreach($file in @('Test-ModelManagement.ps1','lib/platform-model-management.ps1','lib/platform-releases.ps1','lib/platform-receipts.ps1','lib/platform-release-operations.ps1','lib/platform-engine-configuration.ps1','Start-Local.ps1','Build-Services.ps1')){$result.source_hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file)).Hash.ToLowerInvariant()}
    $result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $proof 'result.json')
    [pscustomobject]@{proof=$proof;passed=$result.passed;checks=$checks.Count;failure=$result['failure'];line=$result['failure_line']}|ConvertTo-Json
}
if(-not $result.passed){exit 1}
