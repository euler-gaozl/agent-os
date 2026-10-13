# Disposable SQL metadata for the generic release transaction fixture. The
# synthetic HTTP process still has no database or business implementation.
function Invoke-ReleaseFixtureSQL([hashtable]$Layout,[hashtable]$Connection,[string]$Query){
    Invoke-ExecutionAccessProbe (Join-Path $Layout.postgres_bin 'psql.exe') @('-X','-w','-h',$Connection.host,'-p',[string]$Connection.port,'-U',$Connection.user,'-d',$Connection.database,'-A','-t','-q','-v','ON_ERROR_STOP=1','-f','-') $Query $Connection
}
function Remove-ReleaseAccessFixture([hashtable]$Layout,[hashtable]$Fixture){
    if($Fixture.created_database){Invoke-ReleaseFixtureSQL $Layout $Fixture.admin ('DROP DATABASE '+$Fixture.name+' WITH (FORCE)')|Out-Null}
    foreach($role in $Fixture.created_roles){Invoke-ReleaseFixtureSQL $Layout $Fixture.admin ('DROP ROLE '+$role)|Out-Null}
}
function New-ReleaseAccessFixture([hashtable]$Layout,[string]$Binary){
    $admin=Get-ExecutionAccessConnection @{DATABASE_URL=$env:TEST_DATABASE_URL}
    if($admin.port -ne 55591 -or $admin.database -cne 'postgres' -or $admin.user -cne 'p2_fixture'){throw 'Windows release tests require the disposable PostgreSQL fixture on 55591.'}
    $name='p2_release_'+[guid]::NewGuid().ToString('N')
    $roles=@(($name+'_runtime'),($name+'_telemetry'))
    $fixture=@{admin=$admin;name=$name;created_database=$false;created_roles=[Collections.Generic.List[string]]::new()}
    try{
        foreach($role in $roles){Invoke-ReleaseFixtureSQL $Layout $admin ('CREATE ROLE '+$role+" LOGIN PASSWORD 'fixture-only'")|Out-Null;$fixture.created_roles.Add($role)}
        Invoke-ReleaseFixtureSQL $Layout $admin ('CREATE DATABASE '+$name+' TEMPLATE template0')|Out-Null;$fixture.created_database=$true
        $database=@{};foreach($key in $admin.Keys){$database[$key]=$admin[$key]};$database.database=$name
        Invoke-ReleaseFixtureSQL $Layout $database ('CREATE TABLE public.events(seq bigint); CREATE TABLE public.telemetry_inbox(seq bigint); CREATE TABLE public.telemetry_exports(seq bigint); GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO '+$roles[1])|Out-Null
        $index=0
        foreach($role in @('runtime','telemetry')){
            $url=[UriBuilder]::new($env:TEST_DATABASE_URL);$url.Path='/'+$name;$url.UserName=$roles[$index++];$url.Password='fixture-only'
            Write-PlatformJson (Join-Path $Layout.config_root ('services/'+$role+'.json')) @{DATABASE_URL=$url.Uri.AbsoluteUri;SERVICE_TOKEN='synthetic-fixture-token'}
        }
        $relative='bundles/runtime/runtime.exe';$target=Resolve-ReleasePath $Layout.release_root $relative
        $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target);Copy-Item -LiteralPath $Binary -Destination $target
        $reference=New-ReleaseDescriptor $Layout runtime @{binary=$relative} @{http='synthetic-v1';data='none';engines=@();tools=@()} @{kind='synthetic';dirty=$false}
        $reference.config_sha256=(Get-FileHash -LiteralPath (Join-Path $Layout.config_root 'services/runtime.json')).Hash.ToLowerInvariant()
        $fixture.runtime_reference=$reference
        return $fixture
    }catch{Remove-ReleaseAccessFixture $Layout $fixture;throw}
}
