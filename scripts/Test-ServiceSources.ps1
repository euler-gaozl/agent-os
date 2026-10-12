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
    if($null -ne (Get-SelectedServiceSource $integration worker $contract)){throw 'Unsplit role unexpectedly mapped'}
    $checks.Add('not-yet-extracted role explicitly stays integration-owned')
    Write-PlatformJson (Join-Path $root 'result.json') @{passed=$true;checks=@($checks);scope='synthetic source selection only; no service activation or database';model_calls=0}
    Write-Output ('Source ownership checks passed: '+(Join-Path $root 'result.json'))
}catch{
    Write-PlatformJson (Join-Path $root 'result.json') @{passed=$false;checks=@($checks);error=$_.Exception.Message}
    throw
}
