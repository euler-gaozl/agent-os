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
    $serviceChecks = @'
DO $$ BEGIN
 IF to_regclass('public.note_roots') IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM public.documents d LEFT JOIN public.note_versions v ON v.document_id=d.id WHERE v.document_id IS NULL) THEN RAISE EXCEPTION 'Note lineage missing'; END IF;
  IF EXISTS(SELECT 1 FROM public.note_roots r LEFT JOIN public.note_versions v ON v.document_id=r.current_id AND v.root_id=r.root_id WHERE r.state<>'conflict' AND v.document_id IS NULL) THEN RAISE EXCEPTION 'Note current head missing'; END IF;
  IF EXISTS(SELECT 1 FROM public.note_audits a LEFT JOIN public.calls c ON c.id=a.operation_id WHERE a.operation_id IS NOT NULL AND c.id IS NULL) THEN RAISE EXCEPTION 'Note audit receipt missing'; END IF;
 END IF;
 IF to_regclass('knowledge.artifacts') IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM knowledge.artifacts WHERE encode(sha256(body),'hex')<>hash) THEN RAISE EXCEPTION 'Knowledge artifact hash mismatch'; END IF;
  IF EXISTS(SELECT 1 FROM knowledge.artifact_refs r LEFT JOIN knowledge.artifacts a USING(hash) WHERE a.hash IS NULL) THEN RAISE EXCEPTION 'Knowledge reference missing'; END IF;
 END IF;
 IF to_regclass('toolhub.asset_files') IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM toolhub.asset_files WHERE encode(sha256(body),'hex')<>hash) THEN RAISE EXCEPTION 'Skill file hash mismatch'; END IF;
 END IF;
 IF to_regclass('sources.source_blobs') IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM sources.source_blobs WHERE encode(sha256(body),'hex')<>hash) THEN RAISE EXCEPTION 'Source capture hash mismatch'; END IF;
  IF EXISTS(SELECT 1 FROM sources.source_captures c LEFT JOIN sources.source_blobs b USING(hash) WHERE b.hash IS NULL) THEN RAISE EXCEPTION 'Source capture original missing'; END IF;
 END IF;
END $$;
'@
    & (Join-Path $PostgresBin 'psql.exe') -h $dbUri.Host -p $dbUri.Port -U $credentials[0] -d $verifyDatabase -v ON_ERROR_STOP=1 -Atc $serviceChecks
    if ($LASTEXITCODE -ne 0) { throw 'Service-owned data validation failed.' }
    Write-Output 'Backup restored into an isolated database; schema, original artifact hashes and references checked.'
} finally {
    if ($created -and $verifyDatabase -match '^agentos_restorecheck_[a-f0-9]{32}$') {
        & (Join-Path $PostgresBin 'dropdb.exe') -h $dbUri.Host -p $dbUri.Port -U $credentials[0] $verifyDatabase
        if ($LASTEXITCODE -ne 0) { Write-Warning ('Could not clean isolated verification database '+$verifyDatabase) }
    }
    $env:PGPASSWORD = $previousPassword
}
