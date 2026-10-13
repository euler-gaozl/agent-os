# The maintenance file lock serializes live coordinators. This journal survives
# their death and blocks ordinary writer startup until the owner validates SQL.
# Stop/doctor and PostgreSQL startup stay available for inspection and recovery.
function Write-OwnerMigrationJson([string]$Path,[System.Collections.IDictionary]$Value){
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 16))
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        [IO.File]::Move($temporary,$Path,$true)
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
function Get-OwnerMigrationJournalPath([hashtable]$Layout){
    # Like the maintenance lock, this must not depend on caller-controlled
    # LayoutPath/StateRoot. Otherwise a second layout can restart the same DB.
    $root='D:\workspace\agent-platform\ops'
    $path=Join-Path $root 'owner-migration.pending.json'
    Assert-ReleasePhysicalPath $root $path
    return $path
}
function Assert-NoPendingOwnerMigration([hashtable]$Layout){
    if(Test-Path -LiteralPath (Get-OwnerMigrationJournalPath $Layout)){
        throw 'An owner database migration requires recovery. Ordinary startup, release and configuration changes are blocked; validate the recorded migration before resuming writers.'
    }
}
function Read-OwnerMigrationJournal([hashtable]$Layout){
    try{$journal=Get-Content -LiteralPath (Get-OwnerMigrationJournalPath $Layout) -Raw|ConvertFrom-Json -AsHashtable -NoEnumerate -DateKind String}catch{throw 'Invalid owner migration journal; manual inspection is required.'}
    if($journal -isnot [System.Collections.IDictionary] -or ($journal['format'] -isnot [int] -and $journal['format'] -isnot [long]) -or $journal['format'] -ne 1){throw 'Invalid owner migration journal; manual inspection is required.'}
    foreach($key in @('id','operation','phase','state_root','baseline_sha256','created_at')){if($journal[$key] -isnot [string]){throw 'Invalid owner migration journal; manual inspection is required.'}}
    if($journal.id -cnotmatch '^[a-f0-9]{32}$' -or $journal.operation -cnotin @('telemetry-inbox-v1','runtime-access-v1') -or $journal.phase -cnotin @('prepared','mutation_requested','validating','validated')){throw 'Invalid owner migration journal; manual inspection is required.'}
    if($journal.state_root -cne $Layout.state_root){throw 'Owner migration belongs to a different layout; use its recorded state root for recovery.'}
    $baseline=Join-Path $Layout.state_root ('migrations/'+$journal.id+'/baseline.json')
    Assert-ReleasePhysicalPath $Layout.state_root $baseline
    if($journal['baseline_sha256'] -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $baseline).Hash.ToLowerInvariant() -cne $journal.baseline_sha256){throw 'Owner migration baseline integrity failed; writers remain blocked.'}
    return $journal
}
function New-OwnerMigrationJournal([hashtable]$Layout,[string]$Operation,[System.Collections.IDictionary]$Baseline,[IO.FileStream]$Lock){
    if(-not $Lock){throw 'Owner migration requires the held maintenance lock.'}
    $null=Enter-PlatformMaintenance $Layout.state_root $Lock
    Assert-NoPendingOwnerMigration $Layout
    if($Operation -cnotin @('telemetry-inbox-v1','runtime-access-v1')){throw 'Unknown owner migration operation.'}
    $id=[guid]::NewGuid().ToString('N')
    $directory=Join-Path $Layout.state_root ('migrations/'+$id)
    Assert-ReleasePhysicalPath $Layout.state_root $directory
    $baselinePath=Join-Path $directory 'baseline.json'
    Write-OwnerMigrationJson $baselinePath $Baseline
    $journal=@{format=1;id=$id;operation=$Operation;phase='prepared';state_root=$Layout.state_root;baseline_sha256=(Get-FileHash -LiteralPath $baselinePath).Hash.ToLowerInvariant();created_at=[datetime]::UtcNow.ToString('o')}
    Write-OwnerMigrationJson (Get-OwnerMigrationJournalPath $Layout) $journal
    return $journal
}
function Set-OwnerMigrationPhase([hashtable]$Layout,[string]$ID,[string]$Phase,[IO.FileStream]$Lock){
    if(-not $Lock){throw 'Owner migration requires the held maintenance lock.'}
    $null=Enter-PlatformMaintenance $Layout.state_root $Lock
    $journal=Read-OwnerMigrationJournal $Layout
    if($journal.id -cne $ID){throw 'Owner migration identity changed.'}
    $allowed=@{prepared=@('mutation_requested');mutation_requested=@('validating');validating=@('validating','validated');validated=@('validating')}
    if($Phase -cnotin $allowed[$journal.phase]){throw 'Invalid owner migration phase transition.'}
    $journal.phase=$Phase;$journal.updated_at=[datetime]::UtcNow.ToString('o')
    Write-OwnerMigrationJson (Get-OwnerMigrationJournalPath $Layout) $journal
    return $journal
}
function Complete-OwnerMigrationJournal([hashtable]$Layout,[string]$ID,[IO.FileStream]$Lock){
    if(-not $Lock){throw 'Owner migration requires the held maintenance lock.'}
    $null=Enter-PlatformMaintenance $Layout.state_root $Lock
    $journal=Read-OwnerMigrationJournal $Layout
    if($journal.id -cne $ID -or $journal.phase -cne 'validated'){throw 'Only the validated owner migration may release its writer gate.'}
    $source=Get-OwnerMigrationJournalPath $Layout
    $target=Join-Path $Layout.state_root ('migrations/'+$ID+'/completed.json')
    Assert-ReleasePhysicalPath $Layout.state_root $target
    # Same-volume rename retains the journal as evidence. No delete-and-restart
    # fallback and no automatic privilege expansion on uncertain SQL outcomes.
    Move-Item -LiteralPath $source -Destination $target -ErrorAction Stop
    return $target
}
