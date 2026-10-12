param([string]$EvidenceRoot='D:\workspace\agent-platform\local\evidence')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
. (Join-Path $PSScriptRoot 'lib/service-sources.ps1')
$root=Join-Path $EvidenceRoot ('service-sources-'+[guid]::NewGuid().ToString('N'))
$integration=Join-Path $root 'agent-os';$owner=Join-Path $root 'agent-os-registry'
foreach($path in @((Join-Path $integration 'deploy'),(Join-Path $owner 'deploy'),(Join-Path $owner 'vendor'))){New-Item -ItemType Directory -Path $path -Force|Out-Null}
$contract=@{http='fixture-http';data='fixture-data';tools=@('fixture-tool');engines=@()}
$checks=[Collections.Generic.List[string]]::new()
function Expect-Rejection([string]$Name,[scriptblock]$Action){
    $rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw ('Expected rejection: '+$Name)}
    $checks.Add($Name)
}
$lockPath=Join-Path $integration 'deploy/service-sources.json'
try{
    Expect-Rejection 'missing lock never falls back to integration source' {Get-SelectedServiceSource $integration registry $contract}
    Write-PlatformJson $lockPath @{format=1;services=@{sandbox=@{repository='agent-os-sandbox';commit=('a'*40)}}}
    Expect-Rejection 'missing role mapping never falls back' {Get-SelectedServiceSource $integration registry $contract}
    foreach($role in @('toolhub','storage','sources','knowledge','indexer','runtime','worker')){
        Expect-Rejection ('missing extracted mapping never falls back: '+$role) {Get-SelectedServiceSource $integration $role $contract}
    }
    [IO.File]::WriteAllText((Join-Path $owner 'go.mod'),"module github.com/euler-gaozl/agent-os-registry`ngo 1.27.0`n")
    [IO.File]::WriteAllText((Join-Path $owner 'vendor/modules.txt'),'# synthetic boundary fixture, not a buildable service')
    Write-PlatformJson (Join-Path $owner 'deploy/release-contract.json') @{format=1;role='registry';migration_owner='registry';contract=$contract;backward_compatible=$true}
    Write-PlatformJson (Join-Path $owner 'source-provenance.json') @{sdk=@{commit=('a'*40);module_sum='h1:synthetic-fixture'}}
    & git -C $owner init -q -b main
    & git -C $owner -c user.name=Fixture -c user.email=fixture@example.invalid add .
    & git -C $owner -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m 'Synthetic source boundary fixture'
    if($LASTEXITCODE){throw 'Fixture git initialization failed'}
    $commit=(& git -C $owner rev-parse HEAD).Trim()
    $lock=@{format=1;services=@{registry=@{repository='agent-os-registry';commit=$commit}}}
    Write-PlatformJson $lockPath $lock
    $source=Get-SelectedServiceSource $integration registry $contract
    if($source.commit -cne $commit -or $source.root -ne $owner){throw 'Wrong source selected'}
    $checks.Add('fixed clean owner selected')
    $marker=Join-Path $owner 'dirty-fixture.txt';[IO.File]::WriteAllText($marker,'synthetic')
    Expect-Rejection 'dirty owner refused' {Get-SelectedServiceSource $integration registry $contract}
    Remove-Item -LiteralPath $marker
    $lock.services.registry.commit='b'*40;Write-PlatformJson $lockPath $lock
    Expect-Rejection 'different commit refused' {Get-SelectedServiceSource $integration registry $contract}
    $lock.services.registry.commit=$commit;Write-PlatformJson $lockPath $lock
    Expect-Rejection 'incompatible data contract refused' {Get-SelectedServiceSource $integration registry @{http=$contract.http;data='other-data';tools=$contract.tools;engines=@()}}
    Expect-Rejection 'tool-only contract drift refused' {Get-SelectedServiceSource $integration registry @{http=$contract.http;data=$contract.data;tools=@('other-tool');engines=@()}}
    Expect-Rejection 'engine-only contract drift refused' {Get-SelectedServiceSource $integration registry @{http=$contract.http;data=$contract.data;tools=$contract.tools;engines=@('unexpected-engine')}}
    $lock.services.registry.repository='../outside';Write-PlatformJson $lockPath $lock
    Expect-Rejection 'repository path escape refused' {Get-SelectedServiceSource $integration registry $contract}
    if($null -ne (Get-SelectedServiceSource $integration control $contract)){throw 'Unsplit role unexpectedly mapped'}
    $checks.Add('not-yet-extracted role explicitly stays integration-owned')
    $indexer=Join-Path $root 'agent-os-indexer'
    foreach($dir in @('deploy','vendor')){New-Item -ItemType Directory -Path (Join-Path $indexer $dir) -Force|Out-Null}
    $dependency=@{module='github.com/euler-gaozl/agent-os-knowledge';version='v0.1.0-rc.1';commit=('c'*40);module_sum='h1:synthetic-owner';go_mod_sum='h1:synthetic-gomod';package='indexing';protocol='knowledge-indexing-v1'}
    [IO.File]::WriteAllText((Join-Path $indexer 'go.mod'),"module github.com/euler-gaozl/agent-os-indexer`ngo 1.27.0`nrequire (`n github.com/euler-gaozl/agent-os-knowledge v0.1.0-rc.1`n)`n")
    [IO.File]::WriteAllText((Join-Path $indexer 'go.sum'),"github.com/euler-gaozl/agent-os-knowledge v0.1.0-rc.1 h1:synthetic-owner`ngithub.com/euler-gaozl/agent-os-knowledge v0.1.0-rc.1/go.mod h1:synthetic-gomod`n")
    [IO.File]::WriteAllText((Join-Path $indexer 'vendor/modules.txt'),"# github.com/euler-gaozl/agent-os-knowledge v0.1.0-rc.1`n## explicit`n")
    Write-PlatformJson (Join-Path $indexer 'deploy/release-contract.json') @{format=1;role='indexer';migration_owner='knowledge';contract=$contract;backward_compatible=$true;indexing_protocol='knowledge-indexing-v1'}
    Write-PlatformJson (Join-Path $indexer 'source-provenance.json') @{sdk=@{commit=('a'*40);module_sum='h1:synthetic-fixture'};owner_modules=@($dependency)}
    & git -C $indexer init -q -b main
    & git -C $indexer -c user.name=Fixture -c user.email=fixture@example.invalid add .
    & git -C $indexer -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m 'Synthetic consumer boundary fixture'
    if($LASTEXITCODE){throw 'Consumer fixture Git initialization failed'}
    $indexCommit=(& git -C $indexer rev-parse HEAD).Trim()
    $lock.services.indexer=@{repository='agent-os-indexer';commit=$indexCommit;owner_modules=@($dependency.Clone())}
    Write-PlatformJson $lockPath $lock
    $consumer=Get-SelectedServiceSource $integration indexer $contract
    if($consumer.owner_modules.Count -ne 1 -or $consumer.owner_modules[0].commit -cne $dependency.commit){throw 'Owner dependency provenance omitted'}
    $checks.Add('fixed narrow transaction owner accepted with external migration owner')
    foreach($field in @('commit','version','module_sum','protocol')){
        $saved=$lock.services.indexer.owner_modules[0][$field];$lock.services.indexer.owner_modules[0][$field]='drift';Write-PlatformJson $lockPath $lock
        Expect-Rejection ('transaction dependency drift refused: '+$field) {Get-SelectedServiceSource $integration indexer $contract}
        $lock.services.indexer.owner_modules[0][$field]=$saved
    }
    $lock.services.indexer.Remove('owner_modules');Write-PlatformJson $lockPath $lock
    Expect-Rejection 'missing transaction dependency lock refused' {Get-SelectedServiceSource $integration indexer $contract}
    foreach($field in @('module_sum','go_mod_sum')){
        $wrong=$dependency.Clone();$wrong[$field]='h1:shared-incorrect-declaration'
        Write-PlatformJson (Join-Path $indexer 'source-provenance.json') @{sdk=@{commit=('a'*40);module_sum='h1:synthetic-fixture'};owner_modules=@($wrong)}
        & git -C $indexer add -- source-provenance.json
        & git -C $indexer -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m 'Synthetic incorrect owner checksum declaration'
        if($LASTEXITCODE){throw 'Consumer fixture change failed'}
        $lock.services.indexer.commit=(& git -C $indexer rev-parse HEAD).Trim()
        $lock.services.indexer.owner_modules=@($wrong.Clone());Write-PlatformJson $lockPath $lock
        Expect-Rejection ('matching declarations differing from go.sum refused: '+$field) {Get-SelectedServiceSource $integration indexer $contract}
    }
    $worker=Join-Path $root 'agent-os-worker'
    foreach($dir in @('deploy','vendor')){New-Item -ItemType Directory -Path (Join-Path $worker $dir) -Force|Out-Null}
    $dependency=@{module='github.com/euler-gaozl/agent-os-runtime';version='v0.1.0-rc.1';commit=('c'*40);module_sum='h1:synthetic-owner';go_mod_sum='h1:synthetic-gomod';package='execution';protocol='runtime-execution-v1'}
    [IO.File]::WriteAllText((Join-Path $worker 'go.mod'),"module github.com/euler-gaozl/agent-os-worker`ngo 1.27.0`nrequire (`n github.com/euler-gaozl/agent-os-runtime v0.1.0-rc.1`n)`n")
    [IO.File]::WriteAllText((Join-Path $worker 'go.sum'),"github.com/euler-gaozl/agent-os-runtime v0.1.0-rc.1 h1:synthetic-owner`ngithub.com/euler-gaozl/agent-os-runtime v0.1.0-rc.1/go.mod h1:synthetic-gomod`n")
    [IO.File]::WriteAllText((Join-Path $worker 'vendor/modules.txt'),"# github.com/euler-gaozl/agent-os-runtime v0.1.0-rc.1`n## explicit`n")
    Write-PlatformJson (Join-Path $worker 'deploy/release-contract.json') @{format=1;role='worker';migration_owner='runtime';contract=$contract;backward_compatible=$true;execution_protocol='runtime-execution-v1'}
    Write-PlatformJson (Join-Path $worker 'source-provenance.json') @{sdk=@{commit=('a'*40);module_sum='h1:synthetic-fixture'};owner_modules=@($dependency)}
    & git -C $worker init -q -b main
    & git -C $worker -c user.name=Fixture -c user.email=fixture@example.invalid add .
    & git -C $worker -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m 'Synthetic consumer boundary fixture'
    if($LASTEXITCODE){throw 'Worker fixture Git initialization failed'}
    $indexCommit=(& git -C $worker rev-parse HEAD).Trim()
    $lock.services.worker=@{repository='agent-os-worker';commit=$indexCommit;owner_modules=@($dependency.Clone())}
    Write-PlatformJson $lockPath $lock
    $consumer=Get-SelectedServiceSource $integration worker $contract
    if($consumer.owner_modules.Count -ne 1 -or $consumer.owner_modules[0].commit -cne $dependency.commit){throw 'Owner dependency provenance omitted'}
    $checks.Add('fixed worker narrow worker transaction owner accepted with external migration owner')
    foreach($field in @('commit','version','module_sum','protocol')){
        $saved=$lock.services.worker.owner_modules[0][$field];$lock.services.worker.owner_modules[0][$field]='drift';Write-PlatformJson $lockPath $lock
        Expect-Rejection ('worker transaction dependency drift refused: '+$field) {Get-SelectedServiceSource $integration worker $contract}
        $lock.services.worker.owner_modules[0][$field]=$saved
    }
    $lock.services.worker.Remove('owner_modules');Write-PlatformJson $lockPath $lock
    Expect-Rejection 'missing worker transaction dependency lock refused' {Get-SelectedServiceSource $integration worker $contract}
    foreach($field in @('module_sum','go_mod_sum')){
        $wrong=$dependency.Clone();$wrong[$field]='h1:shared-incorrect-declaration'
        Write-PlatformJson (Join-Path $worker 'source-provenance.json') @{sdk=@{commit=('a'*40);module_sum='h1:synthetic-fixture'};owner_modules=@($wrong)}
        & git -C $worker add -- source-provenance.json
        & git -C $worker -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m 'Synthetic incorrect owner checksum declaration'
        if($LASTEXITCODE){throw 'Worker fixture change failed'}
        $lock.services.worker.commit=(& git -C $worker rev-parse HEAD).Trim()
        $lock.services.worker.owner_modules=@($wrong.Clone());Write-PlatformJson $lockPath $lock
        Expect-Rejection ('matching declarations differing from go.sum refused: '+$field) {Get-SelectedServiceSource $integration worker $contract}
    }
    Write-PlatformJson (Join-Path $root 'result.json') @{passed=$true;checks=@($checks);scope='synthetic source selection only; no service activation or database';model_calls=0}
    Write-Output ('Source ownership checks passed: '+(Join-Path $root 'result.json'))
}catch{
    Write-PlatformJson (Join-Path $root 'result.json') @{passed=$false;checks=@($checks);error=$_.Exception.Message}
    throw
}
