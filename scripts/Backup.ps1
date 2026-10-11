param([string]$PostgresBin = 'D:\workspace\.tools\postgresql\pgsql\bin')
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$config = Get-Content -LiteralPath (Join-Path $repoRoot '.state\dev.json') -Raw | ConvertFrom-Json
$dbUri = [Uri]$config.DATABASE_URL
$credentials = $dbUri.UserInfo.Split(':',2)
$previousPassword = $env:PGPASSWORD
$env:PGPASSWORD = [Uri]::UnescapeDataString($credentials[1])
try {
$backupDirectory = Join-Path $repoRoot '.state\backups'
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
$backupPath = Join-Path $backupDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.dump')
& (Join-Path $PostgresBin 'pg_dump.exe') -h $dbUri.Host -p $dbUri.Port -U $credentials[0] -d $dbUri.AbsolutePath.TrimStart('/') --format=custom --file=$backupPath
if ($LASTEXITCODE -ne 0) { throw 'Backup failed; do not treat this dump as complete.' }
& (Join-Path $PostgresBin 'pg_restore.exe') --list $backupPath | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Backup catalogue validation failed.' }
Write-Output ('Backup created: ' + $backupPath)
Write-Output 'Keep a protected copy of MASTER_KEY separately. This check is not a restoration test.'
} finally { $env:PGPASSWORD = $previousPassword }
