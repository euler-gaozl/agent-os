param([string]$EvidenceRoot='D:\workspace\agent-platform\local\evidence')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
foreach($file in @('platform-paths','platform-releases','platform-release-operations')){. (Join-Path $PSScriptRoot ('lib/'+$file+'.ps1'))}
$proof=Join-Path $EvidenceRoot ('receipt-release-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $proof,(Join-Path $proof 'releases\descriptors'),(Join-Path $proof 'releases\web'),(Join-Path $proof 'config\services'),(Join-Path $proof 'state')
$layout=@{release_root=(Join-Path $proof 'releases');config_root=(Join-Path $proof 'config');state_root=(Join-Path $proof 'state')}
$checks=[Collections.Generic.List[string]]::new()
function Accept([scriptblock]$Action,[string]$Name){& $Action|Out-Null;$checks.Add($Name)}
function Deny([scriptblock]$Action,[string]$Name,[string]$Message=''){$denied=$false;try{& $Action|Out-Null}catch{if($Message -and $_.Exception.Message -notmatch $Message){throw};$denied=$true};if(-not $denied){throw ('Unexpected acceptance: '+$Name)};$checks.Add($Name)}
$result=@{passed=$false;paid_model_calls=0;ci_runs=0;scope='Actual descriptor hashing/catalog/export/restore and pre-stop release rejection with inert file assets; no process activation or database mutation';source_hashes=@{}}
foreach($file in @('Test-ReceiptManagement.ps1','lib/platform-receipts.ps1','lib/platform-releases.ps1','lib/platform-release-operations.ps1','lib/platform-source-execution.ps1','Build-Services.ps1','Start-Local.ps1')){$result.source_hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file)).Hash}
try{
 $contract=@{http='fixture-v1';data='fixture-v1';engines=@();tools=@()}
 Set-Content -LiteralPath (Join-Path $layout.release_root 'runtime.exe') -Value 'inert Runtime fixture'
 Set-Content -LiteralPath (Join-Path $layout.release_root 'control.exe') -Value 'inert Console fixture'
 Set-Content -LiteralPath (Join-Path $layout.release_root 'web\index.html') -Value 'inert Web fixture'
 $provenance=@{kind='fixture';dirty=$false}
 $runtimeOld=New-ReleaseDescriptor $layout runtime @{binary='runtime.exe'} $contract $provenance
 $runtimeNew=New-ReleaseDescriptor $layout runtime @{binary='runtime.exe'} $contract $provenance -ReceiptManagement @{format=1;provides='call-receipts-v1'}
 $controlOld=New-ReleaseDescriptor $layout control @{binary='control.exe';web='web'} $contract $provenance
 $controlNew=New-ReleaseDescriptor $layout control @{binary='control.exe';web='web'} $contract $provenance -ReceiptManagement @{format=1;requires='call-receipts-v1'}
 $ro=Read-ReleaseDescriptor $layout $runtimeOld -Verify;$rn=Read-ReleaseDescriptor $layout $runtimeNew -Verify
 $co=Read-ReleaseDescriptor $layout $controlOld -Verify;$cn=Read-ReleaseDescriptor $layout $controlNew -Verify
 Accept {Assert-ReceiptManagementPolicy $ro $co} 'old_pair_valid'
 Accept {Assert-ReceiptManagementPolicy $rn $co} 'Runtime_can_upgrade_first_or_Console_roll_back_first'
 Accept {Assert-ReceiptManagementPolicy $rn $cn} 'new_pair_valid'
 Deny {Assert-ReceiptManagementPolicy $ro $cn} 'new_Console_old_Runtime_refused' 'Upgrade Runtime first'
 foreach($value in @(@{format=2;provides='call-receipts-v1'},@{format=1;provides='unknown'},@{format='1';provides='call-receipts-v1'},@{format=1;requires='call-receipts-v1'},@{format=1;provides='call-receipts-v1';extra='x'},@{},$null)){
  Deny {Assert-ReceiptManagementDescriptor @{role='runtime';receipt_management=$value}} ('invalid_capability_'+$checks.Count)
 }
 Deny {Assert-ReceiptManagementDescriptor @{role='worker';receipt_management=@{format=1;provides='call-receipts-v1'}}} 'foreign_role_cannot_claim_receipt_capability'
 foreach($entry in @(@{role='runtime';field='provides'},@{role='control';field='requires'})){
  foreach($bad in @(@(),@('call-receipts-v1'),@{name='call-receipts-v1'})){
   $value=@{format=1};$value[$entry.field]=$bad
   Deny {Assert-ReceiptManagementDescriptor @{role=$entry.role;receipt_management=$value}} ('non_string_protocol_'+$entry.role+'_'+$checks.Count)
  }
 }
 Deny {Assert-ReceiptManagementDescriptor @{role=@('runtime');receipt_management=@{format=1;provides='call-receipts-v1'}}} 'non_string_role_rejected'
 $catalog=@{format=2;generation=1;services=@{runtime=@{current=$runtimeOld;previous=$null};control=@{current=$controlOld;previous=$null}}}
 $catalogPath=Join-Path $layout.release_root 'current.json';Write-PlatformJson $catalogPath $catalog
 Accept {Assert-ReceiptManagementDeployment $layout} 'old_catalog_accepted'
 $partial=@{format=2;generation=1;services=@{runtime=@{current=$runtimeNew;previous=$runtimeOld}}}
 Write-PlatformJson $catalogPath $partial
 Accept {Assert-ReceiptManagementDeployment $layout} 'independent_Runtime_without_Console_can_start'
 Write-PlatformJson $catalogPath $catalog
 Deny {Assert-ReceiptManagementDeployment $layout @{control=$cn}} 'startup_candidate_mismatch_refused' 'Upgrade Runtime first'
 $before=(Get-FileHash -LiteralPath $catalogPath).Hash
 Deny {Invoke-ReleaseChange $layout control update $controlNew $PSScriptRoot $null} 'Console_update_rejected_before_pending_or_stop' 'Upgrade Runtime first'
 if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $before){throw 'Rejected change modified catalog'}
 $catalog.services.runtime.current=$runtimeNew;$catalog.services.runtime.previous=$runtimeOld
 $catalog.services.control.current=$controlNew;$catalog.services.control.previous=$controlOld
 $runtimePath=Join-Path $layout.config_root 'services/runtime.json';$controlPath=Join-Path $layout.config_root 'services/control.json'
 Write-PlatformJson $runtimePath @{LISTEN='127.0.0.1:8094';DATABASE_URL='fixture://no-connection'}
 Write-PlatformJson $controlPath @{RUNTIME_URL='http://127.0.0.1:8094'}
 $runtimeNew.config_sha256=(Get-FileHash -LiteralPath $runtimePath).Hash.ToLowerInvariant()
 $controlNew.config_sha256=(Get-FileHash -LiteralPath $controlPath).Hash.ToLowerInvariant()
 Write-PlatformJson $catalogPath $catalog
 $before=(Get-FileHash -LiteralPath $catalogPath).Hash
 Deny {Invoke-ReleaseChange $layout runtime rollback $null $PSScriptRoot $null} 'Runtime_rollback_rejected_before_pending_or_stop' 'Upgrade Runtime first'
 if((Get-FileHash -LiteralPath $catalogPath).Hash -cne $before){throw 'Rejected rollback modified catalog'}
 Accept {Assert-ReceiptManagementDeployment $layout @{control=$co}} 'Console_rollback_candidate_accepted'
 Accept {Assert-ReceiptManagementDeployment $layout} 'new_pair_with_bound_local_target_accepted'
 Accept {Assert-ReceiptManagementTarget @{} @{}} 'default_endpoint_pair_accepted'
 foreach($target in @('http://127.0.0.1:18094','http://192.0.2.1:8094','https://127.0.0.1:8094','http://127.0.0.1:8094/path','http://127.0.0.1:8094/?q=x','http://127.0.0.1:8094/#fragment','http://user@127.0.0.1:8094',@('http://127.0.0.1:8094'),'http://127.0.0.1:8094/',' http://127.0.0.1:8094','http://127.0.0.1:8094 ')){
  Deny {Assert-ReceiptManagementTarget @{LISTEN='127.0.0.1:8094'} @{RUNTIME_URL=$target}} ('unattested_target_'+$checks.Count)
 }
 Write-PlatformJson $controlPath @{RUNTIME_URL='http://127.0.0.1:18094'}
 Deny {Assert-ReceiptManagementDeployment $layout} 'unregistered_Console_configuration_drift_refused' 'configuration differs'
 $controlNew.config_sha256=(Get-FileHash -LiteralPath $controlPath).Hash.ToLowerInvariant();Write-PlatformJson $catalogPath $catalog
 Deny {Assert-ReceiptManagementDeployment $layout} 'registered_foreign_Runtime_target_refused' 'does not target'
 Write-PlatformJson $controlPath @{RUNTIME_URL='http://127.0.0.1:8094'}
 $controlNew.config_sha256=(Get-FileHash -LiteralPath $controlPath).Hash.ToLowerInvariant();Write-PlatformJson $catalogPath $catalog
 $export=Join-Path $proof 'export';Export-ReleaseCatalog $layout $export|Out-Null
 $restored=Join-Path $proof 'restored';Restore-ReleaseCatalog $export $restored|Out-Null
 Accept {Assert-ReceiptManagementPolicy (Read-ReleaseDescriptor @{release_root=$restored} $runtimeNew -Verify) (Read-ReleaseDescriptor @{release_root=$restored} $controlNew -Verify)} 'export_restore_retains_capability_proof'
 $result.passed=$true
}catch{$result.failure=$_.Exception.Message}finally{
 $result.checks=$checks.ToArray();$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $proof 'result.json')
 Write-Output $proof;[pscustomobject]@{passed=$result.passed;checks=$checks.Count;failure=$result['failure']}|ConvertTo-Json
}
if(-not $result.passed){exit 1}
