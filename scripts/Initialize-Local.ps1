param([string]$PostgresBin = '',[string]$LayoutPath='')
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
if(-not $PostgresBin){$PostgresBin=$layout.postgres_bin}
$maintenance=Enter-PlatformMaintenance $layout.state_root
$passwordFile=$null
try {
if ($repoRoot.StartsWith('C:\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Keep this project under D:\workspace.' }
$stateDirectory = $layout.config_root
$configPath = Join-Path $stateDirectory 'dev.json'
$dataDirectory = $layout.database_root
if (-not (Test-Path -LiteralPath (Join-Path $PostgresBin 'initdb.exe'))) { throw 'Install the official PostgreSQL portable binaries on D: first; see docs/operations.md.' }
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $configPath)) {
    $dbPassword = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $config = @{
        DATABASE_URL = ('postgres://agentos:'+$dbPassword+'@127.0.0.1:55432/agentos?sslmode=disable')
        SERVICE_TOKEN = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        ADMIN_TOKEN = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        BUSINESS_TOKEN = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        MASTER_KEY = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        DEV_LOCAL = '1'
    }
    Write-PlatformJson $configPath $config
}
$localSettings = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$dbUri = [Uri]$localSettings.DATABASE_URL
if ($dbUri.Host -ne '127.0.0.1' -or $dbUri.Port -ne 55432) { throw 'Initialize-Local only manages its own loopback cluster on port 55432.' }
$passwordFile = Join-Path $stateDirectory 'pg-password'
[Uri]::UnescapeDataString($dbUri.UserInfo.Split(':',2)[1]) | Set-Content -LiteralPath $passwordFile -Encoding ascii
if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION'))) {
    & (Join-Path $PostgresBin 'initdb.exe') -D $dataDirectory -U agentos --auth=scram-sha-256 --pwfile=$passwordFile --encoding=UTF8 --no-locale
    if ($LASTEXITCODE -ne 0) { throw 'Cluster initialization failed. Existing files were retained for inspection.' }
}
& (Join-Path $PSScriptRoot 'Start-Database.ps1') -PostgresBin $PostgresBin -LayoutPath $LayoutPath -MaintenanceLock $maintenance
$previousPassword = $env:PGPASSWORD
try {
    $env:PGPASSWORD = [Uri]::UnescapeDataString($dbUri.UserInfo.Split(':',2)[1])
    $exists = & (Join-Path $PostgresBin 'psql.exe') -h 127.0.0.1 -p 55432 -U agentos -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='agentos'"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot authenticate to the local cluster.' }
    if ($exists -ne '1') {
        & (Join-Path $PostgresBin 'createdb.exe') -h 127.0.0.1 -p 55432 -U agentos agentos
        if ($LASTEXITCODE -ne 0) { throw 'Database creation failed.' }
    }
} finally { $env:PGPASSWORD = $previousPassword }
Write-Output 'Local database and ignored configuration are ready. No model API key has been configured.'

} finally { try{if($passwordFile -and (Test-Path -LiteralPath $passwordFile)){Remove-Item -LiteralPath $passwordFile}}finally{$maintenance.Dispose()} }
