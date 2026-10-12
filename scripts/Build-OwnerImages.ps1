param(
    [Parameter(Mandatory)][string[]]$Service,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$ExportImage
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
. (Join-Path $PSScriptRoot 'lib/service-sources.ps1')
. (Join-Path $PSScriptRoot 'lib/owner-images.ps1')
$roles=@('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources')
if(-not $Service.Count -or @($Service|Sort-Object -Unique).Count -ne $Service.Count){throw 'Select distinct services.'}
foreach($role in $Service){if($role -cnotin $roles){throw 'Unknown independent service.'}}
$destination=[IO.Path]::GetFullPath($OutputDirectory)
Assert-ReleasePhysicalPath (Split-Path -Parent $destination) $destination
if(Test-Path -LiteralPath $destination){throw 'Use a new output directory; previous evidence is immutable.'}
$integration=(& git -C $repoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -or @(& git -C $repoRoot status --porcelain).Count){throw 'Integration source must be committed and clean.'}
# Validate every requested source before invoking Docker or creating contexts.
$sources=@{}
foreach($role in $Service){$sources[$role]=Get-SelectedServiceSource $repoRoot $role (Get-ServiceReleaseContract $repoRoot $role);Assert-ImageSDKSource $sources[$role]}
$null=New-Item -ItemType Directory -Path $destination
$reports=@();$success=$false
try{
    foreach($role in $Service){
        $source=$sources[$role]
        $tree=@(& git -C $source.root ls-tree -r $source.commit)
        if($LASTEXITCODE -or @($tree|Where-Object{$_ -notmatch '^100(644|755) blob [a-f0-9]{40}\t'}).Count){throw 'Image context requires regular tracked files only.'}
        $context=Join-Path $destination ($role+'-context');$null=New-Item -ItemType Directory -Path $context
        $archive=Join-Path $destination ($role+'-source.tar')
        & git -C $source.root archive --format=tar --output=$archive $source.commit
        if($LASTEXITCODE){throw 'Cannot archive the exact owner commit.'}
        & tar -xf $archive -C $context
        if($LASTEXITCODE){throw 'Cannot extract the committed build context.'}
        $tag='agent-os-'+$role+':owner-'+$source.commit
        $arguments=@('build','--platform','linux/amd64','--tag',$tag)
        $labels=Get-OwnerImageLabels $role $source
        foreach($key in $labels.Keys){$arguments+=@('--label',($key+'='+$labels[$key]))}
        $arguments+=@('--file',(Join-Path $context 'Dockerfile'),$context)
        & docker @arguments
        if($LASTEXITCODE){throw ('Owner Docker build failed: '+$role)}
        $raw=& docker image inspect $tag
        if($LASTEXITCODE){throw 'Cannot inspect built image.'}
        $images=@(($raw -join "`n")|ConvertFrom-Json -AsHashtable)
        if($images.Count -ne 1){throw 'Unexpected image result.'}
        $record=Assert-OwnerImage $role $source $images[0]
        $container=(& docker create --network none --read-only --entrypoint /bin/true $record.image).Trim()
        if($LASTEXITCODE -or $container -cnotmatch '^[a-f0-9]{64}$'){throw 'Cannot create inert image extraction container.'}
        $binaryChecks=@()
        try{
            $binaries=@(@{command=$role;path=$record.entrypoint},@{command='healthcheck';path=$record.healthcheck})
            if($record.migrator){$binaries+=@(@{command='migrate';path=$record.migrator})}
            foreach($binary in $binaries){
                $local=Join-Path $destination ($role+'-'+$binary.command+'.binary')
                & docker cp ($container+':'+$binary.path) $local
                if($LASTEXITCODE){throw 'Cannot extract actual image binary.'}
                $buildInfo=& go version -m -json $local
                if($LASTEXITCODE){throw 'Cannot read actual Go binary build info.'}
                $check=Assert-OwnerBinary $role $source (($buildInfo -join "`n")|ConvertFrom-Json -AsHashtable) $binary.command
                $check.sha256=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLower()
                $binaryChecks+=@($check)
            }
        }finally{
            & docker rm $container
            if($LASTEXITCODE){throw 'Image extraction container cleanup failed.'}
        }
        # Check real executables inside the image. Do not count exit 127 as a
        # successful negative readiness check. Network and capabilities absent.
        $probe='test -x '+$record.entrypoint+' && test -x '+$record.healthcheck
        if($record.migrator){$probe+=' && test -x '+$record.migrator}
        & docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --entrypoint /bin/sh $record.image -ec $probe
        if($LASTEXITCODE){throw 'An owner runtime executable is missing or inaccessible.'}
        & docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --entrypoint $record.entrypoint $record.image --help
        if($LASTEXITCODE){throw 'Owner service cannot execute.'}
        if($record.migrator){
            & docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --entrypoint $record.migrator $record.image --help
            if($LASTEXITCODE){throw 'Owner migrator cannot execute.'}
        }
        $after=Get-SelectedServiceSource $repoRoot $role $source.contract
        if($after.commit -cne $source.commit){throw 'Owner source changed during build.'}
        $record.source_archive_sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
        $record.executables_checked=$true
        $record.binary_checks=$binaryChecks
        if($ExportImage){
            $imageArchive=Join-Path $destination ($role+'-image.tar')
            & docker image save --output $imageArchive $record.image
            if($LASTEXITCODE){throw 'Cannot export verified owner image.'}
            $record.image_archive_sha256=(Get-FileHash -LiteralPath $imageArchive -Algorithm SHA256).Hash.ToLower()
        }
        $reports+=@($record)
    }
    $success=$true
}finally{
    $report=@{format=1;integration_commit=$integration;passed=$success;services=$reports;scope='image build, identity, contract and executable checks only; no live service chain or database migration';provider_calls=0}
    $report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $destination 'result.json') -Encoding utf8NoBOM
}
Write-Output ('Verified independent owner images: '+(Join-Path $destination 'result.json'))
