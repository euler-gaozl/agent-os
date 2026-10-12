param([string[]]$Service=@())
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
$maintenance=Enter-PlatformMaintenance (Join-Path $repoRoot '.state')
try {
$manifestPath = Join-Path $repoRoot '.state\processes.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Output 'No process manifest.'; exit 0 }
$entries = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
$keep=@()
foreach ($entry in $entries) {
    if($Service.Count -gt 0 -and $entry.role -notin $Service){$keep+=$entry;continue}
    $binary=[IO.Path]::GetFullPath($entry.binary)
    if(-not $binary.StartsWith((Join-Path $repoRoot 'bin')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Manifest executable outside repository bin directory.'}
    $running = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
    if ($running -and $running.Path -eq $binary -and $running.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks) {
        Stop-Process -Id $entry.pid
        Wait-Process -Id $entry.pid -Timeout 10 -ErrorAction SilentlyContinue
        Write-Output ('Stopped owned instance ' + $entry.id)
    }
}
ConvertTo-Json -InputObject @($keep)|Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Output 'PostgreSQL remains running. Interrupted runs remain durable and can be taken over after lease expiry.'

} finally { $maintenance.Dispose() }
