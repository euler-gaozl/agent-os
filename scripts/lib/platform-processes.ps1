# Durable Windows process ownership. Requires platform-paths.ps1.
function Initialize-PlatformJobs {
    if(-not ('AgentOS.Maintenance.WindowsJob' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'windows-job.cs')}
}
function Read-PlatformProcesses([hashtable]$Layout){
    $path=Join-Path $Layout.state_root 'processes.json'
    if(Test-Path -LiteralPath $path){return ,@(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable)}
    return ,@()
}
function Get-PlatformProcess([hashtable]$Entry){
    if(-not $Entry['pid'] -or -not $Entry['started_at']){return $null}
    $p=Get-Process -Id ([int]$Entry.pid) -ErrorAction SilentlyContinue
    if($p -and -not $p.HasExited -and $p.Path -eq $Entry.binary -and $p.StartTime.ToUniversalTime().Ticks -eq ([datetime]$Entry.started_at).ToUniversalTime().Ticks){return $p}
    return $null
}
function Assert-InstancePaths([hashtable]$Entry,[hashtable]$Layout){
    if(-not(Test-PathWithin $Entry.binary $Layout.release_root)){throw 'Manifest executable outside managed release root.'}
    if($Entry['job_name']){
        if($Entry.job_name -cnotmatch '^Global\\AgentOS-[a-f0-9]{32}$'){throw 'Invalid owned job name.'}
        if($Entry['launch_config']){
            $root=Join-Path $Layout.config_root 'launches'
            if(-not(Test-PathWithin $Entry.launch_config $root) -or [IO.Path]::GetFileName($Entry.launch_config) -cne ($Entry.id+'.json')){throw 'Invalid launch identity path.'}
            if((Get-FileHash -LiteralPath $Entry.launch_config -Algorithm SHA256).Hash.ToLower() -cne $Entry.launch_config_sha256){throw 'Launch configuration has changed; automatic process adoption refused.'}
        }
    }
}
function Get-PlatformInstanceState([hashtable]$Entry,[hashtable]$Layout){
    Assert-InstancePaths $Entry $Layout
    $process=Get-PlatformProcess $Entry
    if(-not $Entry['job_name'] -or -not $Entry['job_created']){
        $members=@(if($process){$process.Id};foreach($child in @($Entry['legacy_children']|Where-Object{$_})){$live=Get-PlatformProcess $child;if($live){$live.Id}})
        return @{process=$process;members=$members;recovered=$false;requires_stop=([bool]$Entry['legacy_stop_intent'] -or (-not $Entry['job_name'] -and -not $process))}
    }
    Initialize-PlatformJobs
    $members=@([AgentOS.Maintenance.WindowsJob]::Members($Entry.job_name))
    if($process -and $process.Id -notin $members){throw 'Recorded root process is outside its owned job.'}
    $recovered=$false
    if(-not $process -and -not $Entry['pid'] -and $Entry['launch_config']){
        $matches=@()
        foreach($member in $members){
            $os=Get-CimInstance Win32_Process -Filter ('ProcessId='+$member)
            if(-not $os -or $os.ExecutablePath -ne $Entry.binary){continue}
            $arguments=[AgentOS.Maintenance.WindowsJob]::Arguments($os.CommandLine)
            if($arguments.Count -eq 3 -and $arguments[0] -eq $Entry.binary -and $arguments[1] -ceq '--config' -and $arguments[2] -eq $Entry.launch_config){
                $p=Get-Process -Id ([int]$member) -ErrorAction SilentlyContinue
                if($p -and -not $p.HasExited -and $p.Path -eq $Entry.binary -and $p.StartTime.ToUniversalTime() -ge ([datetime]$Entry.intent_at).ToUniversalTime().AddSeconds(-2)){$matches+=$p}
            }
        }
        if($matches.Count -gt 1){throw 'Multiple roots claim the same launch identity.'}
        if($matches.Count -eq 1){$process=$matches[0];$Entry.pid=$process.Id;$Entry.started_at=$process.StartTime.ToUniversalTime().ToString('o');$Entry.status='running';$recovered=$true}
    }
    return @{process=$process;members=$members;recovered=$recovered;requires_stop=$false}
}
function New-PlatformEnvironment {
    # No inherited service/model/PG/Node variables may override the config file.
    # PATH is explicit: arbitrary parent PATH entries cannot shadow executables.
    $environment=@{PATH=(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot}
    foreach($key in @('SystemRoot','WINDIR','TEMP','TMP','LANG','USERPROFILE','APPDATA','LOCALAPPDATA','ProgramData')){
        $value=[Environment]::GetEnvironmentVariable($key)
        if($value){$environment[$key]=$value}
    }
    return (($environment.Keys|Sort-Object|ForEach-Object{$_+'='+$environment[$_]}) -join [char]0)+[char]0+[char]0
}
function Start-PlatformInstance([hashtable]$Entry,[hashtable]$Layout,[scriptblock]$Persist){
    Initialize-PlatformJobs
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $created=[Action]{$Entry.job_created=$true;& $Persist}
    $processId=[AgentOS.Maintenance.WindowsJob]::Start($Entry.binary,$Entry.launch_config,$Layout.project_root,$Entry.job_name,$owner,(New-PlatformEnvironment),(Join-Path $Layout.log_root ($Entry.id+'.stdout.log')),(Join-Path $Layout.log_root ($Entry.id+'.stderr.log')),$created)
    # Caller has already flushed the unique launch intent. A crash here can be
    # resolved from the named job + exact --config path without knowing the PID.
    $p=Get-Process -Id $processId -ErrorAction SilentlyContinue
    if(-not $p -or $p.HasExited){throw ('Service exited at startup: '+$Entry.role)}
    $Entry.pid=$p.Id;$Entry.started_at=$p.StartTime.ToUniversalTime().ToString('o');$Entry.status='running'
}
function Save-LegacyChildren([hashtable]$Entry,[hashtable]$Layout,[scriptblock]$Persist){
    if(-not $Entry['legacy_children']){$Entry.legacy_children=@()}
    foreach($child in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$Entry.pid))){
        $live=Get-Process -Id ([int]$child.ProcessId) -ErrorAction SilentlyContinue
        if(-not $live -or $live.HasExited -or $live.StartTime.ToUniversalTime() -lt ([datetime]$Entry.started_at).ToUniversalTime()){continue}
        if($Entry['legacy_root_stopped_at'] -and $live.StartTime.ToUniversalTime() -gt ([datetime]$Entry.legacy_root_stopped_at).ToUniversalTime()){throw 'Legacy parent PID may have been reused; automatic child cleanup refused.'}
        $node=if($Layout['node_binary']){$Layout.node_binary}else{''}
        $runner=Join-Path $Layout.harness_root 'runner.mjs'
        $arguments=[AgentOS.Maintenance.WindowsJob]::Arguments($child.CommandLine)
        $isNode=$Entry.role -eq 'worker' -and $live.Path -eq $node -and $arguments.Count -eq 3 -and $arguments[0] -eq $node -and $arguments[1] -ceq '--max-old-space-size=192' -and $arguments[2] -eq $runner
        $console=Join-Path $env:SystemRoot 'System32/conhost.exe'
        $isConsole=$live.Path -eq $console -and $arguments.Count -eq 2 -and $arguments[0].Replace('\??\','') -eq $console -and $arguments[1] -match '^0x[0-9a-f]+$'
        if(-not $isNode -and -not $isConsole){throw 'Unexpected legacy descendant; manual ownership review required.'}
        $childEntry=@{pid=$live.Id;started_at=$live.StartTime.ToUniversalTime().ToString('o');binary=$live.Path}
        if(-not @($Entry.legacy_children|Where-Object{$_['pid'] -eq $childEntry.pid -and $_['started_at'] -eq $childEntry.started_at}).Count){$Entry.legacy_children+=@($childEntry)}
    }
    & $Persist
}
function Stop-PlatformInstance([hashtable]$Entry,[hashtable]$Layout,[scriptblock]$Persist){
    Initialize-PlatformJobs
    $state=Get-PlatformInstanceState $Entry $Layout
    if(-not $Entry['job_name']){
        # One-time transition for pre-job instances. Hold the root's kernel
        # handle through the post-exit enumeration to prevent PID reuse here.
        $rootProcess=$state.process
        if($rootProcess){
            $null=$rootProcess.SafeHandle
            Save-LegacyChildren $Entry $Layout $Persist
            $Entry.legacy_stop_intent=$true;& $Persist
            $rootProcess.Kill()
            if(-not $rootProcess.WaitForExit(10000)){throw 'Legacy root did not stop; journal retained.'}
            $Entry.legacy_root_stopped_at=[datetime]::UtcNow.ToString('o');& $Persist
        }elseif(-not $Entry['legacy_root_stopped_at']){
            # A historical ParentProcessId alone is insufficient: that PID may
            # have been reused and exited again. Only recorded exact children
            # are safe here. Keep the unresolved root record for review.
            foreach($child in @($Entry['legacy_children']|Where-Object{$_})){
                $live=Get-PlatformProcess $child
                if($live){$live.Kill();if(-not $live.WaitForExit(10000)){throw 'Recorded legacy child did not stop.'}}
            }
            throw 'Legacy root exit boundary is unknown; new child discovery and replacement are refused. Review this one-time conversion record.'
        }elseif(@(Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue|Where-Object{-not $_.HasExited}).Count){
            throw 'Legacy PID identity has changed; automatic child discovery refused.'
        }
        Save-LegacyChildren $Entry $Layout $Persist
        foreach($child in @($Entry['legacy_children'])){
            $live=Get-PlatformProcess $child
            if($live){$live.Kill();if(-not $live.WaitForExit(10000)){throw 'Legacy Node did not stop; journal retained.'}}
        }
        if($rootProcess){$rootProcess.Dispose()}
        return
    }
    & $Persist
    if(-not $Entry['job_created']){return}
    [AgentOS.Maintenance.WindowsJob]::Stop($Entry.job_name)
    if(Get-PlatformProcess $Entry){throw 'Owned root still runs after stopping its job; manifest retained.'}
}
