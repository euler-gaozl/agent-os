[CmdletBinding()]
param([Parameter(Mandatory)][string]$KnowledgeBinary,[Parameter(Mandatory)][string]$Migrator,[Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
foreach($file in @('platform-paths','platform-lock','platform-releases','platform-processes','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$file+'.ps1'))}
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$proof=[IO.Path]::GetFullPath($EvidenceDirectory)
if(-not(Test-PathWithin $proof 'D:\workspace\agent-platform\local\evidence')){throw 'Fixture evidence must stay inside the local evidence root.'}
$null=New-Item -ItemType Directory -Path $proof
$layout=Get-PlatformLayout $repoRoot
foreach($key in @('state_root','config_root','database_root','log_root','release_root','harness_root','console_web_root','futures_web_root')){$layout[$key]=Join-Path $proof $key;$null=New-Item -ItemType Directory -Path $layout[$key]}
$layout.layout_path=Join-Path $proof 'layout.json';Write-PlatformJson $layout.layout_path $layout
$lock=Enter-PlatformMaintenance $layout.state_root
$checks=[Collections.Generic.List[string]]::new();$roles=[Collections.Generic.List[string]]::new();$created=$false
$result=@{passed=$false;formal_database_writes=0;formal_service_updates=0;model_calls=0;scope='Actual owner migration, restricted PostgreSQL identity, production start/update/rollback/recovery entrypoints, killed psql client with in-flight deferred COMMIT; zero service replicas, not a live Knowledge writer process test'}
function Accept([scriptblock]$Action,[string]$Name){& $Action|Out-Null;$checks.Add($Name)}
function Deny([scriptblock]$Action,[string]$Name,[string]$Pattern){$denied=$false;try{& $Action|Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$denied=$true};if(-not $denied){throw ('Unexpected acceptance: '+$Name)};$checks.Add($Name)}
function SQL([hashtable]$Connection,[string]$Query){Invoke-ExecutionAccessProbe (Join-Path $layout.postgres_bin 'psql.exe') @('-X','-w','-h',$Connection.host,'-p',[string]$Connection.port,'-U',$Connection.user,'-d',$Connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-') $Query $Connection}
function Start-FixtureSQL([hashtable]$Connection,[string]$Query){
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $layout.postgres_bin 'psql.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
    $info.Environment.Clear();foreach($key in @('SystemRoot','WINDIR','TEMP','TMP')){if([Environment]::GetEnvironmentVariable($key)){$info.Environment[$key]=[Environment]::GetEnvironmentVariable($key)}}
    $info.Environment['PGPASSWORD']=$Connection.password;$info.Environment['PGSSLMODE']='disable';$info.Environment['PGCONNECT_TIMEOUT']='3'
    foreach($arg in @('-X','-w','-h',$Connection.host,'-p',[string]$Connection.port,'-U',$Connection.user,'-d',$Connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-')){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$null=$p.Start()
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.StandardInput.Write($Query);$p.StandardInput.Close()
    return @{process=$p;stdout=$out;stderr=$err}
}
function Wait-FixtureBackend([string]$QueryPattern){
    $deadline=[datetime]::UtcNow.AddSeconds(5)
    do{
        $count=[int](SQL $database "SELECT count(*) FROM pg_stat_activity WHERE usename='$app' AND wait_event='PgSleep' AND query LIKE '$QueryPattern';").Trim()
        if($count -eq 1){return};Start-Sleep -Milliseconds 25
    }while([datetime]::UtcNow -lt $deadline)
    throw 'Fixture backend did not reach the controlled PostgreSQL wait.'
}
function Stop-FixtureSQL($Session){
    try{if(-not $Session.process.HasExited){$Session.process.Kill();$Session.process.WaitForExit()};$null=$Session.stdout.GetAwaiter().GetResult();$null=$Session.stderr.GetAwaiter().GetResult()}finally{$Session.process.Dispose()}
}
function Migrate-Fixture([string]$URL,[string]$App,[string]$Indexer){
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Migrator;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Environment.Clear();foreach($key in @('SystemRoot','WINDIR','TEMP','TMP')){if([Environment]::GetEnvironmentVariable($key)){$info.Environment[$key]=[Environment]::GetEnvironmentVariable($key)}}
    $info.Environment['MIGRATION_DATABASE_URL']=$URL;foreach($arg in @('--role',$App,'--indexer-role',$Indexer)){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    try{$null=$p.Start();$started=$true;$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(30000) -or $p.ExitCode){throw 'Isolated Knowledge owner migration failed'};$null=$out.GetAwaiter().GetResult();$null=$err.GetAwaiter().GetResult()}finally{if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
try {
    $admin=Get-ExecutionAccessConnection @{DATABASE_URL=$env:TEST_DATABASE_URL}
    if($admin.port -ne 55591 -or $admin.database -cne 'postgres' -or $admin.user -cne 'p2_fixture'){throw 'Explicit isolated fixture PostgreSQL required.'}
    $name='p2_archive_'+[guid]::NewGuid().ToString('N');$app=$name+'_app';$idx=$name+'_idx'
    foreach($role in @($app,$idx)){SQL $admin ('CREATE ROLE '+$role+" LOGIN PASSWORD 'fixture-only'")|Out-Null;$roles.Add($role)}
    SQL $admin ('CREATE DATABASE '+$name+' TEMPLATE template0')|Out-Null;$created=$true
    $database=@{};foreach($key in $admin.Keys){$database[$key]=$admin[$key]};$database.database=$name
    $uri=[UriBuilder]::new($env:TEST_DATABASE_URL);$uri.Path='/'+$name
    Migrate-Fixture $uri.Uri.AbsoluteUri $app $idx
    $uri.UserName=$app;$uri.Password='fixture-only';$uri.Query='sslmode=disable&search_path=knowledge'
    $config=@{DATABASE_URL=$uri.Uri.AbsoluteUri;LISTEN='127.0.0.1:65529';SERVICE_TOKEN=('fixture-token-'*4);SERVICE_PEERS='{}'}
    Write-PlatformJson (Join-Path $layout.config_root 'services/knowledge.json') $config
    Write-PlatformJson (Join-Path $layout.config_root 'dev.json') @{DATABASE_URL=$env:TEST_DATABASE_URL}
    $configHash=(Get-FileHash -LiteralPath (Join-Path $layout.config_root 'services/knowledge.json')).Hash.ToLowerInvariant()
    Copy-Item -LiteralPath $KnowledgeBinary -Destination (Join-Path $layout.release_root 'reader.exe')
    Set-Content -LiteralPath (Join-Path $layout.release_root 'legacy.exe') -Value 'inert legacy binary; tests must refuse before execution'
    $contract=@{http='agentos-http-v0.6-notes-lifecycle';data='knowledge-v0.6';tools=@();engines=@()}
    $provenance=@{kind='synthetic';dirty=$false}
    $legacy=New-ReleaseDescriptor $layout knowledge @{binary='legacy.exe'} $contract $provenance
    $bridge=New-ReleaseDescriptor $layout knowledge @{binary='reader.exe'} $contract $provenance -KnowledgeArchives @{format=1;reader=2;writer=1}
    $legacy.config_sha256=$configHash;$bridge.config_sha256=$configHash
    $old=Read-ReleaseDescriptor $layout $legacy -Verify;$reader=Read-ReleaseDescriptor $layout $bridge -Verify
    $writer=@{role='knowledge';contract=@{http=$contract.http;data='knowledge-v0.7-source-archives';tools=@();engines=@()};source_archives=@{format=1;reader=2;writer=2}}
    $catalog=@{format=2;generation=1;services=@{knowledge=@{current=$bridge;previous=$legacy;pending=$null}}}
    $catalogPath=Join-Path $layout.release_root 'current.json';Write-PlatformJson $catalogPath $catalog
    Accept {Assert-CompatibleRelease $old $reader;Assert-CompatibleRelease $reader $old} 'legacy_bridge_pair_before_new_writes'
    Accept {Assert-CompatibleRelease $reader $writer;Assert-CompatibleRelease $writer $reader} 'bridge_writer_pair_accepts_bidirectional_readers'
    Deny {Assert-CompatibleRelease $old $writer} 'legacy_cannot_be_writer_recovery_target_even_without_data' 'reader as both'
    Deny {Assert-KnowledgeArchiveBinary $KnowledgeBinary $writer} 'declared_writer_cannot_be_reader_binary' 'differs'
    foreach($bad in @($null,@{},@{format='1';reader=2;writer=1},@{format=1;reader=3;writer=1},@{format=1;reader=2;writer=1;extra=1})){
        Deny {Assert-KnowledgeArchiveDescriptor @{role='knowledge';source_archives=$bad}} ('malformed_profile_'+$checks.Count) 'capability'
    }
    Accept {Assert-KnowledgeArchiveDeployment $layout $old;Assert-KnowledgeArchiveDeployment $layout $reader} 'restricted_login_legacy_and_bridge_before_format2'
    $floorBody='{"format":1,"minimum_reader":2}';$floorBytes=[Text.Encoding]::UTF8.GetBytes($floorBody)
    $floorHash=[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($floorBytes));$floorHex=[Convert]::ToHexStringLower($floorBytes)
    SQL $database "INSERT INTO knowledge.artifacts(hash,body,media_type) VALUES('$floorHash',decode('$floorHex','hex'),'fixture');"|Out-Null
    Accept {Assert-KnowledgeArchiveDeployment $layout $old} 'same_bytes_without_protocol_root_do_not_raise_floor'
    $manifestBytes=[Text.Encoding]::UTF8.GetBytes('{"format":2}')
    $manifestHash=[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($manifestBytes));$manifestHex=[Convert]::ToHexStringLower($manifestBytes)
    # This minimal manifest is sufficient only for the format requirement probe,
    # never for retained-source integrity verification (tested separately).
    $write2="BEGIN; INSERT INTO knowledge.artifacts(hash,body,media_type) VALUES('$manifestHash',decode('$manifestHex','hex'),'fixture') ON CONFLICT DO NOTHING; INSERT INTO knowledge.artifact_refs VALUES('knowledge-source:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:manifests','$manifestHash') ON CONFLICT DO NOTHING; INSERT INTO knowledge.artifact_refs VALUES('knowledge-protocol:source-archives','$floorHash') ON CONFLICT DO NOTHING; COMMIT;"
    $leaf=Get-ExecutionAccessConnection $config
    $session=Start-FixtureSQL $leaf 'SELECT pg_sleep(30);'
    try{
        Wait-FixtureBackend 'SELECT pg_sleep%'
        $catalog.services.knowledge.pending=@{id=[guid]::NewGuid().ToString('N');phase='started';prior=$bridge;target=$bridge;replicas=0;non_target=@()}
        Write-PlatformJson $catalogPath $catalog;$before=(Get-FileHash -LiteralPath $catalogPath).Hash
        Deny {Restore-PendingRelease $layout knowledge $PSScriptRoot $lock} 'live_backend_timeout_retains_pending_recovery' 'probe failed'
        if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $before){throw 'Backend timeout changed recovery journal.'}
    }finally{
        Stop-FixtureSQL $session
        SQL $database "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='$app';"|Out-Null
        $catalog.services.knowledge.pending=$null;Write-PlatformJson $catalogPath $catalog
    }
    # A deferred constraint trigger executes inside COMMIT. Kill only the psql
    # client while the DB is sleeping, leaving its backend to finish the commit.
    SQL $database @'
CREATE FUNCTION knowledge.fixture_delay_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(2); RETURN NEW; END $$;
CREATE CONSTRAINT TRIGGER fixture_delay_commit AFTER INSERT ON knowledge.artifact_refs DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.root='knowledge-protocol:source-archives') EXECUTE FUNCTION knowledge.fixture_delay_commit();
'@|Out-Null
    $session=Start-FixtureSQL $leaf $write2
    try{
        Wait-FixtureBackend 'COMMIT%'
        $session.process.Kill();$session.process.WaitForExit()
        if([int](SQL $database "SELECT count(*) FROM pg_stat_activity WHERE usename='$app' AND wait_event='PgSleep';").Trim() -ne 1){throw 'Client kill did not leave an in-flight backend; fault was not reproduced.'}
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $facts=Get-KnowledgeArchiveFacts $layout $config -Stopped
        if((Get-KnowledgeArchiveRequirement $facts) -ne 2){throw 'Post-stop barrier missed the completed commit.'}
        $result.backend_commit_wait_ms=$timer.ElapsedMilliseconds
        $checks.Add('killed_client_backend_commit_seen_after_quiescence')
        Deny {Assert-KnowledgeArchiveDeployment $layout $old -Stopped} 'legacy_refused_after_delayed_backend_commit' 'require reader 2'
    }finally{
        Stop-FixtureSQL $session
        SQL $database "DROP TRIGGER fixture_delay_commit ON knowledge.artifact_refs; DROP FUNCTION knowledge.fixture_delay_commit(); DELETE FROM knowledge.artifact_refs WHERE root IN ('knowledge-protocol:source-archives','knowledge-source:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:manifests'); DELETE FROM knowledge.artifacts WHERE hash='$manifestHash';"|Out-Null
    }
    $checkpoint={param($point) if($point -eq 'stopped'){SQL $database $write2|Out-Null}}
    Deny {Invoke-ReleaseChange $layout knowledge update $legacy $PSScriptRoot $lock 5 $checkpoint} 'post_stop_recheck_catches_commit_after_precheck' 'require reader 2'
    $observed=Read-ReleaseCatalog $layout
    if($observed.services.knowledge.current.id -cne $bridge.id -or $observed.services.knowledge.pending){throw 'Bridge recovery failed after rejected downgrade.'}
    $checks.Add('failed_downgrade_restores_bridge_catalog_without_legacy_process')
    Accept {Assert-KnowledgeArchiveDeployment $layout $reader} 'bridge_reads_retained_format2'
    $before=(Get-FileHash -LiteralPath $catalogPath).Hash
    Deny {Invoke-ReleaseChange $layout knowledge rollback $null $PSScriptRoot $lock} 'bridge_cannot_then_rollback_to_legacy' 'require reader 2'
    if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $before){throw 'Rejected rollback changed catalog.'}
    $catalog=Read-ReleaseCatalog $layout
    $catalog.services.knowledge.pending=@{id=[guid]::NewGuid().ToString('N');phase='started';prior=$legacy;target=$bridge;replicas=0;non_target=@()}
    Write-PlatformJson $catalogPath $catalog;$before=(Get-FileHash -LiteralPath $catalogPath).Hash
    Deny {Restore-PendingRelease $layout knowledge $PSScriptRoot $lock} 'pending_recovery_cannot_restore_legacy_after_format2' 'require reader 2'
    if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $before){throw 'Rejected pending recovery changed journal.'}
    $catalog.services.knowledge.pending=$null;$catalog.services.knowledge.current=$legacy;Write-PlatformJson $catalogPath $catalog
    Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service knowledge -MaintenanceLock $lock} 'production_start_refuses_legacy_before_creating_process' 'require reader 2'
    $catalog.services.knowledge.current=$bridge;Write-PlatformJson $catalogPath $catalog
    foreach($case in @('missing','multiple','corrupt')){
        switch($case){
            missing {SQL $database "DELETE FROM knowledge.artifact_refs WHERE root='knowledge-protocol:source-archives';"|Out-Null}
            multiple {SQL $database "INSERT INTO knowledge.artifact_refs VALUES('knowledge-protocol:source-archives','$manifestHash');"|Out-Null}
            corrupt {SQL $database "UPDATE knowledge.artifacts SET body=decode('00','hex') WHERE hash='$floorHash';"|Out-Null}
        }
        Deny {Assert-KnowledgeArchiveDeployment $layout $reader} ($case+'_marker_refuses_even_bridge') 'requirement|protocol'
        SQL $database "DELETE FROM knowledge.artifact_refs WHERE root='knowledge-protocol:source-archives'; UPDATE knowledge.artifacts SET body=decode('$floorHex','hex') WHERE hash='$floorHash'; INSERT INTO knowledge.artifact_refs VALUES('knowledge-protocol:source-archives','$floorHash');"|Out-Null
    }
    $settingsPath=Join-Path $layout.config_root 'services/knowledge.json'
    $wrong=@{DATABASE_URL=$config.DATABASE_URL.Replace('/'+$name+'?','/postgres?')};Write-PlatformJson $settingsPath $wrong
    Deny {Assert-KnowledgeArchiveDeployment $layout $reader} 'changed_database_binding_refused' 'configuration differs'
    Write-PlatformJson $settingsPath $config
    $oldEnv=@{PGDATABASE=$env:PGDATABASE;PGHOSTADDR=$env:PGHOSTADDR;PGOPTIONS=$env:PGOPTIONS}
    try{$env:PGDATABASE='wrong';$env:PGHOSTADDR='192.0.2.1';$env:PGOPTIONS='-c role=wrong';Accept {Assert-KnowledgeArchiveDeployment $layout $reader} 'parent_pg_environment_cannot_redirect_probe'}finally{foreach($key in $oldEnv.Keys){[Environment]::SetEnvironmentVariable($key,$oldEnv[$key])}}
    $processes=Read-PlatformProcesses $layout
    if($processes.Count){throw 'Fixture created unexpected service process.'}
    $result.passed=$true
} finally {
    try{
        if($created){SQL $admin ('DROP DATABASE '+$name+' WITH (FORCE)')|Out-Null}
        foreach($role in $roles){SQL $admin ('DROP ROLE '+$role)|Out-Null}
    }finally{
        $lock.Dispose()
        $result.checks=@($checks);$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $proof 'result.json')
    }
}
$result|ConvertTo-Json -Depth 6
