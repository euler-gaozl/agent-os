# Shared Windows backup helpers. Secret values stay in process memory or DPAPI.
Set-StrictMode -Version Latest
function Read-RecoveryJson([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw ('Cannot read recovery input: ' + [IO.Path]::GetFileName($Path)) }
}
function New-ProtectedDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) { throw 'Recovery destination already exists.' }
    $null=New-Item -ItemType Directory -Path $Path -Force
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach($sid in @($owner,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner($owner);Set-Acl -LiteralPath $Path -AclObject $acl
}
function Protect-RecoveryBytes([byte[]]$Bytes) {
    $entropy=[Text.Encoding]::UTF8.GetBytes('AgentOS.PlatformBackup.v1')
    return ,([Security.Cryptography.ProtectedData]::Protect($Bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser))
}
function Unprotect-RecoveryBytes([byte[]]$Bytes) {
    $entropy=[Text.Encoding]::UTF8.GetBytes('AgentOS.PlatformBackup.v1')
    try { return ,([Security.Cryptography.ProtectedData]::Unprotect($Bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)) }
    catch { throw 'Cannot unlock recovery vault with this Windows user profile.' }
}
function Get-BytesHash([byte[]]$Bytes) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLower() }
function Get-DatabaseConnection([string]$Value) {
    try {
        $uri=[uri]$Value
        if($uri.Scheme -notin @('postgres','postgresql') -or -not $uri.Host){throw 'invalid'}
        $parts=$uri.UserInfo.Split(':',2)
        if($parts.Count -ne 2){throw 'invalid'}
        return @{host=$uri.Host;port=if($uri.Port -gt 0){$uri.Port}else{5432};database=[uri]::UnescapeDataString($uri.AbsolutePath.TrimStart('/'));user=[uri]::UnescapeDataString($parts[0]);password=[uri]::UnescapeDataString($parts[1])}
    } catch { throw 'Invalid database connection; connection values were not printed.' }
}
function Invoke-PostgresTool {
    param([string]$PostgresBin,[string]$Tool,[string[]]$Arguments,[hashtable]$Connection,[string]$InputText='',[int]$TimeoutMs=120000,[switch]$HashOutput)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $PostgresBin ($Tool+'.exe')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
    $null=$info.Environment.Remove('PGSERVICE');$null=$info.Environment.Remove('PGSERVICEFILE')
    if($Connection){
        $info.Environment['PGPASSWORD']=$Connection.password
        $info.Environment['PGCONNECT_TIMEOUT']='5';$info.Environment['PGAPPNAME']='agent-os-recovery'
        $info.Environment['PGOPTIONS']='-c timezone=UTC -c extra_float_digits=3 -c bytea_output=hex -c statement_timeout=120000'
        foreach($a in @('-h',$Connection.host,'-p',[string]$Connection.port,'-U',$Connection.user)){$info.ArgumentList.Add($a)}
    }
    foreach($a in $Arguments){$info.ArgumentList.Add($a)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    $cancel=[Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        $null=$process.Start();$started=$true
        $errors=$process.StandardError.ReadToEndAsync()
        $output=if(-not $HashOutput){$process.StandardOutput.ReadToEndAsync()}else{$null}
        if($InputText){$process.StandardInput.Write($InputText)}
        $process.StandardInput.Close()
        if($HashOutput){
            $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                $buffer=[byte[]]::new(16384)
                while(($read=$process.StandardOutput.BaseStream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0){$hash.AppendData($buffer,0,$read)}
                $value=[Convert]::ToHexString($hash.GetHashAndReset()).ToLower()
            }finally{$hash.Dispose()}
        }
        if(-not $process.WaitForExit($TimeoutMs)){throw 'timeout'}
        if($process.ExitCode -ne 0){throw ('exit '+$process.ExitCode)}
        $null=$errors.GetAwaiter().GetResult()
        if(-not $HashOutput){$value=$output.GetAwaiter().GetResult()}
        return $value
    } catch {
        if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()}
        throw ('PostgreSQL '+$Tool+' failed; no connection values or SQL contents were printed.')
    } finally {$cancel.Dispose();$process.Dispose()}
}
function Invoke-RecoverySQL([string]$PostgresBin,[hashtable]$Connection,[string]$SQL,[switch]$HashOutput) {
    return Invoke-PostgresTool -PostgresBin $PostgresBin -Tool psql -Connection $Connection -Arguments @('-X','-w','-A','-t','-q','-v','ON_ERROR_STOP=1','-d',$Connection.database,'-f','-') -InputText $SQL -HashOutput:$HashOutput
}
function Quote-PgIdentifier([string]$Value){return '"'+$Value.Replace('"','""')+'"'}
function Get-DatabaseMetadata([string]$PostgresBin,[hashtable]$Connection){
    $sql=@'
SELECT jsonb_build_object('owner',pg_get_userbyid(d.datdba),'encoding',pg_encoding_to_char(d.encoding),
 'collate',d.datcollate,'ctype',d.datctype,'provider',d.datlocprovider,'locale',d.datlocale,
 'connection_limit',d.datconnlimit,'allow_connections',d.datallowconn,
 'acl',(SELECT jsonb_agg(a::text ORDER BY a::text) FROM unnest(d.datacl) a),
 'settings',(SELECT jsonb_agg(jsonb_build_object('role',CASE WHEN s.setrole=0 THEN '*' ELSE pg_get_userbyid(s.setrole) END,'values',s.setconfig) ORDER BY s.setrole=0,pg_get_userbyid(s.setrole)) FROM pg_db_role_setting s WHERE s.setdatabase=d.oid))::text
FROM pg_database d WHERE datname=current_database();
'@
    return (Invoke-RecoverySQL $PostgresBin $Connection $sql).Trim()
}
function Get-DatabaseSchemaHash([string]$PostgresBin,[hashtable]$Connection){
    $schema=Invoke-PostgresTool -PostgresBin $PostgresBin -Tool pg_dump -Connection $Connection -Arguments @('-w','--schema-only','--create','-d',$Connection.database)
    # pg_dump 18 adds random psql restriction tokens; they are not schema state.
    $normalized=($schema -split '\r?\n'|Where-Object{$_ -notmatch '^\\(un)?restrict '}) -join "`n"
    return Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($normalized))
}
function Assert-NoDatabaseClients([string]$PostgresBin,[hashtable]$Connection,[string[]]$Databases){
    $names=($Databases|ForEach-Object{"'"+$_.Replace("'","''")+"'"}) -join ','
    $sql="SELECT count(*) FROM pg_stat_activity WHERE datname IN ("+$names+") AND pid<>pg_backend_pid() AND backend_type='client backend';"
    if([long](Invoke-RecoverySQL $PostgresBin $Connection $sql).Trim() -ne 0){throw 'Another database client is connected; stop all clients before coordinated backup.'}
}
function Get-DatabaseFingerprints([string]$PostgresBin,[hashtable]$Connection){
    $tablesSQL="SELECT json_build_object('schema',n.nspname,'table',c.relname,'kind',c.relkind)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','p','S') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' ORDER BY n.nspname,c.relname;"
    $raw=Invoke-RecoverySQL $PostgresBin $Connection $tablesSQL
    $result=@()
    foreach($line in $raw.Split("`n",[StringSplitOptions]::RemoveEmptyEntries)){
        $table=$line|ConvertFrom-Json
        $qualified=(Quote-PgIdentifier $table.schema)+'.'+(Quote-PgIdentifier $table.table)
        $count=(Invoke-RecoverySQL $PostgresBin $Connection ('SELECT count(*) FROM '+$qualified+';')).Trim()
        # Sort fixed-size row hashes in PostgreSQL; stream them into SHA-256.
        # No raw row content leaves the database and no full table is buffered here.
        $content=if($table.kind -eq 'S'){"jsonb_build_object('last_value',t.last_value,'is_called',t.is_called)"}else{'to_jsonb(t)'}
        $query="SELECT encode(sha256(convert_to("+$content+"::text,'UTF8')),'hex') AS h FROM "+$qualified+" t ORDER BY h;"
        $fingerprint=Invoke-RecoverySQL $PostgresBin $Connection $query -HashOutput
        $result += [pscustomobject]@{schema=$table.schema;table=$table.table;kind=$table.kind;rows=[long]$count;sha256=$fingerprint}
    }
    return ,$result
}
function Assert-RecoveryQuiescent([string]$ProjectRoot,[string]$StateRoot,[string]$ReleaseRoot=''){
    $manifestPath=Join-Path $StateRoot 'processes.json'
    if(Test-Path -LiteralPath $manifestPath){
        foreach($entry in @(Read-RecoveryJson $manifestPath)){
            $process=Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
            if($process -and $process.Path -eq $entry.binary -and $process.StartTime.ToUniversalTime().Ticks -eq ([datetime]$entry.started_at).ToUniversalTime().Ticks){throw 'Stop all owned platform services before coordinated backup.'}
        }
    }
    # Manifest absence is not proof of a stopped service: reject orphan binaries.
    if(-not $ReleaseRoot){$ReleaseRoot=Join-Path $ProjectRoot 'bin'}
    $prefix=[IO.Path]::GetFullPath($ReleaseRoot)+[IO.Path]::DirectorySeparatorChar
    $matches=@(Get-Process|Where-Object{$_.Path -and $_.Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)})
    $orphans=@();$exited=@()
    foreach($candidate in $matches){
        # Enumeration can retain process objects whose termination has already
        # completed. Only an observed terminated object may be ignored; an
        # unreadable/ambiguous process identity remains a refusal.
        try{$hasExited=$candidate.HasExited}catch{throw 'Cannot verify a platform process termination state.'}
        if($hasExited){$exited+=@{pid=$candidate.Id;name=$candidate.ProcessName;has_exited=$true}}
        else{$orphans+=$candidate}
    }
    if($exited.Count){
        Write-PlatformJson ('D:\workspace\agent-platform\local\evidence\terminated-process-enumeration-'+[guid]::NewGuid().ToString('N')+'.json') @{at=[datetime]::UtcNow.ToString('o');observations=$exited}
    }
    if($orphans.Count){throw ('Platform executable still running; coordinated backup refused: '+(($orphans|ForEach-Object{$_.ProcessName+' PID '+$_.Id}) -join ', '))}
}
function Assert-AllDeploymentsQuiescent([hashtable]$Layout){
    Assert-RecoveryQuiescent $Layout.project_root $Layout.state_root $Layout.release_root
    $catalog='D:\workspace\agent-platform\ops\managed-roots.json'
    if(Test-Path -LiteralPath $catalog){
        foreach($entry in @(Read-RecoveryJson $catalog)){
            foreach($key in @('project_root','state_root','release_root')){
                if(-not [IO.Path]::GetFullPath($entry[$key]).StartsWith('D:\workspace\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid managed deployment root.'}
            }
            Assert-RecoveryQuiescent $entry.project_root $entry.state_root $entry.release_root
        }
    }
}
