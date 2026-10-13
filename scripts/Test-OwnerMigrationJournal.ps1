param([string]$CrashLayout='',[string]$CrashPhase='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-processes','platform-releases','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
if($CrashLayout){
    if(-not(Test-PathWithin $CrashLayout 'D:\workspace\agent-platform\local\evidence')){throw 'Invalid test layout'}
    $layout=Get-PlatformLayout $repo $CrashLayout
    $lock=Enter-PlatformMaintenance $layout.state_root
    $journal=New-OwnerMigrationJournal $layout 'telemetry-inbox-v1' @{fixture='no database';catalog_sha256=(Get-FileHash (Join-Path $layout.release_root 'current.json')).Hash} $lock
    foreach($phase in @('prepared','mutation_requested','validating','validated')){
        if($phase -ne 'prepared'){$journal=Set-OwnerMigrationPhase $layout $journal.id $phase $lock}
        if($phase -ceq $CrashPhase){[Environment]::Exit(198)}
    }
    throw 'Fault point not reached'
}
$proof=Join-Path 'D:\workspace\agent-platform\local\evidence' ('owner-migration-journal-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $proof
$checks=[Collections.Generic.List[string]]::new();$lock=$null;$ownsJournal=$false
$result=@{passed=$false;checks=@();database_writes=0;provider_calls=0;github_actions_runs=0;scope='Actual coordinator process exit and locked lifecycle refusal; no SQL migration or machine power-loss simulation';source_hashes=@{}}
foreach($relative in @('lib/platform-migration-journal.ps1','lib/platform-releases.ps1','lib/platform-release-operations.ps1','lib/platform-engine-configuration.ps1','Start-Local.ps1','Build-Services.ps1','Backup-Platform.ps1','Platform.ps1','Initialize-Local.ps1','Register-ReleaseBaseline.ps1','Doctor-Local.ps1','Test-OwnerMigrationJournal.ps1')){$result.source_hashes[$relative]=(Get-FileHash (Join-Path $PSScriptRoot $relative)).Hash}
function Deny([scriptblock]$Action,[string]$Name,[string]$Pattern='owner database migration requires recovery'){
    $denied=$false;try{& $Action|Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$denied=$true}
    if(-not $denied){throw ('Unexpected acceptance: '+$Name)};$checks.Add($Name)
}
try{
    $initial=Get-PlatformLayout $repo
    $lock=Enter-PlatformMaintenance $initial.state_root
    Assert-NoPendingOwnerMigration $initial
    $lock.Dispose();$lock=$null
    foreach($phase in @('prepared','mutation_requested','validating','validated')){
        $root=Join-Path $proof $phase;$layout=Get-PlatformLayout $repo
        foreach($key in @('state_root','config_root','database_root','log_root','release_root','harness_root','console_web_root','futures_web_root')){$layout[$key]=Join-Path $root $key;$null=New-Item -ItemType Directory -Path $layout[$key] -Force}
        $layout.layout_path=Join-Path $root 'layout.json';Write-PlatformJson $layout.layout_path $layout
        $catalog=Join-Path $layout.release_root 'current.json';Write-PlatformJson $catalog @{format=2;generation=1;services=@{telemetry=@{current=@{fixture=$true};previous=$null;pending=$null}}}
        $before=(Get-FileHash $catalog).Hash
        & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -CrashLayout $layout.layout_path -CrashPhase $phase
        if($LASTEXITCODE -ne 198){throw 'Child failed to reach its explicit process-exit fault'}
        $lock=Enter-PlatformMaintenance $layout.state_root
        $journal=Read-OwnerMigrationJournal $layout
        $ownsJournal=$true
        if($journal.phase -cne $phase){throw 'Journal did not survive process exit'}
        $checks.Add($phase+'_journal_survives_process_exit_and_lock_releases')
        Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service telemetry -MaintenanceLock $lock} ($phase+'_start_refused_before_database_or_process')
        Deny {Invoke-ReleaseChange $layout telemetry update @{} $PSScriptRoot $lock} ($phase+'_update_refused_before_catalog')
        Deny {Invoke-ReleaseChange $layout telemetry rollback @{} $PSScriptRoot $lock} ($phase+'_rollback_refused_before_catalog')
        Deny {Restore-PendingRelease $layout telemetry $PSScriptRoot $lock} ($phase+'_release_recovery_refused')
        Deny {Set-DefaultEngine $layout source $PSScriptRoot $lock} ($phase+'_engine_change_refused')
        Deny {Restore-PendingEngineConfiguration $layout $PSScriptRoot $lock} ($phase+'_engine_recovery_refused')
        $alternate=$layout.Clone();$alternate.state_root=Join-Path $root 'alternate-run';$alternate.layout_path=Join-Path $root 'alternate-layout.json';Write-PlatformJson $alternate.layout_path $alternate
        Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $alternate.layout_path -Service telemetry -MaintenanceLock $lock} ($phase+'_same_database_alternate_state_root_cannot_bypass')
        Deny {& (Join-Path $PSScriptRoot 'Backup-Platform.ps1') -LayoutPath $layout.layout_path -StateRoot $alternate.state_root -Destination ('D:\workspace\agent-platform\local\backups\never-created-'+$journal.id) -MaintenanceLock $lock} ($phase+'_backup_state_root_override_cannot_bypass')
        Deny {Read-OwnerMigrationJournal $alternate} ($phase+'_alternate_layout_cannot_recover_wrong_baseline') 'different layout'
        Deny {Complete-OwnerMigrationJournal $layout ('0'*32) $lock} ($phase+'_wrong_identity_cannot_clear_gate') 'Only the validated'
        if($phase -ne 'validated'){Deny {Complete-OwnerMigrationJournal $layout $journal.id $lock} ($phase+'_unvalidated_cannot_clear_gate') 'Only the validated'}
        Deny {New-OwnerMigrationJournal $layout 'runtime-access-v1' @{} $lock} ($phase+'_second_migration_refused')
        if((Get-FileHash $catalog).Hash -cne $before -or (Test-Path (Join-Path $layout.state_root 'processes.json'))){throw 'Refused maintenance changed catalog or process manifest'}
        $checks.Add($phase+'_refused_calls_preserve_catalog_and_process_manifest')
        if($phase -eq 'prepared'){$journal=Set-OwnerMigrationPhase $layout $journal.id mutation_requested $lock}
        if($journal.phase -in @('mutation_requested','validated')){$journal=Set-OwnerMigrationPhase $layout $journal.id validating $lock}
        $journal=Set-OwnerMigrationPhase $layout $journal.id validated $lock
        $archive=Complete-OwnerMigrationJournal $layout $journal.id $lock
        $ownsJournal=$false
        Assert-NoPendingOwnerMigration $layout
        if(-not(Test-Path $archive)){throw 'Completion evidence was lost'};$checks.Add($phase+'_explicit_validated_recovery_archives_journal')
        $lock.Dispose();$lock=$null
    }
    Deny {& (Join-Path $PSScriptRoot 'Build-Services.ps1') -LayoutPath $layout.layout_path -Service migrate-services} 'shared_migrator_build_refused' 'Unknown service'
    Write-PlatformJson (Join-Path $layout.release_root 'current.json') @{telemetry='inert legacy catalog'}
    Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service telemetry -Migrate} 'explicit_shared_migration_refused_before_config' 'retired shared migrator'
    Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service telemetry} 'missing_legacy_configuration_does_not_invoke_shared_migrator' 'Missing registered service configuration'
    $lock=Enter-PlatformMaintenance $layout.state_root
    $journal=New-OwnerMigrationJournal $layout 'telemetry-inbox-v1' @{fixture='integrity'} $lock
    $ownsJournal=$true
    Deny {Set-OwnerMigrationPhase $layout $journal.id validated $lock} 'prepared_cannot_skip_mutation_or_validation' 'Invalid owner migration phase transition'
    $savedJournal=Get-Content -LiteralPath (Get-OwnerMigrationJournalPath $layout) -Raw
    foreach($invalid in @(('['+$savedJournal+']'),($savedJournal.Replace('"format": 1','"format": true')),($savedJournal.Replace('"phase": "prepared"','"phase": ["prepared"]')))){
        Set-Content -LiteralPath (Get-OwnerMigrationJournalPath $layout) -Value $invalid
        Deny {Read-OwnerMigrationJournal $layout} 'typed_journal_metadata_refused' 'Invalid owner migration journal'
    }
    Set-Content -LiteralPath (Get-OwnerMigrationJournalPath $layout) -Value $savedJournal
    $baseline=Join-Path $layout.state_root ('migrations/'+$journal.id+'/baseline.json')
    Add-Content -LiteralPath $baseline -Value 'corruption'
    Deny {Read-OwnerMigrationJournal $layout} 'baseline_corruption_blocks_recovery' 'integrity failed'
    Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service telemetry -MaintenanceLock $lock} 'corrupt_baseline_still_blocks_writers'
    Set-Content -LiteralPath (Get-OwnerMigrationJournalPath $layout) -Value 'invalid JSON'
    Deny {Read-OwnerMigrationJournal $layout} 'corrupt_journal_blocks_recovery' 'Invalid owner migration journal'
    Deny {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $layout.layout_path -Service telemetry -MaintenanceLock $lock} 'corrupt_journal_still_blocks_writers'
    $lock.Dispose();$lock=$null
    Deny {& (Join-Path $PSScriptRoot 'Build-Services.ps1') -LayoutPath $layout.layout_path -Service telemetry} 'build_refused_before_compilation'
    Deny {& (Join-Path $PSScriptRoot 'Platform.ps1') backup -LayoutPath $layout.layout_path} 'backup_wrapper_refused_before_stopping_services'
    Deny {& (Join-Path $PSScriptRoot 'Initialize-Local.ps1') -LayoutPath $layout.layout_path} 'initialize_refused_before_config_or_database'
    $result.passed=$true
}catch{$result.failure=$_.Exception.Message;throw}
finally{
    # Only this test's synthetic corruption is relocated. Never clear a journal
    # that predated the test or belongs to a real operation.
    if($ownsJournal){
        if(-not $lock){$lock=Enter-PlatformMaintenance $layout.state_root}
        $pending=Get-OwnerMigrationJournalPath $layout
        if(Test-Path -LiteralPath $pending){
            if(-not(Test-PathWithin $layout.state_root $proof)){throw 'Refuse cleanup outside this fixture'}
            $retained=Join-Path $proof 'retained-corrupt-journal.json'
            Assert-ReleasePhysicalPath $proof $retained
            Move-Item -LiteralPath $pending -Destination $retained
        }
    }
    if($lock){$lock.Dispose()};$result.checks=@($checks);Write-PlatformJson (Join-Path $proof 'result.json') $result;Write-Output ('Migration journal evidence: '+$proof)
}
exit 0
