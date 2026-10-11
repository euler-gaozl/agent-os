param([string]$PostgresBin = 'D:\workspace\.tools\postgresql\pgsql\bin')
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dataDirectory = Join-Path $repoRoot '.state\postgres'
if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION'))) { throw 'Initialize the local PostgreSQL cluster first.' }
$readyCommand = Join-Path $PostgresBin 'pg_isready.exe'
& $readyCommand -h 127.0.0.1 -p 55432 -q
if ($LASTEXITCODE -eq 0) { return }
$databaseProcess = Start-Process -FilePath (Join-Path $PostgresBin 'postgres.exe') -ArgumentList @('-D',('"'+$dataDirectory+'"'),'-h','127.0.0.1','-p','55432') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $repoRoot '.state\postgres.stdout.log') -RedirectStandardError (Join-Path $repoRoot '.state\postgres.stderr.log')
for ($attempt=0;$attempt -lt 30;$attempt++) {
    & $readyCommand -h 127.0.0.1 -p 55432 -q
    if ($LASTEXITCODE -eq 0) { Write-Output 'Local PostgreSQL is ready on 127.0.0.1:55432.'; return }
    if ($databaseProcess.HasExited) { throw 'PostgreSQL stopped during startup; inspect .state/postgres.stderr.log.' }
    Start-Sleep -Milliseconds 300
}
throw 'PostgreSQL startup timed out; inspect local logs.'
