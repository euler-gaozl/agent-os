function Get-HarnessComparableFile([string]$Root,[string]$Relative){
    $path=Resolve-ReleasePath $Root $Relative
    if($Relative -in @('node_modules/.modules.yaml','node_modules/.pnpm-workspace-state-v1.json')){
        # pnpm 11 stores JSON in both files. Only installer timestamp/store
        # location fields are excluded; these are not loaded by the DSH runner.
        $metadata=Read-ReleaseJson $path
        foreach($key in @('prunedAt','storeDir','virtualStoreDir','lastValidatedTimestamp')){$null=$metadata.Remove($key)}
        return ConvertTo-Json -InputObject $metadata -Depth 50 -Compress
    }
    if($Relative -match '(^|/)node_modules/\.bin/[^/]+$'){
        $text=[IO.File]::ReadAllText($path)
        $wslRoot='/mnt/'+$Root.Substring(0,1).ToLower()+$Root.Substring(2).Replace('\','/')
        return $text.Replace($Root,'<HARNESS>').Replace($Root.Replace('\','/'),'<HARNESS>').Replace($wslRoot,'<HARNESS>')
    }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
}
function Assert-HarnessEquivalent([string]$Actual,[string]$Rebuilt){
    $inventories=@()
    foreach($tree in @($Actual,$Rebuilt)){
        $parent=Split-Path -Parent $tree;$prefix=(Split-Path -Leaf $tree)+'/'
        $inventory=Get-ReleaseInventory $parent @{harness=(Split-Path -Leaf $tree)}
        $files=@{};foreach($file in $inventory.files){$relative=$file.path.Substring($prefix.Length);$files[$relative]=Get-HarnessComparableFile $tree $relative}
        $links=@{};foreach($link in $inventory.links){$links[$link.path.Substring($prefix.Length)]=@{target=$link.target.Substring($prefix.Length);directory=$link.directory}}
        $inventories+=@(@{files=$files;links=$links})
    }
    foreach($kind in @('files','links')){
        $left=$inventories[0][$kind];$right=$inventories[1][$kind]
        if(@(Compare-Object @($left.Keys|Sort-Object) @($right.Keys|Sort-Object)).Count){throw 'Baseline Harness dependency coverage differs from the offline reconstruction.'}
        foreach($path in $left.Keys){
            if($kind -eq 'files'){if($left[$path] -cne $right[$path]){throw ('Baseline Harness bytes differ from offline reconstruction: '+$path)}}
            elseif($left[$path].target -cne $right[$path].target -or $left[$path].directory -ne $right[$path].directory){throw 'Baseline Harness dependency links differ.'}
        }
    }
    return @{files=$inventories[0].files.Count;links=$inventories[0].links.Count;runtime_bytes_verified=$true;installer_locations_and_timestamps_normalized=$true}
}
