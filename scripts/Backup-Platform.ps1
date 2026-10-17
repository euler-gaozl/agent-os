param(
    [string]$ProjectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')),
    [string]$StateRoot='',
    [Parameter(Mandatory)][string]$Destination,
    [string]$PostgresBin='',
    [string]$Pnpm='pnpm',
    [string]$LayoutPath='',
    [IO.FileStream]$MaintenanceLock=$null
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
$ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot)
$layout=Get-PlatformLayout $ProjectRoot $LayoutPath
if(-not $PostgresBin){$PostgresBin=$layout.postgres_bin}
if(-not $StateRoot){$StateRoot=$layout.state_root}
$configRoot=if($layout.layout_path){$layout.config_root}else{$StateRoot}
$StateRoot=[IO.Path]::GetFullPath($StateRoot)
$layout.state_root=$StateRoot
$Destination=[IO.Path]::GetFullPath($Destination)
if(-not $Destination.StartsWith('D:\workspace\agent-platform\local\backups\',[StringComparison]::OrdinalIgnoreCase)){throw 'Coordinated backups must remain under D:\workspace\agent-platform\local\backups.'}
$maintenance=Enter-PlatformMaintenance $StateRoot $MaintenanceLock
try {
Assert-NoPendingRelease (Read-ReleaseCatalog $layout)
Assert-NoPendingOwnerMigration $layout
Assert-AllDeploymentsQuiescent $layout
$admin=Read-RecoveryJson (Join-Path $configRoot 'dev.json')
$adminConnection=Get-DatabaseConnection $admin.DATABASE_URL
$serviceNames=@('registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','telemetry','sources','control','futures')
$configs=@{};$configFiles=@{};$databaseNames=@{}
foreach($name in $serviceNames){
    $relative='services/'+$name+'.json';$path=Join-Path $configRoot $relative
    if(-not(Test-Path -LiteralPath $path)){throw ('Missing service configuration: '+$name)}
    $configs[$name]=Read-RecoveryJson $path
    $configFiles[$relative]=[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
    if($configs[$name].ContainsKey('DATABASE_URL')){
        $connection=Get-DatabaseConnection $configs[$name].DATABASE_URL
        if($connection.host -ne $adminConnection.host -or $connection.port -ne $adminConnection.port){throw 'A service uses another PostgreSQL cluster. Supply an explicit admin connection per cluster before backing up; no incomplete backup was created.'}
        $databaseNames[$connection.database]=$true
    }
}
$configFiles['dev.json']=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $configRoot 'dev.json')))
$identitiesPath=Join-Path $configRoot 'services/identities.json'
$identities=Read-RecoveryJson $identitiesPath
foreach($name in $serviceNames){if(-not $identities.ContainsKey($name) -or $identities[$name] -cne $configs[$name].SERVICE_TOKEN){throw 'Service identity index differs from its active service configuration.'}}
$configFiles['services/identities.json']=[Convert]::ToBase64String([IO.File]::ReadAllBytes($identitiesPath))
$identities=$null
New-ProtectedDirectory $Destination
$manifest=@{format=1;status='incomplete';created_at=[datetime]::UtcNow.ToString('o');source_root=$ProjectRoot;source_layout=$layout;vault_protection='Windows DPAPI CurrentUser; same user profile required';databases=@();files=@();quiescence='all owned service processes stopped';external_writes_during_restore='forbidden'}
$manifestPath=Join-Path $Destination 'manifest.json'
function Write-Manifest { $manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding utf8 }
function Add-BackupFile([string]$Relative){$path=Join-Path $Destination $Relative;$manifest.files+=@{path=$Relative;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower();bytes=(Get-Item -LiteralPath $path).Length}}
Write-Manifest
try {
    Assert-NoDatabaseClients $PostgresBin $adminConnection @($databaseNames.Keys)
    $initial=@{}
    foreach($database in $databaseNames.Keys|Sort-Object){
        $connection=$adminConnection.Clone();$connection.database=$database
        $initial[$database]=@{tables=(Get-DatabaseFingerprints $PostgresBin $connection);metadata=(Get-DatabaseMetadata $PostgresBin $connection);schema_sha256=(Get-DatabaseSchemaHash $PostgresBin $connection)}
    }
    $roles=Invoke-PostgresTool -PostgresBin $PostgresBin -Tool pg_dumpall -Connection $adminConnection -Arguments @('-w','--roles-only')
    $vault=@{format=1;configuration_files=$configFiles;roles_sql=$roles}
    $plain=[Text.Encoding]::UTF8.GetBytes(($vault|ConvertTo-Json -Depth 6 -Compress))
    try{
        $sealed=Protect-RecoveryBytes $plain
        $check=Unprotect-RecoveryBytes $sealed
        try{if((Get-BytesHash $plain) -ne (Get-BytesHash $check)){throw 'Protected configuration roundtrip mismatch.'}}finally{[Array]::Clear($check,0,$check.Length)}
        [IO.File]::WriteAllBytes((Join-Path $Destination 'configuration.dpapi'),$sealed)
    }finally{[Array]::Clear($plain,0,$plain.Length)}
    Add-BackupFile 'configuration.dpapi';$roles=$null;$vault=$null;$configFiles=$null
    $number=0
    foreach($database in $databaseNames.Keys|Sort-Object){
        $number++;$connection=$adminConnection.Clone();$connection.database=$database
        $dump='database-'+$number+'.dump'
        $before=$initial[$database].tables
        $null=Invoke-PostgresTool -PostgresBin $PostgresBin -Tool pg_dump -Connection $connection -Arguments @('-w','--format=custom','--file',(Join-Path $Destination $dump),'-d',$database)
        $null=Invoke-PostgresTool -PostgresBin $PostgresBin -Tool pg_restore -Arguments @('--list',(Join-Path $Destination $dump))
        $after=Get-DatabaseFingerprints $PostgresBin $connection
        if(($before|ConvertTo-Json -Depth 5 -Compress) -ne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'Database changed during the stopped-service backup; backup remains incomplete.'}
        $manifest.databases+=@{name=$database;dump=$dump;tables=$before;metadata=$initial[$database].metadata;schema_sha256=$initial[$database].schema_sha256}
        Add-BackupFile $dump;Write-Manifest
        Write-Output ('Captured database '+$number+' with '+$before.Count+' verified table fingerprints.')
    }
    $releaseDirectory=Join-Path $Destination 'releases';$null=New-Item -ItemType Directory -Path $releaseDirectory
    $catalog=Read-ReleaseCatalog $layout
    $roles=if($catalog.format -eq 2){$catalog.services.Keys}else{$catalog.legacy.Keys}
    foreach($role in $roles|Sort-Object){
        $binary=(Get-PlatformRelease $layout $role -Verify).assets.binary
        $relative='releases/'+$role+'.exe';Copy-Item -LiteralPath $binary -Destination (Join-Path $Destination $relative);Add-BackupFile $relative
    }
    if($catalog.format -eq 2){
        $manifest.complete_release_archive=Export-ReleaseCatalog $layout (Join-Path $Destination 'release-catalog')
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $Destination 'release-catalog') -File -Recurse){Add-BackupFile ([IO.Path]::GetRelativePath($Destination,$file.FullName).Replace('\','/'))}
    }
    $workerRelease=Get-PlatformRelease $layout worker -Verify
    $runnerRoot=Join-Path $Destination 'harness';$null=New-Item -ItemType Directory -Path $runnerRoot
    foreach($name in @('runner.mjs','package.json','pnpm-lock.yaml','session-seams.test.mjs')){Copy-Item -LiteralPath (Join-Path $workerRelease.assets.harness $name) -Destination (Join-Path $runnerRoot $name);Add-BackupFile ('harness/'+$name)}
    $node=$workerRelease.assets.node
    Copy-Item -LiteralPath $node -Destination (Join-Path $Destination 'releases/node.exe');Add-BackupFile 'releases/node.exe'
    foreach($ui in @('dist','dist-futures')){
        $target=Join-Path $Destination ('web/'+$ui);$null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
        $uiRole=if($ui -eq 'dist'){'control'}else{'futures'}
        $source=(Get-PlatformRelease $layout $uiRole -Verify).assets.web
        Copy-Item -LiteralPath $source -Destination $target -Recurse
        foreach($file in Get-ChildItem -LiteralPath $target -File -Recurse){Add-BackupFile ([IO.Path]::GetRelativePath($Destination,$file.FullName).Replace('\','/'))}
    }
    # Build a dedicated offline package store; do not rely on node_modules links
    # pointing back into the original project or the global package cache.
    $store=Join-Path $Destination 'pnpm-store'
    & $Pnpm --dir $runnerRoot fetch --prod --frozen-lockfile --ignore-scripts --store-dir $store
    if($LASTEXITCODE -ne 0){throw 'Cannot retain offline Harness dependencies; backup remains incomplete.'}
    foreach($file in Get-ChildItem -LiteralPath $store -File -Recurse){Add-BackupFile ([IO.Path]::GetRelativePath($Destination,$file.FullName).Replace('\','/'))}
    Assert-AllDeploymentsQuiescent $layout
    Assert-NoDatabaseClients $PostgresBin $adminConnection @($databaseNames.Keys)
    # Recheck every database against the common pre-capture baseline, including
    # databases captured earlier. Managed start/migrate/build hold this same lock.
    foreach($database in $databaseNames.Keys|Sort-Object){
        $connection=$adminConnection.Clone();$connection.database=$database
        $final=@{tables=(Get-DatabaseFingerprints $PostgresBin $connection);metadata=(Get-DatabaseMetadata $PostgresBin $connection);schema_sha256=(Get-DatabaseSchemaHash $PostgresBin $connection)}
        foreach($field in @('tables','metadata','schema_sha256')){
            if(($initial[$database][$field]|ConvertTo-Json -Depth 6 -Compress) -cne ($final[$field]|ConvertTo-Json -Depth 6 -Compress)){throw 'Coordinated baseline changed; backup remains incomplete.'}
        }
    }
    $manifest.status='captured_not_restore_verified';$manifest.completed_at=[datetime]::UtcNow.ToString('o');Write-Manifest
    [IO.File]::WriteAllBytes((Join-Path $Destination 'manifest-digest.dpapi'),(Protect-RecoveryBytes ([Text.Encoding]::UTF8.GetBytes((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLower()))))
    Write-Output ('Coordinated backup captured: '+$Destination)
    Write-Output 'A clean PostgreSQL cluster restore and credential/dependency checks are still required.'
}catch{
    $manifest.status='failed';$manifest.failure='Backup did not complete; do not use as a verified restoration point.';Write-Manifest
    throw
}
} finally {if($maintenance){$maintenance.Dispose()}}
