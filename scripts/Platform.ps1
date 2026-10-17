param(
    [Parameter(Position=0)][ValidateSet('start','stop','status','doctor','backup','restore-check','build','update','rollback','release-recover','set-engine')][string]$Action='status',
    [string]$LayoutPath='',
    [ValidateRange(1,16)][int]$Workers=2,
    [string[]]$Service=@(),
    [string]$Destination='',
    [string]$BackupDirectory='',
    [string]$Pnpm='pnpm',
    [string]$ReleaseSet='',
    [string]$SourceArtifact='',
    [string]$ResidentArtifact='',
    [string]$BudgetArtifact='',
    [string]$NativeArtifact='',
    [string]$FinalArtifact='',
    [string]$GuardedArtifact='',
    [string]$GuardedV6Artifact='',
    [string]$SourceV2Artifact='',
    [string]$ResidentV2Artifact='',
    [string]$BudgetV2Artifact='',
    [string]$NativeV2Artifact='',
    [string]$FinalV2Artifact='',
    [string]$GuardedV2Artifact='',
    [ValidateSet('source','resident','budget','native','final','guarded','historical','source-v2','resident-v2','budget-v2','native-v2','final-v2','guarded-v2')][string]$Engine='',
    [switch]$WithDatabase
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-processes.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
$layout=Get-PlatformLayout $root $LayoutPath
switch($Action){
    'set-engine' {
        if(-not $Engine){throw 'set-engine requires -Engine source, resident, budget, native, final or historical.'}
        & (Join-Path $PSScriptRoot 'Set-DefaultEngine.ps1') -LayoutPath $LayoutPath -Engine $Engine
    }
    {$_ -in @('update','rollback','release-recover')} {
        if($Service.Count -ne 1){throw 'Select exactly one service for release maintenance.'}
        $releaseAction=if($Action -eq 'release-recover'){'recover'}else{$Action}
        & (Join-Path $PSScriptRoot 'Update-Local.ps1') -LayoutPath $LayoutPath -Service $Service[0] -Action $releaseAction -ReleaseSet $ReleaseSet
    }
    start {& (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $LayoutPath -Workers $Workers -Service $Service}
    stop {
        & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $LayoutPath -Service $Service
        if($WithDatabase){& (Join-Path $PSScriptRoot 'Stop-Database.ps1') -LayoutPath $LayoutPath}
    }
    status {
        $raw=& (Join-Path $PSScriptRoot 'Doctor-Local.ps1') -LayoutPath $LayoutPath
        $report=$raw|ConvertFrom-Json
        [pscustomobject]@{core_ready=$report.core_probe_passed;services=$report.services;issues=$report.issues;releases=$report.release_status;source=$layout.project_root;data=$layout.database_root}|ConvertTo-Json -Depth 6
    }
    doctor {& (Join-Path $PSScriptRoot 'Doctor-Local.ps1') -LayoutPath $LayoutPath}
    build {
        if($Service.Count){& (Join-Path $PSScriptRoot 'Build-Services.ps1') -LayoutPath $LayoutPath -Service $Service -Pnpm $Pnpm -SourceArtifact $SourceArtifact -ResidentArtifact $ResidentArtifact -BudgetArtifact $BudgetArtifact -NativeArtifact $NativeArtifact -FinalArtifact $FinalArtifact -GuardedArtifact $GuardedArtifact -GuardedV6Artifact $GuardedV6Artifact -SourceV2Artifact $SourceV2Artifact -ResidentV2Artifact $ResidentV2Artifact -BudgetV2Artifact $BudgetV2Artifact -NativeV2Artifact $NativeV2Artifact -FinalV2Artifact $FinalV2Artifact -GuardedV2Artifact $GuardedV2Artifact}
        else{& (Join-Path $PSScriptRoot 'Build-Services.ps1') -LayoutPath $LayoutPath -Pnpm $Pnpm -SourceArtifact $SourceArtifact -ResidentArtifact $ResidentArtifact -BudgetArtifact $BudgetArtifact -NativeArtifact $NativeArtifact -FinalArtifact $FinalArtifact -GuardedArtifact $GuardedArtifact -GuardedV6Artifact $GuardedV6Artifact -SourceV2Artifact $SourceV2Artifact -ResidentV2Artifact $ResidentV2Artifact -BudgetV2Artifact $BudgetV2Artifact -NativeV2Artifact $NativeV2Artifact -FinalV2Artifact $FinalV2Artifact -GuardedV2Artifact $GuardedV2Artifact}
    }
    'restore-check' {
        if(-not $BackupDirectory){throw 'restore-check requires -BackupDirectory.'}
        & (Join-Path $PSScriptRoot 'Test-PlatformRecovery.ps1') -BackupDirectory $BackupDirectory -PostgresBin $layout.postgres_bin -Pnpm $Pnpm
    }
    backup {
        if(-not $Destination){$Destination='D:\workspace\agent-platform\local\backups\platform-'+(Get-Date -Format 'yyyyMMdd-HHmmss')}
        $maintenance=Enter-PlatformMaintenance $layout.state_root
        $restart=@();$workerCount=1
        $operationFailure=$null;$restartFailure=$null;$stopAttempted=$false
        try{
            Assert-NoPendingOwnerMigration $layout
            Assert-NoPendingRelease (Read-ReleaseCatalog $layout)
            $manifest=Join-Path $layout.state_root 'processes.json'
            if(Test-Path -LiteralPath $manifest){
                $entries=Read-PlatformProcesses $layout
                $running=@($entries|Where-Object{$state=Get-PlatformInstanceState $_ $layout;[bool]$state.process})
                $restart=@($running.role|Sort-Object -Unique);$workerCount=[Math]::Max(1,@($running|Where-Object role -eq 'worker').Count)
            }
            $stopAttempted=$true
            & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $LayoutPath -MaintenanceLock $maintenance
            & (Join-Path $PSScriptRoot 'Backup-Platform.ps1') -LayoutPath $LayoutPath -Destination $Destination -Pnpm $Pnpm -MaintenanceLock $maintenance
        }catch{$operationFailure=$_}
        finally{
            try{
                if($stopAttempted -and $restart.Count){
                    & (Join-Path $PSScriptRoot 'Stop-Local.ps1') -LayoutPath $LayoutPath -MaintenanceLock $maintenance
                    & (Join-Path $PSScriptRoot 'Start-Local.ps1') -LayoutPath $LayoutPath -Workers $workerCount -Service $restart -MaintenanceLock $maintenance
                }
            }catch{$restartFailure=$_}
            finally{$maintenance.Dispose()}
        }
        if($operationFailure){if($restartFailure){Write-Warning 'Backup failed and restarting the previous deployment also failed; inspect the process manifest.'};throw $operationFailure}
        if($restartFailure){throw 'Backup was captured, but the previous deployment did not restart; inspect the process manifest.'}
    }
}
