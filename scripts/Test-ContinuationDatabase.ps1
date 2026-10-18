param([string]$EvidenceRoot='D:\workspace\agent-platform\local\evidence',[int]$Port=55598)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
foreach($file in @('platform-paths','platform-releases','platform-recovery')){. (Join-Path $PSScriptRoot ('lib/'+$file+'.ps1'))}
$proof=Join-Path $EvidenceRoot ('continuation-database-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $proof
$pg='D:\workspace\.tools\postgresql\pgsql\bin';$data=Join-Path $proof 'postgres'
$layout=@{postgres_bin=$pg}
$admin=@{host='127.0.0.1';port=$Port;user='fixture_owner';password='';database='postgres'}
$runtime=$admin.Clone();$runtime.user='fixture_runtime'
$checks=[Collections.Generic.List[string]]::new();$started=$false
function Check([bool]$Value,[string]$Name){if(-not $Value){throw $Name};$checks.Add($Name)}
try{
    if(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue){throw 'Isolated fixture port is occupied'}
    & (Join-Path $pg 'initdb.exe') -D $data -U fixture_owner -A trust -E UTF8 --locale=C *> (Join-Path $proof 'init.log')
    if($LASTEXITCODE){throw 'Fixture initialization failed'}
    $process=Start-Process -FilePath (Join-Path $pg 'pg_ctl.exe') -ArgumentList @('-D',$data,'-l',(Join-Path $proof 'postgres.log'),'-o',('"-h 127.0.0.1 -p '+$Port+'"'),'start','-w') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $proof 'start.stdout') -RedirectStandardError (Join-Path $proof 'start.stderr')
    if(-not $process.WaitForExit(20000) -or $process.ExitCode -ne 0){throw 'Fixture startup failed'}
    $started=$true
    $null=Invoke-RecoverySQL $pg $admin 'CREATE ROLE fixture_runtime LOGIN; CREATE TABLE runs(id text PRIMARY KEY);'
    $facts=Get-ContinuationDatabaseFacts $layout $runtime
    Check (-not $facts.schema_ready -and -not $facts.has_receipts -and $facts.other_runtime_clients -eq 0) 'missing receipt migration observed without reading user rows'
    # Apply the actual Owner DDL, not a lookalike schema maintained by this test.
    $ddl=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../agent-os-runtime/runtime/continuation_requests.sql') -Raw
    $null=Invoke-RecoverySQL $pg $admin ($ddl+"`nGRANT SELECT,INSERT ON run_continuation_receipts TO fixture_runtime;")
    $facts=Get-ContinuationDatabaseFacts $layout $runtime
    Check ($facts.schema_ready -and -not $facts.has_receipts) 'migrated empty table and minimum Runtime privileges accepted'
    $null=Invoke-RecoverySQL $pg $admin "INSERT INTO runs VALUES('fixture'); INSERT INTO run_continuation_receipts(request_id,run_id,request_hash,expected_failure_version,http_status,response) VALUES('decision','fixture',repeat('a',64),repeat('b',64),409,'{}');"
    $facts=Get-ContinuationDatabaseFacts $layout $runtime
    Check ($facts.schema_ready -and $facts.has_receipts) 'retained rejection is visible with Runtime login'
    $null=Invoke-RecoverySQL $pg $admin 'REVOKE SELECT ON run_continuation_receipts FROM fixture_runtime;'
    $denied=$false;try{Get-ContinuationDatabaseFacts $layout $runtime|Out-Null}catch{$denied=$_.Exception.Message -match 'schema or permissions'}
    Check $denied 'missing permission cannot be interpreted as empty history'
    $null=Invoke-RecoverySQL $pg $admin 'GRANT SELECT ON run_continuation_receipts TO fixture_runtime; ALTER TABLE run_continuation_receipts ALTER COLUMN response DROP NOT NULL;'
    $denied=$false;try{Get-ContinuationDatabaseFacts $layout $runtime|Out-Null}catch{$denied=$_.Exception.Message -match 'schema or permissions'}
    Check $denied 'malformed schema cannot authorize downgrade'
    $null=Invoke-RecoverySQL $pg $admin 'ALTER TABLE run_continuation_receipts ALTER COLUMN response SET NOT NULL;'
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $pg 'psql.exe'))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($key in @($info.Environment.Keys|Where-Object{$_ -like 'PG*'})){$null=$info.Environment.Remove($key)}
    foreach($arg in @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U','fixture_runtime','-d','postgres','-A','-t','-q')){$info.ArgumentList.Add($arg)}
    $held=[Diagnostics.Process]::Start($info)
    try{
        $held.StandardInput.WriteLine("SELECT 'connected';");$held.StandardInput.Flush()
        $line=$held.StandardOutput.ReadLineAsync()
        if(-not $line.Wait(5000) -or $line.Result -cne 'connected'){throw 'Fixture Runtime client failed to connect'}
        $facts=Get-ContinuationDatabaseFacts $layout $runtime
        Check ($facts.other_runtime_clients -eq 1) 'remaining Runtime backend detected before receipt observation'
    }finally{
        $held.StandardInput.Close()
        if(-not $held.WaitForExit(5000)){$held.Kill($true);$held.WaitForExit()}
        $held.Dispose()
    }
    $facts=Get-ContinuationDatabaseFacts $layout $runtime
    Check ($facts.other_runtime_clients -eq 0 -and $facts.has_receipts) 'closed backend and retained receipt remain distinct facts'
    $result=@{passed=$true;checks=$checks.ToArray();scope='Isolated real PostgreSQL, actual receipt DDL, non-owner Runtime login; no formal database changes';provider_calls=0;ci_runs=0}
    $result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $proof 'result.json')
    [pscustomobject]@{passed=$true;checks=$checks.Count;evidence=$proof}|ConvertTo-Json
}finally{
    if($started){& (Join-Path $pg 'pg_ctl.exe') -D $data stop -m fast -w *> (Join-Path $proof 'stop.log');if($LASTEXITCODE){throw 'Fixture database did not stop'}}
}
