param([Parameter(Mandatory)][string[]]$Hosts,[string]$LayoutPath='',[ValidateRange(1,120)][int]$TimeoutSeconds=30)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-processes','platform-releases','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$layout=Get-PlatformLayout $root $LayoutPath
$lock=Enter-PlatformMaintenance $layout.state_root
try{
    $result=Set-ServiceMCPHosts $layout 'sources' $Hosts $PSScriptRoot $lock $TimeoutSeconds
    $report=@($result|Where-Object{$_ -is [System.Collections.IDictionary]})[-1]
    Write-PlatformJson (Join-Path (Split-Path -Parent $layout.state_root) ('evidence/source-hosts-'+$report.operation+'.json')) $report
    $report|ConvertTo-Json -Depth 5
}finally{$lock.Dispose()}
