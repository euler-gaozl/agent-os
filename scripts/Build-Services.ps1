param(
    [string[]]$Service=@('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources','migrate-services'),
    [string]$LayoutPath='', [string]$Pnpm='pnpm', [string]$NodeBinary='', [switch]$AllowDirty
)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root
$saved=@{};foreach($key in @('PATH','GOPATH','GOCACHE')){$saved[$key]=[Environment]::GetEnvironmentVariable($key)}
try{
    $allowed=@('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources','migrate-services')
    if(-not $Service.Count){throw 'Select at least one service to build.'}
    foreach($role in $Service){if($role -notin $allowed){throw ('Unknown service: '+$role)}}
    if(Test-Path -LiteralPath (Join-Path $layout.release_root 'current.json')){Assert-NoPendingRelease (Read-ReleaseCatalog $layout)}
    $revision=(& git -C $repoRoot rev-parse HEAD).Trim();if($LASTEXITCODE){throw 'Cannot identify build source.'}
    $dirty=@(& git -C $repoRoot status --porcelain).Count -gt 0
    if($dirty -and -not $AllowDirty){throw 'Source has uncommitted changes. Commit before building a release, or explicitly stage a marked development build with -AllowDirty.'}
    $needsNode=@($Service|Where-Object{$_ -in @('worker','control','futures')}).Count -gt 0
    if($needsNode -and -not $NodeBinary){
        if(Test-Path -LiteralPath (Join-Path $layout.release_root 'current.json')){$NodeBinary=(Get-PlatformRelease $layout worker).assets.node}
        elseif($layout['node_binary']){$NodeBinary=$layout.node_binary}else{$NodeBinary=(Get-Command node -ErrorAction Stop).Source}
    }
    if($needsNode){$NodeBinary=[IO.Path]::GetFullPath($NodeBinary);$env:PATH=(Split-Path -Parent $NodeBinary)+';'+$env:PATH}
    $env:GOPATH='D:\workspace\.tools\gopath';$env:GOCACHE='D:\workspace\.tools\gocache'
    $go=if(Test-Path -LiteralPath 'D:\workspace\.tools\go\bin\go.exe'){'D:\workspace\.tools\go\bin\go.exe'}else{(Get-Command go -ErrorAction Stop).Source}
    $buildId=[guid]::NewGuid().ToString('N');$references=@{}
    Push-Location $repoRoot
    try{
        foreach($role in $Service|Sort-Object -Unique){
            $directory=Join-Path $layout.release_root ('bundles/'+$role+'-'+$buildId)
            Assert-ReleasePhysicalPath $layout.release_root $directory
            if(Test-Path -LiteralPath $directory){throw 'Build destination already exists.'}
            $null=New-Item -ItemType Directory -Path $directory -Force
            $binary=Join-Path $directory ($role+'.exe')
            & $go build -trimpath -ldflags='-s -w' -o $binary ('./cmd/'+$role)
            if($LASTEXITCODE){throw ('Build failed: '+$role)}
            $assets=@{binary=(Get-ReleaseRelative $layout.release_root $binary)}
            if($role -eq 'worker'){
                $nodeVersion=& $NodeBinary --version
                if($LASTEXITCODE -or $nodeVersion -notmatch '^v24\.'){throw 'This pinned Harness release requires Node 24.'}
                Copy-Item -LiteralPath $NodeBinary -Destination (Join-Path $directory 'node.exe')
                $harness=Join-Path $directory 'harness';$null=New-Item -ItemType Directory -Path $harness
                $tracked=(& git ls-files -- harness) -split '\r?\n'
                foreach($relative in $tracked|Where-Object{$_}){
                    $source=Resolve-ReleasePath $repoRoot $relative
                    $target=Resolve-ReleasePath $harness $relative.Substring('harness/'.Length)
                    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
                    Copy-Item -LiteralPath $source -Destination $target
                }
                # Install into THIS dependency tree; old absolute junctions must not escape.
                & $Pnpm --dir $harness install --frozen-lockfile --ignore-scripts --prod --store-dir 'D:\workspace\.tools\pnpm-store'
                if($LASTEXITCODE){throw 'Pinned Harness dependency installation failed.'}
                & (Join-Path $directory 'node.exe') --test (Join-Path $harness 'session-seams.test.mjs')
                if($LASTEXITCODE){throw 'Staged Harness interface checks failed.'}
                $assets.node=Get-ReleaseRelative $layout.release_root (Join-Path $directory 'node.exe')
                $assets.harness=Get-ReleaseRelative $layout.release_root $harness
            }
            if($role -in @('control','futures')){
                & $Pnpm --dir (Join-Path $repoRoot 'web') install --frozen-lockfile --ignore-scripts --store-dir 'D:\workspace\.tools\pnpm-store'
                if($LASTEXITCODE){throw 'Web dependency installation failed.'}
                & $Pnpm --dir (Join-Path $repoRoot 'web') exec tsc --noEmit
                if($LASTEXITCODE){throw 'Web type checking failed.'}
                $mode=if($role -eq 'control'){'console'}else{'futures'}
                $output=Join-Path $directory 'web'
                & $Pnpm --dir (Join-Path $repoRoot 'web') exec vite build --mode $mode --outDir $output
                if($LASTEXITCODE){throw 'Selected Web build failed.'}
                $assets.web=Get-ReleaseRelative $layout.release_root $output
            }
            $references[$role]=New-ReleaseDescriptor $layout $role $assets (Get-ServiceReleaseContract $repoRoot $role) @{kind='source-build';commit=$revision;dirty=$dirty;built_at=[datetime]::UtcNow.ToString('o')}
        }
    }finally{Pop-Location}
    $staged=Join-Path $layout.release_root ('staged/'+$buildId+'.json')
    Write-PlatformJson $staged @{format=1;build=$buildId;releases=$references;activated=$false}
    Write-Output ('Staged complete service bundles without changing any current version: '+$staged)
}finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])};$maintenance.Dispose()}
