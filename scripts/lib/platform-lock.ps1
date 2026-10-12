# All managed lifecycle changes use the same exclusive OS file lock. The handle
# is released even if the process crashes; a leftover file is not a stale lock.
function Enter-PlatformMaintenance([string]$StateRoot) {
    $null=New-Item -ItemType Directory -Path $StateRoot -Force
    try { return [IO.File]::Open((Join-Path $StateRoot 'maintenance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'Another platform maintenance operation is active. Wait for it to finish.' }
}
