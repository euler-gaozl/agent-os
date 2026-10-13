param([Parameter(Mandatory)][string]$Evidence)
$ErrorActionPreference='Stop'
$samples=@(Get-Content -LiteralPath (Join-Path $Evidence 'process-samples.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
if(-not $samples.Count){throw 'No process measurements'}
$peaks=@{}
foreach($role in @('runtime','storage','node','joint-worker-a','joint-worker-b','joint-worker-c')){
 $rows=@($samples|ForEach-Object {$_.processes}|Where-Object role -eq $role)
 if(-not $rows.Count){throw ('Process was never measured: '+$role)}
 $peaks[$role]=@{samples=$rows.Count;working_set_bytes=($rows.working_set_bytes|Measure-Object -Maximum).Maximum;private_bytes=($rows.private_bytes|Measure-Object -Maximum).Maximum}
}
$phases=@{}
foreach($name in @('idle-before','single-20','single-20-idle','single-50','single-50-idle','takeover-100','takeover-idle','parallel-50','continuous-0','continuous-0-idle','continuous-1','continuous-1-idle','continuous-2','continuous-2-idle','idle-after')){
 $rows=@($samples|Where-Object {$_.phase -eq $name -and @($_.processes|Where-Object role -eq 'runtime').Count})
 if(-not $rows.Count){throw ('Measurement phase missing: '+$name)}
 $nodeCounts=@($rows|ForEach-Object {@($_.processes|Where-Object role -eq 'node').Count})
 $sumRss=@($rows|ForEach-Object {($_.processes.working_set_bytes|Measure-Object -Sum).Sum})
 $phases[$name]=@{samples=$rows.Count;max_node_count=($nodeCounts|Measure-Object -Maximum).Maximum;sampled_total_working_set_peak=($sumRss|Measure-Object -Maximum).Maximum;last=$rows[-1]}
 if($name -match 'idle' -and @($rows[-1].processes|Where-Object role -eq 'node').Count){throw ('Node still present at idle phase: '+$name)}
 if($name -notmatch 'idle' -and ($nodeCounts|Measure-Object -Maximum).Maximum -lt 1){throw ('No Node sample during workload: '+$name)}
}
if($phases['parallel-50'].max_node_count -lt 2){throw 'Two simultaneous Node processes were not measured'}
$observed=Get-Content -LiteralPath (Join-Path $Evidence 'observed-processes.json') -Raw|ConvertFrom-Json -AsHashtable
foreach($key in $observed.Keys){$p=Get-Process -Id ([int]$key) -ErrorAction SilentlyContinue;if($p -and $p.StartTime.ToUniversalTime().Ticks -eq [long]$observed[$key].start){throw 'A measured fixture process remains alive after test cleanup'}}
$takeover=Get-Content -LiteralPath (Join-Path $Evidence 'takeover-100.json') -Raw|ConvertFrom-Json -DateKind String
$s=$takeover.scenario
$summary=@{passed=$true;samples=$samples.Count;sampling_interval_floor_ms=250;forced_gc=$false;node_heap_bytes=$null;peaks=$peaks;phases=$phases;takeover=@{kill_to_observed_claim_ms=([datetime]$s.claimed_at-[datetime]$s.killed_at).TotalMilliseconds;observed_claim_to_first_new_provider_request_ms=([datetime]$s.first_new_request_at-[datetime]$s.claimed_at).TotalMilliseconds};cleanup_verified=$true;scope='Windows sampled WorkingSet64/PrivateMemorySize64; includes released Runtime, Storage, Worker(s) and observed Node children. Excludes PostgreSQL, Go acceptance/controller, fixture HTTP servers and rest of formal platform. Peaks are sampled, not hard limits. Recovery interval includes polling and transport; not a native snapshot restore measurement.'}
$summary|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $Evidence 'resource-summary.json')
