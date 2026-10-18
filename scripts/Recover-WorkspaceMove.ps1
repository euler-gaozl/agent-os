param([Parameter(Mandatory)][string]$Journal,[IO.FileStream]$MaintenanceLock=$null)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
$base='D:\workspace\agent-platform';$oldRoot='D:\workspace\agent-os';$newRoot=Join-Path $base 'repos/agent-os'
$maintenance=Enter-PlatformMaintenance '' $MaintenanceLock
$heldLock=if($maintenance){$maintenance}else{$MaintenanceLock}
function Assert-RecoveryMovePath([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    if(-not(Test-PathWithin $current 'D:\workspace')){throw 'Recorded move escapes the managed workspace.'}
    while($current){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Recorded move traverses a junction, symbolic link or mount point.'}
        $parent=[IO.Path]::GetDirectoryName($current);if($parent -eq $current){break};$current=$parent
    }
}
try{
    $Journal=[IO.Path]::GetFullPath($Journal)
    if(-not(Test-PathWithin $Journal (Join-Path $base 'local/evidence'))){throw 'Recovery requires a retained local migration journal.'}
    $record=Read-RecoveryJson $Journal
    if($record.format -ne 1 -or $record.status -in @('passed','rolled_back')){throw 'Only an interrupted or failed migration may be rolled back.'}
    if($record.plan.Count -ne 4 -or $record.old_layout.project_root -ne $oldRoot){throw 'Unrecognized relocation plan.'}
    $expectedFrom=@((Join-Path $oldRoot '.state/postgres'),(Join-Path $oldRoot '.state'),(Join-Path $oldRoot 'bin'),$oldRoot)
    for($i=0;$i -lt 4;$i++){
        $move=$record.plan[$i]
        if([IO.Path]::GetFullPath($move.from) -ne $expectedFrom[$i]){throw 'Recorded source differs from the fixed migration.'}
        Assert-RecoveryMovePath $move.from;Assert-RecoveryMovePath $move.to
    }
    if($record.plan[0].to -ne (Join-Path $base 'local/data/postgres') -or
       (Split-Path -Parent $record.plan[1].to) -ne (Join-Path $base 'local/legacy-state') -or (Split-Path -Leaf $record.plan[1].to) -notmatch '^\d{8}-\d{6}$' -or
       (Split-Path -Parent $record.plan[2].to) -ne (Join-Path $base 'local/releases') -or (Split-Path -Leaf $record.plan[2].to) -notmatch '^legacy-\d{8}-\d{6}$' -or
       $record.plan[3].to -ne $newRoot){throw 'Recorded destination differs from the fixed migration.'}
    # A completed directory rename leaves exactly one side. The intent may be
    # newer than the completion record, so the latter is not treated as truth.
    $completed=0;$seenUnmoved=$false
    foreach($move in $record.plan){
        $from=Test-Path -LiteralPath $move.from -PathType Container;$to=Test-Path -LiteralPath $move.to -PathType Container
        if($from -eq $to){throw 'Move state is ambiguous (both directories exist or neither exists); automatic recovery refused.'}
        if($to){if($seenUnmoved){throw 'Directory states do not match the ordered migration.'};$completed++}else{$seenUnmoved=$true}
    }
    $old=$record.old_layout
    # Validate saved layout with the same path contract as ordinary maintenance.
    $currentRoot=if($completed -eq 4){$newRoot}else{$oldRoot}
    if([IO.Path]::GetFullPath((Get-Location).Path).StartsWith($currentRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or (Get-Location).Path -eq $currentRoot){throw 'Run recovery from D:\workspace, outside the directory being moved.'}
    $layout=$old.Clone();$null=$layout.Remove('layout_path');$layout.project_root=$currentRoot
    if($completed -ge 1){$layout.database_root=$record.plan[0].to}
    $recoveryPath=Join-Path $base ('ops/layout-recovery-'+[guid]::NewGuid().ToString('N')+'.json')
    Write-PlatformJson $recoveryPath $layout
    $layout=Get-PlatformLayout $currentRoot $recoveryPath
    $record.status='rolling_back';$record.recovered_move_count=$completed;Write-PlatformJson $Journal $record
    & (Join-Path $currentRoot 'scripts/Stop-Local.ps1') -LayoutPath $recoveryPath -MaintenanceLock $heldLock
    & (Join-Path $currentRoot 'scripts/Stop-Database.ps1') -LayoutPath $recoveryPath -MaintenanceLock $heldLock
    for($i=$completed-1;$i -ge 0;$i--){
        $move=$record.plan[$i]
        Assert-RecoveryMovePath $move.from;Assert-RecoveryMovePath $move.to
        if((Test-Path -LiteralPath $move.from) -or -not(Test-Path -LiteralPath $move.to -PathType Container)){throw 'Directory state changed during recovery.'}
        $record.recovery_intent=$move;Write-PlatformJson $Journal $record
        [IO.Directory]::Move($move.to,$move.from)
        $record.recovery_intent=$null;Write-PlatformJson $Journal $record
    }
    Write-PlatformText (Join-Path $oldRoot '.local/layout.path') $record.old_pointer
    Register-PlatformRoots @($old)
    & (Join-Path $oldRoot 'scripts/Start-Database.ps1') -LayoutPath $old.layout_path -MaintenanceLock $heldLock
    if(-not $record.ContainsKey('recovery_database_content_verified')){$record.recovery_database_content_verified=$false}
    $recoveryServicesMayHaveRun=$record.ContainsKey('recovery_services_start_attempted') -and $record.recovery_services_start_attempted
    if($record.ContainsKey('database_fingerprints') -and -not $record.services_start_attempted -and -not $recoveryServicesMayHaveRun){
        # No service was started after the frozen baseline; exact row and schema
        # checks are meaningful before restoring workers and their heartbeats.
        if(-not(Get-OwnedDatabase $old)){throw 'Cannot verify the recovered database owner.'}
        $admin=Read-RecoveryJson (Join-Path $old.config_root 'dev.json');$connection=Get-DatabaseConnection $admin.DATABASE_URL
        foreach($name in $record.database_fingerprints.Keys){
            $db=$connection.Clone();$db.database=$name
            $after=@{tables=(Get-DatabaseFingerprints $old.postgres_bin $db);metadata=(Get-DatabaseMetadata $old.postgres_bin $db);schema=(Get-DatabaseSchemaHash $old.postgres_bin $db)}
            foreach($field in @('tables','metadata','schema')){
                if(($record.database_fingerprints[$name][$field]|ConvertTo-Json -Depth 6 -Compress) -cne ($after[$field]|ConvertTo-Json -Depth 6 -Compress)){throw 'Recovered database content or permissions differ from the stopped baseline.'}
            }
        }
        $record.recovery_database_content_verified=$true;$record.recovery_database_checked_at=[datetime]::UtcNow.ToString('o');Write-PlatformJson $Journal $record
    }
    $record.recovery_services_start_attempted=$true;Write-PlatformJson $Journal $record
    & (Join-Path $oldRoot 'scripts/Start-Local.ps1') -LayoutPath $old.layout_path -Service $record.roles -Workers $record.workers -MaintenanceLock $heldLock
    $doctor=(& (Join-Path $oldRoot 'scripts/Doctor-Local.ps1') -LayoutPath $old.layout_path)|ConvertFrom-Json
    if(-not $doctor.core_probe_passed){throw 'Old deployment did not become ready after directory recovery.'}
    $record.status='rolled_back';$record.recovery='old source/data directories and services restored';$record.recovery_finished_at=[datetime]::UtcNow.ToString('o')
    Write-PlatformJson $Journal $record
    Write-Output 'Recorded relocation rolled back; the original deployment is ready.'
}finally{if($maintenance){$maintenance.Dispose()}}
