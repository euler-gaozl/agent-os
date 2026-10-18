param([string]$PostgresBin = '',[string]$LayoutPath='',[IO.FileStream]$MaintenanceLock=$null)
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root $MaintenanceLock
try {
if(-not $PostgresBin){$PostgresBin=$layout.postgres_bin}else{$layout.postgres_bin=[IO.Path]::GetFullPath($PostgresBin)}
$dataDirectory = $layout.database_root
if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION'))) { throw 'Initialize the local PostgreSQL cluster first.' }
$readyCommand = Join-Path $PostgresBin 'pg_isready.exe'
$owned=Get-OwnedDatabase $layout
if($owned){& $readyCommand -h 127.0.0.1 -p 55432 -q;if($LASTEXITCODE -eq 0){return};throw 'Owned PostgreSQL exists but is not ready; inspect its log before restarting.'}
if(Get-NetTCPConnection -State Listen -LocalPort 55432 -ErrorAction SilentlyContinue){throw 'Port 55432 is occupied by another process; the platform will not connect to it.'}
$null=New-Item -ItemType Directory -Force -Path $layout.log_root
$databaseProcess = Start-Process -FilePath (Join-Path $PostgresBin 'postgres.exe') -ArgumentList @('-D',('"'+$dataDirectory+'"'),'-h','127.0.0.1','-p','55432') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $layout.log_root 'postgres.stdout.log') -RedirectStandardError (Join-Path $layout.log_root 'postgres.stderr.log')
for ($attempt=0;$attempt -lt 30;$attempt++) {
    & $readyCommand -h 127.0.0.1 -p 55432 -q
    if ($LASTEXITCODE -eq 0) { $verified=Get-OwnedDatabase $layout;if($verified.Id -ne $databaseProcess.Id){throw 'PostgreSQL startup process identity mismatch.'};Write-Output 'Owned local PostgreSQL is ready on 127.0.0.1:55432.'; return }
    if ($databaseProcess.HasExited) { throw 'PostgreSQL stopped during startup; inspect .state/postgres.stderr.log.' }
    Start-Sleep -Milliseconds 300
}
throw 'PostgreSQL startup timed out; inspect local logs.'
}finally{if($maintenance){$maintenance.Dispose()}}
