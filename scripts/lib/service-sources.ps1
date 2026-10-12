# The integration repository coordinates fixed service versions. It never
# supplies business source to independently owned service builds.
function Get-SelectedServiceSource([string]$IntegrationRoot,[string]$Role,[System.Collections.IDictionary]$Contract){
    $extracted=@('registry','sandbox','telemetry','toolhub','storage','sources','knowledge','indexer')
    if($Role -notin $extracted){return $null}
    $lockPath=Join-Path $IntegrationRoot 'deploy/service-sources.json'
    if(-not(Test-Path -LiteralPath $lockPath)){throw 'Independent service source lock is required.'}
    $lock=Read-ReleaseJson $lockPath
    if($lock.format -ne 1 -or -not $lock.services){throw 'Invalid service source lock.'}
    if(-not $lock.services.Contains($Role)){throw ('Independent service source mapping is required: '+$Role)}
    $entry=$lock.services[$Role]
    if($entry.repository -cne ('agent-os-'+$Role) -or $entry.commit -cnotmatch '^[a-f0-9]{40}$'){
        throw 'Unreviewed independent service source mapping.'
    }
    $reposRoot=Split-Path -Parent $IntegrationRoot
    $sourceRoot=Join-Path $reposRoot $entry.repository
    Assert-ReleasePhysicalPath $reposRoot $sourceRoot
    if(-not(Test-Path -LiteralPath (Join-Path $sourceRoot '.git'))){throw 'Selected service repository is missing; checkout its locked version.'}
    $revision=(& git -C $sourceRoot rev-parse HEAD).Trim()
    if($LASTEXITCODE -or $revision -cne $entry.commit){throw ('Service source commit differs from the integration lock: '+$Role)}
    $status=@(& git -C $sourceRoot status --porcelain)
    if($LASTEXITCODE -or $status.Count){throw ('Independent service source must be clean: '+$Role)}
    $owner=Read-ReleaseJson (Join-Path $sourceRoot 'deploy/release-contract.json')
    $migrationOwner=if($Role -eq 'indexer'){'knowledge'}else{$Role}
    if($owner.format -ne 1 -or $owner.role -cne $Role -or $owner.migration_owner -cne $migrationOwner -or
        -not $owner.contract -or $owner.backward_compatible -ne $true -or (Get-ContractIdentity $owner.contract) -cne (Get-ContractIdentity $Contract)){
        throw ('Owner release contract is not compatible with this integration: '+$Role)
    }
    $proof=Read-ReleaseJson (Join-Path $sourceRoot 'source-provenance.json')
    if($proof.sdk.commit -cnotmatch '^[a-f0-9]{40}$' -or -not $proof.sdk.module_sum.StartsWith('h1:')){throw 'SDK source provenance is incomplete.'}
    $module=Get-Content -LiteralPath (Join-Path $sourceRoot 'go.mod') -Raw
    if($module -match '(?m)^replace\s' -or $module -notmatch ('(?m)^module github\.com/euler-gaozl/'+[regex]::Escape($entry.repository)+'\s*$')){throw 'Independent module identity/replacements invalid.'}
    if(-not(Test-Path -LiteralPath (Join-Path $sourceRoot 'vendor/modules.txt'))){throw 'Pinned vendored dependencies missing.'}
    $dependencies=@($proof['owner_modules']|Where-Object{$null -ne $_})
    $lockedDependencies=@($entry['owner_modules']|Where-Object{$null -ne $_})
    if($Role -eq 'indexer'){
        if($dependencies.Count -ne 1 -or $lockedDependencies.Count -ne 1 -or $owner['indexing_protocol'] -cne 'knowledge-indexing-v1'){
            throw 'Indexer requires one fixed Knowledge transaction module and protocol.'
        }
        $dependency=$dependencies[0]
        if($dependency.module -cne 'github.com/euler-gaozl/agent-os-knowledge' -or $dependency.package -cne 'indexing' -or
            $dependency.protocol -cne $owner.indexing_protocol -or $dependency.version -cnotmatch '^v\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$' -or
            $dependency.commit -cnotmatch '^[a-f0-9]{40}$' -or -not $dependency.module_sum.StartsWith('h1:') -or -not $dependency.go_mod_sum.StartsWith('h1:')){
            throw 'Indexer transaction owner provenance is incomplete.'
        }
        foreach($field in @('module','version','commit','module_sum','go_mod_sum','protocol','package')){
            if($dependency[$field] -cne $lockedDependencies[0][$field]){throw ('Transaction owner dependency differs from integration lock: '+$field)}
        }
        $requirePattern='(?m)^\s*'+[regex]::Escape($dependency.module)+'\s+'+[regex]::Escape($dependency.version)+'\s*$'
        if($module -notmatch $requirePattern){throw 'Transaction owner module is not pinned in go.mod.'}
        $sums=Get-Content -LiteralPath (Join-Path $sourceRoot 'go.sum') -Raw
        foreach($sum in @(@{version=$dependency.version;value=$dependency.module_sum},@{version=($dependency.version+'/go.mod');value=$dependency.go_mod_sum})){
            $sumPattern='(?m)^'+[regex]::Escape($dependency.module)+' '+[regex]::Escape($sum.version)+' '+[regex]::Escape($sum.value)+'\r?$'
            if($sums -notmatch $sumPattern){throw 'Transaction owner checksum differs from go.sum.'}
        }
        $manifest=Get-Content -LiteralPath (Join-Path $sourceRoot 'vendor/modules.txt') -Raw
        if($manifest -notmatch ('(?m)^# '+[regex]::Escape($dependency.module)+' '+[regex]::Escape($dependency.version)+'\s*$')){throw 'Vendored transaction module version differs.'}
    }elseif($dependencies.Count -or $lockedDependencies.Count){throw 'Unreviewed cross-owner module dependency.'}
    return @{root=$sourceRoot;repository=$entry.repository;commit=$revision;sdk=$proof.sdk;owner_modules=$dependencies;contract=$owner.contract}
}
