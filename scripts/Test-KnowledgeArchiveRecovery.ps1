[CmdletBinding()]
param([string]$PostgresBin='D:\workspace\.tools\postgresql\pgsql\bin',[string]$Report)
$ErrorActionPreference='Stop'
# Synthetic SQL verifier fixtures only. Never use the formal database connection.
$fixtureURL=$env:TEST_DATABASE_URL
if($fixtureURL -cne 'postgres://p2_fixture@127.0.0.1:55591/postgres?sslmode=disable'){throw 'Explicit isolated local fixture connection required.'}
$env:PGCLIENTENCODING='UTF8'
$OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'lib/knowledge-archive-recovery.ps1')
function Get-BytesHash([byte[]]$Bytes){return [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($Bytes))}
function Invoke-RecoverySQL([string]$Bin,[hashtable]$Connection,[string]$SQL){
    $out=@(& (Join-Path $Bin 'psql.exe') --no-psqlrc --dbname $Connection.url -At -v ON_ERROR_STOP=1 -c $SQL 2>&1)
    if($LASTEXITCODE){throw 'Synthetic archive verifier SQL failed.'}
    return ($out -join "`n")
}
function Hex([byte[]]$Bytes){return [Convert]::ToHexStringLower($Bytes)}
$database='archive_verify_'+[guid]::NewGuid().ToString('N')
$admin=@{url=$fixtureURL};$connection=@{url=$fixtureURL.Replace('/postgres?','/'+$database+'?')}
$checks=[Collections.Generic.List[string]]::new()
$null=Invoke-RecoverySQL $PostgresBin $admin ('CREATE DATABASE '+$database)
try {
    $null=Invoke-RecoverySQL $PostgresBin $connection @'
CREATE SCHEMA knowledge;
CREATE TABLE knowledge.documents(id text PRIMARY KEY,content text);
CREATE TABLE knowledge.knowledge_files(id text PRIMARY KEY,document_id text,artifact_hash text,kb_id text,kb_revision int);
CREATE TABLE knowledge.artifacts(hash text PRIMARY KEY,body bytea);
CREATE TABLE knowledge.artifact_refs(root text,hash text,PRIMARY KEY(root,hash));
'@
    $file='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$document='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';$root='knowledge-source:'+$file
    $raw=[Text.Encoding]::UTF8.GetBytes('<p>库存🙂120吨</p>');$text=[Text.Encoding]::UTF8.GetBytes('库存🙂120吨')
    $rawHash=Get-BytesHash $raw;$textHash=Get-BytesHash $text
    $rawHex=Hex $raw;$textHex=Hex $text
    $null=Invoke-RecoverySQL $PostgresBin $connection @"
INSERT INTO knowledge.documents VALUES('$document',convert_from(decode('$textHex','hex'),'UTF8'));
INSERT INTO knowledge.knowledge_files VALUES('$file','$document','$textHash','synthetic',1);
INSERT INTO knowledge.artifacts VALUES('$rawHash',decode('$rawHex','hex')),('$textHash',decode('$textHex','hex'));
INSERT INTO knowledge.artifact_refs VALUES('${root}:payloads','$rawHash'),('${root}:payloads','$textHash');
"@
    $v1=@{format=1;file_id=$file;document_id=$document;knowledge=@{id='synthetic';revision=1};file_sha256=$textHash;url='https://fixture.invalid/evidence';captured_at='2026-01-01T00:00:00Z';media_type='text/html';extraction_method='fixture';raw_sha256=$rawHash;raw_encoding='identity';stored_raw_sha256=$rawHash;stored_raw_bytes=$raw.Length;raw_bytes=$raw.Length;text_sha256=$textHash;text_bytes=$text.Length;spans=@(@{start=0;end=7;document_start=0;document_end=7});provenance='operator_imported_archive: URL, capture time and extraction method are submitter assertions; hashes and matching spans verify retention consistency, not raw-to-text derivation, completeness or factual accuracy'}
    $v2=$v1|ConvertTo-Json -Depth 12|ConvertFrom-Json -AsHashtable
    $v2.format=2;$v2.extraction_method='Sources extraction: agentos-text-html-v1'
    $v2.provenance='sources_service_capture: bytes and metadata were read from an authenticated retained Sources capture; raw is the HTTP client response body after transport/content decoding; hashes and matching spans verify retention consistency, not website authenticity, extraction completeness or factual accuracy; fetched_at is collection time, not publication or statistical period'
    $v2.capture=@{capture_id=('c'*32);requested_url=$v2.url;final_url=$v2.url;extraction_version='agentos-text-html-v1';import_format='source-capture-document-v1'}
    function Save-Manifest([hashtable]$Value,[switch]$ExponentialFormat){
        $json=$Value|ConvertTo-Json -Depth 12 -Compress
        if($ExponentialFormat){$json=$json -replace '"format":2(?=[,}])','"format":2e0'}
        $bytes=[Text.Encoding]::UTF8.GetBytes($json);$hash=Get-BytesHash $bytes;$hex=Hex $bytes
        $null=Invoke-RecoverySQL $PostgresBin $connection "INSERT INTO knowledge.artifacts VALUES('$hash',decode('$hex','hex')) ON CONFLICT DO NOTHING; INSERT INTO knowledge.artifact_refs VALUES('${root}:manifests','$hash') ON CONFLICT DO NOTHING;"
        return $hash
    }
    $h1=Save-Manifest $v1;$h2=Save-Manifest $v2
    $good=Test-RecoveredKnowledgeArchives $PostgresBin $connection
    if($good.manifests -ne 2 -or -not $good.versioned_provenance){throw 'Both source archive formats must verify.'}
    $checks.Add('format1_and_format2_verified_with_unicode_spans')
    foreach($case in @('unknown_format','string_format','exponential_format','numeric_capture_id','string_byte_length','wrong_provenance','wrong_final_url','wrong_extraction_version','wrong_capture_id','wrong_span')){
        $bad=$v2|ConvertTo-Json -Depth 12|ConvertFrom-Json -AsHashtable
        switch($case){
            unknown_format {$bad.format=99}
            string_format {$bad.format='2'}
            numeric_capture_id {$bad.capture.capture_id=[Numerics.BigInteger]::Parse(('1'*32))}
            string_byte_length {$bad.raw_bytes=[string]$bad.raw_bytes}
            wrong_provenance {$bad.provenance=$v1.provenance}
            wrong_final_url {$bad.capture.final_url='https://other.invalid/'}
            wrong_extraction_version {$bad.capture.extraction_version='future-v99'}
            wrong_capture_id {$bad.capture.capture_id='invalid'}
            wrong_span {$bad.spans[0].document_end=6}
        }
        $hash=Save-Manifest $bad -ExponentialFormat:($case -eq 'exponential_format');$rejected=$false
        try{$null=Test-RecoveredKnowledgeArchives $PostgresBin $connection}catch{$rejected=$true}
        if(-not $rejected){throw ('Invalid archive accepted: '+$case)}
        $null=Invoke-RecoverySQL $PostgresBin $connection "DELETE FROM knowledge.artifact_refs WHERE root='${root}:manifests' AND hash='$hash'; DELETE FROM knowledge.artifacts WHERE hash='$hash';"
        $checks.Add($case+'_rejected')
    }
    $null=Invoke-RecoverySQL $PostgresBin $connection "UPDATE knowledge.artifacts SET body=decode('00','hex') WHERE hash='$rawHash';"
    $rejected=$false;try{$null=Test-RecoveredKnowledgeArchives $PostgresBin $connection}catch{$rejected=$true}
    if(-not $rejected){throw 'Corrupt payload accepted.'};$checks.Add('corrupt_payload_rejected')
    $result=@{passed=$true;checks=@($checks);scope='synthetic isolated PostgreSQL verifier fixtures; not a formal backup restore';provider_calls=0}
    if($Report){$result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $Report}
    $result|ConvertTo-Json -Depth 5
} finally {
    $null=Invoke-RecoverySQL $PostgresBin $admin ('DROP DATABASE '+$database+' WITH (FORCE)')
}
