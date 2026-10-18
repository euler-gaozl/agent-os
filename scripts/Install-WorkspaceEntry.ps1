$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
$layout=Get-PlatformLayout $root
if($root -ne 'D:\workspace\agent-platform\repos\agent-os'){throw 'Install the stable entry only from the verified grouped checkout.'}
$entry=Join-Path $PSScriptRoot 'Platform.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count -or -not $ast.ParamBlock){throw 'Cannot read maintenance entry parameters.'}
# Forward bound parameters as a dictionary, preserving switches and arrays.
$proxy=$ast.ParamBlock.Extent.Text+"`n"+@'
$ErrorActionPreference='Stop'
$entry=Join-Path $PSScriptRoot '../repos/agent-os/scripts/Platform.ps1'
if(-not(Test-Path -LiteralPath $entry)){throw 'Integration checkout is missing under agent-platform/repos/agent-os.'}
& $entry @PSBoundParameters
'@
Write-PlatformText 'D:\workspace\agent-platform\ops\Platform.ps1' $proxy
Write-Output 'Stable maintenance entry installed: D:\workspace\agent-platform\ops\Platform.ps1'
