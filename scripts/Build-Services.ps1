param([string[]]$Service = @('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources','migrate-services'),[string]$LayoutPath='')
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-lock.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
$layout=Get-PlatformLayout $repoRoot $LayoutPath
$maintenance=Enter-PlatformMaintenance $layout.state_root
try {
$allowed=@('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','sources','migrate-services')
foreach($name in $Service){if($name -notin $allowed){throw ('Unknown service: '+$name)}}
$go=if(Test-Path 'D:\workspace\.tools\go\bin\go.exe'){'D:\workspace\.tools\go\bin\go.exe'}else{'go'}
$release=Join-Path $layout.release_root ('releases/'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $release -Force|Out-Null
$indexPath=Join-Path $layout.release_root 'current.json'
$index=if(Test-Path -LiteralPath $indexPath){Get-Content -LiteralPath $indexPath -Raw|ConvertFrom-Json -AsHashtable}else{@{}}
Push-Location $repoRoot
try {
 foreach($name in $Service){$target=Join-Path $release ($name+'.exe'); & $go build -trimpath -ldflags='-s -w' -o $target ('./cmd/'+$name);if($LASTEXITCODE -ne 0){throw ('Build failed: '+$name)};$index[$name]=$target}
 Write-PlatformJson $indexPath $index
 Write-Output ('Built independent services: '+($Service -join ', '))
} finally {Pop-Location}

} finally { $maintenance.Dispose() }
