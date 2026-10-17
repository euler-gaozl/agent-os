param([string]$EvidenceRoot='D:\workspace\agent-platform\local\evidence')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
foreach($file in @('platform-paths','platform-releases','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$file+'.ps1'))}
$proof=Join-Path $EvidenceRoot ('continuation-release-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $proof,(Join-Path $proof 'releases/descriptors'),(Join-Path $proof 'releases/web'),(Join-Path $proof 'releases/harness'),(Join-Path $proof 'state')|Out-Null
$layout=@{release_root=(Join-Path $proof 'releases');state_root=(Join-Path $proof 'state')}
$checks=[Collections.Generic.List[string]]::new()
function Accept([string]$Name,[scriptblock]$Action){& $Action|Out-Null;$checks.Add($Name)}
function Deny([string]$Name,[string]$Message,[scriptblock]$Action){$denied=$false;try{& $Action|Out-Null}catch{if($_.Exception.Message -notmatch $Message){throw};$denied=$true};if(-not $denied){throw ('Unexpected acceptance: '+$Name)};$checks.Add($Name)}
$contract=@{http='fixture-v1';data='fixture-v1';tools=@();engines=@()}
$provenance=@{kind='fixture';dirty=$false}
$old=@{};$new=@{};$refsOld=@{};$refsNew=@{}
$capabilities=@{runtime=@{format=1;provides='failed-run-continuation-v1';requires='native-model-revision-guard-v1'};worker=@{format=1;provides='native-model-revision-guard-v1'};control=@{format=1;requires='failed-run-continuation-v1'}}
foreach($file in @('runtime.exe','worker.exe','control.exe','node.exe','web/index.html','harness/runner.mjs')){Set-Content -LiteralPath (Join-Path $layout.release_root $file) -Value 'inert fixture asset'}
foreach($role in @('runtime','worker','control')){
    $assets=@{binary=($role+'.exe')}
    if($role -eq 'control'){$assets.web='web'}
    if($role -eq 'worker'){$assets.node='node.exe';$assets.harness='harness'}
    $refsOld[$role]=New-ReleaseDescriptor $layout $role $assets $contract $provenance
    $refsNew[$role]=New-ReleaseDescriptor $layout $role $assets $contract $provenance -ContinuationManagement $capabilities[$role]
    $old[$role]=Read-ReleaseDescriptor $layout $refsOld[$role] -Verify
    $new[$role]=Read-ReleaseDescriptor $layout $refsNew[$role] -Verify
}
$ready=@{schema_ready=$true;has_receipts=$false}
$missing=@{schema_ready=$false;has_receipts=$false}
$retained=@{schema_ready=$true;has_receipts=$true}
Accept 'legacy combination needs no migration' {Assert-ContinuationPolicy $old.runtime $old.worker $old.control $missing}
Accept 'Worker may upgrade before migration' {Assert-ContinuationPolicy $old.runtime $new.worker $old.control $missing}
Accept 'Runtime may upgrade after Worker and migration' {Assert-ContinuationPolicy $new.runtime $new.worker $old.control $ready}
Accept 'complete new combination' {Assert-ContinuationPolicy $new.runtime $new.worker $new.control $retained}
Deny 'old Worker cannot claim after action activation' 'revision-aware' {Assert-ContinuationPolicy $new.runtime $old.worker $old.control $ready}
Deny 'Console cannot precede Runtime' 'Console requires' {Assert-ContinuationPolicy $old.runtime $new.worker $new.control $ready}
Deny 'migration required' 'Owner receipt migration' {Assert-ContinuationPolicy $new.runtime $new.worker $old.control $missing}
Deny 'retained receipt survives Console rollback' 'Retained continuation' {Assert-ContinuationPolicy $old.runtime $new.worker $old.control $retained}
Accept 'Runtime rollback before any receipt with old Console' {Assert-ContinuationPolicy $old.runtime $new.worker $old.control $ready}
foreach($value in @($null,@{},@{format='1';provides='native-model-revision-guard-v1'},@{format=1;provides=@('native-model-revision-guard-v1')},@{format=1;provides='unknown'},@{format=1;provides='native-model-revision-guard-v1';extra='unrecognized'})){
    Deny ('malformed capability '+$checks.Count) 'Invalid' {Assert-ContinuationDescriptor @{role='worker';continuation_management=$value}}
}
Deny 'wrong Owner cannot claim guard' 'belongs only' {Assert-ContinuationDescriptor @{role='sources';continuation_management=$capabilities.worker}}
Deny 'missing database facts rejected' 'Missing continuation' {Assert-ContinuationPolicy $new.runtime $new.worker $new.control @{}}
$catalog=@{format=2;generation=1;services=@{}}
foreach($role in @('runtime','worker','control')){$catalog.services[$role]=@{current=$refsOld[$role];previous=$null;pending=$null}}
Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog
# These tests exercise real descriptor/catalog and operation preflight. Only the
# database observations, process state and bound endpoint readers are controlled fixtures.
$script:fixtureFacts=$ready.Clone();$script:fixtureFacts.other_runtime_clients=0
$script:factReads=0
function Get-ContinuationFacts([hashtable]$Layout){$script:factReads++;return $script:fixtureFacts.Clone()}
function Get-BoundRuntimeConfiguration {return @{LISTEN='127.0.0.1:8094';DATABASE_URL='postgres://runtime:fixture@127.0.0.1:55598/continuation?sslmode=disable&search_path=public'}}
function Get-BoundReceiptControlConfiguration {return @{RUNTIME_URL='http://127.0.0.1:8094'}}
function Get-BoundExecutionConsumerConfiguration {return @{DATABASE_URL='postgres://worker:fixture@127.0.0.1:55598/continuation?sslmode=disable&search_path=public'}}
$script:workerEntries=@()
function Read-PlatformProcesses {return ,$script:workerEntries}
function Get-PlatformInstanceState($entry){return $entry.fixture_state}
Accept 'legacy catalog has no new dependency' {Assert-ContinuationDeployment $layout}
if($script:factReads -ne 0){throw 'Legacy catalog unexpectedly read continuation database'}
Deny 'new Runtime candidate rejected before stop' 'revision-aware' {Assert-ContinuationDeployment $layout @{runtime=$new.runtime}}
$catalog.services.worker.current=$refsNew.worker
Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog
Accept 'Runtime candidate after Worker' {Assert-ContinuationDeployment $layout @{runtime=$new.runtime}}
$script:workerEntries=@(@{role='worker';release_reference=$refsNew.worker;fixture_state=@{process=$true;requires_stop=$false;members=@()}},@{role='worker';release_reference=$refsOld.worker;fixture_state=@{process=$true;requires_stop=$false;members=@()}})
Deny 'second live Worker with old binary blocks Runtime' 'live Worker lacks' {Assert-ContinuationDeployment $layout @{runtime=$new.runtime}}
$script:workerEntries[1].release_reference=$refsNew.worker
Accept 'both live Workers provide revision guard' {Assert-ContinuationDeployment $layout @{runtime=$new.runtime}}
$script:workerEntries[1].fixture_state=@{process=$null;requires_stop=$false;members=@(123)}
Deny 'orphaned Worker descendants block Runtime' 'ownership is unresolved' {Assert-ContinuationDeployment $layout @{runtime=$new.runtime}}
$script:workerEntries[1].fixture_state=@{process=$null;requires_stop=$true;members=@()}
Deny 'unfinished Worker stop blocks Runtime' 'ownership is unresolved' {Assert-ContinuationDeployment $layout @{runtime=$new.runtime}}
$script:workerEntries=@()
$catalog.services.runtime.current=$refsNew.runtime
Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog
Deny 'managed Worker rollback preflight rejects old pin' 'revision-aware' {Invoke-ReleaseChange $layout worker update $refsOld.worker $PSScriptRoot $null}
$catalog.services.runtime.pending=@{id='fixture-pending';prior=$refsOld.runtime;target=$refsNew.runtime;action='update'}
Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog
$script:fixtureFacts.has_receipts=$true
# Recovery must fail before process inspection/stopping when its prior cannot read
# permanent decisions. The remaining guards are deliberately not stubbed.
Deny 'pending recovery cannot hide committed decisions' 'Retained continuation' {Restore-PendingRelease $layout runtime $PSScriptRoot $null}
$script:fixtureFacts.has_receipts=$false;$script:fixtureFacts.other_runtime_clients=1
Deny 'post-stop in-flight database backend blocks downgrade' 'clients remain' {Assert-ContinuationDeployment $layout @{runtime=$old.runtime} -RuntimeStopped}
$script:fixtureFacts.other_runtime_clients=0
Accept 'post-stop clean empty receipt state permits rollback' {Assert-ContinuationDeployment $layout @{runtime=$old.runtime} -RuntimeStopped}
$result=@{passed=$true;checks=$checks.ToArray();scope='Real descriptors/catalog and operation preflight; controlled database and process observations, no process activation';provider_calls=0;ci_runs=0}
$result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $proof 'result.json')
[pscustomobject]@{passed=$true;checks=$checks.Count;evidence=$proof}|ConvertTo-Json
