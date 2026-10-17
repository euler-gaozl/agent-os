[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$LegacyBinary,[Parameter(Mandatory)][string]$ReaderBinary,
 [Parameter(Mandatory)][string]$WriterBinary,[Parameter(Mandatory)][string]$Migrator,
 [Parameter(Mandatory)][string]$PeerBinary,[Parameter(Mandatory)][string]$EvidenceDirectory,
 [IO.FileStream]$MaintenanceLock=$null
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
foreach($file in @('platform-paths','platform-lock','platform-releases','platform-processes','platform-release-operations','knowledge-archive-recovery')){. (Join-Path $PSScriptRoot ('lib/'+$file+'.ps1'))}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));$proof=[IO.Path]::GetFullPath($EvidenceDirectory)
if(-not(Test-PathWithin $proof 'D:\workspace\agent-platform\local\evidence')){throw 'Isolated evidence root required.'}
$null=New-Item -ItemType Directory -Path $proof
$layout=Get-PlatformLayout $repo
foreach($key in @('state_root','config_root','database_root','log_root','release_root','harness_root','console_web_root','futures_web_root')){$layout[$key]=Join-Path $proof $key;$null=New-Item -ItemType Directory -Path $layout[$key]}
$layout.layout_path=Join-Path $proof 'layout.json';Write-PlatformJson $layout.layout_path $layout
$ownedLock=Enter-PlatformMaintenance $layout.state_root $MaintenanceLock
$lock=if($MaintenanceLock){$MaintenanceLock}else{$ownedLock}
$checks=[Collections.Generic.List[string]]::new();$roles=[Collections.Generic.List[string]]::new();$created=$false;$http=$null
$result=@{passed=$false;checks_passed=$false;cleanup_passed=$false;provider_calls=0;formal_database_changes=0;fixture_script_formal_service_changes=0;requires_exclusive_service_roles=@('knowledge','sources');scope='Real legacy/reader/writer Knowledge binaries, isolated PostgreSQL and authenticated HTTP fixture peers, real Windows release manager update/failure/rollback; fixture data is not researched evidence. The caller must separately account for temporary formal service stops needed for exclusive roles.'}
function SQL([hashtable]$Connection,[string]$Query){Invoke-ExecutionAccessProbe (Join-Path $layout.postgres_bin 'psql.exe') @('-X','-w','-h',$Connection.host,'-p',[string]$Connection.port,'-U',$Connection.user,'-d',$Connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-') $Query $Connection}
function Invoke-RecoverySQL([string]$Bin,[hashtable]$Connection,[string]$Query){SQL $Connection $Query}
function Get-BytesHash([byte[]]$Bytes){[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($Bytes))}
function Free-Port{$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();try{return $l.LocalEndpoint.Port}finally{$l.Stop()}}
function Assert([bool]$OK,[string]$Message){if(-not $OK){throw $Message}}
function Deny([scriptblock]$Action,[string]$Pattern,[string]$Name){$denied=$false;try{& $Action|Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$denied=$true};Assert $denied ('Unexpected acceptance: '+$Name);$checks.Add($Name)}
function Request([string]$Method,[string]$Path,$Body=$null){
 $req=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$base+$Path)
 if($null -ne $Body){$req.Content=[Net.Http.StringContent]::new(($Body|ConvertTo-Json -Depth 10 -Compress),[Text.Encoding]::UTF8,'application/json')}
 try{$response=$http.SendAsync($req).GetAwaiter().GetResult();try{$bytes=$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();return @{status=[int]$response.StatusCode;bytes=$bytes}}finally{$response.Dispose()}}finally{$req.Dispose()}
}
function Import-Capture{
 $reply=Request POST '/v1/import-capture' @{knowledge=@{id='capture-release';revision=1};capture_id=('a'*32)}
 Assert ($reply.status -eq 200) ('Actual capture import failed: HTTP '+$reply.status)
 return [Text.Encoding]::UTF8.GetString($reply.bytes)|ConvertFrom-Json -AsHashtable -DateKind String
}
function Verify-Archive($Receipt){
 foreach($member in @('raw','text','manifest')){
  $reply=Request GET ('/v1/files/'+$Receipt.file.id+'/source-archives/'+$Receipt.source.manifest_sha256+'/'+$member)
  Assert ($reply.status -eq 200) ('Source member unavailable after release: '+$member)
  $expected=switch($member){raw {$Receipt.source.archive.stored_raw_sha256} text {$Receipt.source.archive.text_sha256} manifest {$Receipt.source.manifest_sha256}}
  Assert ((Get-BytesHash $reply.bytes) -ceq $expected) ('Source member hash differs: '+$member)
 }
 $report=Test-RecoveredKnowledgeArchives $layout.postgres_bin $database
 Assert ($report.manifests -eq 1 -and $report.minimum_reader -eq 2) 'Complete archive association/floor missing in actual database.'
 return $report
}
try{
 $admin=Get-ExecutionAccessConnection @{DATABASE_URL=$env:TEST_DATABASE_URL}
 Assert ($admin.port -eq 55591 -and $admin.database -ceq 'postgres' -and $admin.user -ceq 'p2_fixture') 'Explicit disposable PostgreSQL required.'
 $name='capture_release_'+[guid]::NewGuid().ToString('N');$app=$name+'_app';$idx=$name+'_idx'
 foreach($role in @($app,$idx)){SQL $admin ('CREATE ROLE '+$role+" LOGIN PASSWORD 'fixture-only'")|Out-Null;$roles.Add($role)}
 SQL $admin ('CREATE DATABASE '+$name+' TEMPLATE template0')|Out-Null;$created=$true
 $database=@{};foreach($key in $admin.Keys){$database[$key]=$admin[$key]};$database.database=$name
 $uri=[UriBuilder]::new($env:TEST_DATABASE_URL);$uri.Path='/'+$name
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Migrator;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $info.Environment.Clear();foreach($key in @('SystemRoot','WINDIR','TEMP','TMP')){if([Environment]::GetEnvironmentVariable($key)){$info.Environment[$key]=[Environment]::GetEnvironmentVariable($key)}}
 $info.Environment['MIGRATION_DATABASE_URL']=$uri.Uri.AbsoluteUri;foreach($arg in @('--role',$app,'--indexer-role',$idx)){$info.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info
 try{$null=$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();Assert ($p.WaitForExit(30000) -and $p.ExitCode -eq 0) 'Owner migration failed';$null=$out.GetAwaiter().GetResult();$null=$err.GetAwaiter().GetResult()}finally{if(-not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
 $uri.UserName=$app;$uri.Password='fixture-only';$uri.Query='sslmode=disable&search_path=knowledge'
 $peerPort=Free-Port;$port=Free-Port;$base='http://127.0.0.1:'+$port;$peerBase='http://127.0.0.1:'+$peerPort
 $knowledgeToken='fixture-knowledge-identity-0000000000000000';$controlToken='fixture-control-identity-000000000000000000';$peerToken='fixture-sources-identity-000000000000000000'
 $peers=@{control=(Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($controlToken)));knowledge=(Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($knowledgeToken)))}
 $config=@{LISTEN=('127.0.0.1:'+$port);DATABASE_URL=$uri.Uri.AbsoluteUri;SERVICE_TOKEN=$knowledgeToken;SERVICE_PEERS=($peers|ConvertTo-Json -Compress);SOURCES_URL=$peerBase;REGISTRY_URL=$peerBase;RUNTIME_URL=$peerBase;DB_MAX_CONNS='3'}
 Write-PlatformJson (Join-Path $layout.config_root 'services/knowledge.json') $config
 Write-PlatformJson (Join-Path $layout.config_root 'services/sources.json') @{LISTEN=('127.0.0.1:'+$peerPort);SERVICE_TOKEN=$peerToken;KNOWLEDGE_TOKEN=$knowledgeToken}
 Write-PlatformJson (Join-Path $layout.config_root 'dev.json') @{DATABASE_URL=$env:TEST_DATABASE_URL}
 $configHash=(Get-FileHash -LiteralPath (Join-Path $layout.config_root 'services/knowledge.json')).Hash.ToLowerInvariant()
 $provenance=@{kind='isolated-real-binary-fixture';dirty=$false}
 $contract=@{http='agentos-http-v0.6-notes-lifecycle';data='knowledge-v0.6';tools=@();engines=@()}
 $refs=@{}
 foreach($version in @('legacy','reader','writer')){
  $source=switch($version){legacy {$LegacyBinary} reader {$ReaderBinary} writer {$WriterBinary}}
  Copy-Item -LiteralPath $source -Destination (Join-Path $layout.release_root ($version+'.exe'))
  $c=@{};foreach($key in $contract.Keys){$c[$key]=$contract[$key]};$profile=$null
  if($version -ne 'legacy'){$profile=@{format=1;reader=2;writer=$(if($version -eq 'writer'){2}else{1})}}
  if($version -eq 'writer'){$c.data='knowledge-v0.7-source-archives'}
  $refs[$version]=New-ReleaseDescriptor $layout knowledge @{binary=($version+'.exe')} $c $provenance -KnowledgeArchives $profile
  $refs[$version].config_sha256=$configHash
 }
 Copy-Item -LiteralPath $PeerBinary -Destination (Join-Path $layout.release_root 'peer.exe')
 $peer=New-ReleaseDescriptor $layout sources @{binary='peer.exe'} @{http='fixture-v1';data='none';tools=@();engines=@()} $provenance
 $peer.config_sha256=(Get-FileHash -LiteralPath (Join-Path $layout.config_root 'services/sources.json')).Hash.ToLowerInvariant()
 $catalog=@{format=2;generation=1;services=@{knowledge=@{current=$refs.legacy;previous=$null;pending=$null};sources=@{current=$peer;previous=$null;pending=$null}}}
 $catalogPath=Join-Path $layout.release_root 'current.json';Write-PlatformJson $catalogPath $catalog
 $handler=[Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false;$http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[timespan]::FromSeconds(15);$http.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$controlToken)
 & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service sources,knowledge -MaintenanceLock $lock|Out-Null
 Wait-ReleaseReady $layout knowledge 1 $refs.legacy 10
 $null=Invoke-ReleaseChange $layout knowledge update $refs.reader $PSScriptRoot $lock 10
 $null=Invoke-ReleaseChange $layout knowledge rollback $null $PSScriptRoot $lock 10
 $null=Invoke-ReleaseChange $layout knowledge update $refs.reader $PSScriptRoot $lock 10
 $checks.Add('real_legacy_reader_upgrade_rollback_before_new_writes')
 $readerReply=Request POST '/v1/import-capture' @{knowledge=@{id='capture-release';revision=1};capture_id=('a'*32)}
 Assert ($readerReply.status -eq 503) 'Reader bridge unexpectedly writes format 2.'
 $receiptPath=Join-Path $proof 'committed-receipt.json'
 $checkpoint={param($point) if($point -eq 'started'){$receipt=Import-Capture;Write-PlatformJson $receiptPath $receipt;throw 'fixture release failure after durable capture commit'}}
 Deny {Invoke-ReleaseChange $layout knowledge update $refs.writer $PSScriptRoot $lock 10 $checkpoint} 'fixture release failure after durable capture commit' 'writer_commits_before_release_failure'
 $catalog=Read-ReleaseCatalog $layout
 Assert ($catalog.services.knowledge.current.id -ceq $refs.reader.id -and -not $catalog.services.knowledge.pending) 'Failed writer did not restore reader bridge.'
 Wait-ReleaseReady $layout knowledge 1 $refs.reader 10
 $receipt=Read-ReleaseJson $receiptPath
 $result.after_failed_writer=Verify-Archive $receipt
 $checks.Add('automatic_reader_recovery_preserves_complete_format2_archive')
 $snapshot=Get-ReleaseProcessSnapshot $layout;$before=(Get-FileHash -LiteralPath $catalogPath).Hash
 Deny {Invoke-ReleaseChange $layout knowledge rollback $null $PSScriptRoot $lock 10} 'require reader 2' 'second_rollback_to_legacy_refused_before_stop'
 Assert ((Get-FileHash -LiteralPath $catalogPath).Hash -ceq $before -and (Test-ReleaseSnapshotsEqual $snapshot (Get-ReleaseProcessSnapshot $layout))) 'Rejected rollback changed catalog or live process identities.'
 $null=Invoke-ReleaseChange $layout knowledge update $refs.writer $PSScriptRoot $lock 10
 $retry=Import-Capture
 Assert ($retry.file.id -ceq $receipt.file.id -and $retry.source.manifest_sha256 -ceq $receipt.source.manifest_sha256) 'Retry after recovery duplicated capture.'
 Assert ([int](SQL $database 'SELECT count(*) FROM knowledge.knowledge_files;').Trim() -eq 1) 'Unexpected duplicate files.'
 $checks.Add('actual_writer_retry_after_recovery_is_idempotent')
 $null=Invoke-ReleaseChange $layout knowledge rollback $null $PSScriptRoot $lock 10
 $result.after_explicit_rollback=Verify-Archive $receipt
 $checks.Add('writer_to_reader_rollback_keeps_archive_readable')
 # Pending recovery must retain its journal and current live process when an
 # operator attempts to restore a legacy binary after the new data committed.
 $catalog=Read-ReleaseCatalog $layout;$catalog.services.knowledge.pending=@{id=[guid]::NewGuid().ToString('N');phase='started';prior=$refs.legacy;target=$refs.reader;replicas=1;non_target=@()}
 Write-PlatformJson $catalogPath $catalog;$before=(Get-FileHash -LiteralPath $catalogPath).Hash;$pendingSnapshot=Get-ReleaseProcessSnapshot $layout
 Deny {Restore-PendingRelease $layout knowledge $PSScriptRoot $lock 10} 'require reader 2' 'incompatible_pending_recovery_retains_journal_and_process'
 Assert ((Get-FileHash -LiteralPath $catalogPath).Hash -ceq $before -and (Test-ReleaseSnapshotsEqual $pendingSnapshot (Get-ReleaseProcessSnapshot $layout))) 'Invalid recovery modified journal or live process identities.'
 $catalog.services.knowledge.pending=$null;Write-PlatformJson $catalogPath $catalog
 $result.checks_passed=$true
}finally{
 try{
  if($http){$http.Dispose()}
  & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $layout.layout_path -MaintenanceLock $lock|Out-Null
  if($created){SQL $admin ('DROP DATABASE '+$name+' WITH (FORCE)')|Out-Null}
  foreach($role in $roles){SQL $admin ('DROP ROLE '+$role)|Out-Null}
  $result.cleanup_passed=$true
 }finally{if($ownedLock){$ownedLock.Dispose()};$result.passed=$result.checks_passed -and $result.cleanup_passed;$result.checks=@($checks);Write-PlatformJson (Join-Path $proof 'result.json') $result}
}
$result|ConvertTo-Json -Depth 8
