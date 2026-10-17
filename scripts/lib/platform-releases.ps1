# One atomic catalog owns committed and pending Windows releases. Paths inside
# descriptors are relative so a verified backup can reconstruct the same bundle.
. (Join-Path $PSScriptRoot 'platform-source-execution.ps1')
. (Join-Path $PSScriptRoot 'platform-receipts.ps1')
. (Join-Path $PSScriptRoot 'platform-continuation.ps1')
. (Join-Path $PSScriptRoot 'platform-execution-access.ps1')
. (Join-Path $PSScriptRoot 'platform-knowledge-archives.ps1')
. (Join-Path $PSScriptRoot 'platform-model-management.ps1')
. (Join-Path $PSScriptRoot 'platform-migration-journal.ps1')
function Read-ReleaseJson([string]$Path){
    try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}catch{throw ('Invalid release metadata: '+[IO.Path]::GetFileName($Path))}
}
function Resolve-ReleasePath([string]$Root,[string]$Relative){
    if(-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains('\') -or $Relative -match '(^|/)\.\.?(/|$)' -or $Relative.Contains(':')){throw 'Release path must be a normalized relative path.'}
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if(-not(Test-PathWithin $full $Root)){throw 'Release path escapes its managed root.'}
    return $full
}
function Get-ReleaseRelative([string]$Root,[string]$Path){
    if(-not(Test-PathWithin $Path $Root)){throw 'Release dependency is outside its managed root.'}
    return [IO.Path]::GetRelativePath($Root,$Path).Replace('\','/')
}
function Assert-ReleasePhysicalPath([string]$Root,[string]$Path){
    if(-not(Test-PathWithin $Path $Root)){throw 'Release path escapes its managed root.'}
    $cursor=[IO.Path]::GetFullPath($Path)
    while($true){
        if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A release root or physical parent is a reparse point.'}}
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if(-not $parent -or $parent -eq $cursor){break}
        $cursor=$parent
    }
}
function Get-ReleaseInventory([string]$Root,[System.Collections.IDictionary]$Assets){
    $files=@{};$links=@{}
    foreach($asset in $Assets.Keys|Sort-Object){
        $start=Resolve-ReleasePath $Root $Assets[$asset]
        Assert-ReleasePhysicalPath $Root $start
        $initial=Get-Item -LiteralPath $start -Force
        $boundary=if($initial.PSIsContainer){$start}else{Split-Path -Parent $start}
        $queue=[Collections.Generic.Stack[string]]::new();$queue.Push($start)
        while($queue.Count){
            $path=$queue.Pop();$item=Get-Item -LiteralPath $path -Force
            $relative=Get-ReleaseRelative $Root $path
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
                $target=$item.ResolveLinkTarget($true)
                if(-not $target -or -not(Test-PathWithin $target.FullName $boundary)){throw 'Release link target escapes its dependency tree.'}
                # Flatten link chains to their final internal physical target.
                # This keeps restored links independent of old absolute roots.
                Assert-ReleasePhysicalPath $Root $target.FullName
                $links[$relative]=@{path=$relative;target=(Get-ReleaseRelative $Root $target.FullName);directory=($target -is [IO.DirectoryInfo])}
            }elseif($item.PSIsContainer){
                foreach($child in Get-ChildItem -LiteralPath $path -Force){$queue.Push($child.FullName)}
            }else{
                $files[$relative]=@{path=$relative;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
            }
        }
    }
    foreach($link in $links.Values){
        if(-not $link.directory -and -not $files.ContainsKey($link.target)){throw 'Release link target was not captured.'}
        if($link.directory -and -not @($files.Keys|Where-Object{$_.StartsWith($link.target+'/',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Release directory link has no captured content.'}
    }
    return @{files=@($files.Keys|Sort-Object|ForEach-Object{$files[$_]});links=@($links.Keys|Sort-Object|ForEach-Object{$links[$_]})}
}
function New-ReleaseDescriptor([hashtable]$Layout,[string]$Role,[System.Collections.IDictionary]$Assets,[System.Collections.IDictionary]$Contract,[System.Collections.IDictionary]$Provenance,[System.Collections.IDictionary]$SourceExecution=$null,[System.Collections.IDictionary]$ResidentExecution=$null,[System.Collections.IDictionary]$ReceiptManagement=$null,[System.Collections.IDictionary]$ExecutionAccess=$null,[System.Collections.IDictionary]$KnowledgeArchives=$null,[System.Collections.IDictionary]$BudgetExecution=$null,[System.Collections.IDictionary]$NativeExecution=$null,[System.Collections.IDictionary]$ModelManagement=$null,[System.Collections.IDictionary]$ContinuationManagement=$null,[System.Collections.IDictionary]$FinalExecution=$null,[System.Collections.IDictionary]$GuardedExecution=$null,[System.Collections.IDictionary]$GuardedV6Execution=$null){
    Assert-ReleaseAssets $Role $Assets
    $identifier=$Role+'-'+[guid]::NewGuid().ToString('N')
    $inventory=Get-ReleaseInventory $Layout.release_root $Assets
    $descriptor=@{format=1;id=$identifier;role=$Role;created_at=[datetime]::UtcNow.ToString('o');assets=$Assets;contract=$Contract;provenance=$Provenance;files=$inventory.files;links=$inventory.links}
    if($SourceExecution){$descriptor.source_execution=$SourceExecution}
    if($ResidentExecution){$descriptor.resident_execution=$ResidentExecution}
    if($BudgetExecution){$descriptor.budget_execution=$BudgetExecution}
    if($NativeExecution){$descriptor.native_execution=$NativeExecution}
    if($FinalExecution){$descriptor.final_execution=$FinalExecution}
    if($GuardedExecution){$descriptor.guarded_execution=$GuardedExecution}
    if($GuardedV6Execution){$descriptor.guarded_v6_execution=$GuardedV6Execution}
    if($null -ne $ReceiptManagement){$descriptor.receipt_management=$ReceiptManagement}
    if($null -ne $ExecutionAccess){$descriptor.execution_access=$ExecutionAccess}
    if($null -ne $KnowledgeArchives){$descriptor.source_archives=$KnowledgeArchives}
    if($null -ne $ModelManagement){$descriptor.model_management=$ModelManagement}
    if($null -ne $ContinuationManagement){$descriptor.continuation_management=$ContinuationManagement}
    Assert-SourceExecutionDescriptor $descriptor
    Assert-ReceiptManagementDescriptor $descriptor
    Assert-ContinuationDescriptor $descriptor
    Assert-ExecutionAccessDescriptor $descriptor
    Assert-KnowledgeArchiveDescriptor $descriptor
    Assert-ModelManagementDescriptor $descriptor
    $relative='descriptors/'+$identifier+'.json';$path=Resolve-ReleasePath $Layout.release_root $relative
    Assert-ReleasePhysicalPath $Layout.release_root $path
    if(Test-Path -LiteralPath $path){throw 'Release descriptor already exists.'}
    Write-PlatformJson $path $descriptor
    return @{id=$identifier;manifest=$relative;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()}
}
function Read-ReleaseDescriptor([hashtable]$Layout,[System.Collections.IDictionary]$Reference,[switch]$Verify){
    if($Reference.id -cnotmatch '^[a-z][a-z0-9-]+-[a-f0-9]{32}$' -or $Reference.manifest -cne ('descriptors/'+$Reference.id+'.json') -or $Reference.sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid release reference.'}
    $path=Resolve-ReleasePath $Layout.release_root $Reference.manifest
    Assert-ReleasePhysicalPath $Layout.release_root $path
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() -cne $Reference.sha256){throw 'Release descriptor digest mismatch.'}
    $descriptor=Read-ReleaseJson $path
    if($descriptor.format -ne 1 -or $descriptor.id -cne $Reference.id -or -not $descriptor.assets['binary']){throw 'Invalid release descriptor identity.'}
    Assert-ReleaseAssets $descriptor.role $descriptor.assets
    Assert-SourceExecutionDescriptor $descriptor
    Assert-ReceiptManagementDescriptor $descriptor
    Assert-ContinuationDescriptor $descriptor
    Assert-ExecutionAccessDescriptor $descriptor
    Assert-KnowledgeArchiveDescriptor $descriptor
    Assert-ModelManagementDescriptor $descriptor
    foreach($relative in $descriptor.assets.Values){$null=Resolve-ReleasePath $Layout.release_root $relative}
    if($Verify){
        $actual=Get-ReleaseInventory $Layout.release_root $descriptor.assets
        foreach($kind in @('files','links')){
            $expected=@($descriptor[$kind]);$observed=@($actual[$kind])
            if($expected.Count -ne $observed.Count){throw ('Release '+$kind+' coverage differs.')}
            for($i=0;$i -lt $expected.Count;$i++){
                $keys=if($kind -eq 'files'){@('path','bytes','sha256')}else{@('path','target','directory')}
                foreach($key in $keys){if([string]$expected[$i][$key] -cne [string]$observed[$i][$key]){throw ('Release content differs: '+$expected[$i].path)}}
            }
        }
    }
    return $descriptor
}
function Read-ReleaseCatalog([hashtable]$Layout){
    $catalog=Read-ReleaseJson (Join-Path $Layout.release_root 'current.json')
    if($catalog.Contains('format')){
        if($catalog.format -ne 2 -or -not $catalog.services -or $catalog.generation -lt 1){throw 'Unsupported release catalog.'}
        return $catalog
    }
    return @{format=1;legacy=$catalog}
}
function Assert-NoPendingRelease([hashtable]$Catalog){
    if($Catalog.format -eq 2){foreach($role in $Catalog.services.Keys){if($Catalog.services[$role]['pending']){throw ('Unfinished release operation for '+$role+'. Run release recovery before other maintenance.')}}}
}
function Get-PlatformRelease([hashtable]$Layout,[string]$Role,[string]$PendingOperation='', [switch]$Verify){
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -eq 1){
        if($PendingOperation){throw 'Pending release requires the versioned catalog.'}
        $binary=[IO.Path]::GetFullPath([string]$catalog.legacy[$Role]);if(-not(Test-PathWithin $binary $Layout.release_root)){throw 'Unmanaged legacy executable.'}
        $assets=@{binary=$binary}
        if($Role -eq 'worker'){
            $assets.harness=$Layout.harness_root
            if($Layout['node_binary']){$assets.node=$Layout.node_binary}
            else{
                $configPath=Join-Path $Layout.config_root 'services/worker.json'
                $workerConfig=if(Test-Path -LiteralPath $configPath){Read-ReleaseJson $configPath}else{@{}}
                $assets.node=if($workerConfig['AGENTOS_NODE']){$workerConfig.AGENTOS_NODE}else{(Get-Command node -ErrorAction Stop).Source}
                $workerConfig=$null
            }
        }
        if($Role -eq 'control'){$assets.web=$Layout.console_web_root}
        if($Role -eq 'futures'){$assets.web=$Layout.futures_web_root}
        return @{format=1;assets=$assets;reference=$null;descriptor=$null}
    }
    if(-not $catalog.services.Contains($Role)){throw ('No release registered for '+$Role)}
    $entry=$catalog.services[$Role];$reference=$entry.current
    if($entry['pending']){
        if(-not $PendingOperation -or $entry.pending.id -cne $PendingOperation){throw ('Release is pending for '+$Role+'; recover it before ordinary startup.')}
        $reference=if($entry.pending.phase -eq 'reverting'){$entry.pending.prior}else{$entry.pending.target}
    }elseif($PendingOperation){throw 'Pending operation identity does not match.'}
    $descriptor=Read-ReleaseDescriptor $Layout $reference -Verify:$Verify
    if($descriptor.role -cne $Role){throw 'Release role mismatch.'}
    $assets=@{};foreach($key in $descriptor.assets.Keys){$assets[$key]=Resolve-ReleasePath $Layout.release_root $descriptor.assets[$key]}
    return @{format=2;assets=$assets;reference=$reference;descriptor=$descriptor}
}
function Get-ReleaseReferences([hashtable]$Catalog){
    if($Catalog.format -ne 2){return ,@()}
    $all=@{}
    foreach($entry in $Catalog.services.Values){
        foreach($reference in @($entry.current,$entry['previous'])){if($reference){$all[$reference.id]=$reference}}
        if($entry['pending']){foreach($reference in @($entry.pending.prior,$entry.pending.target)){if($reference){$all[$reference.id]=$reference}}}
    }
    return ,@($all.Values|Sort-Object id)
}
function Get-ContractIdentity([System.Collections.IDictionary]$Contract){
    $keys=@('http','data','engines','tools')
    if(@($Contract.Keys).Count -ne $keys.Count){throw 'Unrecognized compatibility contract fields.'}
    $normalized=[ordered]@{}
    foreach($key in $keys){
        if(-not $Contract.Contains($key)){throw 'Missing compatibility contract field.'}
        if($key -in @('engines','tools')){$normalized[$key]=@($Contract[$key]|Sort-Object -Unique)}else{$normalized[$key]=[string]$Contract[$key];if(-not $normalized[$key]){throw 'Empty compatibility contract.'}}
    }
    return ConvertTo-Json -InputObject $normalized -Depth 5 -Compress
}
function Get-ServiceReleaseContract([string]$ProjectRoot,[string]$Role){
    $contracts=Read-ReleaseJson (Join-Path $ProjectRoot 'deploy/windows-release-contracts.json')
    return Get-ContractForService $contracts $Role
}
function Get-ContractForService([System.Collections.IDictionary]$Contracts,[string]$Role){
    if($contracts.format -ne 1 -or -not $contracts.data_contracts.Contains($Role)){throw 'No reviewed Windows contract for this service.'}
    if($Contracts['service_contracts'] -and $Contracts.service_contracts.Contains($Role)){$override=$Contracts.service_contracts[$Role];$null=Get-ContractIdentity $override;return $override}
    $engines=@();$tools=@()
    if($Role -eq 'worker'){$engines=@($contracts.worker_engines)}
    if($Role -in @('worker','runtime','registry','toolhub','control','futures')){$tools=@($contracts.builtin_tools)}
    return @{http=$contracts.http_contract;data=$contracts.data_contracts[$Role];engines=$engines;tools=$tools}
}
function Assert-ReleaseAssets([string]$Role,[System.Collections.IDictionary]$Assets){
    if($Role -notin @('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources','migrate-services')){throw 'Unknown release role.'}
    $expected=@('binary');if($Role -eq 'worker'){$expected+=@('node','harness')};if($Role -in @('control','futures')){$expected+='web'}
    if($Role -eq 'worker' -and $Assets.Contains('source_harness')){$expected+='source_harness'}
    if($Role -eq 'worker' -and $Assets.Contains('resident_harness')){$expected+='resident_harness'}
    if($Role -eq 'worker' -and $Assets.Contains('budget_harness')){$expected+='budget_harness'}
    if($Role -eq 'worker' -and $Assets.Contains('native_harness')){$expected+='native_harness'}
    if($Role -eq 'worker' -and $Assets.Contains('final_harness')){$expected+='final_harness'}
    if($Role -eq 'worker' -and $Assets.Contains('guarded_harness')){$expected+='guarded_harness'}
    if(@(Compare-Object @($Assets.Keys|Sort-Object) @($expected|Sort-Object)).Count){throw 'Release does not contain the complete role-specific asset set.'}
}
function Assert-CompatibleRelease([System.Collections.IDictionary]$Previous,[System.Collections.IDictionary]$Next){
    if($Previous.role -cne $Next.role){throw 'Cannot replace a release with another service role.'}
    Assert-KnowledgeArchivePair $Previous $Next
    # Both candidates can write BEFORE readiness. Equality is deliberate: the
    # previous release must understand candidate writes even when startup fails.
    if((Get-ContractIdentity $Previous.contract) -cne (Get-ContractIdentity $Next.contract) -and -not(Test-SourceRuntimeTransition $Previous $Next) -and -not(Test-KnowledgeArchiveTransition $Previous $Next)){throw 'Bidirectional release compatibility is not established. A coordinated migration is required; automatic rollback cannot undo database writes.'}
    # Reviewed Runtime and Knowledge transitions additionally require live
    # domain probes. Operations recheck the applicable state during startup,
    # release and recovery; metadata alone cannot permit a data downgrade.
}
function Export-ReleaseCatalog([hashtable]$Layout,[string]$Destination){
    $catalog=Read-ReleaseCatalog $Layout;Assert-NoPendingRelease $catalog
    if($catalog.format -ne 2){throw 'Complete release export requires the versioned catalog.'}
    if(Test-Path -LiteralPath $Destination){throw 'Release export destination already exists.'}
    $files=@{};$links=@{}
    foreach($reference in (Get-ReleaseReferences $catalog)){
        $descriptor=Read-ReleaseDescriptor $Layout $reference -Verify
        foreach($file in $descriptor.files){
            if($files.ContainsKey($file.path) -and $files[$file.path].sha256 -cne $file.sha256){throw 'Conflicting shared release content.'}
            $files[$file.path]=$file
        }
        foreach($link in $descriptor.links){
            if($links.ContainsKey($link.path) -and ($links[$link.path].target -cne $link.target -or $links[$link.path].directory -ne $link.directory)){throw 'Conflicting shared release link.'}
            $links[$link.path]=$link
        }
        $path=Resolve-ReleasePath $Layout.release_root $reference.manifest
        $files[$reference.manifest]=@{path=$reference.manifest;bytes=(Get-Item -LiteralPath $path).Length;sha256=$reference.sha256}
    }
    $catalogPath=Join-Path $Layout.release_root 'current.json'
    $files['current.json']=@{path='current.json';bytes=(Get-Item -LiteralPath $catalogPath).Length;sha256=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLower()}
    $null=New-Item -ItemType Directory -Path $Destination
    foreach($file in $files.Values){
        $from=Resolve-ReleasePath $Layout.release_root $file.path;Assert-ReleasePhysicalPath $Layout.release_root $from
        $to=Resolve-ReleasePath $Destination ('files/'+$file.path)
        $null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to)
        Copy-Item -LiteralPath $from -Destination $to
        if((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash.ToLower() -cne $file.sha256){throw 'Release content changed during export.'}
    }
    $index=@{format=1;catalog_generation=$catalog.generation;files=@($files.Keys|Sort-Object|ForEach-Object{$files[$_]});links=@($links.Keys|Sort-Object|ForEach-Object{$links[$_]})}
    Write-PlatformJson (Join-Path $Destination 'archive.json') $index
    return @{references=(Get-ReleaseReferences $catalog).Count;files=$index.files.Count;links=$index.links.Count;generation=$catalog.generation}
}
function Restore-ReleaseCatalog([string]$Archive,[string]$Destination){
    if(Test-Path -LiteralPath $Destination){throw 'Release restoration requires a new directory.'}
    $index=Read-ReleaseJson (Join-Path $Archive 'archive.json')
    if($index.format -ne 1){throw 'Unsupported release archive.'}
    # Validate all paths and source bytes before creating any links. No link may
    # become a parent of another archived path or point outside captured bytes.
    $paths=@{};$linkPaths=@{}
    foreach($file in $index.files){
        $from=Resolve-ReleasePath $Archive ('files/'+$file.path);Assert-ReleasePhysicalPath $Archive $from
        $null=Resolve-ReleasePath $Destination $file.path
        if($paths.ContainsKey($file.path)){throw 'Duplicate archive path.'};$paths[$file.path]=$true
        if((Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash.ToLower() -cne $file.sha256 -or (Get-Item -LiteralPath $from).Length -ne $file.bytes){throw 'Release archive digest mismatch.'}
    }
    foreach($link in $index.links){
        $null=Resolve-ReleasePath $Destination $link.path;$null=Resolve-ReleasePath $Destination $link.target
        if($paths.ContainsKey($link.path) -or $linkPaths.ContainsKey($link.path)){throw 'Duplicate archive link path.'};$linkPaths[$link.path]=$true
        if($link.directory){if(-not @($paths.Keys|Where-Object{$_.StartsWith($link.target+'/',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Uncaptured directory link target.'}}
        elseif(-not $paths.ContainsKey($link.target)){throw 'Uncaptured file link target.'}
    }
    foreach($linkPath in $linkPaths.Keys){foreach($path in @($paths.Keys)+@($linkPaths.Keys)){if($path.StartsWith($linkPath+'/',[StringComparison]::OrdinalIgnoreCase)){throw 'Archive link is a parent of another entry.'}}}
    $null=New-Item -ItemType Directory -Path $Destination
    foreach($file in $index.files){
        $to=Resolve-ReleasePath $Destination $file.path;$null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to)
        Copy-Item -LiteralPath (Resolve-ReleasePath $Archive ('files/'+$file.path)) -Destination $to
    }
    foreach($link in $index.links){
        $to=Resolve-ReleasePath $Destination $link.path;$target=Resolve-ReleasePath $Destination $link.target
        Assert-ReleasePhysicalPath $Destination $target
        $null=New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to)
        $kind=if($link.directory){'Junction'}else{'SymbolicLink'}
        $null=New-Item -ItemType $kind -Path $to -Target $target
    }
    $restored=@{release_root=$Destination};$catalog=Read-ReleaseCatalog $restored;Assert-NoPendingRelease $catalog
    if($catalog.generation -ne $index.catalog_generation){throw 'Restored release generation differs.'}
    foreach($reference in (Get-ReleaseReferences $catalog)){$null=Read-ReleaseDescriptor $restored $reference -Verify}
    return @{references=(Get-ReleaseReferences $catalog).Count;files=$index.files.Count;links=$index.links.Count;generation=$catalog.generation;all_bundles_verified=$true}
}
