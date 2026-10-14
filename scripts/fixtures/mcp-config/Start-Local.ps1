param([string]$LayoutPath,[string]$Service,[IO.FileStream]$MaintenanceLock,[string]$PendingOperation='')
# Test-only lifecycle for synthetic HTTP processes on ephemeral ports. The
# production Start-Local cross-layout exclusion remains enabled and unchanged.
$layout=Get-Content -LiteralPath $LayoutPath -Raw|ConvertFrom-Json -AsHashtable
if(-not(Test-PathWithin $layout.state_root 'D:\workspace\agent-platform\local\evidence') -or $Service -cnotin @('runtime','toolhub')){throw 'Invalid isolated configuration fixture.'}
$release=Get-PlatformRelease $layout $Service $PendingOperation -Verify
$bytes=[IO.File]::ReadAllBytes((Join-Path $layout.config_root ('services/'+$Service+'.json')))
if((Get-BytesHash $bytes) -cne $release.reference.config_sha256){throw 'Fixture config/release mismatch.'}
$entries=Read-PlatformProcesses $layout
if(@($entries|Where-Object role -eq $Service).Count){throw 'Fixture service already present.'}
$identifier=[guid]::NewGuid().ToString('N');$id=$Service+'-'+$identifier
$launch=Join-Path $layout.config_root ('launches/'+$id+'.json')
$config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable
Write-PlatformJson $launch $config
$entry=@{pid=0;role=$Service;id=$id;started_at=$null;binary=$release.assets.binary;status='launching';intent_at=[datetime]::UtcNow.ToString('o');job_name=('Global\AgentOS-'+$identifier);launch_config=$launch;launch_config_sha256=(Get-BytesHash $bytes);source_config_sha256=(Get-BytesHash $bytes);release_reference=$release.reference}
# Write-PlatformJson may choose different indentation; bind the actual snapshot.
$entry.launch_config_sha256=(Get-FileHash -LiteralPath $launch).Hash.ToLowerInvariant()
$all=@($entries)+@($entry)
Start-PlatformInstance $entry $layout {Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $all}
Write-PlatformJson (Join-Path $layout.state_root 'processes.json') $all
