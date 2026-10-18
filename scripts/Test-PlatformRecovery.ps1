param(
    [Parameter(Mandatory)][string]$BackupDirectory,
    [string]$PostgresBin='D:\workspace\.tools\postgresql\pgsql\bin',
    [string]$Pnpm='pnpm'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
. (Join-Path $PSScriptRoot 'lib/knowledge-archive-recovery.ps1')
$BackupDirectory=[IO.Path]::GetFullPath($BackupDirectory)
$manifestPath=Join-Path $BackupDirectory 'manifest.json'
$expected=[Text.Encoding]::UTF8.GetString((Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $BackupDirectory 'manifest-digest.dpapi')))))
if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLower() -ne $expected){throw 'Backup manifest integrity check failed.'}
$manifest=Read-RecoveryJson $manifestPath
if($manifest.status -ne 'captured_not_restore_verified'){throw 'Backup capture is not complete.'}
foreach($item in $manifest.files){
    $file=[IO.Path]::GetFullPath((Join-Path $BackupDirectory $item.path))
    if(-not $file.StartsWith($BackupDirectory+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Backup contains an out-of-root file path.'}
    if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower() -ne $item.sha256){throw ('Backup file integrity mismatch: '+$item.path)}
}
$vaultBytes=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $BackupDirectory 'configuration.dpapi')))
try{$vault=[Text.Encoding]::UTF8.GetString($vaultBytes)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($vaultBytes,0,$vaultBytes.Length)}
$configs=@{}
foreach($relative in $vault.configuration_files.Keys){
    if($relative -ne 'dev.json' -and $relative -notmatch '^services/[a-z-]+\.json$'){throw 'Unexpected protected configuration path.'}
    $configs[$relative]=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($vault.configuration_files[$relative]))|ConvertFrom-Json -AsHashtable
}
$identifier=[guid]::NewGuid().ToString('N')
$verificationRoot=[IO.Path]::GetFullPath('D:\workspace\agent-platform\local\restore-checks\'+$identifier)
New-ProtectedDirectory $verificationRoot
$data=Join-Path $verificationRoot 'postgres'
$passwordFile=Join-Path $verificationRoot 'bootstrap-password.tmp'
$password=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
[IO.File]::WriteAllText($passwordFile,$password,[Text.UTF8Encoding]::new($false))
$adminName='agentos_restore_'+$identifier.Substring(0,12)
$server=$null;$stopped=$false;$cleanupFailed=$false
$report=@{format=1;started_at=[datetime]::UtcNow.ToString('o');backup_manifest_sha256=$expected;status='incomplete';databases=@();role_logins=@();credential_decryptions=0;provider_calls=0;workers_started=0;isolated_cluster=$true;configuration_roundtrip=$true}
try {
    if($manifest.ContainsKey('complete_release_archive')){
        $report.complete_release_archive=Restore-ReleaseCatalog (Join-Path $BackupDirectory 'release-catalog') (Join-Path $verificationRoot 'releases')
        $restoredLayout=@{release_root=(Join-Path $verificationRoot 'releases')}
        $report.archived_worker_bundle_checks=@()
        foreach($reference in (Get-ReleaseReferences (Read-ReleaseCatalog $restoredLayout))){
            $descriptor=Read-ReleaseDescriptor $restoredLayout $reference
            if($descriptor.role -ne 'worker'){continue}
            $archivedNode=Resolve-ReleasePath $restoredLayout.release_root $descriptor.assets.node
            $archivedHarness=Resolve-ReleasePath $restoredLayout.release_root $descriptor.assets.harness
            & $archivedNode --test (Join-Path $archivedHarness 'session-seams.test.mjs')
            if($LASTEXITCODE){throw 'A retained Worker dependency bundle failed after restoration.'}
            $report.archived_worker_bundle_checks+=@{id=$reference.id;passed=$true}
        }
    }
    $null=Invoke-PostgresTool -PostgresBin $PostgresBin -Tool initdb -Arguments @('-D',$data,'--username',$adminName,'--pwfile',$passwordFile,'--encoding=UTF8','--locale=C','--auth-host=scram-sha-256','--auth-local=scram-sha-256')
    Remove-Item -LiteralPath $passwordFile
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $server=Start-Process -FilePath (Join-Path $PostgresBin 'postgres.exe') -ArgumentList @('-D',('"'+$data+'"'),'-h','127.0.0.1','-p',[string]$port,'-c','shared_buffers=32MB','-c','max_connections=12') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $verificationRoot 'postgres.stdout.log') -RedirectStandardError (Join-Path $verificationRoot 'postgres.stderr.log')
    $connection=@{host='127.0.0.1';port=$port;database='postgres';user=$adminName;password=$password}
    $ready=$false
    for($attempt=0;$attempt -lt 60;$attempt++){
        if($server.HasExited){throw 'Isolated PostgreSQL stopped during startup.'}
        $socket=@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue|Where-Object OwningProcess -eq $server.Id)
        if($socket.Count){try{$actual=(Invoke-RecoverySQL $PostgresBin $connection 'SHOW data_directory;').Trim();if([IO.Path]::GetFullPath($actual) -eq [IO.Path]::GetFullPath($data)){$ready=$true;break}}catch{}}
        Start-Sleep -Milliseconds 200
    }
    if(-not $ready){throw 'Cannot verify ownership and readiness of isolated PostgreSQL.'}
    $null=Invoke-RecoverySQL $PostgresBin $connection $vault.roles_sql
    foreach($database in $manifest.databases){
        $target=$connection.Clone();$target.database=$database.name
        $dump=[IO.Path]::GetFullPath((Join-Path $BackupDirectory $database.dump))
        if(-not $dump.StartsWith($BackupDirectory+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Dump path escapes backup root.'}
        $null=Invoke-PostgresTool -PostgresBin $PostgresBin -Tool pg_restore -Connection $connection -Arguments @('-w','--exit-on-error','--create','-d','postgres',$dump)
        if((Get-DatabaseMetadata $PostgresBin $target) -cne $database.metadata){throw 'Restored database ownership, permissions or settings differ.'}
        $schemaVerification=Test-RecoveryDatabaseSchema $PostgresBin $target $database.schema_sha256
        if(-not $schemaVerification.matched){throw 'Restored schema or object permissions differ.'}
        $fingerprints=Get-DatabaseFingerprints $PostgresBin $target
        $expectedTables=@($database.tables)
        if($fingerprints.Count -ne $expectedTables.Count){throw 'Restored relation count differs.'}
        for($i=0;$i -lt $expectedTables.Count;$i++){
            foreach($key in @('schema','table','kind','rows','sha256')){if([string]$fingerprints[$i].$key -cne [string]$expectedTables[$i][$key]){throw ('Restored content differs: '+$expectedTables[$i].schema+'.'+$expectedTables[$i].table)}}
        }
        $archives=Test-RecoveredKnowledgeArchives $PostgresBin $target
        $report.databases+=@{name=$database.name;relations=$fingerprints.Count;all_fingerprints_match=$true;metadata_match=$true;schema_and_acl_match=$true;schema_verification=$schemaVerification;source_archives=$archives}
        Write-Output ('Restored database with '+$fingerprints.Count+' matching table/sequence fingerprints.')
    }
    foreach($relative in $configs.Keys){
        $config=$configs[$relative]
        if($relative -eq 'dev.json' -or -not $config.ContainsKey('DATABASE_URL')){continue}
        $original=Get-DatabaseConnection $config.DATABASE_URL
        $login=$original.Clone();$login.host='127.0.0.1';$login.port=$port
        $actual=(Invoke-RecoverySQL $PostgresBin $login 'SELECT current_user;').Trim()
        if($actual -cne $original.user){throw 'A restored service identity cannot authenticate.'}
        $report.role_logins+=@{role=[IO.Path]::GetFileNameWithoutExtension($relative);authenticated=$true}
    }
    $report.identity_index_verified=$false
    if($configs.ContainsKey('services/identities.json')){
        $identities=$configs['services/identities.json']
        foreach($role in @('registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','telemetry','sources','control','futures')){
            if(-not $identities.ContainsKey($role) -or $identities[$role] -cne $configs['services/'+$role+'.json'].SERVICE_TOKEN){throw 'Recovered identity index differs from the service configurations.'}
        }
        $report.identity_index_verified=$true
    }
    $registry=$configs['services/registry.json']
    $registryDb=Get-DatabaseConnection $registry.DATABASE_URL
    $registryDb.host='127.0.0.1';$registryDb.port=$port
    $sealedRows=Invoke-RecoverySQL $PostgresBin $registryDb "SELECT json_build_object('name',name,'sealed',encode(sealed,'base64'))::text FROM public.secrets ORDER BY name;"
    if(-not $registry.ContainsKey('MASTER_KEY')){throw 'Registry master key is absent from the recovered configuration.'}
    $key=[Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($registry.MASTER_KEY))
    $aes=[Security.Cryptography.AesGcm]::new($key,16)
    try{
        foreach($line in $sealedRows.Split("`n",[StringSplitOptions]::RemoveEmptyEntries)){
            $row=$line|ConvertFrom-Json;$sealed=[Convert]::FromBase64String($row.sealed)
            if($sealed.Length -lt 28){throw 'Restored sealed credential is malformed.'}
            $nonce=$sealed[0..11];$cipherLength=$sealed.Length-28;$cipher=$sealed[12..(11+$cipherLength)];$tag=$sealed[($sealed.Length-16)..($sealed.Length-1)]
            $plain=[byte[]]::new($cipherLength)
            try{$aes.Decrypt([byte[]]$nonce,[byte[]]$cipher,[byte[]]$tag,$plain,[Text.Encoding]::UTF8.GetBytes($row.name));$report.credential_decryptions++}finally{[Array]::Clear($plain,0,$plain.Length)}
        }
    }finally{$aes.Dispose();[Array]::Clear($key,0,$key.Length)}
    # Reconstruct dependencies in a fresh folder entirely from the retained store.
    $harness=Join-Path $verificationRoot 'harness';$null=New-Item -ItemType Directory -Path $harness
    foreach($name in @('package.json','pnpm-lock.yaml','runner.mjs','session-seams.test.mjs')){Copy-Item -LiteralPath (Join-Path $BackupDirectory ('harness/'+$name)) -Destination (Join-Path $harness $name)}
    & $Pnpm --dir $harness install --offline --frozen-lockfile --ignore-scripts --prod --store-dir (Join-Path $BackupDirectory 'pnpm-store')
    if($LASTEXITCODE -ne 0){throw 'Offline Harness reconstruction failed.'}
    & (Join-Path $BackupDirectory 'releases/node.exe') --test (Join-Path $harness 'session-seams.test.mjs')
    if($LASTEXITCODE -ne 0){throw 'Retained Node and reconstructed Harness failed interface checks.'}
    $report.harness_offline_reconstructed=$true;$report.status='passed';$report.completed_at=[datetime]::UtcNow.ToString('o')
}catch{$report.status='failed';$report.failure='Restoration verification failed; original platform was not modified.';throw}
finally{
    if($server -and -not $server.HasExited){
        try{$null=Invoke-PostgresTool -PostgresBin $PostgresBin -Tool pg_ctl -Arguments @('-D',$data,'-m','fast','-w','-t','20','stop');$stopped=$true}catch{$cleanupFailed=$true;$report.status='cleanup_failed';$report.cleanup='isolated server still needs inspection';Write-Warning 'Could not confirm isolated PostgreSQL shutdown.'}
    }elseif($server){$stopped=$true}
    if(Test-Path -LiteralPath $passwordFile){Remove-Item -LiteralPath $passwordFile}
    $report.isolated_cluster_stopped=$stopped
    $report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $verificationRoot 'result.json') -Encoding utf8
    Write-Output ('Verification evidence: '+(Join-Path $verificationRoot 'result.json'))
    # Keep the protected, stopped verification cluster for inspection. Retention
    # cleanup is a separate, explicit operation, never recursive deletion here.
}
if($cleanupFailed){throw 'Restore checks finished, but isolated server cleanup failed; verification is incomplete.'}
