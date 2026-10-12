# The integration repository coordinates fixed service versions. It never
# supplies business source to independently owned service builds.
function Get-SelectedServiceSource([string]$IntegrationRoot,[string]$Role,[System.Collections.IDictionary]$Contract){
    if($Role -notin @('registry','sandbox','telemetry')){return $null}
    $lockPath=Join-Path $IntegrationRoot 'deploy/service-sources.json'
    if(-not(Test-Path -LiteralPath $lockPath)){throw 'Independent service source lock is required.'}
    $lock=Read-ReleaseJson $lockPath
    if($lock.format -ne 1 -or -not $lock.services){throw 'Invalid service source lock.'}
    if(-not $lock.services.Contains($Role)){throw ('Independent service source mapping is required: '+$Role)}
    $entry=$lock.services[$Role]
    if($Role -notin @('registry','sandbox','telemetry') -or $entry.repository -cne ('agent-os-'+$Role) -or $entry.commit -cnotmatch '^[a-f0-9]{40}$'){
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
    if($owner.format -ne 1 -or $owner.role -cne $Role -or $owner.migration_owner -cne $Role -or
        -not $owner.contract -or $owner.backward_compatible -ne $true -or (Get-ContractIdentity $owner.contract) -cne (Get-ContractIdentity $Contract)){
        throw ('Owner release contract is not compatible with this integration: '+$Role)
    }
    $proof=Read-ReleaseJson (Join-Path $sourceRoot 'source-provenance.json')
    if($proof.sdk.commit -cnotmatch '^[a-f0-9]{40}$' -or -not $proof.sdk.module_sum.StartsWith('h1:')){throw 'SDK source provenance is incomplete.'}
    $module=Get-Content -LiteralPath (Join-Path $sourceRoot 'go.mod') -Raw
    if($module -match '(?m)^replace\s' -or $module -notmatch ('(?m)^module github\.com/euler-gaozl/'+[regex]::Escape($entry.repository)+'\s*$')){throw 'Independent module identity/replacements invalid.'}
    if(-not(Test-Path -LiteralPath (Join-Path $sourceRoot 'vendor/modules.txt'))){throw 'Pinned vendored dependencies missing.'}
    return @{root=$sourceRoot;repository=$entry.repository;commit=$revision;sdk=$proof.sdk;contract=$owner.contract}
}
