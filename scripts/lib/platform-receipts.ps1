# Additive management capability, separate from the unchanged execution/data
# protocol. Old descriptors remain valid; new Console requires a capable Runtime.
function Assert-ReceiptManagementDescriptor([System.Collections.IDictionary]$Descriptor){
    if(-not $Descriptor.Contains('receipt_management')){return}
    if($Descriptor.role -isnot [string]){throw 'Receipt management service role must be a string.'}
    $value=$Descriptor.receipt_management
    $field=if($Descriptor.role -ceq 'runtime'){'provides'}elseif($Descriptor.role -ceq 'control'){'requires'}else{throw 'Receipt management belongs only to Runtime or Console.'}
    if($value -isnot [System.Collections.IDictionary]){throw 'Unrecognized receipt management capability.'}
    if($value.Count -ne 2 -or -not $value.Contains('format') -or -not $value.Contains($field)){throw 'Unrecognized receipt management capability.'}
    if(($value.format -isnot [long] -and $value.format -isnot [int]) -or $value.format -ne 1 -or $value[$field] -isnot [string]){throw 'Unrecognized receipt management capability.'}
    if($value[$field] -cne 'call-receipts-v1'){throw 'Unrecognized receipt management capability.'}
}
function Assert-ReceiptManagementPolicy([System.Collections.IDictionary]$Runtime,[System.Collections.IDictionary]$Control){
    if($Runtime.role -isnot [string] -or $Control.role -isnot [string]){throw 'Receipt management service pair is invalid.'}
    if($Runtime.role -cne 'runtime' -or $Control.role -cne 'control'){throw 'Receipt management service pair is invalid.'}
    Assert-ReceiptManagementDescriptor $Runtime;Assert-ReceiptManagementDescriptor $Control
    if($Control.Contains('receipt_management') -and -not $Runtime.Contains('receipt_management')){throw 'Console requires call-receipts-v1. Upgrade Runtime first; roll back Console before Runtime.'}
}
function Assert-ReceiptManagementDeployment([hashtable]$Layout,[System.Collections.IDictionary]$Overrides=@{}){
    $catalog=Read-ReleaseCatalog $Layout
    if($catalog.format -ne 2){return}
    $pair=@{}
    foreach($role in @('runtime','control')){
        if($Overrides.Contains($role)){$pair[$role]=$Overrides[$role]}
        elseif($catalog.services.Contains($role)){$pair[$role]=Read-ReleaseDescriptor $Layout $catalog.services[$role].current -Verify}
        else{$pair[$role]=@{role=$role}}
    }
    Assert-ReceiptManagementPolicy $pair.runtime $pair.control
    if($pair.control.Contains('receipt_management')){
        if(-not $catalog.services.Contains('runtime') -or -not $catalog.services.Contains('control')){throw 'Receipt management requires registered Runtime and Console configuration.'}
        $runtimeConfig=Get-BoundRuntimeConfiguration $Layout $catalog
        $controlConfig=Get-BoundReceiptControlConfiguration $Layout $catalog
        try{Assert-ReceiptManagementTarget $runtimeConfig $controlConfig}finally{$runtimeConfig=$null;$controlConfig=$null}
    }
}
function Assert-ReceiptManagementTarget([System.Collections.IDictionary]$RuntimeConfig,[System.Collections.IDictionary]$ControlConfig){
    # This Windows catalog attests the local pair only. Remote Runtime targets
    # need their own capability/identity attestation, never this local proof.
    if(($RuntimeConfig.Contains('LISTEN') -and $RuntimeConfig.LISTEN -isnot [string]) -or ($ControlConfig.Contains('RUNTIME_URL') -and $ControlConfig.RUNTIME_URL -isnot [string])){throw 'Receipt management endpoint configuration must be text.'}
    $listen=if($RuntimeConfig['LISTEN']){$RuntimeConfig.LISTEN}else{':8094'}
    $target=if($ControlConfig['RUNTIME_URL']){$ControlConfig.RUNTIME_URL}else{'http://127.0.0.1:8094'}
    if($listen -isnot [string] -or $target -isnot [string]){throw 'Receipt management endpoint configuration must be text.'}
    if($listen -cnotmatch '^(127\.0\.0\.1|0\.0\.0\.0|):([0-9]{1,5})$'){throw 'Receipt capability requires an attested local IPv4 Runtime listener.'}
    $port=[int]$Matches[2]
    $uri=$null
    if($port -lt 1 -or $port -gt 65535 -or -not [uri]::TryCreate($target,[UriKind]::Absolute,[ref]$uri)){throw 'Receipt management target is invalid.'}
    if($uri.Scheme -cne 'http' -or $uri.Host -cne '127.0.0.1' -or $uri.Port -ne $port -or $uri.AbsolutePath -cne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo){throw 'Console RUNTIME_URL does not target the Runtime attested by this Windows catalog.'}
    # BFF concatenates /v1 paths and refuses redirects. Even a trailing slash
    # would produce //v1 and fail; attest only the exact usable base URL.
    if($target -cne ('http://127.0.0.1:'+$port)){throw 'Console RUNTIME_URL must be the exact local base URL without a trailing slash.'}
}
function Get-BoundReceiptControlConfiguration([hashtable]$Layout,[System.Collections.IDictionary]$Catalog){
    . (Join-Path $PSScriptRoot 'platform-processes.ps1')
    $deployment=$Catalog.services.control
    if($deployment['pending'] -and $deployment.pending['configuration']){throw 'Unreviewed pending Console configuration migration.'}
    $bytes=[IO.File]::ReadAllBytes((Join-Path $Layout.config_root 'services/control.json'))
    try{
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if($deployment.current['config_sha256'] -cne $hash){throw 'Console configuration differs from its registered deployment.'}
        $config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -AsHashtable
    }finally{[Array]::Clear($bytes,0,$bytes.Length)}
    $allowed=@($deployment.current)
    if($deployment['pending']){$allowed+=@($deployment.pending.prior,$deployment.pending.target)}
    foreach($entry in @((Read-PlatformProcesses $Layout)|Where-Object role -eq 'control')){
        $state=Get-PlatformInstanceState $entry $Layout
        if($state.requires_stop -or (-not $state.process -and $state.members.Count)){throw 'Console process ownership is unresolved.'}
        if(-not $state.process){continue}
        if(-not $entry['job_name'] -or -not $entry['launch_config'] -or $entry['source_config_sha256'] -cne $hash){throw 'Live Console configuration is not bound to the registered deployment.'}
        $reference=@($allowed|Where-Object{$entry['release_reference'] -and $_.id -ceq $entry.release_reference.id})
        if($reference.Count -eq 0){throw 'Live Console does not belong to its registered deployment.'}
        $descriptor=Read-ReleaseDescriptor $Layout $reference[0] -Verify
        if($entry.binary -ne (Resolve-ReleasePath $Layout.release_root $descriptor.assets.binary)){throw 'Live Console binary differs from its registered deployment.'}
        $launch=Read-ReleaseJson $entry.launch_config
        try{foreach($key in @('RUNTIME_URL','REGISTRY_URL')){if([string]$launch[$key] -cne [string]$config[$key]){throw 'Live Console service target differs from registered configuration.'}}}finally{$launch=$null}
    }
    return $config
}
