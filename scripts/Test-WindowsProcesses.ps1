param([string]$ChildRoot='',[string]$NodeBinary='',[string]$GoBinary='')
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-processes.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
if($ChildRoot){
    if(-not(Test-PathWithin $ChildRoot 'D:\workspace\agent-platform\local\evidence')){throw 'Invalid fixture root.'}
    $layout=Get-Content -LiteralPath (Join-Path $ChildRoot 'layout.json') -Raw|ConvertFrom-Json -AsHashtable
    $entry=Get-Content -LiteralPath (Join-Path $ChildRoot 'crash-entry.json') -Raw|ConvertFrom-Json -AsHashtable
    $helper=Join-Path $PSScriptRoot 'lib/platform-processes.ps1'
    $line=(Select-String -LiteralPath $helper -SimpleMatch '$p=Get-Process -Id $processId').LineNumber
    Assert ($line -gt 0) 'Crash seam absent.'
    $null=Set-PSBreakpoint -Script $helper -Line $line -Action {[Environment]::Exit(196)}
    Start-PlatformInstance $entry $layout {Write-PlatformJson (Join-Path $ChildRoot 'crash-entry.json') $entry}
    throw 'Injected crash was not reached.'
}
$root='D:\workspace\agent-platform\local\evidence\windows-processes-'+[guid]::NewGuid().ToString('N')
New-ProtectedDirectory $root
if(-not $NodeBinary){$NodeBinary=if(Test-Path -LiteralPath 'D:\workspace\agent-platform\local\releases\node\baseline\node.exe'){'D:\workspace\agent-platform\local\releases\node\baseline\node.exe'}else{(Get-Command node -ErrorAction Stop).Source}}
$layout=@{project_root=$repo;state_root=$root;release_root=(Join-Path $root 'releases');config_root=(Join-Path $root 'config');log_root=(Join-Path $root 'logs');harness_root=(Join-Path $root 'harness');node_binary=$NodeBinary}
foreach($path in @($layout.release_root,(Join-Path $layout.config_root 'launches'),$layout.log_root,$layout.harness_root)){$null=New-Item -ItemType Directory -Path $path -Force}
Write-PlatformJson (Join-Path $root 'layout.json') $layout
$binary=Join-Path $layout.release_root 'worker.exe'
if(-not $GoBinary){$GoBinary=if(Test-Path -LiteralPath 'D:\workspace\.tools\go\bin\go.exe'){'D:\workspace\.tools\go\bin\go.exe'}else{(Get-Command go -ErrorAction Stop).Source}}
$originalGoCache=$env:GOCACHE;$originalGoPath=$env:GOPATH
try{$env:GOCACHE='D:\workspace\.tools\gocache';$env:GOPATH='D:\workspace\.tools\gopath';& $GoBinary build -o $binary (Join-Path $PSScriptRoot 'fixtures/windows-instance/main.go');if($LASTEXITCODE){throw 'Fixture build failed.'}}finally{$env:GOCACHE=$originalGoCache;$env:GOPATH=$originalGoPath}
$runner=Join-Path $layout.harness_root 'runner.mjs'
Write-PlatformText $runner 'while (true) {} // intentionally cannot process stdin close'
$entries=[Collections.Generic.List[hashtable]]::new();$checks=[Collections.Generic.List[string]]::new()
function New-Fixture([bool]$Child=$true){
    $id='worker-'+[guid]::NewGuid().ToString('N');$config=Join-Path $layout.config_root ('launches/'+$id+'.json')
    $report=Join-Path $root ($id+'.json')
    Write-PlatformJson $config @{report=$report;node=$(if($Child){$layout.node_binary}else{''});runner=$runner}
    $entry=@{pid=0;started_at=$null;id=$id;role='worker';binary=$binary;job_name=('Global\AgentOS-'+[guid]::NewGuid().ToString('N'));intent_at=[datetime]::UtcNow.ToString('o');status='launching';launch_config=$config;launch_config_sha256=(Get-FileHash -LiteralPath $config).Hash.ToLower();fixture_report=$report}
    $entries.Add($entry);Write-PlatformJson (Join-Path $root 'processes.json') @($entries.ToArray())
    return $entry
}
function Persist {Write-PlatformJson (Join-Path $root 'processes.json') @($entries.ToArray())}
function Fixture-Report([hashtable]$Entry){
    for($i=0;$i -lt 100;$i++){
        if(Test-Path -LiteralPath $Entry.fixture_report){try{return Get-Content -LiteralPath $Entry.fixture_report -Raw|ConvertFrom-Json -AsHashtable}catch{}}
        Start-Sleep -Milliseconds 50
    }
    throw 'Fixture report was not written.'
}
$result=@{started_at=[datetime]::UtcNow.ToString('o');provider_calls=0;database_connections=0;scope='real Windows synthetic processes, not an Agent task';checks=@();status='incomplete'}
try{
    $one=New-Fixture;$two=New-Fixture $false
    $old=@{};foreach($key in @('DATABASE_URL','NODE_OPTIONS','SERVICE_TOKEN','AGENTOS_TEST_POISON')){$old[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,'synthetic-unwanted-parent-value')}
    $lockPath=Join-Path $root 'non-inherited-maintenance.lock'
    $lock=[IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{Start-PlatformInstance $one $layout ${function:Persist};Start-PlatformInstance $two $layout ${function:Persist}}finally{$lock.Dispose();foreach($key in $old.Keys){[Environment]::SetEnvironmentVariable($key,$old[$key])}}
    $lock=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$lock.Dispose()
    $checks.Add('maintenance_lock_not_inherited_by_running_instances')
    Persist
    $report=Fixture-Report $one
    Assert ($report.forbidden_environment_absent -and $report.system_environment_present) 'Environment isolation failed.'
    Assert ($report.path -eq ((Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)) 'Unexpected executable search path.'
    $members=@([AgentOS.Maintenance.WindowsJob]::Members($one.job_name))
    Write-PlatformJson (Join-Path $root 'first-members.json') @{members=$members;root=$one.pid;child=$report.child_pid;live=@($members|ForEach-Object{Get-Process -Id $_ -ErrorAction SilentlyContinue}|Select-Object Id,ProcessName)}
    Assert ($one.pid -in $members -and $report.child_pid -in $members) 'Root or busy Node was not inside the Job.'
    $checks.Add('atomic_root_and_child_membership_and_clean_environment')
    $collision=New-Fixture $false;$collision.job_name=$one.job_name;$failed=$false
    try{Start-PlatformInstance $collision $layout ${function:Persist}}catch{$failed=$true}
    Assert $failed 'Duplicate job name was accepted.'
    Stop-PlatformInstance $collision $layout ${function:Persist}
    $members=@([AgentOS.Maintenance.WindowsJob]::Members($one.job_name))
    Assert ($one.pid -in $members -and $report.child_pid -in $members) 'Collision cleanup harmed the original job.'
    $checks.Add('duplicate_job_refused_without_terminating_owner')
    Stop-Process -Id $one.pid
    Wait-Process -Id $one.pid -Timeout 5 -ErrorAction SilentlyContinue
    for($i=0;$i -lt 100 -and (Get-Process -Id $report.child_pid -ErrorAction SilentlyContinue);$i++){Start-Sleep -Milliseconds 50}
    Assert (-not(Get-Process -Id $report.child_pid -ErrorAction SilentlyContinue)) 'Root exit did not automatically terminate the busy fixture child.'
    Stop-PlatformInstance $one $layout ${function:Persist}
    Assert (-not(Get-Process -Id $report.child_pid -ErrorAction SilentlyContinue)) 'Parent-dead orphan was not terminated.'
    Assert ([bool](Get-PlatformProcess $two)) 'Non-target instance was changed.'
    $checks.Add('parent_exit_automatically_terminates_busy_child_and_non_target_unchanged')
    $crash=New-Fixture
    Write-PlatformJson (Join-Path $root 'crash-entry.json') $crash
    $child=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-ChildRoot',('"'+$root+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'crash.stdout.log') -RedirectStandardError (Join-Path $root 'crash.stderr.log')
    Assert ($child.WaitForExit(30000)) 'Crash process did not finish.'
    Assert ($child.ExitCode -eq 196) 'Crash seam did not exit at the expected point.'
    $crash=Get-Content -LiteralPath (Join-Path $root 'crash-entry.json') -Raw|ConvertFrom-Json -AsHashtable
    $entries.Add($crash)
    Assert ($crash.pid -eq 0 -and $crash.job_created) 'Crash did not preserve launch intent without PID.'
    $state=Get-PlatformInstanceState $crash $layout
    Assert ($state.recovered -and [bool]$state.process) 'Independent process could not recover launch identity.'
    $crashReport=Fixture-Report $crash
    Stop-PlatformInstance $crash $layout ${function:Persist}
    Assert (-not(Get-Process -Id $crashReport.child_pid -ErrorAction SilentlyContinue)) 'Crash-recovered child was not stopped.'
    $checks.Add('launcher_exit_after_create_before_pid_save_recovered_in_other_process')
    $legacy=New-Fixture
    $legacy.Remove('job_name');$legacy.Remove('launch_config_sha256')
    $p=Start-Process -FilePath $binary -ArgumentList @('--config',('"'+$legacy.launch_config+'"')) -WindowStyle Hidden -PassThru
    $legacy.pid=$p.Id;$legacy.started_at=$p.StartTime.ToUniversalTime().ToString('o');$legacy.Remove('launch_config')
    Persist
    $legacyReport=Fixture-Report $legacy
    $legacy.legacy_stop_intent=$true
    $state=Get-PlatformInstanceState $legacy $layout
    Assert $state.requires_stop 'Incomplete legacy stop could be discarded by start.'
    Stop-PlatformInstance $legacy $layout ${function:Persist}
    Assert (-not(Get-Process -Id $legacyReport.child_pid -ErrorAction SilentlyContinue)) 'Legacy child adoption failed.'
    $checks.Add('legacy_root_and_busy_child_verified_before_and_after_root_stop')
    $unknown=New-Fixture
    $unknown.Remove('job_name');$unknown.Remove('launch_config_sha256')
    $unknownProcess=Start-Process -FilePath $binary -ArgumentList @('--config',('"'+$unknown.launch_config+'"')) -WindowStyle Hidden -PassThru
    $unknown.pid=$unknownProcess.Id;$unknown.started_at=$unknownProcess.StartTime.ToUniversalTime().ToString('o');$unknown.Remove('launch_config');Persist
    $unknownReport=Fixture-Report $unknown
    $unknownProcess.Kill();$null=$unknownProcess.WaitForExit(10000)
    $unknownState=Get-PlatformInstanceState $unknown $layout
    Assert $unknownState.requires_stop 'Unknown legacy root exit allowed replacement.'
    $refused=$false;try{Stop-PlatformInstance $unknown $layout ${function:Persist}}catch{$refused=$true}
    Assert $refused 'Unknown legacy exit boundary was accepted.'
    $knownFixtureChild=Get-Process -Id $unknownReport.child_pid -ErrorAction SilentlyContinue
    Assert ([bool]$knownFixtureChild -and -not $knownFixtureChild.HasExited) 'Unknown descendant was killed instead of refusing discovery.'
    # This fixture itself created and observed the child; retain the refused
    # record, then clean up that exact observed child without claiming recovery.
    Write-PlatformJson (Join-Path $root 'legacy-unknown-exit-refused.json') $unknown
    Assert ($knownFixtureChild.Path -eq $layout.node_binary -and $knownFixtureChild.StartTime.ToUniversalTime() -ge ([datetime]$unknown.started_at).ToUniversalTime()) 'Fixture cleanup identity mismatch.'
    $knownFixtureChild.Kill();$null=$knownFixtureChild.WaitForExit(10000)
    $unknownProcess.Dispose();$null=$entries.Remove($unknown);Persist
    $checks.Add('unknown_legacy_exit_refuses_discovery_and_replacement_without_killing_child')
    $failedPersist=New-Fixture $false;$failure=$false
    try{Start-PlatformInstance $failedPersist $layout {throw 'Synthetic journal failure'}}catch{$failure=$true}
    Assert $failure 'Journal failure was ignored.'
    Assert (-not(Test-Path -LiteralPath $failedPersist.fixture_report)) 'Process started before creation marker persisted.'
    Assert (@([AgentOS.Maintenance.WindowsJob]::Members($failedPersist.job_name)).Count -eq 0) 'Failed journal left a job member.'
    $checks.Add('job_creation_journal_failure_prevents_process_start')
    $result.status='passed'
}finally{
    $cleanup=@()
    foreach($entry in $entries){try{Stop-PlatformInstance $entry $layout ${function:Persist}}catch{$cleanup+=@(@{id=$entry.id;error=$_.Exception.Message})}}
    if($cleanup.Count){$result.status='cleanup_failed';$result.cleanup_failed=$cleanup}
    $result.checks=@($checks.ToArray());$result.completed_at=[datetime]::UtcNow.ToString('o')
    Write-PlatformJson (Join-Path $root 'result.json') $result
    Write-Output ('Windows process evidence: '+(Join-Path $root 'result.json'))
}
if($result.status -ne 'passed'){throw 'Windows process verification did not pass.'}
