# Read-only checks against the already restored, isolated database. No source
# retrieval, provider call, retention mutation or original database connection.
function Test-RecoveredKnowledgeArchives([string]$PostgresBin,[hashtable]$Connection) {
    $exists=(Invoke-RecoverySQL $PostgresBin $Connection "SELECT to_regclass('knowledge.artifact_refs') IS NOT NULL;").Trim()
    if($exists -ne 't'){return @{present=$false;manifests=0}}
    $markerJSON=(Invoke-RecoverySQL $PostgresBin $Connection @'
SELECT coalesce(json_agg(m),'[]'::json)::text FROM (
 SELECT r.hash,encode(substring(a.body FROM 1 FOR 257),'hex') body,octet_length(a.body) bytes
 FROM knowledge.artifact_refs r LEFT JOIN knowledge.artifacts a ON a.hash=r.hash
 WHERE r.root='knowledge-protocol:source-archives' ORDER BY r.hash LIMIT 2
) m;
'@).Trim()
    $markers=ConvertFrom-Json -InputObject $markerJSON -AsHashtable -NoEnumerate
    $minimumReader=1
    if($markers -isnot [array] -or $markers.Count -gt 1){throw 'Recovered archive protocol root is invalid.'}
    if($markers.Count -eq 1){
        $bytes=[Text.Encoding]::UTF8.GetBytes('{"format":1,"minimum_reader":2}')
        $marker=$markers[0]
        if($marker.hash -cne (Get-BytesHash $bytes) -or $marker.body -cne [Convert]::ToHexStringLower($bytes) -or $marker.bytes -ne $bytes.Length){throw 'Recovered archive reader requirement is invalid.'}
        $minimumReader=2
    }
    $invalid=(Invoke-RecoverySQL $PostgresBin $Connection @'
SELECT count(*) FROM knowledge.artifact_refs r
LEFT JOIN knowledge.knowledge_files f ON f.id=split_part(r.root,':',2)
LEFT JOIN knowledge.artifacts a ON a.hash=r.hash
WHERE r.root LIKE 'knowledge-source:%' AND
 (r.root !~ '^knowledge-source:[a-f0-9]{32}:(manifests|payloads)$' OR f.id IS NULL OR a.hash IS NULL);
'@).Trim()
    if($invalid -ne '0'){throw 'Recovered source archive root or target is invalid.'}
    $count=0;$after='';$identityDigest=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
    while($true){
        # One archive at a time bounds restored raw material in this verifier.
        $row=(Invoke-RecoverySQL $PostgresBin $Connection ("SELECT json_build_object('root',root,'hash',hash)::text FROM knowledge.artifact_refs WHERE root ~ '^knowledge-source:[a-f0-9]{32}:manifests$' AND root||'/'||hash > '"+$after+"' ORDER BY root,hash LIMIT 1;")).Trim()
        if(-not $row){break}
        $identity=$row|ConvertFrom-Json
        if($identity.root -cnotmatch '^knowledge-source:[a-f0-9]{32}:manifests$' -or $identity.hash -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid recovered archive cursor.'}
        $after=$identity.root+'/'+$identity.hash
        $identityDigest.AppendData([Text.Encoding]::UTF8.GetBytes($after+"`n"))
        $sql=@'
WITH manifest AS (
 SELECT a.body,convert_from(a.body,'UTF8')::jsonb m,convert_from(a.body,'UTF8')::json j FROM knowledge.artifacts a
 WHERE a.hash='{HASH}' AND octet_length(a.body)<=16384 AND encode(sha256(a.body),'hex')=a.hash
), association AS (
 SELECT m,j,raw.body raw,text.body text,d.content document
 FROM manifest
 JOIN knowledge.knowledge_files f ON f.id=m->>'file_id'
 JOIN knowledge.documents d ON d.id=f.document_id
 JOIN knowledge.artifact_refs rr ON rr.root='knowledge-source:'||f.id||':payloads' AND rr.hash=m->>'stored_raw_sha256'
 JOIN knowledge.artifacts raw ON raw.hash=rr.hash
 JOIN knowledge.artifact_refs tr ON tr.root=rr.root AND tr.hash=m->>'text_sha256'
 JOIN knowledge.artifacts text ON text.hash=tr.hash
 WHERE 'knowledge-source:'||f.id||':manifests'='{ROOT}' AND (
  (m->>'format'='1'
   AND m->>'provenance'='operator_imported_archive: URL, capture time and extraction method are submitter assertions; hashes and matching spans verify retention consistency, not raw-to-text derivation, completeness or factual accuracy'
   AND (NOT m ? 'capture' OR m->'capture'='null'::jsonb))
  OR (m->>'format'='2'
   AND m->>'provenance'='sources_service_capture: bytes and metadata were read from an authenticated retained Sources capture; raw is the HTTP client response body after transport/content decoding; hashes and matching spans verify retention consistency, not website authenticity, extraction completeness or factual accuracy; fetched_at is collection time, not publication or statistical period'
   AND jsonb_typeof(m->'capture')='object'
   AND m->'capture'->>'capture_id' ~ '^[a-f0-9]{32}$'
   AND m->'capture'->>'requested_url'=m->>'url'
   AND m->'capture'->>'final_url'=m->>'url'
   AND m->'capture'->>'import_format'='source-capture-document-v1'
   AND m->'capture'->>'extraction_version' IN ('agentos-text-html-v1','unrecorded')
   AND m->>'extraction_method'='Sources extraction: '||(m->'capture'->>'extraction_version')
   AND m->>'raw_encoding'='identity'))
 AND NOT EXISTS (
  SELECT 1 FROM unnest(ARRAY['file_id','document_id','file_sha256','url','captured_at','media_type','extraction_method','raw_sha256','raw_encoding','stored_raw_sha256','text_sha256','provenance']) k
  WHERE jsonb_typeof(m->k) IS DISTINCT FROM 'string')
 AND NOT EXISTS (
  SELECT 1 FROM unnest(ARRAY['format','stored_raw_bytes','raw_bytes','text_bytes']) k
  WHERE jsonb_typeof(m->k) IS DISTINCT FROM 'number' OR (j->k)::text !~ '^(0|[1-9][0-9]*)$')
 AND jsonb_typeof(m->'knowledge')='object' AND jsonb_typeof(m->'knowledge'->'id')='string'
 AND jsonb_typeof(m->'knowledge'->'revision')='number' AND (j->'knowledge'->'revision')::text ~ '^[1-9][0-9]*$'
 AND (m->>'format'='1' OR NOT EXISTS (
  SELECT 1 FROM unnest(ARRAY['capture_id','requested_url','final_url','extraction_version','import_format']) k
  WHERE jsonb_typeof(m->'capture'->k) IS DISTINCT FROM 'string'))
 AND jsonb_typeof(m->'spans')='array' AND NOT EXISTS (
  SELECT 1 FROM json_array_elements(j->'spans') span,unnest(ARRAY['start','end','document_start','document_end']) k
  WHERE json_typeof(span) IS DISTINCT FROM 'object' OR json_typeof(span->k) IS DISTINCT FROM 'number' OR (span->k)::text !~ '^(0|[1-9][0-9]*)$')
 AND m->>'file_sha256'=f.artifact_hash AND m->>'document_id'=f.document_id
 AND m->'knowledge'->>'id'=f.kb_id AND (m->'knowledge'->>'revision')::int=f.kb_revision
 AND octet_length(raw.body) BETWEEN 1 AND 1048576 AND octet_length(raw.body)=(m->>'stored_raw_bytes')::int
 AND encode(sha256(raw.body),'hex')=m->>'stored_raw_sha256'
 AND octet_length(text.body) BETWEEN 1 AND 1048576 AND octet_length(text.body)=(m->>'text_bytes')::int
 AND encode(sha256(text.body),'hex')=m->>'text_sha256'
 AND (m->>'raw_bytes')::int BETWEEN 1 AND 1048576 AND m->>'raw_encoding' IN ('gzip','identity')
 AND m->>'raw_sha256' ~ '^[a-f0-9]{64}$' AND jsonb_array_length(m->'spans') BETWEEN 1 AND 64
)
SELECT json_build_object('format',(m->>'format')::int,'raw',encode(raw,'base64'),'encoding',m->>'raw_encoding','raw_sha256',m->>'raw_sha256','raw_bytes',(m->>'raw_bytes')::int)::text
FROM association WHERE NOT EXISTS (
 SELECT 1 FROM jsonb_array_elements(m->'spans') s WHERE NOT coalesce(
 (s->>'start')::int>=0 AND (s->>'end')::int>(s->>'start')::int AND (s->>'end')::int<=char_length(convert_from(text,'UTF8'))
 AND (s->>'document_start')::int>=0 AND (s->>'document_end')::int>(s->>'document_start')::int AND (s->>'document_end')::int<=char_length(document)
 AND (s->>'end')::int-(s->>'start')::int=(s->>'document_end')::int-(s->>'document_start')::int
 AND substring(convert_from(text,'UTF8') FROM (s->>'start')::int+1 FOR (s->>'end')::int-(s->>'start')::int)=substring(document FROM (s->>'document_start')::int+1 FOR (s->>'document_end')::int-(s->>'document_start')::int),false));
'@
        $sql=$sql.Replace('{HASH}',$identity.hash).Replace('{ROOT}',$identity.root)
        $raw=(Invoke-RecoverySQL $PostgresBin $Connection $sql).Trim()
        if(-not $raw){throw 'Recovered source archive bytes or document association differ.'}
        $archive=$raw|ConvertFrom-Json;$bytes=[Convert]::FromBase64String($archive.raw)
        if($archive.format -gt $minimumReader){throw 'Recovered source archives lack their persistent reader requirement.'}
        if($archive.encoding -eq 'gzip'){
            $input=[IO.MemoryStream]::new($bytes,$false);$gzip=[IO.Compression.GZipStream]::new($input,[IO.Compression.CompressionMode]::Decompress);$output=[IO.MemoryStream]::new()
            try{
                $buffer=[byte[]]::new(8192)
                while(($read=$gzip.Read($buffer,0,$buffer.Length)) -gt 0){if($output.Length+$read -gt 1048576){throw 'Recovered gzip exceeds limit.'};$output.Write($buffer,0,$read)}
                $bytes=$output.ToArray()
            }finally{$gzip.Dispose();$input.Dispose();$output.Dispose()}
        }
        if($bytes.Length -ne $archive.raw_bytes -or (Get-BytesHash $bytes) -cne $archive.raw_sha256){throw 'Recovered expanded source bytes differ.'}
        $count++
    }
    $identityHash=[Convert]::ToHexStringLower($identityDigest.GetHashAndReset())
    return @{present=$true;manifests=$count;identity_sha256=$identityHash;member_hashes_and_lengths=$true;gzip_expansion=$true;file_document_revision_and_spans=$true;versioned_provenance=$true;minimum_reader=$minimumReader;provider_calls=0}
    } finally {$identityDigest.Dispose()}
}
