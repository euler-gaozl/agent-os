param([Parameter(Mandatory)][string]$VerifiedBackup,[string]$LayoutPath='',[string]$Pnpm='pnpm')
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-release-baseline.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root
try{
    $old=Read-ReleaseCatalog $layout
    if($old.format -ne 1){throw 'Baseline is already registered; this operation never overwrites versioned release history.'}
    $backup=[IO.Path]::GetFullPath($VerifiedBackup)
    $manifestPath=Join-Path $backup 'manifest.json'
    $hash=(Get-FileHash -LiteralPath $manifestPath).Hash.ToLower()
    $expected=[Text.Encoding]::UTF8.GetString((Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $backup 'manifest-digest.dpapi')))))
    if($hash -cne $expected){throw 'Baseline backup integrity failed.'}
    $verified=@(Get-ChildItem -LiteralPath 'D:\workspace\agent-platform\local\restore-checks' -File -Recurse -Filter result.json|ForEach-Object{Read-RecoveryJson $_.FullName}|Where-Object{$_['status'] -eq 'passed' -and $_['backup_manifest_sha256'] -eq $hash -and $_['isolated_cluster_stopped']})
    if(-not $verified.Count){throw 'Baseline requires an actually verified isolated restore.'}
    $backupManifest=Read-RecoveryJson $manifestPath
    foreach($file in $backupManifest.files){$path=Resolve-ReleasePath $backup $file.path;if((Get-FileHash -LiteralPath $path).Hash.ToLower() -cne $file.sha256){throw 'Verified backup changed.'}}
    $bytes=Unprotect-RecoveryBytes ([IO.File]::ReadAllBytes((Join-Path $backup 'configuration.dpapi')))
    try{$vault=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable}finally{[Array]::Clear($bytes,0,$bytes.Length)}
    foreach($relative in $vault.configuration_files.Keys){
        if($relative -ne 'dev.json' -and $relative -notmatch '^services/[a-z-]+\.json$'){throw 'Invalid baseline configuration path.'}
        $retained=[Convert]::FromBase64String($vault.configuration_files[$relative])
        try{if((Get-FileHash -LiteralPath (Join-Path $layout.config_root $relative)).Hash.ToLower() -cne (Get-BytesHash $retained)){throw 'Baseline configuration changed since verified backup.'}}finally{[Array]::Clear($retained,0,$retained.Length)}
    }
    $vault=$null
    $baselines=Read-ReleaseJson (Join-Path $repoRoot 'deploy/windows-release-baselines.json')
    $go=if(Test-Path -LiteralPath 'D:\workspace\.tools\go\bin\go.exe'){'D:\workspace\.tools\go\bin\go.exe'}else{(Get-Command go -ErrorAction Stop).Source}
    $checkRoot='D:\workspace\agent-platform\local\evidence\release-baseline-'+[guid]::NewGuid().ToString('N')
    New-ProtectedDirectory $checkRoot
    $rebuilt=Join-Path $checkRoot 'harness';$null=New-Item -ItemType Directory -Path $rebuilt
    foreach($name in @('runner.mjs','package.json','pnpm-lock.yaml','session-seams.test.mjs')){Copy-Item -LiteralPath (Join-Path $backup ('harness/'+$name)) -Destination (Join-Path $rebuilt $name)}
    $oldPath=$env:PATH
    try{
        $workerRelease=Get-PlatformRelease $layout worker
        $env:PATH=(Split-Path -Parent $workerRelease.assets.node)+';'+$env:PATH
        & $Pnpm --dir $rebuilt install --offline --frozen-lockfile --ignore-scripts --prod --store-dir (Join-Path $backup 'pnpm-store')
        if($LASTEXITCODE){throw 'Baseline offline reconstruction failed.'}
        $dependencyProof=Assert-HarnessEquivalent $workerRelease.assets.harness $rebuilt
        Write-PlatformJson (Join-Path $checkRoot 'result.json') $dependencyProof
    }finally{$env:PATH=$oldPath}
    $catalog=@{format=2;generation=1;registered_at=[datetime]::UtcNow.ToString('o');services=@{}}
    foreach($role in $old.legacy.Keys|Sort-Object){
        $release=Get-PlatformRelease $layout $role
        $buildInfo=(& $go version -m $release.assets.binary) -join "`n"
        if($LASTEXITCODE -or $buildInfo -notmatch 'vcs\.revision=([a-f0-9]{40})'){throw 'Cannot establish baseline executable source provenance.'}
        $revision=$Matches[1]
        if($buildInfo -notmatch 'vcs\.modified=false' -or -not $baselines.Contains($revision)){throw 'No reviewed baseline contract for this executable revision.'}
        if((Get-FileHash -LiteralPath $release.assets.binary).Hash -cne (Get-FileHash -LiteralPath (Join-Path $backup ('releases/'+$role+'.exe'))).Hash){throw 'Executable differs from the verified baseline.'}
        if($role -eq 'worker'){
            if((Get-FileHash -LiteralPath $release.assets.node).Hash -cne (Get-FileHash -LiteralPath (Join-Path $backup 'releases/node.exe')).Hash){throw 'Node differs from verified baseline.'}
            foreach($name in @('runner.mjs','package.json','pnpm-lock.yaml','session-seams.test.mjs')){
                if((Get-FileHash -LiteralPath (Join-Path $release.assets.harness $name)).Hash -cne (Get-FileHash -LiteralPath (Join-Path $backup ('harness/'+$name))).Hash){throw 'Harness inputs differ from the verified baseline.'}
            }
        }
        if($role -in @('control','futures')){
            $retainedWeb=Join-Path $backup $(if($role -eq 'control'){'web/dist'}else{'web/dist-futures'})
            $actualFiles=@(Get-ChildItem -LiteralPath $release.assets.web -File -Recurse)
            if($actualFiles.Count -ne @(Get-ChildItem -LiteralPath $retainedWeb -File -Recurse).Count){throw 'Web file coverage differs from verified baseline.'}
            foreach($file in $actualFiles){$saved=Join-Path $retainedWeb ([IO.Path]::GetRelativePath($release.assets.web,$file.FullName));if((Get-FileHash -LiteralPath $file.FullName).Hash -cne (Get-FileHash -LiteralPath $saved).Hash){throw 'Web differs from verified baseline.'}}
        }
        $assets=@{};foreach($key in $release.assets.Keys){$assets[$key]=Get-ReleaseRelative $layout.release_root $release.assets[$key]}
        $reference=New-ReleaseDescriptor $layout $role $assets (Get-ContractForService $baselines[$revision] $role) @{kind='adopted-existing';commit=$revision;verified_backup_manifest_sha256=$hash;rebuilt=$false;installed_harness_verified=($role -eq 'worker')}
        $config=Join-Path $layout.config_root $(if($role -eq 'migrate-services'){'dev.json'}else{'services/'+$role+'.json'})
        $reference.config_sha256=(Get-FileHash -LiteralPath $config).Hash.ToLower()
        $catalog.services[$role]=@{current=$reference;previous=$null;pending=$null}
    }
    # Save the exact legacy pointer before the one authoritative format switch.
    $archive=Join-Path $layout.release_root ('legacy-index-'+[guid]::NewGuid().ToString('N')+'.json')
    Write-PlatformJson $archive $old.legacy
    Write-PlatformJson (Join-Path $layout.release_root 'current.json') $catalog
    Write-Output ('Registered '+$catalog.services.Count+' existing release units. No running process or database was changed.')
}finally{$maintenance.Dispose()}
