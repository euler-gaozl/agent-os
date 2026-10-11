param([Parameter(Mandatory)][string]$BackupPath,[string]$PostgresBin = 'D:\workspace\.tools\postgresql\pgsql\bin')
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$config = Get-Content -LiteralPath (Join-Path $repoRoot '.state\dev.json') -Raw | ConvertFrom-Json
$dbUri = [Uri]$config.DATABASE_URL
$credentials = $dbUri.UserInfo.Split(':',2)
$verifyDatabase = 'agentos_restorecheck_' + [Guid]::NewGuid().ToString('N')
$previousPassword = $env:PGPASSWORD
$created = $false
try {
    $env:PGPASSWORD = [Uri]::UnescapeDataString($credentials[1])
    & (Join-Path $PostgresBin 'createdb.exe') -h $dbUri.Host -p $dbUri.Port -U $credentials[0] $verifyDatabase
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create isolated restoration database.' }
    $created = $true
    & (Join-Path $PostgresBin 'pg_restore.exe') -h $dbUri.Host -p $dbUri.Port -U $credentials[0] -d $verifyDatabase --exit-on-error --no-owner $BackupPath
    if ($LASTEXITCODE -ne 0) { throw 'Restore failed.' }
    $checkSQL = "SELECT 'resources='||count(*) FROM resources; SELECT 'documents='||count(*) FROM documents; SELECT 'artifacts='||count(*) FROM artifacts; SELECT 'artifact_hash_mismatches='||count(*) FROM artifacts WHERE encode(sha256(body),'hex')<>hash; SELECT 'dangling_artifact_refs='||count(*) FROM artifact_refs r LEFT JOIN artifacts a ON a.hash=r.hash WHERE a.hash IS NULL;"
    & (Join-Path $PostgresBin 'psql.exe') -h $dbUri.Host -p $dbUri.Port -U $credentials[0] -d $verifyDatabase -v ON_ERROR_STOP=1 -Atc $checkSQL
    if ($LASTEXITCODE -ne 0) { throw 'Restored database validation failed.' }
    $invalid = & (Join-Path $PostgresBin 'psql.exe') -h $dbUri.Host -p $dbUri.Port -U $credentials[0] -d $verifyDatabase -Atc "SELECT count(*) FROM artifacts WHERE encode(sha256(body),'hex')<>hash"
    if ($LASTEXITCODE -ne 0 -or $invalid -ne '0') { throw 'Artifact integrity validation failed.' }
    Write-Output 'Backup restored into an isolated database; schema, original artifact hashes and references checked.'
} finally {
    if ($created -and $verifyDatabase -match '^agentos_restorecheck_[a-f0-9]{32}$') {
        & (Join-Path $PostgresBin 'dropdb.exe') -h $dbUri.Host -p $dbUri.Port -U $credentials[0] $verifyDatabase
        if ($LASTEXITCODE -ne 0) { Write-Warning ('Could not clean isolated verification database '+$verifyDatabase) }
    }
    $env:PGPASSWORD = $previousPassword
}
