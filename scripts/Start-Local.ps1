param([ValidateRange(1,16)][int]$Workers = 2)
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$binary = Join-Path $repoRoot 'bin\agentos.exe'
$config = Join-Path $repoRoot '.state\dev.json'
$manifestPath = Join-Path $repoRoot '.state\processes.json'
if (-not (Test-Path -LiteralPath $binary)) { throw 'Build bin/agentos.exe before starting.' }
if (-not (Test-Path -LiteralPath $config)) { throw 'Create local configuration using docs/operations.md.' }
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'web\dist\index.html'))) { throw 'Build the web console before starting.' }
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'web\dist-futures\index.html'))) { throw 'Build the futures workspace before starting.' }
if (Test-Path -LiteralPath $manifestPath) {
    $previous = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($entry in $previous) {
        $running = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if ($running -and $running.Path -eq $binary -and $running.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks) { throw 'Platform is already running. Stop it using Stop-Local.ps1 before restarting.' }
    }
}
$occupied = Get-NetTCPConnection -State Listen -LocalPort 8090,8091,8092,8093,8094,8095,8096,8098 -ErrorAction SilentlyContinue
if ($occupied) { throw 'A platform port is occupied. Stop the owning platform processes before starting.' }
$databaseSettings = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
$databaseUri = [Uri]$databaseSettings.DATABASE_URL
if ($databaseUri.Host -eq '127.0.0.1' -and $databaseUri.Port -eq 55432) { & (Join-Path $PSScriptRoot 'Start-Database.ps1') }
$previousInstance = $env:INSTANCE_ID
Push-Location $repoRoot
try {
    & $binary --role migrate --config $config
    if ($LASTEXITCODE -ne 0) { throw 'Database migration failed; check that PostgreSQL is running.' }
    & $binary --role seed --config $config
    if ($LASTEXITCODE -ne 0) { throw 'Business pack registration failed.' }
    $roles = @('storage','registry','runtime','knowledge','indexer','toolhub','sandbox','control','futures') + @(1..$Workers | ForEach-Object { 'worker' })
    $started = @()
    foreach ($role in $roles) {
        $instance = $role + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
        $stdout = Join-Path $repoRoot ('.state\' + $instance + '.stdout.log')
        $stderr = Join-Path $repoRoot ('.state\' + $instance + '.stderr.log')
        $env:INSTANCE_ID = $instance
        $process = Start-Process -FilePath $binary -ArgumentList @('--role',$role,'--config',('"'+$config+'"')) -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $started += [pscustomobject]@{ pid=$process.Id; role=$role; id=$instance; started_at=$process.StartTime.ToUniversalTime().ToString('o'); binary=$binary }
        $started | ConvertTo-Json -AsArray | Set-Content -LiteralPath $manifestPath -Encoding utf8
    }
    Start-Sleep -Milliseconds 500
    foreach ($entry in $started) {
        if (-not (Get-Process -Id $entry.pid -ErrorAction SilentlyContinue)) { throw ('Service exited during startup: '+$entry.role+'. Inspect its .state log.') }
    }
    Write-Output ('Started ' + $started.Count + ' processes. Console: http://127.0.0.1:8090 | Futures: http://127.0.0.1:8098')
} catch {
    # The manifest identifies only processes launched by this invocation.
    if ($started.Count -gt 0) { & (Join-Path $PSScriptRoot 'Stop-Local.ps1') }
    throw
} finally { $env:INSTANCE_ID = $previousInstance; Pop-Location }
