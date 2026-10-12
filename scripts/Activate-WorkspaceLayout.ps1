param([Parameter(Mandatory)][string]$LayoutPath)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
$pointer=Join-Path $root '.local/layout.path'
$oldLock=Enter-PlatformMaintenance ''
$nextLock=$oldLock;$stopped=$false;$activated=$false
$report=@{started_at=[datetime]::UtcNow.ToString('o');status='incomplete';database_moved=$false;configuration_changed=$false}
try {
    $old=Get-PlatformLayout $root
    $next=Get-PlatformLayout $root $LayoutPath
    if($old.state_root -eq $next.state_root){throw 'The new layout must use a separate process state directory.'}
    if($old.database_root -ne $next.database_root){throw 'Activation does not move a database. Stop and verify PostgreSQL separately before a physical relocation.'}
    $oldPointer=if(Test-Path -LiteralPath $pointer){Get-Content -LiteralPath $pointer -Raw}else{$null}
    # Keep an immutable rollback description independent of the active pointer.
    $oldSnapshot='D:\workspace\agent-platform\ops\layout-'+[guid]::NewGuid().ToString('N')+'.json'
    $snapshot=$old.Clone();$null=$snapshot.Remove('layout_path');Write-PlatformJson $oldSnapshot $snapshot
    Assert-RecoveryQuiescent $root $next.state_root $next.release_root
    $before=@(Read-RecoveryJson (Join-Path $old.state_root 'processes.json'))
    $roles=@($before|ForEach-Object{$_.role}|Sort-Object -Unique)
    if(-not $roles.Count){throw 'No running deployment recorded for activation.'}
    $workers=@($before|Where-Object role -eq 'worker').Count
    foreach($name in @('dev.json')+@(Get-ChildItem -LiteralPath (Join-Path $old.config_root 'services') -File -Filter *.json|ForEach-Object{'services/'+$_.Name})){
        if((Get-FileHash -LiteralPath (Join-Path $old.config_root $name)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $next.config_root $name)).Hash){throw 'Prepared configuration differs; prepare a fresh layout before activation.'}
    }
    $oldIndex=Read-RecoveryJson (Join-Path $old.release_root 'current.json');$newIndex=Read-RecoveryJson (Join-Path $next.release_root 'current.json')
    if($oldIndex.Keys.Count -ne $newIndex.Keys.Count){throw 'Prepared release set differs.'}
    foreach($role in $oldIndex.Keys){if((Get-FileHash -LiteralPath $oldIndex[$role]).Hash -ne (Get-FileHash -LiteralPath $newIndex[$role]).Hash){throw 'Prepared binary differs; activation only relocates the verified build.'}}
    $stopped=$true
    & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $oldSnapshot -MaintenanceLock $oldLock
    Assert-AllDeploymentsQuiescent $next
    & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $LayoutPath -Service $roles -Workers ([Math]::Max(1,$workers)) -MaintenanceLock $nextLock
    $doctor=(& (Join-Path $PSScriptRoot 'Doctor-Local.ps1') -LayoutPath $LayoutPath)|ConvertFrom-Json
    if(-not $doctor.core_probe_passed){throw 'Prepared deployment did not pass readiness checks.'}
    $activePath='D:\workspace\agent-platform\ops\layout-'+[guid]::NewGuid().ToString('N')+'.json'
    $active=$next.Clone();$null=$active.Remove('layout_path');Write-PlatformJson $activePath $active
    $null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pointer)
    Write-PlatformText $pointer $activePath
    $report.status='passed';$report.owned_processes=$doctor.processes.Count;$report.http_ready=$true;$report.active_layout=$activePath;$activated=$true
}catch{
    $report.status='failed'
    if($stopped){
        try{
            & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $LayoutPath -MaintenanceLock $nextLock
            if($null -ne $oldPointer){
                if(-not(Test-Path -LiteralPath $pointer) -or (Get-Content -LiteralPath $pointer -Raw) -cne $oldPointer){Write-PlatformText $pointer $oldPointer}
            }elseif(Test-Path -LiteralPath $pointer){Remove-Item -LiteralPath $pointer}
            & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $oldSnapshot -MaintenanceLock $oldLock
            & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $oldSnapshot -Service $roles -Workers ([Math]::Max(1,$workers)) -MaintenanceLock $oldLock
            $report.recovery='previous deployment restarted'
        }catch{$report.recovery='automatic recovery failed; inspect process manifests before further changes'}
    }
    throw
}finally{
    $report.completed_at=[datetime]::UtcNow.ToString('o')
    $path='D:\workspace\agent-platform\local\evidence\layout-activation-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json'
    try{Write-PlatformJson $path $report}finally{$oldLock.Dispose()}
    Write-Output ('Activation evidence: '+$path)
}
if($activated){Write-Output 'Services now use separate configuration, release, log and process directories. PostgreSQL has not moved.'}
