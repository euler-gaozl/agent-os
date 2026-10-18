$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
. (Join-Path $PSScriptRoot 'lib/owner-images.ps1')
$repo=Split-Path -Parent $PSScriptRoot
$count=0
foreach($role in @('registry','runtime','worker','control','futures','toolhub','knowledge','indexer','sandbox','sources','storage','telemetry')){
    $source=@{repository=$(if($role -eq 'control'){'agent-os-console'}else{'agent-os-'+$role});commit=('a'*40);contract=(Get-ServiceReleaseContract $repo $role);sdk=@{};owner_modules=@()}
    $app=$role -in @('worker','control','futures');$base=if($app){'/app'}else{'/usr/local/bin'}
    $good=@{Id=('sha256:'+('b'*64));Os='linux';Architecture='amd64';Config=@{User=$(if($app){'10001'}else{'65532:65532'});Labels=(Get-OwnerImageLabels $role $source);Entrypoint=@($base+'/service');Cmd=@('--config','/run/service.json');Healthcheck=@{Test=@('CMD',($base+'/healthcheck'))}}}
    $record=Assert-OwnerImage $role $source $good
    if(($role -in @('worker','control','futures','indexer')) -and $record.migrator){throw 'Consumer unexpectedly owns a migrator.'}
    $count++
    $changes=@(
        {param($x) $x.Config.User='0'},
        {param($x) $x.Architecture='arm64'},
        {param($x) $x.Id='latest'},
        {param($x) $x.Config.Entrypoint=@('/bin/sh')},
        {param($x) $x.Config.Cmd=@('--config','/run/all-services.json')},
        {param($x) $x.Config.Healthcheck.Test=@('NONE')},
        {param($x) $x.Config.Healthcheck.Test=@('CMD','/missing/healthcheck')},
        {param($x) $x.Config.Labels['org.opencontainers.image.revision']=('c'*40)},
        {param($x) $x.Config.Labels['org.opencontainers.image.source']='https://example.invalid/other'},
        {param($x) $x.Config.Labels['org.agentos.role']='wrong'},
        {param($x) $x.Config.Labels['org.agentos.contract']='{}'},
        {param($x) $x.Config.Labels['org.agentos.builtin-tools']='["unknown_tool"]'},
        {param($x) $x.Config.Labels['org.agentos.worker-engines']='["unknown-engine"]'}
    )
    foreach($change in $changes){
        $bad=$good|ConvertTo-Json -Depth 12|ConvertFrom-Json -AsHashtable
        & $change $bad
        $denied=$false
        try{$null=Assert-OwnerImage $role $source $bad}catch{$denied=$true}
        if(-not $denied){throw ('Incompatible image was accepted: '+$role)}
        $count++
    }
}
$source=@{repository='agent-os-worker';sdk=@{module='github.com/euler-gaozl/agent-os-sdk';version='v0.1.0-rc.2'};owner_modules=@(@{module='github.com/euler-gaozl/agent-os-runtime';version='v0.1.0-rc.1'})}
$info=@{Main=@{Path='github.com/euler-gaozl/agent-os-worker'};Path='github.com/euler-gaozl/agent-os-worker/cmd/worker';GoVersion='go1.27.2';Settings=@(@{Key='GOOS';Value='linux'},@{Key='GOARCH';Value='amd64'},@{Key='CGO_ENABLED';Value='0'});Deps=@(@{Path=$source.sdk.module;Version=$source.sdk.version},@{Path=$source.owner_modules[0].module;Version=$source.owner_modules[0].version})}
$null=Assert-OwnerBinary worker $source $info worker;$count++
foreach($change in @(
    {param($x) $x.Main.Path='github.com/euler-gaozl/agent-os'},
    {param($x) $x.Path='github.com/euler-gaozl/agent-os-worker/cmd/healthcheck'},
    {param($x) $x.Main.Replace=@{Path='../local'}},
    {param($x) $x.Deps[0].Version='v99.0.0'},
    {param($x) $x.Deps[1].Version='v99.0.0'},
    {param($x) $x.Deps[1].Replace=@{Path='../runtime'}},
    {param($x) $x.Deps=@($x.Deps[0])},
    {param($x) $x.Deps+=@(@{Path='github.com/euler-gaozl/agent-os-storage';Version='v0.1.0'})},
    {param($x) $x.Settings[0].Value='windows'},
    {param($x) $x.Settings[2].Value='1'}
)){
    $bad=$info|ConvertTo-Json -Depth 12|ConvertFrom-Json -AsHashtable;& $change $bad
    $denied=$false;try{$null=Assert-OwnerBinary worker $source $bad worker}catch{$denied=$true}
    if(-not $denied){throw 'Incompatible binary build info accepted.'};$count++
}
Write-Output ('Passed '+$count+' synthetic image and binary contract cases; no Docker or live readiness claim.')
