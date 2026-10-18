# Knowledge owns this protocol. The Windows manager reads only its fixed
# compatibility metadata with the bound Knowledge account, never business rows.
function Assert-KnowledgeArchiveDescriptor([System.Collections.IDictionary]$Descriptor){
    if(-not $Descriptor.Contains('source_archives')){
        if($Descriptor.role -ceq 'knowledge' -and $Descriptor['contract'] -and $Descriptor.contract.data -ceq 'knowledge-v0.7-source-archives'){throw 'New Knowledge data contract lacks archive capabilities.'}
        return
    }
    $v=$Descriptor.source_archives
    if($Descriptor.role -cne 'knowledge' -or $v -isnot [System.Collections.IDictionary] -or $v.Count -ne 3){throw 'Invalid Knowledge archive capability.'}
    foreach($key in @('format','reader','writer')){if(-not $v.Contains($key) -or ($v[$key] -isnot [int] -and $v[$key] -isnot [long])){throw 'Invalid Knowledge archive capability type.'}}
    if($v.format -ne 1 -or $v.reader -ne 2 -or $v.writer -notin @(1,2)){throw 'Unknown Knowledge archive capability.'}
    if($Descriptor['contract']){
        $expected=if($v.writer -eq 1){'knowledge-v0.6'}else{'knowledge-v0.7-source-archives'}
        if($Descriptor.contract.data -cne $expected){throw 'Knowledge writer/data contract differs.'}
    }
}
function Get-DeclaredKnowledgeArchives([System.Collections.IDictionary]$Release){
    Assert-KnowledgeArchiveDescriptor $Release
    if($Release.Contains('source_archives')){return $Release.source_archives}
    return $null
}
function Assert-KnowledgeArchiveBinary([string]$Binary,[System.Collections.IDictionary]$Descriptor){
    Assert-KnowledgeArchiveDescriptor $Descriptor
    if(-not $Descriptor.Contains('source_archives')){return}
    try{$actual=(Invoke-ExecutionAccessProbe $Binary @('--source-archive-profile')).Trim()|ConvertFrom-Json -AsHashtable -NoEnumerate}catch{throw 'Knowledge binary cannot attest its archive capability.'}
    Assert-KnowledgeArchiveDescriptor @{role='knowledge';source_archives=$actual}
    foreach($key in @('format','reader','writer')){if($actual[$key] -ne $Descriptor.source_archives[$key]){throw 'Knowledge binary archive capability differs from its descriptor.'}}
}
function Assert-KnowledgeArchivePair([System.Collections.IDictionary]$Previous,[System.Collections.IDictionary]$Next){
    foreach($d in @($Previous,$Next)){Assert-KnowledgeArchiveDescriptor $d}
    if($Previous.role -cne 'knowledge'){return}
    $old=if($Previous.Contains('source_archives')){$Previous.source_archives}else{@{reader=1;writer=1}}
    $new=if($Next.Contains('source_archives')){$Next.source_archives}else{@{reader=1;writer=1}}
    if($old.reader -lt $new.writer -or $new.reader -lt $old.writer){throw 'Knowledge writer needs a format-2 reader as both target and recovery release. Install the reader bridge first.'}
}
function Test-KnowledgeArchiveTransition([System.Collections.IDictionary]$Previous,[System.Collections.IDictionary]$Next){
    if($Previous.role -cne 'knowledge' -or $Next.role -cne 'knowledge'){return $false}
    Assert-KnowledgeArchivePair $Previous $Next
    if(-not $Previous.Contains('source_archives') -or -not $Next.Contains('source_archives')){return $false}
    if(@($Previous.contract.data,$Next.contract.data|Sort-Object -Unique).Count -ne 2){return $false}
    if($Previous.contract.data -cnotin @('knowledge-v0.6','knowledge-v0.7-source-archives') -or $Next.contract.data -cnotin @('knowledge-v0.6','knowledge-v0.7-source-archives')){return $false}
    $normalized=@{http=$Next.contract.http;data=$Previous.contract.data;engines=$Next.contract.engines;tools=$Next.contract.tools}
    return (Get-ContractIdentity $Previous.contract) -ceq (Get-ContractIdentity $normalized)
}
function Get-BoundKnowledgeArchiveConfiguration([hashtable]$Layout,[System.Collections.IDictionary]$Catalog){
    . (Join-Path $PSScriptRoot 'platform-processes.ps1')
    if(-not $Catalog.services.Contains('knowledge')){throw 'Knowledge configuration is not registered.'}
    $deployment=$Catalog.services.knowledge
    if($deployment['pending'] -and $deployment.pending['configuration']){throw 'Unreviewed pending Knowledge configuration migration.'}
    $bytes=[IO.File]::ReadAllBytes((Join-Path $Layout.config_root 'services/knowledge.json'))
    try{
        $hash=[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($bytes))
        if($deployment.current['config_sha256'] -cne $hash){throw 'Knowledge configuration differs from its registered deployment.'}
        $config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable
    }finally{[Array]::Clear($bytes,0,$bytes.Length)}
    $allowed=@($deployment.current)
    if($deployment['pending']){$allowed+=@($deployment.pending.prior,$deployment.pending.target)}
    foreach($entry in @((Read-PlatformProcesses $Layout)|Where-Object role -eq 'knowledge')){
        $state=Get-PlatformInstanceState $entry $Layout
        if($state.requires_stop -or (-not $state.process -and $state.members.Count)){throw 'Knowledge process ownership is unresolved.'}
        if(-not $state.process){continue}
        if(-not $entry['job_name'] -or -not $entry['launch_config'] -or $entry['source_config_sha256'] -cne $hash){throw 'Live Knowledge configuration is not bound to its deployment.'}
        $reference=@($allowed|Where-Object{$entry['release_reference'] -and $_.id -ceq $entry.release_reference.id})
        if($reference.Count -eq 0){throw 'Live Knowledge does not belong to its registered deployment.'}
        $descriptor=Read-ReleaseDescriptor $Layout $reference[0] -Verify
        if($entry.binary -ne (Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary)){throw 'Live Knowledge binary differs from its deployment.'}
        $launch=Read-ReleaseJson $entry.launch_config
        try{if([string]$launch['DATABASE_URL'] -cne [string]$config['DATABASE_URL']){throw 'Live Knowledge database differs from its bound configuration.'}}finally{$launch=$null}
    }
    return $config
}
function Get-KnowledgeArchiveFacts([hashtable]$Layout,[System.Collections.IDictionary]$Configuration,[switch]$Stopped){
    $connection=Get-ExecutionAccessConnection $Configuration
    if($connection.schema -cne 'knowledge'){throw 'Archive compatibility requires the Knowledge schema.'}
    $sql=@'
BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY;
SET LOCAL statement_timeout='5000';
SET LOCAL search_path=pg_catalog;
__QUIESCENCE__
WITH marker AS MATERIALIZED (
 SELECT r.hash,encode(substring(a.body FROM 1 FOR 257),'hex') body,octet_length(a.body) bytes
 FROM knowledge.artifact_refs r LEFT JOIN knowledge.artifacts a ON a.hash=r.hash
 WHERE r.root='knowledge-protocol:source-archives' ORDER BY r.hash LIMIT 2
), manifests AS MATERIALIZED (
 SELECT CASE WHEN a.body IS NULL OR octet_length(a.body)>16384 OR encode(sha256(a.body),'hex')<>a.hash THEN 'invalid'
 ELSE (convert_from(a.body,'UTF8')::json->'format')::text END format
 FROM knowledge.artifact_refs r LEFT JOIN knowledge.artifacts a ON a.hash=r.hash
 WHERE r.root >= 'knowledge-source:' AND r.root < 'knowledge-source;' AND r.root ~ '^knowledge-source:[a-f0-9]{32}:manifests$'
)
SELECT json_build_object('format',1,'database',current_database(),'login',session_user,'effective_login',current_user,
 'leaf_identity',(SELECT NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls OR rolreplication)
 AND NOT EXISTS(SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid) FROM pg_roles r WHERE rolname=current_user),
 'markers',(SELECT coalesce(json_agg(marker),'[]'::json) FROM marker),
 'has_format2',EXISTS(SELECT 1 FROM manifests WHERE format='2'),
 'invalid_manifest',EXISTS(SELECT 1 FROM manifests WHERE format IS NULL OR format NOT IN ('1','2')))::text;
