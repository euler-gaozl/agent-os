# Linux images keep their owner's startup contract. Do not assume the former
# monorepo /app layout, nor treat an absent healthcheck as a dependency failure.
function Assert-OwnerBinary([string]$Role,[System.Collections.IDictionary]$Source,[System.Collections.IDictionary]$Info,[string]$Command){
    $module='github.com/euler-gaozl/'+$Source.repository
    if($Command -cnotin @($Role,'healthcheck','migrate') -or $Info.Main.Path -cne $module -or $Info.Path -cne ($module+'/cmd/'+$Command)){throw 'Image binary package does not belong to selected owner.'}
    $settings=@{};foreach($setting in $Info.Settings){$settings[$setting.Key]=$setting.Value}
    if($settings['GOOS'] -cne 'linux' -or $settings['GOARCH'] -cne 'amd64' -or $settings['CGO_ENABLED'] -cne '0'){throw 'Image binary target differs.'}
    if($Info.Main['Replace']){throw 'Image binary main module has a replacement.'}
    $expected=@($Source.sdk)+@($Source.owner_modules)
    $observed=@()
    foreach($dependency in @($Info['Deps']|Where-Object{$null -ne $_})){
        if($dependency['Replace']){throw 'Image dependency replacement is forbidden.'}
        if($dependency.Path.StartsWith('github.com/euler-gaozl/agent-os')){
            $match=@($expected|Where-Object{$_.module -ceq $dependency.Path})
            if($match.Count -ne 1 -or $match[0].version -cne $dependency.Version){throw 'Image binary SDK/transaction dependency differs from source provenance.'}
            $observed+=@(@{module=$dependency.Path;version=$dependency.Version})
        }
    }
    if($Command -ceq $Role){
        foreach($dependency in $expected){if(@($observed|Where-Object{$_.module -ceq $dependency.module}).Count -ne 1){throw 'Service binary is missing its declared owner dependency.'}}
    }
    # git archive intentionally omits .git; commit attribution comes from the
    # exact source archive, not an invented vcs.revision build setting.
    return @{package=$Info.Path;module=$Info.Main.Path;go_version=$Info.GoVersion;target='linux/amd64';dependencies=$observed}
}
function Assert-ImageSDKSource([System.Collections.IDictionary]$Source){
    $sdk=$Source.sdk
    if($sdk.module -cne 'github.com/euler-gaozl/agent-os-sdk' -or $sdk.version -cnotmatch '^v\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$'){throw 'Unreviewed SDK provenance.'}
    $prefix=[regex]::Escape($sdk.module)+'\s+'+[regex]::Escape($sdk.version)
    $module=Get-Content -LiteralPath (Join-Path $Source.root 'go.mod') -Raw
    $sums=Get-Content -LiteralPath (Join-Path $Source.root 'go.sum') -Raw
    $vendor=Get-Content -LiteralPath (Join-Path $Source.root 'vendor/modules.txt') -Raw
    if($module -notmatch ('(?m)^\s*'+$prefix+'\s*$') -or
       $sums -notmatch ('(?m)^'+$prefix+' '+[regex]::Escape($sdk.module_sum)+'\r?$') -or
       $vendor -notmatch ('(?m)^# '+$prefix+'\r?$')){throw 'SDK declaration, checksum or vendor version differs.'}
}
function Get-OwnerImageLabels([string]$Role,[System.Collections.IDictionary]$Source){
    return [ordered]@{
        'org.opencontainers.image.source'=('https://github.com/euler-gaozl/'+$Source.repository)
        'org.opencontainers.image.revision'=$Source.commit
        'org.agentos.role'=$Role
        'org.agentos.contract'=(Get-ContractIdentity $Source.contract)
        'org.agentos.builtin-tools'=(ConvertTo-Json -InputObject @($Source.contract.tools) -Compress)
        'org.agentos.worker-engines'=(ConvertTo-Json -InputObject @($Source.contract.engines) -Compress)
    }
}
function Assert-OwnerImage([string]$Role,[System.Collections.IDictionary]$Source,[System.Collections.IDictionary]$Image){
    if($Image.Id -cnotmatch '^sha256:[a-f0-9]{64}$' -or $Image.Os -cne 'linux' -or $Image.Architecture -cne 'amd64'){throw 'Unexpected image identity or target.'}
    $expected=Get-OwnerImageLabels $Role $Source
    foreach($key in $expected.Keys){if($Image.Config.Labels[$key] -cne $expected[$key]){throw ('Owner image label differs: '+$key)}}
    $appLayout=$Role -in @('worker','control','futures')
    $binaryRoot=if($appLayout){'/app'}else{'/usr/local/bin'}
    $user=if($appLayout){'10001'}else{'65532:65532'}
    if($Image.Config.User -cne $user){throw 'Owner container identity changed; review config ownership before rollout.'}
    $entry=@($Image.Config.Entrypoint);$command=@($Image.Config.Cmd);$health=@($Image.Config.Healthcheck.Test)
    if($entry.Count -ne 1 -or $entry[0] -cne ($binaryRoot+'/service') -or
       $command.Count -ne 2 -or $command[0] -cne '--config' -or $command[1] -cne '/run/service.json' -or
       $health.Count -ne 2 -or $health[0] -cne 'CMD' -or $health[1] -cne ($binaryRoot+'/healthcheck')){throw 'Owner entrypoint/config/healthcheck contract changed.'}
    $migrationOwner=if($Role -eq 'worker'){'runtime'}elseif($Role -eq 'indexer'){'knowledge'}elseif($Role -in @('control','futures')){'none'}else{$Role}
    return @{role=$Role;image=$Image.Id;repository=$Source.repository;commit=$Source.commit;contract=$Source.contract;sdk=$Source.sdk;owner_modules=@($Source.owner_modules);user=$user;uid=($user.Split(':')[0]);entrypoint=$entry[0];healthcheck=$health[1];migration_owner=$migrationOwner;migrator=$(if($migrationOwner -ceq $Role){$binaryRoot+'/migrate'}else{$null})}
}
