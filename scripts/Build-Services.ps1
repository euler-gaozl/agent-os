param([string[]]$Service = @('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','migrate-services'))
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$allowed=@('control','registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','futures','telemetry','migrate-services')
foreach($name in $Service){if($name -notin $allowed){throw ('Unknown service: '+$name)}}
$go=if(Test-Path 'D:\workspace\.tools\go\bin\go.exe'){'D:\workspace\.tools\go\bin\go.exe'}else{'go'}
$release=Join-Path $repoRoot ('bin\releases\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $release -Force|Out-Null
$indexPath=Join-Path $repoRoot 'bin\current.json'
$index=if(Test-Path -LiteralPath $indexPath){Get-Content -LiteralPath $indexPath -Raw|ConvertFrom-Json -AsHashtable}else{@{}}
Push-Location $repoRoot
try {
 foreach($name in $Service){$target=Join-Path $release ($name+'.exe'); & $go build -trimpath -ldflags='-s -w' -o $target ('./cmd/'+$name);if($LASTEXITCODE -ne 0){throw ('Build failed: '+$name)};$index[$name]=$target}
 $index|ConvertTo-Json|Set-Content -LiteralPath $indexPath -Encoding utf8
 Write-Output ('Built independent services: '+($Service -join ', '))
} finally {Pop-Location}
