#Requires -Version 5.1
<#
.SYNOPSIS
    Agent Manager run script: start this worktree's dedicated server.

.DESCRIPTION
    Runs from the selected worktree (WORKTREE_PATH) or the main repo root when
    LOCAL is selected. Lives in the main repository's .kilo/.

    Two worktrees must never fight over resources, so this script:
      * derives a stable per-worktree UDP port in 7100-7999;
      * keeps the SQLite DB inside the worktree's .local/ directory;
      * runs the first `--import` (class_name registration) before starting.

    Requires the GODOT environment variable (the Godot 4.7.1 console
    executable). Setup/run scripts only receive WORKTREE_PATH/REPO_PATH, so
    GODOT must come from the user's shell environment.

.EXAMPLE
    $env:GODOT = "D:\code\game\godot_engine\Godot_v4.7.1-stable_win64_console.exe"
#>
[CmdletBinding()]
param(
    [string]$Godot = $env:GODOT
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Godot)) {
    throw "Set the GODOT environment variable to the Godot 4.7.1 console executable before using Run."
}
if (-not (Test-Path -LiteralPath $Godot)) {
    throw "Godot executable not found: $Godot"
}

# Stable per-worktree port so parallel worktrees never share UDP 7000.
$seed = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
$hash = 0
foreach ($ch in $seed.ToCharArray()) { $hash = ($hash * 31 + [int]$ch) -band 0x7fffffff }
$port = 7100 + ($hash % 900)

New-Item -ItemType Directory -Force -Path .local | Out-Null

# First import registers class_name globally; headless start fails without it.
& $Godot --headless --path server --import
& $Godot --headless --path client --import

Write-Host ("[run] server -> 127.0.0.1:{0}  db=server/.local/mmorpg_server.db" -f $port)
& $Godot --headless --path server -- --server --port $port --db .local/mmorpg_server.db
