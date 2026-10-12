param(
    [string]$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')),
    [string]$StateRoot = '',
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$LayoutPath=''
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
$layout=Get-PlatformLayout $ProjectRoot $LayoutPath
if (-not $StateRoot) { $StateRoot = $layout.state_root }
$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$configRoot=if($layout.layout_path){$layout.config_root}else{$StateRoot}
$groups = @{}
$files = @()
$missing = @()
$roles = @('registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','telemetry','sources','control','futures')
foreach ($role in $roles) {
    $configPath = Join-Path $configRoot ('services/' + $role + '.json')
    if (-not (Test-Path -LiteralPath $configPath)) { $missing += $role; continue }
    # Config values remain in memory only. Never emit parsed objects or DSNs.
    try { $config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json }
    catch { throw ('Invalid configuration JSON for ' + $role) }
    $files += [pscustomobject]@{role=$role;path=$configPath;sha256=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLower();contains_master_key=[bool]$config.MASTER_KEY;protected_copy_verified=$false}
    if (-not $config.DATABASE_URL) { continue }
    try { $uri=[uri]$config.DATABASE_URL;if($uri.Scheme -notin @('postgres','postgresql') -or -not $uri.Host){throw 'invalid'} }
    catch { throw ('Unsupported database configuration for ' + $role + '; no connection string was printed.') }
    $port=if($uri.Port -lt 1){5432}else{$uri.Port}
    $database=[uri]::UnescapeDataString($uri.AbsolutePath.TrimStart('/'))
    $identity=$uri.Host.ToLower()+':'+$port+'/'+$database
    if (-not $groups.ContainsKey($identity)) {
        $groups[$identity]=[pscustomobject]@{host=$uri.Host;port=$port;database=$database;roles=@();backup_status='required';restore_status='not_verified';consistency='stop all platform writes before the coordinated backup'}
    }
    $groups[$identity].roles += $role
}
$adminPath=Join-Path $configRoot 'dev.json'
$identityPath=Join-Path $configRoot 'services/identities.json'
if(Test-Path -LiteralPath $identityPath){$files += [pscustomobject]@{role='identity-index';path=$identityPath;sha256=(Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash.ToLower();protected_copy_verified=$false}}else{$missing+='identity-index'}
if(Test-Path -LiteralPath $adminPath){$files += [pscustomobject]@{role='bootstrap-admin';path=$adminPath;sha256=(Get-FileHash -LiteralPath $adminPath -Algorithm SHA256).Hash.ToLower();protected_copy_verified=$false}}
$indexPath=Join-Path $layout.release_root 'current.json'
$releases=@()
$catalog=@{format=1;legacy=@{}}
if(Test-Path -LiteralPath $indexPath){
    $catalog=Read-ReleaseCatalog $layout;Assert-NoPendingRelease $catalog
    $roles=if($catalog.format -eq 2){$catalog.services.Keys}else{$catalog.legacy.Keys}
    foreach($role in $roles|Sort-Object){
        $release=Get-PlatformRelease $layout $role -Verify
        $binary=$release.assets.binary
        if(-not(Test-PathWithin $binary $layout.release_root)){throw ('Release outside the managed root: '+$role)}
        $exists=Test-Path -LiteralPath $binary
        $releases += [pscustomobject]@{role=$role;path=$binary;exists=$exists;reference=$release.reference;sha256=if($exists){(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLower()}else{$null}}
    }
}
$harness=@()
$retained=@()
if($catalog.format -eq 2){
    foreach($reference in (Get-ReleaseReferences $catalog)){
        $descriptor=Read-ReleaseDescriptor $layout $reference -Verify
        $retained+=@{reference=$reference;role=$descriptor.role;files=$descriptor.files.Count;links=$descriptor.links.Count;complete_bundle_verified=$true}
    }
}
$harnessRoot=$layout.harness_root
$hasWorker=if($catalog.format -eq 2){$catalog.services.Contains('worker')}else{$catalog.legacy.Contains('worker')}
if($hasWorker){$harnessRoot=(Get-PlatformRelease $layout worker).assets.harness}
foreach($relative in @('harness/runner.mjs','harness/package.json','harness/pnpm-lock.yaml')){
    $file=Join-Path $harnessRoot ([IO.Path]::GetFileName($relative))
    if(Test-Path -LiteralPath $file){$harness += [pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()}}
}
$report=[pscustomobject]@{
    schema_version=1;observed_at=[datetime]::UtcNow.ToString('o');project_root=$ProjectRoot;state_root=$StateRoot
    databases=@($groups.Values|Sort-Object host,port,database);configuration_files=$files;missing_service_configurations=$missing
    releases=$releases;retained_release_references=$retained;harness_inputs=$harness
    recovery_verified=$false
    remaining_checks=@('Protect and verify a recoverable copy of all configurations and MASTER_KEY.','Quiesce writers and back up every listed authoritative database.','Retain exact executable/Harness versions and dependency artifacts.','Restore every domain to isolated databases; check original data and references.','Keep workers and externally effectful tools disabled in the restoration environment.','Verify service identities, grants, cross-domain references and recovery ordering before cutover.')
    limitations=@('This is a read-only inventory, not a backup or a passing restoration test.','Database groups deliberately ignore role/search_path: a complete database dump must include every owned schema.','No passwords, tokens, master-key values or raw DSNs are recorded.','External RAG indexes need their own rebuild/backup policy when enabled.')
}
$ReportPath=[IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath)|Out-Null
$stream=[IO.File]::Open($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 8));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
[pscustomobject]@{report=$ReportPath;authoritative_databases=$groups.Count;configuration_files=$files.Count;release_binaries=$releases.Count;recovery_verified=$false}|ConvertTo-Json
