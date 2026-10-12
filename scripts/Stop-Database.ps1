param([string]$LayoutPath='',[IO.FileStream]$MaintenanceLock=$null)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root $MaintenanceLock
try {
    Assert-AllDeploymentsQuiescent $layout
    $owned=Get-OwnedDatabase $layout
    if(-not $owned){Write-Output 'Owned local PostgreSQL is stopped.';return}
    $null=Invoke-PostgresTool -PostgresBin $layout.postgres_bin -Tool pg_ctl -Arguments @('-D',$layout.database_root,'-m','fast','-w','-t','30','stop')
    if(Get-OwnedDatabase $layout){throw 'Could not verify PostgreSQL shutdown.'}
    Write-Output 'Owned local PostgreSQL stopped; data retained.'
}finally{if($maintenance){$maintenance.Dispose()}}
