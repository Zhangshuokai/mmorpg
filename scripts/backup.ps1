#Requires -Version 5.1
<#
.SYNOPSIS
    Backs up the server SQLite database (S-D-2 / S-O-5).

.DESCRIPTION
    Creates a timestamped, self-describing backup of a database file. The server
    opens its DB with journal_mode=WAL and checkpoints on a clean shutdown, so a
    backup taken while the server is STOPPED is a single consistent file. Run
    backups during a maintenance window; copying a live database is not
    guaranteed to be race-free.

    The backup contains the .db file, its -wal file when one is present, and a
    manifest.txt with a SHA-256 and size per file (so restore.ps1 can verify).
    The rebuildable -shm index is deliberately not copied: a stale one can
    confuse WAL recovery.

    Old backups for the same database file are pruned to -Keep.

.EXAMPLE
    powershell -File scripts/backup.ps1
.EXAMPLE
    powershell -File scripts/backup.ps1 -Database server/.local/mmorpg_server.db -Out D:\backups -Keep 20

.NOTES
    The database parameter is named -Database (not -Db) because -Db collides with
    PowerShell's built-in -Debug alias.
#>
[CmdletBinding()]
param(
    [string]$Database = 'server/.local/mmorpg_server.db',
    [string]$Out = '.local/backups',
    [int]$Keep = 10,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

$dbPath = Resolve-RepoPath $Database
if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) {
    throw "database not found: $dbPath"
}
$dbItem = Get-Item -LiteralPath $dbPath
if ($dbItem.Length -eq 0) {
    throw "database is empty (0 bytes), refusing to back up: $dbPath"
}

$outRoot = Resolve-RepoPath $Out
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssZ')
$baseName = $dbItem.Name
$staging = Join-Path $outRoot "$baseName.$stamp"
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$sources = @($dbPath)
$wal = "$dbPath-wal"
if (Test-Path -LiteralPath $wal -PathType Leaf) { $sources += $wal }

$manifest = New-Object System.Collections.Generic.List[string]
foreach ($source in $sources) {
    $dest = Join-Path $staging ([System.IO.Path]::GetFileName($source))
    Copy-Item -LiteralPath $source -Destination $dest -Force
    $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
    $size = (Get-Item -LiteralPath $dest).Length
    $manifest.Add(("{0}  {1}  {2}" -f $hash, $size, [System.IO.Path]::GetFileName($source)))
}
$manifest.Add("source=$dbPath")
$manifest.Add(("utc=" + (Get-Date).ToUniversalTime().ToString('o')))
Set-Content -LiteralPath (Join-Path $staging 'manifest.txt') -Value $manifest -Encoding UTF8

$result = $staging
if (-not $NoZip) {
    $zip = "$staging.zip"
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $staging -Recurse -Force
    $result = $zip
}

# Prune older backups of this same database to -Keep (never the one we just made:
# it has the newest timestamp).
$keepCount = [Math]::Max(1, $Keep)
$existing = @(Get-ChildItem -LiteralPath $outRoot -Force |
    Where-Object { $_.Name -like "$baseName.*" } |
    Sort-Object LastWriteTime -Descending)
$doomed = @($existing | Select-Object -Skip $keepCount)
foreach ($item in $doomed) {
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
}

Write-Host "[backup] $dbPath -> $result"
if ($doomed.Count -gt 0) { Write-Host ("[backup] pruned {0} old backup(s)" -f $doomed.Count) }
Write-Output $result
