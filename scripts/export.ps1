#Requires -Version 5.1
<#
.SYNOPSIS
    Exports the MMORPG release artifacts (Linux dedicated server + Windows client).

.DESCRIPTION
    Godot does not create the export output directory and `build/` is gitignored,
    so a fresh checkout fails the export with "the given export path does not
    exist". This script creates the directory, runs the export and verifies that
    the artifact was actually produced.

    The Godot executable is taken from -Godot, falling back to the GODOT
    environment variable. Nothing here depends on a specific machine layout.

.EXAMPLE
    $env:GODOT = "D:\code\game\godot_engine\Godot_v4.7.1-stable_win64_console.exe"
    powershell -File scripts/export.ps1 -Target all

.EXAMPLE
    powershell -File scripts/export.ps1 -Target server -Godot "C:\Godot\godot_console.exe"
#>
[CmdletBinding()]
param(
    [ValidateSet('server', 'client', 'all')]
    [string]$Target = 'all',

    [string]$Godot = $env:GODOT
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

if ([string]::IsNullOrWhiteSpace($Godot)) {
    throw "Set the GODOT environment variable or pass -Godot <path to the Godot console executable>."
}
if (-not (Test-Path -LiteralPath $Godot)) {
    throw "Godot executable not found: $Godot"
}

$jobs = @()
if ($Target -eq 'all' -or $Target -eq 'server') {
    $jobs += [pscustomobject]@{ Project = 'server'; Preset = 'Linux Server'; Output = 'build/mmorpg_server.x86_64' }
}
if ($Target -eq 'all' -or $Target -eq 'client') {
    $jobs += [pscustomobject]@{ Project = 'client'; Preset = 'Windows Client'; Output = 'build/mmorpg_client.exe' }
}

$exitCode = 0
foreach ($job in $jobs) {
    $projectDir = Join-Path $RepoRoot $job.Project
    # Godot will not create this directory itself.
    New-Item -ItemType Directory -Force -Path (Join-Path $projectDir 'build') | Out-Null

    Write-Host ("[export] preset '{0}' -> {1}/{2}" -f $job.Preset, $job.Project, $job.Output)
    & $Godot --headless --path $projectDir --export-release $job.Preset $job.Output
    $artifact = Join-Path $projectDir $job.Output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $artifact)) {
        Write-Error ("[fail] export of preset '{0}' did not produce {1}" -f $job.Preset, $artifact)
        $exitCode = 1
    }
}

if ($exitCode -ne 0) { exit $exitCode }
Write-Host "[done] exports complete."
