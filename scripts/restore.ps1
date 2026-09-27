#Requires -Version 5.1
<#
.SYNOPSIS
    Restores a database backup produced by scripts/backup.ps1 (S-O-5 drill).

.DESCRIPTION
    Restores a backup (zip or directory) into a target database path, then prints
    the restored file and its SHA-256. It validates the SQLite file header before
    writing anything, and removes stale -wal/-shm side files at the target so an
    old log cannot corrupt the restored database.

    The target is intentionally NOT the live default path unless you pass it
    explicitly; use this to restore into a scratch DB and boot the server against
    it (the restore drill), or to roll back in a maintenance window.

.EXAMPLE
    powershell -File scripts/restore.ps1 -Backup backups/mmorpg_server.db.20260927-120000Z.zip -Out server/.local/scratch.db
.EXAMPLE
    powershell -File scripts/restore.ps1 -Backup backups/mmorpg_server.db.20260927-120000Z -Out server/.local/scratch.db -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Backup,
    [Parameter(Mandatory = $true)][string]$Out,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

$backupPath = Resolve-RepoPath $Backup
if (-not (Test-Path -LiteralPath $backupPath)) {
    throw "backup not found: $backupPath"
}

$temp = Join-Path $env:TEMP ("mmorpg-restore-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    $sourceDir = $backupPath
    if (-not (Get-Item -LiteralPath $backupPath).PSIsContainer) {
        Expand-Archive -LiteralPath $backupPath -DestinationPath $temp -Force
        $sourceDir = $temp
    }

    $dbFiles = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Filter '*.db' -ErrorAction SilentlyContinue)
    if ($dbFiles.Count -ne 1) {
        throw "expected exactly one .db inside the backup, found $($dbFiles.Count)"
    }
    $srcDb = $dbFiles[0]

    # Verify the SQLite magic header ("SQLite format 3\0") before touching a target.
    $header = New-Object byte[] 16
    $stream = [System.IO.File]::OpenRead($srcDb.FullName)
    try { [void]$stream.Read($header, 0, 16) } finally { $stream.Dispose() }
    if ([System.Text.Encoding]::ASCII.GetString($header) -ne "SQLite format 3`0") {
        throw "not a SQLite database: $($srcDb.FullName)"
    }

    $outPath = Resolve-RepoPath $Out
    if (Test-Path -LiteralPath $outPath) {
        if (-not $Force) { throw "target exists: $outPath (pass -Force to overwrite)" }
        Remove-Item -LiteralPath $outPath -Force
    }
    $outDir = Split-Path -Parent $outPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    foreach ($side in @("$outPath-wal", "$outPath-shm")) {
        if (Test-Path -LiteralPath $side) { Remove-Item -LiteralPath $side -Force }
    }

    Copy-Item -LiteralPath $srcDb.FullName -Destination $outPath -Force
    $srcWal = Join-Path $srcDb.DirectoryName "$($srcDb.Name)-wal"
    if (Test-Path -LiteralPath $srcWal -PathType Leaf) {
        Copy-Item -LiteralPath $srcWal -Destination "$outPath-wal" -Force
    }

    $hash = (Get-FileHash -LiteralPath $outPath -Algorithm SHA256).Hash
    Write-Host "[restore] $backupPath -> $outPath"
    Write-Host "[restore] sha256=$hash"
    Write-Output $outPath
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
