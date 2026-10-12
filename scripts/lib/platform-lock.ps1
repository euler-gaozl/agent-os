# All managed lifecycle changes use the same exclusive OS file lock. The handle
# is released even if the process crashes; a leftover file is not a stale lock.
function Enter-PlatformMaintenance([string]$StateRoot,[IO.FileStream]$ExistingLock=$null) {
    # Stable across old/staged/active layouts and source checkout relocation.
    $lockPath='D:\workspace\agent-platform\ops\maintenance.lock'
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force
    if($ExistingLock){
        if(-not $ExistingLock.CanWrite -or $ExistingLock.Name -ne $lockPath){throw 'Inherited maintenance lock does not match this platform.'}
        # The caller retains ownership through the whole compound operation.
        return $null
    }
    try { return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'Another platform maintenance operation is active. Wait for it to finish.' }
}
