$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$binary = Join-Path $repoRoot 'bin\agentos.exe'
$manifestPath = Join-Path $repoRoot '.state\processes.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Output 'No process manifest.'; exit 0 }
$entries = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
foreach ($entry in $entries) {
    $running = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
    if ($running -and $running.Path -eq $binary -and $running.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks) {
        Stop-Process -Id $entry.pid
        Write-Output ('Stopped owned instance ' + $entry.id)
    }
}
Write-Output 'PostgreSQL remains running. Interrupted runs remain durable and can be taken over after lease expiry.'
