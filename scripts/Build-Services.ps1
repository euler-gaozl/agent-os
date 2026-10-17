param(
    [string[]]$Service=@('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources'),
    [string]$LayoutPath='', [string]$Pnpm='pnpm', [string]$NodeBinary='', [string]$SourceArtifact='', [string]$ResidentArtifact='', [string]$BudgetArtifact='', [string]$NativeArtifact='', [string]$FinalArtifact='', [string]$GuardedArtifact='', [switch]$AllowDirty
)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
. (Join-Path $PSScriptRoot 'lib/service-sources.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root
$saved=@{};foreach($key in @('PATH','GOPATH','GOCACHE','GOWORK','GOENV','GOFLAGS','GOTOOLCHAIN','GOROOT','GOOS','GOARCH','GOAMD64','GOEXPERIMENT','CGO_ENABLED')){$saved[$key]=[Environment]::GetEnvironmentVariable($key)}
try{
    Assert-NoPendingOwnerMigration $layout
    $allowed=@('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources')
    if(-not $Service.Count){throw 'Select at least one service to build.'}
    if($SourceArtifact -and 'worker' -notin $Service){throw 'SourceArtifact requires a selected Worker build.'}
    if($ResidentArtifact -and 'worker' -notin $Service){throw 'ResidentArtifact requires a selected Worker build.'}
    if($BudgetArtifact -and 'worker' -notin $Service){throw 'BudgetArtifact requires a selected Worker build.'}
    if($NativeArtifact -and 'worker' -notin $Service){throw 'NativeArtifact requires a selected Worker build.'}
    if($FinalArtifact -and 'worker' -notin $Service){throw 'FinalArtifact requires a selected Worker build.'}
    if($GuardedArtifact -and 'worker' -notin $Service){throw 'GuardedArtifact requires a selected Worker build.'}
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
    $env:GOWORK='off'
    $env:GOENV='off';$env:GOFLAGS='';$env:GOTOOLCHAIN='local';$env:GOROOT=$null
    $env:GOOS='windows';$env:GOARCH='amd64';$env:GOAMD64='v1';$env:GOEXPERIMENT='';$env:CGO_ENABLED='0'
    $go=if(Test-Path -LiteralPath 'D:\workspace\.tools\go\bin\go.exe'){'D:\workspace\.tools\go\bin\go.exe'}else{(Get-Command go -ErrorAction Stop).Source}
    $buildId=[guid]::NewGuid().ToString('N');$references=@{}
    Push-Location $repoRoot
    try{
        foreach($role in $Service|Sort-Object -Unique){
            $contract=Get-ServiceReleaseContract $repoRoot $role
            $owner=Get-SelectedServiceSource $repoRoot $role $contract
            if($owner){$contract=$owner.contract}
            $sourceExecution=$null;$residentExecution=$null;$budgetExecution=$null;$nativeExecution=$null;$finalExecution=$null;$guardedExecution=$null
            if($role -eq 'runtime' -and $owner -and $owner.release['source_submission_protocol']){
                $sourceExecution=@{format=1;engine=$owner.release.source_engine_candidate;execution_protocol=$owner.release.execution_protocol;state_protocol=$owner.release.source_management_protocol;submission_protocol=$owner.release.source_submission_protocol;preview_protocol=$owner.release.source_management_preview_protocol}
                if($owner.release['source_engine_candidates']){
                    $candidates=@($owner.release.source_engine_candidates)
                    if($candidates.Count -ne @($candidates|Sort-Object -Unique).Count -or @($candidates|Where-Object{$_ -cnotin @((Get-SourceEngineProfiles).engine)}).Count){throw 'Runtime declares unsupported or duplicate source engines.'}
                    if((Get-ResidentEngineName) -cin $candidates){
                        $residentExecution=@{};foreach($key in $sourceExecution.Keys){$residentExecution[$key]=$sourceExecution[$key]}
                        $residentExecution.engine=Get-ResidentEngineName
                    }
                    if((Get-BudgetEngineName) -cin $candidates){
                        if($owner.release['budget_model_receipt_protocol'] -ne 1){throw 'Runtime budget receipt protocol is missing.'}
                        $budgetExecution=$sourceExecution.Clone();$budgetExecution.engine=Get-BudgetEngineName
                        $budgetExecution.model_receipt_protocol='budget-model-receipt-v1'
                    }
                    if((Get-NativeEngineName) -cin $candidates){
                        if($owner.release['native_model_receipt_protocol'] -ne 2){throw 'Runtime native receipt protocol is missing.'}
                        $nativeExecution=$sourceExecution.Clone();$nativeExecution.engine=Get-NativeEngineName
                        $nativeExecution.model_receipt_protocol='native-model-receipt-v2'
                    }
                    if((Get-FinalEngineName) -cin $candidates){
                        if($owner.release['native_model_receipt_protocol'] -ne 2 -or $owner.release['final_output_protocol'] -ne 1 -or $owner.release['final_continuation_protocol'] -ne 1){throw 'Runtime final receipt or continuation protocol is missing.'}
                        $finalExecution=$sourceExecution.Clone();$finalExecution.engine=Get-FinalEngineName
                        $finalExecution.model_receipt_protocol='native-model-receipt-v2';$finalExecution.final_output_protocol='receipt-field-v1'
                        $finalExecution.continuation_protocol='final-model-continuation-v1'
                    }
                    if((Get-GuardedEngineName) -cin $candidates){
                        if(-not $finalExecution -or $owner.release['tool_input_protocol'] -ne 1){throw 'Guarded Runtime protocols are incomplete.'}
                        $guardedExecution=$finalExecution.Clone();$guardedExecution.engine=Get-GuardedEngineName;$guardedExecution.tool_input_protocol=1
                    }
                }
            }
            $directory=Join-Path $layout.release_root ('bundles/'+$role+'-'+$buildId)
            Assert-ReleasePhysicalPath $layout.release_root $directory
            if(Test-Path -LiteralPath $directory){throw 'Build destination already exists.'}
            $null=New-Item -ItemType Directory -Path $directory -Force
            $binary=Join-Path $directory ($role+'.exe')
            if($owner){& $go -C $owner.root build -mod=vendor -trimpath -ldflags='-s -w' -o $binary ('./cmd/'+$role)}
            else{& $go build -trimpath -ldflags='-s -w' -o $binary ('./cmd/'+$role)}
            if($LASTEXITCODE){throw ('Build failed: '+$role)}
            if($owner){
                $info=(& $go version -m -json $binary)|ConvertFrom-Json -AsHashtable
                if($LASTEXITCODE -or $info.Main.Path -cne ('github.com/euler-gaozl/'+$owner.repository)){throw 'Built module identity differs from its owner.'}
                $sdk=@($info.Deps|Where-Object{$_.Path -ceq $owner.sdk.module})
                if($sdk.Count -ne 1 -or $sdk[0].Version -cne $owner.sdk.version -or $sdk[0]['Replace']){throw 'Built SDK differs from the recorded fixed dependency.'}
                foreach($dependency in $owner.owner_modules){
                    $compiled=@($info.Deps|Where-Object{$_.Path -ceq $dependency.module})
                    if($compiled.Count -ne 1 -or $compiled[0].Version -cne $dependency.version -or $compiled[0]['Replace']){throw 'Built transaction module differs from its fixed owner dependency.'}
                }
                $settings=@{};foreach($setting in $info.Settings){$settings[$setting.Key]=$setting.Value}
                if($settings['vcs.revision'] -cne $owner.commit -or $settings['vcs.modified'] -cne 'false' -or $settings['GOOS'] -cne 'windows' -or $settings['GOARCH'] -cne 'amd64'){
                    throw 'Built version or target does not match the selected clean service commit.'
                }
                # Fail if source changed during compilation; no descriptor is published.
                $after=Get-SelectedServiceSource $repoRoot $role $contract
                if($after.commit -cne $owner.commit){throw 'Service source changed during compilation.'}
            }
            $assets=@{binary=(Get-ReleaseRelative $layout.release_root $binary)}
            if($role -eq 'worker'){
                $nodeVersion=& $NodeBinary --version
                if($LASTEXITCODE -or $nodeVersion -notmatch '^v24\.'){throw 'This pinned Harness release requires Node 24.'}
                Copy-Item -LiteralPath $NodeBinary -Destination (Join-Path $directory 'node.exe')
                if($owner){
                    $notice=Join-Path $owner.root ('licenses/node-'+$nodeVersion.Trim()+'.txt')
                    if(-not(Test-Path -LiteralPath $notice)){throw 'Selected Worker source does not include notices for this Node version.'}
                }
                $harness=Join-Path $directory 'harness';$null=New-Item -ItemType Directory -Path $harness
                # Keep redistributed Node notices inside an inventoried asset tree,
                # so export/backup/restore carries the license with the binary.
                if($owner){Copy-Item -LiteralPath $notice -Destination (Join-Path $harness 'NODE-LICENSE.txt')}
                $harnessSource=if($owner){$owner.root}else{$repoRoot}
                $tracked=(& git -C $harnessSource ls-files -- harness) -split '\r?\n'
                foreach($relative in $tracked|Where-Object{$_}){
                    $source=Resolve-ReleasePath $harnessSource $relative
                    $target=Resolve-ReleasePath $harness $relative.Substring('harness/'.Length)
                    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
                    Copy-Item -LiteralPath $source -Destination $target
                }
                # Install into THIS dependency tree; old absolute junctions must not escape.
                & $Pnpm --dir $harness install --frozen-lockfile --ignore-scripts --prod --config.node-linker=hoisted --store-dir 'D:\workspace\.tools\pnpm-store'
                if($LASTEXITCODE){throw 'Pinned Harness dependency installation failed.'}
                & (Join-Path $directory 'node.exe') --test (Join-Path $harness 'session-seams.test.mjs')
                if($LASTEXITCODE){throw 'Staged Harness interface checks failed.'}
                if(@(Get-ChildItem -LiteralPath $harness -Recurse -Force|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Windows Harness bundle must not contain directory or file links.'}
                $assets.node=Get-ReleaseRelative $layout.release_root (Join-Path $directory 'node.exe')
                $assets.harness=Get-ReleaseRelative $layout.release_root $harness
                if($SourceArtifact){
                    if(-not $owner){throw 'Source Harness requires an independently pinned Worker source.'}
                    $sourcePath=Join-Path $directory 'source-harness'
                    $sourceExecution=Copy-PinnedSourceHarness $SourceArtifact $sourcePath (Join-Path $owner.root 'worker/source-harness-lock.json')
                    $assets.source_harness=Get-ReleaseRelative $layout.release_root $sourcePath
                }
                if($ResidentArtifact){
                    if(-not $owner -or $owner.release['resident_engine_candidate'] -cne (Get-ResidentEngineName)){throw 'Resident Harness requires a resident-enabled independent Worker.'}
                    $residentPath=Join-Path $directory 'resident-harness'
                    $residentExecution=Copy-PinnedSourceHarness $ResidentArtifact $residentPath (Join-Path $owner.root 'worker/resident-harness-lock.json') (Get-ResidentEngineName)
                    $assets.resident_harness=Get-ReleaseRelative $layout.release_root $residentPath
                }
                if($BudgetArtifact){
                    if(-not $owner -or $owner.release['budget_engine_candidate'] -cne (Get-BudgetEngineName) -or $owner.release['budget_model_receipt_protocol'] -ne 1){throw 'Budget Harness requires a compatible independent Worker.'}
                    $budgetPath=Join-Path $directory 'budget-harness'
                    $budgetExecution=Copy-PinnedSourceHarness $BudgetArtifact $budgetPath (Join-Path $owner.root 'worker/budget-harness-lock.json') (Get-BudgetEngineName)
                    $assets.budget_harness=Get-ReleaseRelative $layout.release_root $budgetPath
                }
                if($NativeArtifact){
                    if(-not $owner -or $owner.release['native_engine_candidate'] -cne (Get-NativeEngineName) -or $owner.release['native_model_receipt_protocol'] -ne 2){throw 'Native Harness requires a compatible independent Worker.'}
                    $nativePath=Join-Path $directory 'native-harness'
                    $nativeExecution=Copy-PinnedSourceHarness $NativeArtifact $nativePath (Join-Path $owner.root 'worker/native-harness-lock.json') (Get-NativeEngineName)
                    $assets.native_harness=Get-ReleaseRelative $layout.release_root $nativePath
                }
                if($FinalArtifact){
                    if(-not $owner -or $owner.release['final_engine_candidate'] -cne (Get-FinalEngineName) -or $owner.release['native_model_receipt_protocol'] -ne 2 -or $owner.release['final_output_protocol'] -ne 1){throw 'Final Harness requires a compatible independent Worker.'}
                    $finalPath=Join-Path $directory 'final-harness'
                    $finalExecution=Copy-PinnedSourceHarness $FinalArtifact $finalPath (Join-Path $owner.root 'worker/final-harness-lock.json') (Get-FinalEngineName)
                    $assets.final_harness=Get-ReleaseRelative $layout.release_root $finalPath
                }
                if($GuardedArtifact){
                    if(-not $owner -or $owner.release['guarded_engine_candidate'] -cne (Get-GuardedEngineName) -or $owner.release['tool_input_protocol'] -ne 1){throw 'Guarded Harness requires a compatible independent Worker.'}
                    $guardedPath=Join-Path $directory 'guarded-harness'
                    $guardedExecution=Copy-PinnedSourceHarness $GuardedArtifact $guardedPath (Join-Path $owner.root 'worker/guarded-harness-lock.json') (Get-GuardedEngineName)
                    $assets.guarded_harness=Get-ReleaseRelative $layout.release_root $guardedPath
                }
            }
            if($role -in @('control','futures')){
                $webSource=Join-Path $owner.root 'web'
                & $Pnpm --dir $webSource install --frozen-lockfile --ignore-scripts --store-dir 'D:\workspace\.tools\pnpm-store'
                if($LASTEXITCODE){throw 'Web dependency installation failed.'}
                & $Pnpm --dir $webSource exec tsc --noEmit
                if($LASTEXITCODE){throw 'Web type checking failed.'}
                $mode=if($role -eq 'control'){'console'}else{'futures'}
                $output=Join-Path $directory 'web'
                & $Pnpm --dir $webSource exec vite build --mode $mode --outDir $output
                if($LASTEXITCODE){throw 'Selected Web build failed.'}
                $assets.web=Get-ReleaseRelative $layout.release_root $output
            }
            $provenance=@{kind='source-build';commit=$revision;dirty=$dirty;built_at=[datetime]::UtcNow.ToString('o')}
            if($owner){$after=Get-SelectedServiceSource $repoRoot $role $contract;if($after.commit -cne $owner.commit){throw 'Service source changed while packaging runtime assets.'}}
            if($owner){$provenance=@{kind='independent-source-build';repository=$owner.repository;commit=$owner.commit;integration_commit=$revision;dirty=$dirty;sdk=$owner.sdk;owner_modules=$owner.owner_modules;built_at=[datetime]::UtcNow.ToString('o')}}
            $receiptManagement=if($owner){$owner.release['receipt_management']}else{$null}
            $executionAccess=$null;if($owner){$executionAccess=Get-DeclaredExecutionAccess $owner.release}
            if($null -ne $executionAccess){Assert-ExecutionAccessBinary $binary @{role=$role;execution_access=$executionAccess}}
            $knowledgeArchives=$null;if($owner){$knowledgeArchives=Get-DeclaredKnowledgeArchives $owner.release}
            if($null -ne $knowledgeArchives){Assert-KnowledgeArchiveBinary $binary @{role=$role;contract=$contract;source_archives=$knowledgeArchives}}
            $modelManagement=$null;if($owner){$modelManagement=Get-DeclaredModelManagement $owner.release}
            if($null -ne $modelManagement){Assert-ModelManagementBinary $binary @{role=$role;model_management=$modelManagement}}
            $continuationManagement=if($owner){$owner.release['continuation_management']}else{$null}
            $references[$role]=New-ReleaseDescriptor $layout $role $assets $contract $provenance $sourceExecution $residentExecution $receiptManagement $executionAccess $knowledgeArchives -BudgetExecution $budgetExecution -NativeExecution $nativeExecution -FinalExecution $finalExecution -GuardedExecution $guardedExecution -ModelManagement $modelManagement -ContinuationManagement $continuationManagement
        }
    }finally{Pop-Location}
    $staged=Join-Path $layout.release_root ('staged/'+$buildId+'.json')
    Write-PlatformJson $staged @{format=1;build=$buildId;releases=$references;activated=$false}
    Write-Output ('Staged complete service bundles without changing any current version: '+$staged)
}finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])};$maintenance.Dispose()}
