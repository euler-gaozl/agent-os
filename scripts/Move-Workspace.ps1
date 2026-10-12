param([Parameter(Mandatory)][string]$VerifiedBackup)
$ErrorActionPreference='Stop'
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
$base='D:\workspace\agent-platform'
$targetRoot=Join-Path $base 'repos/agent-os'
$targetData=Join-Path $base 'local/data/postgres'
$archiveRoot=Join-Path $base ('local/legacy-state/'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
if($sourceRoot -ne 'D:\workspace\agent-os'){throw 'This migration only relocates the original D:\workspace\agent-os checkout.'}
if([IO.Path]::GetFullPath((Get-Location).Path).StartsWith($sourceRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Run this migration from D:\workspace, outside the directory being moved.'}
$maintenance=Enter-PlatformMaintenance ''
$journalPath=Join-Path $base ('local/evidence/workspace-move-'+[guid]::NewGuid().ToString('N')+'.json')
$journal=@{format=1;started_at=[datetime]::UtcNow.ToString('o');status='preflight';moves=@();database_reinitialized=$false;services_start_attempted=$false}
$moves=[Collections.Generic.List[object]]::new();$stopAttempted=$false
function Save-MoveJournal {Write-PlatformJson $journalPath $journal}
function Assert-MoveAncestors([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    if([IO.Path]::GetPathRoot($current) -ne 'D:\'){throw 'Relocation must use the same D: volume.'}
    while($current){
        if(Test-Path -LiteralPath $current){
            if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Relocation path traverses a junction, symbolic link or mount point.'}
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if($parent -eq $current){break};$current=$parent
    }
}
function Move-CheckedDirectory([string]$From,[string]$To){
    $fromPath=[IO.Path]::GetFullPath($From);$toPath=[IO.Path]::GetFullPath($To)
    if(-not(Test-PathWithin $fromPath 'D:\workspace') -or -not(Test-PathWithin $toPath $base)){throw 'Move path escapes the explicitly named workspace.'}
    Assert-MoveAncestors $fromPath;Assert-MoveAncestors $toPath
    if(-not(Test-Path -LiteralPath $fromPath -PathType Container) -or (Test-Path -LiteralPath $toPath)){throw 'Move source is missing or its exact destination already exists.'}
    if((Get-Item -LiteralPath $fromPath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing to move a reparse-point root.'}
    $journal.intent=@{from=$fromPath;to=$toPath};Save-MoveJournal
    # Directory.Move is one same-volume rename. PowerShell Move-Item may walk
    # children and partially move a tree containing pnpm junctions.
    [IO.Directory]::Move($fromPath,$toPath)
    $moves.Add(@{from=$fromPath;to=$toPath});$journal.moves=@($moves.ToArray());$journal.intent=$null;Save-MoveJournal
}
function Get-TreeHashes([string]$Directory){
    $files=@(Get-ChildItem -LiteralPath $Directory -Recurse -Force)
    if(@($files|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'External PostgreSQL tablespaces require a separate relocation plan.'}
    return ,@($files|Where-Object{-not $_.PSIsContainer}|Sort-Object FullName|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath($Directory,$_.FullName);bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()}})
}
function Protect-MovingTree([string]$Directory){
    if(-not(Test-PathWithin $Directory $sourceRoot)){throw 'Only the original private state tree may have permissions reset.'}
    $items=@(Get-Item -LiteralPath $Directory)+@(Get-ChildItem -LiteralPath $Directory -Recurse -Force)
    if(@($items|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Private state contains a reparse point; refusing to follow or change it.'}
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $allowed=@($owner.Value,'S-1-5-18','S-1-5-32-544')
    foreach($item in $items){
        $existing=(Get-Acl -LiteralPath $item.FullName).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
        $broad=@($existing|Where-Object{$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed})
        $ownerAccess=@($existing|Where-Object{$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -eq $owner.Value -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl})
        if(-not $broad.Count -and $ownerAccess.Count){continue}
        $acl=if($item.PSIsContainer){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
        $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
        foreach($sid in $allowed){
            $identity=[Security.Principal.SecurityIdentifier]::new($sid)
            $rule=if($item.PSIsContainer){[Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')}else{[Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','Allow')}
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
        $actual=(Get-Acl -LiteralPath $item.FullName).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
        if(@($actual|Where-Object{$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed}).Count){throw 'Private state permission verification failed.'}
    }
}
try{
    $old=Get-PlatformLayout $sourceRoot
    if($old.database_root -ne (Join-Path $sourceRoot '.state/postgres')){throw 'Database is not in the expected original location.'}
    if($old.state_root -ne (Join-Path $base 'local/run') -or $old.config_root -ne (Join-Path $base 'local/config')){throw 'Activate separated runtime paths before moving source and data.'}
    $legacyBin=Join-Path $old.release_root ('legacy-'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    foreach($movePath in @($sourceRoot,$old.database_root,(Join-Path $sourceRoot '.state'),(Join-Path $sourceRoot 'bin'),$targetRoot,$targetData,$archiveRoot,$legacyBin)){Assert-MoveAncestors $movePath}
    foreach($destination in @($targetRoot,$targetData,$archiveRoot,$legacyBin)){if(Test-Path -LiteralPath $destination){throw 'A relocation destination already exists; inspect previous migration evidence.'}}
    $VerifiedBackup=[IO.Path]::GetFullPath($VerifiedBackup)
    $backupPath=Join-Path $VerifiedBackup 'manifest.json'
    $backupHash=(Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLower()
    $authenticated=[Text.Encoding]::UTF8.GetString((Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $VerifiedBackup 'manifest-digest.dpapi')))))
    if($backupHash -ne $authenticated){throw 'Backup authentication failed.'}
    $reports=@(Get-ChildItem -LiteralPath (Join-Path $base 'local/restore-checks') -File -Filter result.json -Recurse|ForEach-Object{Read-RecoveryJson $_.FullName})
    if(-not @($reports|Where-Object{$_.backup_manifest_sha256 -eq $backupHash -and $_.status -eq 'passed' -and $_.isolated_cluster_stopped}).Count){throw 'The selected backup has not passed isolated restoration.'}
    $backupManifest=Read-RecoveryJson $backupPath
    foreach($file in $backupManifest.files){$path=[IO.Path]::GetFullPath((Join-Path $VerifiedBackup $file.path));if(-not(Test-PathWithin $path $VerifiedBackup) -or (Get-FileHash -LiteralPath $path).Hash.ToLower() -ne $file.sha256){throw 'Verified backup content changed.'}}
    $vaultBytes=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $VerifiedBackup 'configuration.dpapi')))
    try{$vault=[Text.Encoding]::UTF8.GetString($vaultBytes)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($vaultBytes,0,$vaultBytes.Length)}
    $configNames=@('dev.json')+@(Get-ChildItem -LiteralPath (Join-Path $old.config_root 'services') -Filter *.json -File|ForEach-Object{'services/'+$_.Name})
    if(@(Compare-Object @($vault.configuration_files.Keys|Sort-Object) @($configNames|Sort-Object)).Count){throw 'Configured service set changed after the verified backup.'}
    foreach($name in $configNames){
        $retained=[Convert]::FromBase64String($vault.configuration_files[$name])
        try{if((Get-FileHash -LiteralPath (Join-Path $old.config_root $name)).Hash.ToLower() -ne (Get-BytesHash $retained)){throw 'Configuration changed after the verified backup.'}}finally{[Array]::Clear($retained,0,$retained.Length)}
    }
    $vault=$null
    $releaseIndex=Read-RecoveryJson (Join-Path $old.release_root 'current.json')
    foreach($role in $releaseIndex.Keys){
        if(-not(Test-PathWithin $releaseIndex[$role] $old.release_root) -or (Get-FileHash -LiteralPath $releaseIndex[$role]).Hash -ne (Get-FileHash -LiteralPath (Join-Path $VerifiedBackup ('releases/'+$role+'.exe'))).Hash){throw 'Service release changed after the verified backup.'}
    }
    $entries=@(Read-RecoveryJson (Join-Path $old.state_root 'processes.json'))
    $entries=@($entries|Where-Object{$p=Get-Process -Id $_.pid -ErrorAction SilentlyContinue;$p -and $p.Path -eq $_.binary -and $p.StartTime.ToUniversalTime().Ticks -eq ([datetime]$_.started_at).ToUniversalTime().Ticks})
    $roles=@($entries|ForEach-Object{$_.role}|Sort-Object -Unique);$workers=[Math]::Max(1,@($entries|Where-Object role -eq 'worker').Count)
    if(-not $roles.Count){throw 'No deployment recorded; preserve the intended role set before relocation.'}
    $oldPointer=[IO.File]::ReadAllText((Join-Path $sourceRoot '.local/layout.path'))
    $revision=(& git -C $sourceRoot rev-parse HEAD).Trim();if($LASTEXITCODE -ne 0){throw 'Cannot identify source revision.'}
    $sourceStatus=(& git -C $sourceRoot status --porcelain) -join "`n"
    $admin=Read-RecoveryJson (Join-Path $old.config_root 'dev.json');$connection=Get-DatabaseConnection $admin.DATABASE_URL
    if($connection.host -ne '127.0.0.1' -or $connection.port -ne 55432){throw 'This migration only manages the owned loopback PostgreSQL cluster.'}
    $databases=@($backupManifest.databases|ForEach-Object{$_.name})
    $journal.old_layout=$old;$journal.old_pointer=$oldPointer;$journal.roles=$roles;$journal.workers=$workers
    $journal.plan=@(@{from=$old.database_root;to=$targetData},@{from=(Join-Path $sourceRoot '.state');to=$archiveRoot},@{from=(Join-Path $sourceRoot 'bin');to=$legacyBin},@{from=$sourceRoot;to=$targetRoot})
    $journal.backup_manifest_sha256=$backupHash;$journal.source_revision=$revision;Save-MoveJournal
    $stopAttempted=$true
    & (Join-Path $sourceRoot 'scripts/Stop-Local.ps1') -LayoutPath $old.layout_path -MaintenanceLock $maintenance
    Assert-AllDeploymentsQuiescent $old
    if(-not(Get-OwnedDatabase $old)){throw 'Owned PostgreSQL is not running; refusing to connect for relocation fingerprints.'}
    $clients=(Invoke-RecoverySQL $old.postgres_bin $connection "SELECT count(*) FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND backend_type='client backend';").Trim()
    if([long]$clients -ne 0){throw 'Another client still uses this cluster; database relocation refused.'}
    $before=@{}
    foreach($database in $databases){$db=$connection.Clone();$db.database=$database;$before[$database]=@{tables=(Get-DatabaseFingerprints $old.postgres_bin $db);metadata=(Get-DatabaseMetadata $old.postgres_bin $db);schema=(Get-DatabaseSchemaHash $old.postgres_bin $db)}}
    $journal.database_fingerprints=$before;Save-MoveJournal
    & (Join-Path $sourceRoot 'scripts/Stop-Database.ps1') -LayoutPath $old.layout_path -MaintenanceLock $maintenance
    Protect-MovingTree (Join-Path $sourceRoot '.state')
    $journal.private_state_acl_checked=$true
    $dataHashes=Get-TreeHashes $old.database_root
    $journal.status='stopped_and_fingerprinted';$journal.database_files=$dataHashes.Count;Save-MoveJournal
    foreach($parent in @((Split-Path -Parent $targetData),(Split-Path -Parent $archiveRoot))){if(-not(Test-Path -LiteralPath $parent)){New-ProtectedDirectory $parent}}
    Move-CheckedDirectory $old.database_root $targetData
    $afterHashes=Get-TreeHashes $targetData
    if(($dataHashes|ConvertTo-Json -Depth 4 -Compress) -cne ($afterHashes|ConvertTo-Json -Depth 4 -Compress)){throw 'PostgreSQL files changed during the stopped-directory move.'}
    $journal.database_file_hashes_match=$true;Save-MoveJournal
    Move-CheckedDirectory (Join-Path $sourceRoot '.state') $archiveRoot
    Move-CheckedDirectory (Join-Path $sourceRoot 'bin') $legacyBin
    Move-CheckedDirectory $sourceRoot $targetRoot
    $new=$old.Clone();$null=$new.Remove('layout_path');$new.project_root=$targetRoot;$new.database_root=$targetData
    $new.legacy_state_root=$archiveRoot
    $newLayout=Join-Path $base ('ops/layout-'+[guid]::NewGuid().ToString('N')+'.json');Write-PlatformJson $newLayout $new
    Write-PlatformText (Join-Path $targetRoot '.local/layout.path') $newLayout
    $journal.active_layout=$newLayout;Save-MoveJournal
    Register-PlatformRoots @($new)
    if((& git -C $targetRoot rev-parse HEAD).Trim() -ne $revision -or ((& git -C $targetRoot status --porcelain) -join "`n") -cne $sourceStatus){throw 'Source revision or pending changes differ after relocation.'}
    & (Join-Path $targetRoot 'scripts/Start-Database.ps1') -LayoutPath $newLayout -MaintenanceLock $maintenance
    $actual=(Invoke-RecoverySQL $new.postgres_bin $connection 'SHOW data_directory;').Trim()
    if([IO.Path]::GetFullPath($actual) -ne $targetData){throw 'PostgreSQL did not open the relocated data directory.'}
    foreach($database in $databases){
        $db=$connection.Clone();$db.database=$database
        $after=@{tables=(Get-DatabaseFingerprints $new.postgres_bin $db);metadata=(Get-DatabaseMetadata $new.postgres_bin $db);schema=(Get-DatabaseSchemaHash $new.postgres_bin $db)}
        foreach($field in @('tables','metadata','schema')){if(($before[$database][$field]|ConvertTo-Json -Depth 6 -Compress) -cne ($after[$field]|ConvertTo-Json -Depth 6 -Compress)){throw 'Relocated database content or permissions differ.'}}
    }
    $journal.database_content_match=$true
    $journal.services_start_attempted=$true;Save-MoveJournal
    & (Join-Path $targetRoot 'scripts/Start-Local.ps1') -LayoutPath $newLayout -Service $roles -Workers $workers -MaintenanceLock $maintenance
    $doctor=(& (Join-Path $targetRoot 'scripts/Doctor-Local.ps1') -LayoutPath $newLayout)|ConvertFrom-Json
    if(-not $doctor.core_probe_passed){throw 'Relocated deployment did not become ready.'}
    $journal.status='passed';$journal.active_layout=$newLayout;$journal.owned_processes=$doctor.processes.Count;$journal.archive_root=$archiveRoot;$journal.legacy_builds=$legacyBin
}catch{
    $originalFailure=$_;$journal.status='failed'
    Save-MoveJournal
    if($stopAttempted){
        try{
            $currentRoot=if(Test-Path -LiteralPath $targetRoot){$targetRoot}else{$sourceRoot}
            & (Join-Path $currentRoot 'scripts/Recover-WorkspaceMove.ps1') -Journal $journalPath -MaintenanceLock $maintenance
            $journal=Read-RecoveryJson $journalPath
        }catch{$journal=Read-RecoveryJson $journalPath;$journal.recovery='automatic recovery incomplete; inspect this journal before any further move'}
    }
    throw $originalFailure
}finally{
    $journal.finished_at=[datetime]::UtcNow.ToString('o')
    try{Save-MoveJournal}finally{$maintenance.Dispose()}
    Write-Output ('Relocation evidence: '+$journalPath)
}
Write-Output ('Source: '+$targetRoot)
Write-Output ('Database: '+$targetData)
