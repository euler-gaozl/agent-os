param([string[]]$Service=@(),[string]$LayoutPath='',[IO.FileStream]$MaintenanceLock=$null)
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-processes.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root $MaintenanceLock
try {
$manifestPath = Join-Path $layout.state_root 'processes.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Output 'No process manifest.'; return }
$entries = Read-PlatformProcesses $layout
$keep=@()
foreach ($entry in $entries) {
    if($Service.Count -gt 0 -and $entry.role -notin $Service){$keep+=$entry;continue}
    Stop-PlatformInstance $entry $layout {Write-PlatformJson $manifestPath @($entries)}
    Write-Output ('Stopped owned instance tree ' + $entry.id)
}
Write-PlatformJson $manifestPath @($keep)
Write-Output 'PostgreSQL remains running. Interrupted runs remain durable and can be taken over after lease expiry.'

} finally { if($maintenance){$maintenance.Dispose()} }
