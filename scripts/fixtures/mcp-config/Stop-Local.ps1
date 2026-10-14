param([string]$LayoutPath,[string]$Service,[IO.FileStream]$MaintenanceLock)
$layout=Get-Content -LiteralPath $LayoutPath -Raw|ConvertFrom-Json -AsHashtable
if(-not(Test-PathWithin $layout.state_root 'D:\workspace\agent-platform\local\evidence') -or $Service -cnotin @('runtime','toolhub')){throw 'Invalid isolated configuration fixture.'}
$entries=Read-PlatformProcesses $layout
foreach($entry in @($entries|Where-Object role -eq $Service)){Stop-PlatformInstance $entry $layout {Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $entries}}
Write-PlatformJson (Join-Path $layout.state_root 'processes.json') @($entries|Where-Object role -ne $Service)
