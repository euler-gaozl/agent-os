param([Parameter(Mandatory)][string]$RulesFile,[string]$LayoutPath='',[ValidateRange(1,120)][int]$TimeoutSeconds=30)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($library in @('platform-paths','platform-lock','platform-processes','platform-releases','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$library+'.ps1'))}
$rules=ConvertTo-ReceiptExports (Get-Content -LiteralPath $RulesFile -Raw)
$layout=Get-PlatformLayout $root $LayoutPath
$lock=Enter-PlatformMaintenance $layout.state_root
try{
    $result=Set-ServiceMCPHosts $layout runtime @($rules) $PSScriptRoot $lock $TimeoutSeconds -Policy receipt-exports
    $report=@($result|Where-Object{$_ -is [System.Collections.IDictionary]})[-1]
    Write-PlatformJson (Join-Path (Split-Path -Parent $layout.state_root) ('evidence/receipt-config-'+$report.operation+'.json')) $report
    $report|ConvertTo-Json -Depth 5
}finally{$lock.Dispose()}
