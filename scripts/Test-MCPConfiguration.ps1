param([string]$CrashRoot='',[string]$CrashPoint='',[ValidateSet('runtime','toolhub','sources')][string]$Role='runtime',[ValidateSet('network','receipt-exports')][string]$Policy='network')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-processes','platform-recovery','platform-releases','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
. (Join-Path $PSScriptRoot 'fixtures/windows-release/access.ps1')
$fixtureScripts=Join-Path $PSScriptRoot 'fixtures/mcp-config'
# Test registry injection isolates production processes; the real global scanner
# still runs against these actual registered-layout process records.
$script:extraRoot=$null
function Get-MCPManagedRoots([hashtable]$Layout){return ,@( $Layout; if($script:extraRoot){$script:extraRoot} )}
function Test-HostValues([string]$Service,[string[]]$Hosts){
    if($Policy -ceq 'receipt-exports'){
        $rules=@($Hosts|Sort-Object|ForEach-Object{[ordered]@{app='fixture';id=('check-'+($_.Split(':')[-1]));tool=('fixture_check_'+($_.Split(':')[-1]));input_path=@('arguments','draft');output_path=@('content','0','text')}})
        return ,@((ConvertTo-ReceiptExports (ConvertTo-Json -InputObject $rules -Depth 8 -Compress)))
    }
    if($Service -cne 'sources'){return ,$Hosts}
    return ,@($Hosts|ForEach-Object{if($_ -ceq '127.0.0.1:8101'){'example.com'}elseif($_ -ceq '127.0.0.1:8098'){'example.org'}else{throw 'Unknown synthetic host mapping.'}})
}
function Set-TestHosts([hashtable]$Target,[string]$Service,[string[]]$Hosts,[string]$Scripts,[IO.FileStream]$Lock,[int]$TimeoutSeconds=30,[scriptblock]$Checkpoint={param($point)}){
    $receiptFixtureLayout=$Target;$receiptFixtureService=$Service;$receiptFixtureCheckpoint=$Checkpoint
    $guardedCheckpoint={param($point)
        # The lightweight HTTP fixture startup omits production's source-engine
        # checks. Exercise its real configuration binding at stable journal phases.
        if($receiptFixtureService -ceq 'runtime' -and $point -in @('prepared','stopped','configuration_written','started','ready','committed')){
            $null=Get-BoundRuntimeConfiguration $receiptFixtureLayout (Read-ReleaseCatalog $receiptFixtureLayout)
        }
        & $receiptFixtureCheckpoint $point
    }
    Set-ServiceMCPHosts $Target $Service (Test-HostValues $Service $Hosts) $Scripts $Lock $TimeoutSeconds $guardedCheckpoint -Policy $Policy
}
if($CrashRoot){
    if(-not(Test-PathWithin $CrashRoot 'D:\workspace\agent-platform\local\evidence')){throw 'Invalid fault fixture root.'}
    $layout=Get-PlatformLayout $repo (Join-Path $CrashRoot 'layout.json');$lock=Enter-PlatformMaintenance $layout.state_root
    try{
        $checkpoint={param($point) if($point -ceq $CrashPoint){[Environment]::Exit(197)}}
        if($CrashPoint -in @('reverting','prior_configuration_written','recovery_ready')){Restore-PendingMCPConfiguration $layout $Role $fixtureScripts $lock 4 $checkpoint|Out-Null}
        else{Set-TestHosts $layout $Role @('127.0.0.1:8101','127.0.0.1:8098') $fixtureScripts $lock 4 $checkpoint|Out-Null}
    }finally{$lock.Dispose()}
    throw 'MCP fault checkpoint not reached.'
}
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('mcp-config-'+[guid]::NewGuid().ToString('N'));New-ProtectedDirectory $proof
$layout=@{format=1;project_root=$repo;state_root=(Join-Path $proof 'run');release_root=(Join-Path $proof 'releases');config_root=(Join-Path $proof 'config');log_root=(Join-Path $proof 'logs');layout_path=(Join-Path $proof 'layout.json');database_root=(Join-Path $proof 'unused-db');harness_root=(Join-Path $proof 'unused-harness');console_web_root=(Join-Path $proof 'unused-console');futures_web_root=(Join-Path $proof 'unused-futures');postgres_bin='D:\workspace\.tools\postgresql\pgsql\bin'}
foreach($path in @($layout.state_root,$layout.release_root,$layout.log_root,$layout.config_root)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
Write-PlatformJson $layout.layout_path $layout
$checks=[Collections.Generic.List[string]]::new();$access=$null;$lock=$null;$started=$false;$child=$null
$cluster='D:\workspace\agent-platform\local\evidence\p2-first-services-85be4f84e89f47ad935b6ed8882093c0\postgres'
$result=@{passed=$false;scope='Real synthetic Windows HTTP processes, DPAPI, catalog/config commits and subprocess exits; real restricted PostgreSQL idle check; test lifecycle on ephemeral ports, not production entrypoint or MCP execution';model_calls=0;actions=0}
function Check([bool]$Value,[string]$Name){if(-not $Value){throw $Name};$checks.Add($Name)}
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Name){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};if($message -notmatch $Pattern){throw ($Name+': '+$message)};$checks.Add($Name)}
function Assert-Hosts([string]$Service,[string]$Expected){
    $catalog=Read-ReleaseCatalog $layout;$config=Read-ReleaseJson (Join-Path $layout.config_root ('services/'+$Service+'.json'))
    Wait-ReleaseReady $layout $Service 1 $catalog.services[$Service].current 4
    $suffix=if($Policy -ceq 'receipt-exports'){'receipt-exports'}elseif($Service -ceq 'sources'){'source-hosts'}else{'mcp-hosts'}
    if($Policy -ceq 'receipt-exports'){$Expected=(Test-HostValues $Service $Expected.Split(','))[0]}
    elseif($Service -ceq 'sources'){$Expected=ConvertTo-SourceHosts (Test-HostValues $Service $Expected.Split(','))}
    $reply=Invoke-RestMethod ('http://'+$config.LISTEN+'/fixture/'+$suffix) -Headers @{Authorization=('Bearer '+$config.SERVICE_TOKEN)} -NoProxy -TimeoutSec 3
    if($reply.hosts -cne $Expected){throw 'Actual process loaded different MCP policy.'}
    $null=Get-BoundRuntimeConfiguration $layout $catalog
}
function Crash([string]$Service,[string]$Point){
    $script:child=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-CrashRoot',('"'+$proof+'"'),'-CrashPoint',$Point,'-Role',$Service,'-Policy',$Policy) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof ($Service+'-'+$Point+'.out.log')) -RedirectStandardError (Join-Path $proof ($Service+'-'+$Point+'.err.log'))
    if(-not $script:child.WaitForExit(45000)){ $script:child.Kill();if(-not $script:child.WaitForExit(10000)){throw 'Fault child exit unconfirmed'};throw 'MCP fault deadline exceeded; terminated exact child' }
    if($script:child.ExitCode -ne 197){throw ('MCP fault not reached: '+$Service+'/'+$Point)}
    $script:child.Dispose();$script:child=$null
}
try{
    & (Join-Path $layout.postgres_bin 'pg_ctl.exe') -D $cluster status *> (Join-Path $proof 'pg-prior.log');if($LASTEXITCODE -ne 3){throw 'Disposable cluster must be stopped.'}
    $pgStart=Start-Process -FilePath (Join-Path $layout.postgres_bin 'pg_ctl.exe') -ArgumentList @('-D',$cluster,'-l',(Join-Path $proof 'pg.log'),'-o','"-h 127.0.0.1 -p 55591"','start','-w') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof 'pg-start.log') -RedirectStandardError (Join-Path $proof 'pg-start.err.log')
    if(-not $pgStart.WaitForExit(15000) -or $pgStart.ExitCode){throw 'Disposable PostgreSQL startup failed'};$started=$true
    $env:TEST_DATABASE_URL='postgres://p2_fixture:fixture-only@127.0.0.1:55591/postgres?sslmode=disable&search_path=public'
    $env:GOCACHE='D:\workspace\.tools\gocache';$env:GOWORK='off';$env:GOENV='off';$env:GOFLAGS='';$env:GOTOOLCHAIN='local'
    $binary=Join-Path $proof 'fixture.exe'
    & 'D:\workspace\.tools\go\bin\go.exe' build -trimpath -o $binary (Join-Path $PSScriptRoot 'fixtures/windows-release/main.go');if($LASTEXITCODE){throw 'Fixture build failed'}
    $access=New-ReleaseAccessFixture $layout $binary
    $db=$access.admin.Clone();$db.database=$access.name
    $null=Invoke-ReleaseFixtureSQL $layout $db ('CREATE TABLE runs(id text,status text); GRANT SELECT ON runs TO '+$access.created_roles[0])
    $catalog=@{format=2;generation=1;services=@{}}
    $marker=Join-Path $proof 'unready.marker'
    foreach($service in @('runtime','toolhub','sources')){
        $config=Read-ReleaseJson (Join-Path $layout.config_root 'services/runtime.json')
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
        $config.LISTEN='127.0.0.1:'+$port;$config.MCP_ALLOWED_HOSTS='127.0.0.1:8101';$config.unready_mcp_marker=$marker
        if($Policy -ceq 'receipt-exports'){$config.APP_RECEIPT_EXPORTS=(Test-HostValues runtime @('127.0.0.1:8101'))[0];$config.receipt_protocol_marker=$marker+'.protocol'}
        if($service -ceq 'sources'){$config.SOURCE_ALLOWED_HOSTS='example.com'}
        Write-PlatformJson (Join-Path $layout.config_root ('services/'+$service+'.json')) $config
        $relative='bundles/'+$service+'/current.exe';$path=Resolve-ReleasePath $layout.release_root $relative;New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force|Out-Null;Copy-Item -LiteralPath $binary -Destination $path
        $reference=New-ReleaseDescriptor $layout $service @{binary=$relative} @{http='synthetic-v1';data='none';engines=@();tools=@()} @{kind='synthetic';dirty=$false}
        $reference.config_sha256=(Get-FileHash -LiteralPath (Join-Path $layout.config_root ('services/'+$service+'.json'))).Hash.ToLowerInvariant()
        $previous=$reference.Clone()
        $catalog.services[$service]=@{current=$reference;previous=$previous;pending=$null}
    }
    Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog
    $lock=Enter-PlatformMaintenance $layout.state_root
    foreach($service in @('runtime','toolhub','sources')){& (Join-Path $fixtureScripts 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service $service -MaintenanceLock $lock;Assert-Hosts $service '127.0.0.1:8101'}
    foreach($bad in @('https://example.com','*.test:443','host:0','host:99999','host:80/path','HOST:10','host:080','host.:10')){Reject {ConvertTo-MCPHosts @($bad)} 'MCP' ('reject_'+$bad)}
    Check ((ConvertTo-MCPHosts @('host:80','[::1]:80')) -ceq '[::1]:80,host:80') 'explicit_default_ports_preserved'
    foreach($bad in @('https://example.com','*.example.com','example.com:443','127.0.0.1','[::1]','localhost','host.local','EXAMPLE.COM','example.com.','a..com','-a.com','a-.com','example.com/path','user@example.com')){Reject {ConvertTo-SourceHosts @($bad)} 'Sources' ('source_reject_'+$bad)}
    Reject {ConvertTo-SourceHosts @()} 'Sources' 'empty_sources_policy_rejected_without_default_fallback'
    Reject {ConvertTo-SourceHosts @('example.com','example.com')} 'Duplicate' 'duplicate_source_host_rejected'
    Check ((ConvertTo-SourceHosts @('example.org','example.com')) -ceq 'example.com,example.org') 'source_hosts_canonical'
    if($Policy -ceq 'receipt-exports'){
        Check ((Get-ReceiptProjectionProbeURI @{}) -ceq 'http://127.0.0.1:8094/v1/receipt-projections') 'receipt_probe_matches_runtime_default_listener'
        Check ((Get-ReceiptProjectionProbeURI @{LISTEN=''}) -ceq 'http://127.0.0.1:8094/v1/receipt-projections') 'receipt_probe_empty_listener_matches_runtime_default'
        Check ((Get-ReceiptProjectionProbeURI @{LISTEN='127.0.0.1:18094'}) -ceq 'http://127.0.0.1:18094/v1/receipt-projections') 'receipt_probe_explicit_local_listener'
        foreach($bad in @('https://example.com','example.com:8094','127.0.0.1:0','127.0.0.1:65536','127.0.0.1:8094/path')){Reject {Get-ReceiptProjectionProbeURI @{LISTEN=$bad}} 'Receipt projection' 'receipt_probe_invalid_listener_rejected'}
        Reject {Get-ReceiptProjectionProbeURI @{LISTEN=8094}} 'must be text' 'receipt_probe_nontext_listener_rejected'
        foreach($bad in @('{}','null','[{"app":"x"}]','[{"app":"x","id":"y","tool":"z","input_path":[],"output_path":["x"]}]')){Reject {ConvertTo-ReceiptExports $bad} 'receipt|Receipt' 'invalid_receipt_projection_denied'}
        Check ((ConvertTo-ReceiptExports '[]') -ceq '[]') 'empty_receipt_policy_is_closed'
        $priorConfigHash=(Get-FileHash -LiteralPath (Join-Path $layout.config_root 'services/runtime.json')).Hash
        [IO.File]::WriteAllText(($marker+'.protocol'),'unsupported')
        Reject {Set-TestHosts $layout runtime @('127.0.0.1:8101','127.0.0.1:8098') $fixtureScripts $lock 4} 'required receipt projection protocol' 'old_runtime_refused_before_configuration'
        Check ((Get-FileHash -LiteralPath (Join-Path $layout.config_root 'services/runtime.json')).Hash -ceq $priorConfigHash) 'old_runtime_configuration_unchanged'
        [IO.File]::WriteAllText(($marker+'.protocol'),'digest')
        Reject {Set-TestHosts $layout runtime @('127.0.0.1:8101','127.0.0.1:8098') $fixtureScripts $lock 4} 'loaded configuration digest' 'unloaded_projection_policy_refused_after_restart'
        Check ((Get-FileHash -LiteralPath (Join-Path $layout.config_root 'services/runtime.json')).Hash -ceq $priorConfigHash -and -not (Read-ReleaseCatalog $layout).services.runtime.pending) 'digest_failure_restores_prior_configuration'
        Remove-Item -LiteralPath ($marker+'.protocol')
    }
    $testedServices=if($Policy -ceq 'receipt-exports'){@('runtime')}else{@('runtime','toolhub','sources')}
    foreach($service in $testedServices){
        $hostKey=(Get-NetworkHostProfile $service $Policy).key
        $others=Get-ReleaseProcessSnapshot $layout $service
        $entries=Read-PlatformProcesses $layout;$live=@($entries|Where-Object role -eq $service)[0]
        $savedLaunch=[IO.File]::ReadAllBytes($live.launch_config);$savedProcesses=[IO.File]::ReadAllBytes((Join-Path $layout.state_root 'processes.json'))
        $drift=Read-ReleaseJson $live.launch_config;$drift[$hostKey]='127.0.0.1:1';Write-PlatformJson $live.launch_config $drift
        $live.launch_config_sha256=(Get-FileHash -LiteralPath $live.launch_config).Hash.ToLowerInvariant();Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $entries
        Reject {Set-TestHosts $layout $service @('127.0.0.1:8098') $fixtureScripts $lock 4} 'configuration differs' ($service+'_live_launch_drift_refused')
        [IO.File]::WriteAllBytes($live.launch_config,$savedLaunch);[IO.File]::WriteAllBytes((Join-Path $layout.state_root 'processes.json'),$savedProcesses)
        $runtimeConfig=Read-ReleaseJson (Join-Path $layout.config_root 'services/runtime.json');$runtimeConfig.DATABASE_URL+='&dbname=postgres'
        Reject {Assert-MCPExecutionIdle $layout $runtimeConfig} 'explicit local PostgreSQL' ($service+'_query_database_override_refused')
        $script:extraRoot=@{state_root=(Join-Path $proof 'other-run');release_root=$layout.release_root}
        $foreign=$live.Clone();$foreign.role='worker';Write-PlatformJson (Join-Path $script:extraRoot.state_root 'processes.json') @($foreign)
        Reject {Set-TestHosts $layout $service @('127.0.0.1:8098') $fixtureScripts $lock 4} 'every registered layout' ($service+'_cross_layout_ingress_refused')
        $script:extraRoot=$null
        $null=Invoke-ReleaseFixtureSQL $layout $db "INSERT INTO runs VALUES('active','queued')"
        Reject {Set-TestHosts $layout $service @('127.0.0.1:8098') $fixtureScripts $lock 4} 'Execution work is active' ($service+'_active_runs_denied')
        $null=Invoke-ReleaseFixtureSQL $layout $db 'DELETE FROM runs'
        $null=Set-TestHosts $layout $service @('127.0.0.1:8101','127.0.0.1:8098') $fixtureScripts $lock 4
        Assert-Hosts $service '127.0.0.1:8098,127.0.0.1:8101'
        $current=Read-ReleaseCatalog $layout
        Check ($current.services[$service].current.config_sha256 -ceq $current.services[$service].previous.config_sha256) ($service+'_previous_code_binding_preserved')
        $null=Set-TestHosts $layout $service @('127.0.0.1:8101') $fixtureScripts $lock 4
        [IO.File]::WriteAllText($marker,'synthetic failure')
        Reject {Set-TestHosts $layout $service @('127.0.0.1:8101','127.0.0.1:8098') $fixtureScripts $lock 1} 'ready' ($service+'_readiness_failure_restores_prior')
        Remove-Item -LiteralPath $marker;Assert-Hosts $service '127.0.0.1:8101'
        $lock.Dispose();$lock=$null
        foreach($point in @('prepared','configuration_replaced','started','committed','prior_configuration_written')){
            Crash $service $(if($point -eq 'prior_configuration_written'){'started'}else{$point})
            if($point -eq 'prior_configuration_written'){Crash $service $point}
            $lock=Enter-PlatformMaintenance $layout.state_root
            if($point -eq 'committed'){
                Assert-Hosts $service '127.0.0.1:8098,127.0.0.1:8101'
                Reject {Invoke-ReleaseChange $layout $service recover $null $fixtureScripts $lock 4} 'No pending' ($service+'_committed_not_rewound')
                $null=Set-TestHosts $layout $service @('127.0.0.1:8101') $fixtureScripts $lock 4
            }else{$null=Invoke-ReleaseChange $layout $service recover $null $fixtureScripts $lock 4}
            Assert-Hosts $service '127.0.0.1:8101'
            Check (Test-ReleaseSnapshotsEqual $others (Get-ReleaseProcessSnapshot $layout $service)) ($service+'_crash_'+$point+'_non_target_preserved')
            $lock.Dispose();$lock=$null
        }
        Crash $service 'started';$lock=Enter-PlatformMaintenance $layout.state_root
        $entries=Read-PlatformProcesses $layout;$live=@($entries|Where-Object role -eq $service)[0]
        $savedLaunch=[IO.File]::ReadAllBytes($live.launch_config);$savedProcesses=[IO.File]::ReadAllBytes((Join-Path $layout.state_root 'processes.json'))
        $drift=Read-ReleaseJson $live.launch_config;$drift[$hostKey]='127.0.0.1:1';Write-PlatformJson $live.launch_config $drift
        $live.launch_config_sha256=(Get-FileHash -LiteralPath $live.launch_config).Hash.ToLowerInvariant();Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $entries
        Reject {Invoke-ReleaseChange $layout $service recover $null $fixtureScripts $lock 4} 'configuration differs' ($service+'_recovery_third_launch_refused')
        [IO.File]::WriteAllBytes($live.launch_config,$savedLaunch);[IO.File]::WriteAllBytes((Join-Path $layout.state_root 'processes.json'),$savedProcesses)
        $script:extraRoot=@{state_root=(Join-Path $proof 'other-run');release_root=$layout.release_root}
        $foreign=$live.Clone();$foreign.role='worker';Write-PlatformJson (Join-Path $script:extraRoot.state_root 'processes.json') @($foreign)
        Reject {Invoke-ReleaseChange $layout $service recover $null $fixtureScripts $lock 4} 'every registered layout' ($service+'_recovery_cross_layout_ingress_refused')
        $script:extraRoot=$null
        $path=Join-Path $layout.config_root ('services/'+$service+'.json');$original=[IO.File]::ReadAllBytes($path)
        [IO.File]::AppendAllText($path,' ')
        Reject {Invoke-ReleaseChange $layout $service recover $null $fixtureScripts $lock 4} 'neither recorded version' ($service+'_manual_drift_not_overwritten')
        [IO.File]::WriteAllBytes($path,$original)
        $null=Invoke-ReleaseChange $layout $service recover $null $fixtureScripts $lock 4
        Assert-Hosts $service '127.0.0.1:8101'
        # Missing source key must not allow an injected live launch key.
        $catalog=Read-ReleaseCatalog $layout;$path=Join-Path $layout.config_root ('services/'+$service+'.json')
        $savedConfig=[IO.File]::ReadAllBytes($path);$savedCatalog=[IO.File]::ReadAllBytes((Join-Path $layout.release_root 'current.json'))
        $absent=Read-ReleaseJson $path;$null=$absent.Remove($hostKey);Write-PlatformJson $path $absent
        $catalog.services[$service].current.config_sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        $entries=Read-PlatformProcesses $layout;$live=@($entries|Where-Object role -eq $service)[0];$savedProcesses=[IO.File]::ReadAllBytes((Join-Path $layout.state_root 'processes.json'))
        $live.source_config_sha256=$catalog.services[$service].current.config_sha256;Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $entries;Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog
        Reject {Assert-MCPInstanceConfiguration $layout $service $catalog.services[$service].current $absent} 'configuration differs' ($service+'_extra_live_policy_key_denied')
        [IO.File]::WriteAllBytes($path,$savedConfig);[IO.File]::WriteAllBytes((Join-Path $layout.release_root 'current.json'),$savedCatalog);[IO.File]::WriteAllBytes((Join-Path $layout.state_root 'processes.json'),$savedProcesses)
    }
    $result.passed=$true
}catch{$result.failure=$_.Exception.Message;throw}
finally{
    $safe=$true
    if($child){try{if(-not $child.HasExited){$child.Kill();if(-not $child.WaitForExit(10000)){throw 'Child still alive'}};$child.Dispose()}catch{$safe=$false}}
    if($safe){try{if(-not $lock){$lock=Enter-PlatformMaintenance $layout.state_root};foreach($service in @('runtime','toolhub','sources')){& (Join-Path $fixtureScripts 'Stop-Local.ps1') -LayoutPath $layout.layout_path -Service $service -MaintenanceLock $lock}}catch{$safe=$false;$result.cleanup_failure='Synthetic process cleanup failed'}finally{if($lock){$lock.Dispose()}}}
    if($safe -and $access){Remove-ReleaseAccessFixture $layout $access}
    if($safe -and $started){& (Join-Path $layout.postgres_bin 'pg_ctl.exe') -D $cluster stop -m fast -w *> (Join-Path $proof 'pg-stop.log');if($LASTEXITCODE){$safe=$false}}
    $result.cleanup_complete=$safe;$result.checks=@($checks.ToArray());if(-not $safe){$result.passed=$false};Write-PlatformJson (Join-Path $proof 'result.json') $result
    Write-Output ('MCP configuration evidence: '+$proof)
}
if(-not $result.passed){throw 'MCP configuration verification incomplete.'}
