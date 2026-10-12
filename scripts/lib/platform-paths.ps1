# Explicit machine paths let a source checkout move without moving live data.
function Get-PlatformLayout([string]$ProjectRoot,[string]$LayoutPath='') {
    $root=[IO.Path]::GetFullPath($ProjectRoot)
    if(-not $LayoutPath){
        $pointer=Join-Path $root '.local/layout.path'
        if(Test-Path -LiteralPath $pointer){$LayoutPath=(Get-Content -LiteralPath $pointer -Raw).Trim()}
    }
    $layout=@{format=1;project_root=$root;state_root=(Join-Path $root '.state');config_root=(Join-Path $root '.state');database_root=(Join-Path $root '.state/postgres');log_root=(Join-Path $root '.state');release_root=(Join-Path $root 'bin');harness_root=(Join-Path $root 'harness');console_web_root=(Join-Path $root 'web/dist');futures_web_root=(Join-Path $root 'web/dist-futures');postgres_bin='D:\workspace\.tools\postgresql\pgsql\bin'}
    if($LayoutPath){
        try{$inputLayout=Get-Content -LiteralPath $LayoutPath -Raw|ConvertFrom-Json -AsHashtable}catch{throw 'Cannot parse platform layout; configuration values were not printed.'}
        if($inputLayout.format -ne 1){throw 'Unsupported platform layout format.'}
        foreach($key in $layout.Keys|ForEach-Object{$_}){
            if($key -eq 'format'){continue}
            if(-not $inputLayout.ContainsKey($key) -or -not [IO.Path]::IsPathFullyQualified([string]$inputLayout[$key])){throw ('Layout requires an absolute path: '+$key)}
            $layout[$key]=[IO.Path]::GetFullPath([string]$inputLayout[$key]).TrimEnd([IO.Path]::DirectorySeparatorChar)
            if(-not $layout[$key].StartsWith('D:\workspace\',[StringComparison]::OrdinalIgnoreCase)){throw ('Platform path must remain under D:\workspace: '+$key)}
        }
        if($layout.project_root -ne $root){throw 'Layout refers to another source checkout. Use that checkout to run maintenance.'}
        if($inputLayout.ContainsKey('node_binary')){
            $layout.node_binary=[IO.Path]::GetFullPath([string]$inputLayout.node_binary)
            if(-not(Test-PathWithin $layout.node_binary 'D:\workspace')){throw 'Node release must remain under D:\workspace.'}
        }
    }
    $layout.layout_path=$LayoutPath
    return $layout
}
function Test-PathWithin([string]$Path,[string]$Root){
    return [IO.Path]::GetFullPath($Path).StartsWith([IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
function Write-PlatformText([string]$Path,[string]$Value){
    $parent=Split-Path -Parent $Path;$null=New-Item -ItemType Directory -Path $parent -Force
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,$Value,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$Path,$true)
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
function Write-PlatformJson([string]$Path,$Value){Write-PlatformText $Path (ConvertTo-Json -InputObject $Value -Depth 12)}
function Register-PlatformRoots([hashtable[]]$Layouts){
    $path='D:\workspace\agent-platform\ops\managed-roots.json'
    $entries=@();if(Test-Path -LiteralPath $path){$entries=@(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable)}
    foreach($layout in $Layouts){if(-not @($entries|Where-Object{$_.state_root -eq $layout.state_root -and $_.release_root -eq $layout.release_root}).Count){$entries+=@{project_root=$layout.project_root;state_root=$layout.state_root;release_root=$layout.release_root}}}
    Write-PlatformJson $path $entries
}
function Get-OwnedDatabase([hashtable]$Layout,[int]$Port=55432){
    $pidFile=Join-Path $Layout.database_root 'postmaster.pid'
    if(-not(Test-Path -LiteralPath $pidFile)){return $null}
    $fields=Get-Content -LiteralPath $pidFile
    if($fields.Count -lt 4){throw 'PostgreSQL identity file is incomplete.'}
    $process=Get-Process -Id ([int]$fields[0]) -ErrorAction SilentlyContinue
    if(-not $process){return $null}
    $expectedBinary=[IO.Path]::GetFullPath((Join-Path $Layout.postgres_bin 'postgres.exe'))
    $started=[DateTimeOffset]::FromUnixTimeSeconds([long]$fields[2]).UtcDateTime
    if($process.Path -ne $expectedBinary -or [IO.Path]::GetFullPath($fields[1]) -ne $Layout.database_root -or [int]$fields[3] -ne $Port -or [Math]::Abs(($process.StartTime.ToUniversalTime()-$started).TotalSeconds) -gt 3){throw 'PostgreSQL process identity does not match this platform data directory.'}
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if($listeners.Count -and @($listeners|Where-Object OwningProcess -ne $process.Id).Count){throw 'PostgreSQL port is owned by another process.'}
    return $process
}