COMMIT;
'@
    # A dead Windows client can leave its PostgreSQL backend finishing COMMIT.
    # After all managed instances stop, wait for this LOGIN's other backends;
    # the following statement then takes a NEW READ COMMITTED data snapshot.
    # Never kill a backend or assume that a lost reply means a rolled-back write.
    $quiescence=if($Stopped){@'
DO $quiescence$
DECLARE deadline timestamptz := clock_timestamp()+interval '4 seconds';
BEGIN
 LOOP
  PERFORM pg_stat_clear_snapshot();
  EXIT WHEN NOT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND usename=session_user AND pid<>pg_backend_pid());
  IF clock_timestamp()>=deadline THEN RAISE EXCEPTION 'Knowledge database sessions are still active'; END IF;
  PERFORM pg_sleep(0.05);
 END LOOP;
END $quiescence$;
'@}else{''}
    $sql=$sql.Replace('__QUIESCENCE__',$quiescence)
    try{
        $arguments=@('-X','-w','-h',$connection.host,'-p',[string]$connection.port,'-U',$connection.user,'-d',$connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-')
        $facts=(Invoke-ExecutionAccessProbe (Join-Path $Layout.postgres_bin 'psql.exe') $arguments $sql $connection).Trim()|ConvertFrom-Json -AsHashtable
        if($facts.database -cne $connection.database -or $facts.login -cne $connection.user -or $facts.effective_login -cne $connection.user){throw 'Archive probe database/login differs from the bound configuration.'}
        return $facts
    }finally{$connection=$null}
}
function Get-KnowledgeArchiveRequirement([System.Collections.IDictionary]$Facts){
    if(($Facts['format'] -isnot [int] -and $Facts['format'] -isnot [long]) -or $Facts.format -ne 1){throw 'Invalid archive facts version.'}
    foreach($key in @('leaf_identity','has_format2','invalid_manifest')){if(-not $Facts.Contains($key) -or $Facts[$key] -isnot [bool]){throw 'Invalid archive facts type.'}}
    if(-not $Facts.leaf_identity -or $Facts.invalid_manifest){throw 'Archive compatibility rejects privileged identity or unknown/corrupt retained format.'}
    if(-not $Facts.Contains('markers') -or $Facts.markers -isnot [array] -or $Facts.markers.Count -gt 1){throw 'Invalid archive reader requirement root.'}
    if($Facts.markers.Count -eq 0){
        if($Facts.has_format2){throw 'Format 2 source archive exists without its persistent reader requirement.'}
        return 1
    }
    $marker=$Facts.markers[0]
    $bytes=[Text.Encoding]::UTF8.GetBytes('{"format":1,"minimum_reader":2}')
    $hash=[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($bytes));$body=[Convert]::ToHexStringLower($bytes)
    if($marker -isnot [System.Collections.IDictionary] -or $marker.Count -ne 3 -or $marker.hash -cne $hash -or $marker.body -cne $body -or ($marker.bytes -isnot [int] -and $marker.bytes -isnot [long]) -or $marker.bytes -ne $bytes.Length){throw 'Archive reader requirement marker is corrupt or unknown.'}
    return 2
}
function Assert-KnowledgeArchiveDeployment([hashtable]$Layout,[System.Collections.IDictionary]$Target=$null,[switch]$Stopped){
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -ne 2){throw 'Archive compatibility requires a versioned catalog.'}
    $descriptor=if($Target){$Target}else{Read-ReleaseDescriptor $Layout $catalog.services.knowledge.current -Verify}
    if($descriptor.role -cne 'knowledge'){throw 'Archive compatibility target is not Knowledge.'}
    Assert-KnowledgeArchiveDescriptor $descriptor
    $config=Get-BoundKnowledgeArchiveConfiguration $Layout $catalog
    try{
        $live=@((Read-PlatformProcesses $Layout)|Where-Object { $_.role -eq 'knowledge' -and (Get-PlatformInstanceState $_ $Layout).process })
        if($Stopped -and $live.Count){throw 'Knowledge instances are still running after stop.'}
        # Cold starts and zero-replica operations also need the backend barrier.
        $facts=Get-KnowledgeArchiveFacts $Layout $config -Stopped:($Stopped -or $live.Count -eq 0)
        $required=Get-KnowledgeArchiveRequirement $facts
        $reader=if($descriptor.Contains('source_archives')){$descriptor.source_archives.reader}else{1}
        if($reader -lt $required){throw 'Retained source archives require reader 2; this Knowledge start or rollback is refused.'}
        Assert-KnowledgeArchiveBinary (Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary) $descriptor
    }finally{$config=$null}
}
