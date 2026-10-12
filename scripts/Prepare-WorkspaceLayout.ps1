param([Parameter(Mandatory)][string]$VerifiedBackup,[string]$Pnpm='pnpm')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
$old=Get-PlatformLayout $root
$maintenance=Enter-PlatformMaintenance $old.state_root
try {
    if((Read-RecoveryJson (Join-Path $old.release_root 'current.json')).ContainsKey('format')){throw 'This historical layout preparation only accepts the legacy catalog.'}
    # Verification reports never contain secrets; require the exact authenticated
    # backup manifest to have passed a fresh-cluster restoration first.
    $VerifiedBackup=[IO.Path]::GetFullPath($VerifiedBackup)
    $manifestPath=Join-Path $VerifiedBackup 'manifest.json'
    $hash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLower()
    $authenticated=[Text.Encoding]::UTF8.GetString((Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $VerifiedBackup 'manifest-digest.dpapi')))))
    if($hash -ne $authenticated){throw 'Backup integrity check failed.'}
    $reports=@(Get-ChildItem -LiteralPath 'D:\workspace\agent-platform\local\restore-checks' -Filter result.json -Recurse -File|ForEach-Object{Read-RecoveryJson $_.FullName})
    if(-not @($reports|Where-Object{$_.backup_manifest_sha256 -eq $hash -and $_.status -eq 'passed' -and $_.isolated_cluster_stopped}).Count){throw 'This backup has not passed isolated restoration.'}
    $manifest=Read-RecoveryJson $manifestPath
    foreach($file in $manifest.files){
        $path=[IO.Path]::GetFullPath((Join-Path $VerifiedBackup $file.path))
        if(-not(Test-PathWithin $path $VerifiedBackup) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() -ne $file.sha256){throw 'Retained backup content differs.'}
    }
    $vaultBytes=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $VerifiedBackup 'configuration.dpapi')))
    try{$vault=[Text.Encoding]::UTF8.GetString($vaultBytes)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($vaultBytes,0,$vaultBytes.Length)}
    foreach($name in $vault.configuration_files.Keys){
        if($name -ne 'dev.json' -and $name -notmatch '^services/[a-z-]+\.json$'){throw 'Unexpected protected configuration path.'}
        $retained=[Convert]::FromBase64String($vault.configuration_files[$name])
        try{if((Get-FileHash -LiteralPath (Join-Path $old.config_root $name)).Hash.ToLower() -ne (Get-BytesHash $retained)){throw 'Configuration changed after the backup; capture and verify a new baseline first.'}}finally{[Array]::Clear($retained,0,$retained.Length)}
    }
    $vault=$null
    $base='D:\workspace\agent-platform'
    $layout=@{format=1;project_root=$root;state_root=(Join-Path $base 'local/run');config_root=(Join-Path $base 'local/config');database_root=$old.database_root;log_root=(Join-Path $base 'local/logs');release_root=(Join-Path $base 'local/releases');harness_root=(Join-Path $base 'local/releases/harness/baseline');console_web_root=(Join-Path $base 'local/releases/web/baseline/dist');futures_web_root=(Join-Path $base 'local/releases/web/baseline/dist-futures');postgres_bin=$old.postgres_bin;node_binary=(Join-Path $base 'local/releases/node/baseline/node.exe')}
    $destination=Join-Path $base 'ops/layout-staged.json'
    foreach($path in @($layout.state_root,$layout.config_root,$layout.log_root,$layout.release_root)){
        if(Test-Path -LiteralPath $path){throw 'A target workspace directory already exists; inspect the previous preparation before continuing.'}
    }
    foreach($path in @($layout.state_root,$layout.config_root,$layout.log_root,$layout.release_root)){New-ProtectedDirectory $path}
    $null=New-Item -ItemType Directory -Path (Join-Path $layout.config_root 'services')
    $configurationHashes=@{}
    foreach($name in @('dev.json')+@(Get-ChildItem -LiteralPath (Join-Path $old.config_root 'services') -Filter *.json -File|ForEach-Object{'services/'+$_.Name})){
        $source=Join-Path $old.config_root $name;$target=Join-Path $layout.config_root $name
        Copy-Item -LiteralPath $source -Destination $target
        $before=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash;$after=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if($before -ne $after){throw 'Configuration copy verification failed.'};$configurationHashes[$name]=$after.ToLower()
    }
    $release=Join-Path $layout.release_root 'services/baseline';$null=New-Item -ItemType Directory -Path $release -Force
    $index=Read-RecoveryJson (Join-Path $old.release_root 'current.json');$newIndex=@{}
    foreach($role in $index.Keys){
        $source=[IO.Path]::GetFullPath($index[$role]);if(-not(Test-PathWithin $source $old.release_root)){throw 'Unmanaged release path.'}
        if((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath (Join-Path $VerifiedBackup ('releases/'+$role+'.exe'))).Hash){throw 'Release changed after the verified backup.'}
        $target=Join-Path $release ($role+'.exe');Copy-Item -LiteralPath $source -Destination $target
        if((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw 'Release copy verification failed.'}
        $newIndex[$role]=$target
    }
    Write-PlatformJson (Join-Path $layout.release_root 'current.json') $newIndex
    $null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $layout.node_binary)
    Copy-Item -LiteralPath (Join-Path $VerifiedBackup 'releases/node.exe') -Destination $layout.node_binary
    $null=New-Item -ItemType Directory -Force -Path $layout.harness_root
    foreach($name in @('runner.mjs','package.json','pnpm-lock.yaml','session-seams.test.mjs')){
        $source=Join-Path $old.harness_root $name;$saved=Join-Path $VerifiedBackup ('harness/'+$name)
        if((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $saved).Hash){throw 'Harness changed after the verified baseline; take another backup before preparation.'}
        Copy-Item -LiteralPath $saved -Destination (Join-Path $layout.harness_root $name)
    }
    & $Pnpm --dir $layout.harness_root install --offline --frozen-lockfile --ignore-scripts --prod --store-dir (Join-Path $VerifiedBackup 'pnpm-store')
    if($LASTEXITCODE -ne 0){throw 'Offline Harness preparation failed.'}
    foreach($item in @(@{source=(Join-Path $VerifiedBackup 'web/dist');target=$layout.console_web_root},@{source=(Join-Path $VerifiedBackup 'web/dist-futures');target=$layout.futures_web_root})){
        $null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $item.target)
        Copy-Item -LiteralPath $item.source -Destination $item.target -Recurse
        foreach($file in Get-ChildItem -LiteralPath $item.source -File -Recurse){$target=Join-Path $item.target ([IO.Path]::GetRelativePath($item.source,$file.FullName));if((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw 'Web copy verification failed.'}}
    }
    Write-PlatformJson $destination $layout
    Register-PlatformRoots @($old,$layout)
    Write-PlatformJson (Join-Path $base 'local/evidence/workspace-preparation.json') @{status='prepared_not_active';prepared_at=[datetime]::UtcNow.ToString('o');layout=$destination;verified_backup_manifest=$hash;configuration_hashes=$configurationHashes;releases=$newIndex.Keys.Count}
    Write-Output ('Prepared separate runtime paths: '+$destination)
    Write-Output 'Existing services and PostgreSQL are unchanged. Activation still requires a stop/start check.'
}finally{$maintenance.Dispose()}
