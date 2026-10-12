param([string[]]$Service=@(),[string]$LayoutPath='',[IO.FileStream]$MaintenanceLock=$null)
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root $MaintenanceLock
try {
$manifestPath = Join-Path $layout.state_root 'processes.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Output 'No process manifest.'; return }
$entries = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
$keep=@()
foreach ($entry in $entries) {
    if($Service.Count -gt 0 -and $entry.role -notin $Service){$keep+=$entry;continue}
    $binary=[IO.Path]::GetFullPath($entry.binary)
    if(-not(Test-PathWithin $binary $layout.release_root)){throw 'Manifest executable outside managed release directory.'}
    $running = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
    if ($running -and $running.Path -eq $binary -and $running.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks) {
        Stop-Process -Id $entry.pid
        Wait-Process -Id $entry.pid -Timeout 10 -ErrorAction SilentlyContinue
        if(Get-Process -Id $entry.pid -ErrorAction SilentlyContinue){$keep+=$entry;throw 'Owned service did not stop; process manifest was retained.'}
        Write-Output ('Stopped owned instance ' + $entry.id)
    }
}
Write-PlatformJson $manifestPath @($keep)
Write-Output 'PostgreSQL remains running. Interrupted runs remain durable and can be taken over after lease expiry.'

} finally { if($maintenance){$maintenance.Dispose()} }
