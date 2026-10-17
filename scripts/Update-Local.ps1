param(
    [Parameter(Mandatory)][string]$Service,
    [ValidateSet('update','rollback','recover')][string]$Action='update',
    [string]$ReleaseSet='', [string]$LayoutPath='', [ValidateRange(1,120)][int]$TimeoutSeconds=30
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-processes','platform-releases','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$layout=Get-PlatformLayout $root $LayoutPath
$lock=Enter-PlatformMaintenance $layout.state_root
try{
    $target=$null
    if($Action -eq 'update'){
        if(-not $ReleaseSet){throw 'update requires a staged -ReleaseSet from build.'}
        $set=Read-ReleaseJson $ReleaseSet
        if($set.format -ne 1 -or -not $set.releases.Contains($Service)){throw 'The staged set does not contain this service.'}
        $target=$set.releases[$Service]
    }elseif($ReleaseSet){throw 'rollback/recover use the catalog; do not supply a separate release set.'}
    $result=Invoke-ReleaseChange $layout $Service $Action $target $PSScriptRoot $lock $TimeoutSeconds
    # Lifecycle scripts emit progress; retain only the structured final result.
    $report=@($result|Where-Object{$_ -is [System.Collections.IDictionary]})[-1]
    $path=Join-Path (Split-Path -Parent $layout.state_root) ('evidence/release-'+$report.operation+'-'+$Action+'.json')
    Write-PlatformJson $path $report
    $report|ConvertTo-Json -Depth 5
}finally{$lock.Dispose()}
