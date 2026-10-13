# Whole tree ownership comes from atomic Windows Job assignment, not PID scans.
param([Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][string]$PostgresBin)
$ErrorActionPreference='Stop'
if(-not ('AgentOS.Maintenance.WindowsJob' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'lib/windows-job.cs')}
$jobFile=Join-Path $Evidence 'job.json'
$members=@()
if(Test-Path -LiteralPath $jobFile){
 $job=Get-Content -LiteralPath $jobFile -Raw|ConvertFrom-Json
 if($job.name -notmatch '^Local\\AgentOS-ResidentFixture-[0-9a-f]{32}$' -or -not $job.created){throw 'Unverified fixture Job; preserving databases'}
 $members=@([AgentOS.Maintenance.WindowsJob]::Members($job.name))
 [AgentOS.Maintenance.WindowsJob]::Stop($job.name)
 if(@([AgentOS.Maintenance.WindowsJob]::Members($job.name)).Count){throw 'Fixture Job still occupied; preserving databases'}
}elseif(Test-Path -LiteralPath (Join-Path $Evidence 'processes.json')){throw 'Fixture Job journal missing; preserving databases'}
$dbFiles=@(Get-ChildItem -LiteralPath $Evidence -Filter '*-database.json')
foreach($file in $dbFiles){
 $manifest=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
 if($manifest.database -notmatch '^joint_([0-9a-f]{16})_(runtime|storage)$'){throw 'Invalid fixture database name'}
 $prefix='joint_'+$Matches[1]+'_'
 foreach($role in $manifest.roles){if($role -notmatch ('^'+$prefix+'(runtime|worker|storage)$')){throw 'Invalid fixture role name'}}
 & (Join-Path $PostgresBin 'psql.exe') -X -w -h 127.0.0.1 -p 55591 -U p2_fixture -d postgres -v ON_ERROR_STOP=1 -c ('DROP DATABASE IF EXISTS "'+$manifest.database+'" WITH (FORCE)') *> (Join-Path $Evidence ($manifest.database+'-drop.log'))
 if($LASTEXITCODE){throw 'Fixture database cleanup failed'}
 foreach($role in $manifest.roles){& (Join-Path $PostgresBin 'psql.exe') -X -w -h 127.0.0.1 -p 55591 -U p2_fixture -d postgres -v ON_ERROR_STOP=1 -c ('DROP ROLE IF EXISTS "'+$role+'"') *> (Join-Path $Evidence ($role+'-drop-role.log'));if($LASTEXITCODE){throw 'Fixture role cleanup failed'}}
}
return @{verified=$true;job_members_before_stop=$members;job_members_after_stop=0;databases_removed=$dbFiles.Count}
