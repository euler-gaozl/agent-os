param(
    [string]$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')),
    [string]$StateRoot = '',
    [string]$ReportPath = '',
    [string]$LayoutPath = ''
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
. (Join-Path $PSScriptRoot 'lib/platform-paths.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-processes.ps1')
. (Join-Path $PSScriptRoot 'lib/platform-releases.ps1')
$layout=Get-PlatformLayout $ProjectRoot $LayoutPath
if (-not $StateRoot) { $StateRoot = $layout.state_root }
$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$configRoot=if($layout.layout_path){$layout.config_root}else{$StateRoot}
$issues = [Collections.Generic.List[object]]::new()
function Add-Issue([string]$Severity, [string]$Code, [string]$Message) {
    $issues.Add([pscustomobject]@{ severity = $Severity; code = $Code; message = $Message })
}
function Read-Object([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
    catch { Add-Issue 'error' 'invalid_local_json' ('Cannot parse local file: ' + [IO.Path]::GetFileName($Path)); return $null }
}
try{Assert-NoPendingOwnerMigration $layout}catch{Add-Issue 'error' 'owner_migration_pending' $_.Exception.Message}
$releaseStatus=@{format=$null;generation=$null;services=@()}
try{
    $releaseCatalog=Read-ReleaseCatalog $layout;$releaseStatus.format=$releaseCatalog.format
    if($releaseCatalog.format -eq 2){
        $releaseStatus.generation=$releaseCatalog.generation
        foreach($role in $releaseCatalog.services.Keys|Sort-Object){
            $releaseEntry=$releaseCatalog.services[$role]
            $releaseStatus.services+=@{role=$role;current=$releaseEntry.current.id;previous=$(if($releaseEntry['previous']){$releaseEntry.previous.id}else{$null});pending=$(if($releaseEntry['pending']){$releaseEntry.pending.phase}else{$null})}
            if($releaseEntry['pending']){Add-Issue 'error' 'release_pending' ('Interrupted release for '+$role+'; run release-recover for this service.')}
        }
    }
}catch{Add-Issue 'error' 'release_catalog_invalid' 'Release catalog cannot be read or validated.'}
$manifest = @(Read-Object (Join-Path $StateRoot 'processes.json') | Where-Object { $null -ne $_ })
$expected = @('registry','runtime','worker','toolhub','knowledge','indexer','storage','sandbox','sources','control','futures')
$ports = @{ control=8090;toolhub=8091;storage=8092;sandbox=8093;runtime=8094;knowledge=8095;registry=8096;indexer=8097;futures=8098;sources=8101 }
$processes = @()
foreach ($entry in $manifest) {
    $running = $null;$memberCount=0
    $owned = $false
    try {
        $instance=Get-PlatformInstanceState $entry $layout
        $running=$instance.process;$owned=[bool]$running;$memberCount=$instance.members.Count
        if($instance.recovered){Add-Issue 'warning' 'launch_identity_recovered' ('Launch PID was not saved; recovered owned identity for '+$entry.role+'. stop can reconcile it.')}
    }catch{Add-Issue 'error' 'process_identity_unverified' ('Cannot verify launch identity: '+$entry.role)}
    if (-not $owned) { Add-Issue 'error' 'instance_not_owned_or_stopped' ('Recorded instance is stopped or no longer matches: ' + $entry.role) }
    $processes += [pscustomobject]@{
        role=$entry.role; instance=$entry.id; pid=$entry.pid; owned_and_running=$owned
        binary=$entry.binary;managed_job=[bool]$entry['job_created'];job_members=$memberCount;working_set_mib=if($owned){[math]::Round($running.WorkingSet64/1MB,2)}else{$null}
    }
}
$services = @()
foreach ($role in $expected) {
    $instances = @($processes | Where-Object { $_.role -eq $role -and $_.owned_and_running })
    if ($instances.Count -eq 0) { Add-Issue 'error' 'service_not_running' ('No owned running instance: ' + $role) }
    $configPath = Join-Path $configRoot ('services/' + $role + '.json')
    $config = Read-Object $configPath
    if ($null -eq $config) { Add-Issue 'error' 'configuration_missing' ('Missing valid configuration for ' + $role) }
    $health = $null; $ready = $null
    if ($ports.ContainsKey($role)) {
        # Only a fixed loopback endpoint is contacted. No configured external URL
        # is trusted for sending credentials; response bodies are not retained.
        $base = 'http://127.0.0.1:' + $ports[$role]
        try { $health = (Invoke-WebRequest ($base + '/healthz') -TimeoutSec 3 -NoProxy).StatusCode -eq 200 }
        catch { $health = $false }
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $ports[$role] -ErrorAction SilentlyContinue)
        $ownedIds=@($instances|ForEach-Object{$_.pid})
        $ownedListener = @($listeners | Where-Object { $_.OwningProcess -in $ownedIds }).Count -gt 0
        if ($config -and $ownedListener) {
            $key = if($role -eq 'control'){'ADMIN_TOKEN'}elseif($role -eq 'futures'){'BUSINESS_TOKEN'}else{'SERVICE_TOKEN'}
            $token = $config[$key]
            if ($role -eq 'futures' -and -not $token) { $token = $config['ADMIN_TOKEN'] }
            if (-not $token) { $token = $config['SERVICE_TOKEN'] }
            if ($token) {
                try { $ready = (Invoke-WebRequest ($base + '/readyz') -Headers @{Authorization=('Bearer ' + $token)} -TimeoutSec 3 -NoProxy).StatusCode -eq 200 }
                catch { $ready = $false }
            }
        }
        if ($health -ne $true) { Add-Issue 'error' 'health_failed' ('Health probe failed: ' + $role) }
        if ($ready -ne $true) { Add-Issue 'error' 'readiness_unverified' ('Readiness is not verified: ' + $role) }
    }
    $services += [pscustomobject]@{role=$role;instances=$instances.Count;config_present=($null -ne $config);health=$health;ready=$ready}
}
$sandbox = Read-Object (Join-Path $configRoot 'services/sandbox.json')
$docker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
$sandboxConfigured = $null -ne $sandbox -and [bool]$sandbox['SANDBOX_IMAGE']
if (-not $docker -or -not $sandboxConfigured) {
    Add-Issue 'warning' 'sandbox_execution_unavailable' 'Sandbox API may be alive, but isolated code execution is not configured on this Windows host.'
}
$computer = Get-CimInstance Win32_ComputerSystem
$databaseProcesses = @(Get-Process postgres -ErrorAction SilentlyContinue | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith('D:\workspace\.tools\postgresql\',[StringComparison]::OrdinalIgnoreCase) })
$revision = & git -C $ProjectRoot rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0) { $revision = $null; Add-Issue 'error' 'source_revision_unknown' 'Cannot identify the integration repository revision.' }
$dirty = @(& git -C $ProjectRoot status --porcelain 2>$null).Count -gt 0
$total = ($processes | Where-Object owned_and_running | Measure-Object working_set_mib -Sum).Sum
$databaseTotal = ($databaseProcesses | Measure-Object WorkingSet64 -Sum).Sum
$report = [pscustomobject]@{
    schema_version=1; observed_at=[datetime]::UtcNow.ToString('o'); project_root=$ProjectRoot; state_root=$StateRoot
    source_revision=$revision; source_has_changes=$dirty;configuration_root=$configRoot;database_root=$layout.database_root;release_root=$layout.release_root
    host=[pscustomobject]@{os='Windows';logical_processors=$computer.NumberOfLogicalProcessors;physical_memory_gib=[math]::Round($computer.TotalPhysicalMemory/1GB,1)}
    services=$services;processes=$processes;release_status=$releaseStatus
    resource_snapshot=[pscustomobject]@{service_working_set_mib=[math]::Round($total,2);postgres_processes=$databaseProcesses.Count;postgres_working_set_mib=[math]::Round($databaseTotal/1MB,2);scope='Instantaneous working sets; shared pages may be counted more than once. Not a workload benchmark.'}
    dependencies=[pscustomobject]@{docker_cli=$docker;wsl_command=[bool](Get-Command wsl -ErrorAction SilentlyContinue);wsl_distribution='not_probed';sandbox_image_configured=$sandboxConfigured}
    issues=@($issues.ToArray());core_probe_passed=(@($issues | Where-Object severity -eq 'error').Count -eq 0)
    limitations=@('Health/readiness do not prove business task success.','No database rows, credentials, configuration contents or response bodies are included.','Worker execution and backup restoration require separate acceptance tests.')
}
$json = $report | ConvertTo-Json -Depth 8
if ($ReportPath) {
    $ReportPath = [IO.Path]::GetFullPath($ReportPath)
    # A report is an explicit output; refuse overwriting an existing file.
    $parent = Split-Path -Parent $ReportPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $file = [IO.File]::Open($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json);$file.Write($bytes,0,$bytes.Length) } finally { $file.Dispose() }
}
$json
if (-not $report.core_probe_passed) { exit 1 }
