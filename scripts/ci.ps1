#Requires -Version 5.1
<#
.SYNOPSIS
    One-command CI pipeline for the MMORPG repo (S-O-1): contract verify ->
    parse checks -> unit tests -> headless bot -> release exports.

.DESCRIPTION
    Runs the same pipeline locally and on CI:

      1. scripts/link_shared.ps1 -Verify   (junctions + Net autoload + @rpc rule +
                                             Protocol.RPC_NAMES reconciliation)
      2. import + headless parse check of both projects
      3. GDScript unit tests (tests/run_tests.gd, --script + extends SceneTree)
      4. headless bot against a server this script starts itself, on an isolated
         --port and --db .local/ci.db (the default user:// DB is never touched)
      5. scripts/export.ps1  (Linux dedicated server + Windows client)

    The Godot executable comes from -Godot / $env:GODOT. This script never
    hardcodes a machine path; CI points $env:GODOT at its downloaded engine.

.PARAMETER Port
    UDP port for the throwaway CI server. Default 7099; must not collide with a
    developer server or another worktree.

.PARAMETER SkipExport
    Stop after the bot (fast inner loop). Off by default so the pipeline always
    proves the export artifacts are produced.

.EXAMPLE
    $env:GODOT = "D:\code\game\godot_engine\Godot_v4.7.1-stable_win64_console.exe"
    powershell -File scripts/ci.ps1

.EXAMPLE
    powershell -File scripts/ci.ps1 -Port 7201 -SkipExport
#>
[CmdletBinding()]
param(
    [string]$Godot = $env:GODOT,

    [ValidateRange(1024, 65535)]
    [int]$Port = 7099,

    [ValidateSet('all', 'server', 'client')]
    [string]$Export = 'all',

    [switch]$SkipExport
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location -LiteralPath $RepoRoot

if ([string]::IsNullOrWhiteSpace($Godot)) {
    throw "Set the GODOT environment variable or pass -Godot <path to the Godot 4.7.1 console executable>."
}
if (-not (Test-Path -LiteralPath $Godot)) {
    throw "Godot executable not found: $Godot"
}

# $env:GODOT normally points at the *_console.exe. That executable is only a thin
# launcher around the real engine and is unreliable under redirected output /
# CPU load: it can return -1 and/or return before the engine has finished. For
# every step we drive ourselves, run the real engine sibling through
# Start-Process -Wait (which blocks on it and propagates its real exit code).
# export.ps1 is still handed the console exe, since its `& $Godot` needs the
# console-subsystem process to block.
$Engine = $Godot
if ($Godot -match '_console\.exe$') {
    $realEngine = $Godot -replace '_console\.exe$', '.exe'
    if (Test-Path -LiteralPath $realEngine) { $Engine = $realEngine }
}

$LocalDir = Join-Path $RepoRoot '.local'
New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
$DbRelative = '.local/ci.db'
$LinkScript = Join-Path $PSScriptRoot 'link_shared.ps1'
$ExportScript = Join-Path $PSScriptRoot 'export.ps1'
$TestsScript = Join-Path $RepoRoot 'tests/run_tests.gd'

# Captures a native command's combined stdout+stderr and exit code. Output is
# redirected to files rather than pipes: the Godot Windows console wrapper exits
# with -1 and truncates output when stderr is a separate pipe (the unit tests
# intentionally emit a push_warning). Files keep both streams and the true exit
# code, and avoid PowerShell 5.1 turning native stderr into ErrorRecord noise.
$script:LastExit = 0
function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $outFile = Join-Path $LocalDir 'ci_capture.out'
    $errFile = Join-Path $LocalDir 'ci_capture.err'
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

    $quoted = @()
    foreach ($a in $Arguments) {
        if ($a -match '\s') { $quoted += ('"' + $a + '"') } else { $quoted += $a }
    }

    $proc = Start-Process -FilePath $FilePath -WorkingDirectory (Get-Location).Path -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ArgumentList $quoted
    $script:LastExit = $proc.ExitCode

    $text = ''
    if (Test-Path -LiteralPath $outFile) { $text += (Get-Content -LiteralPath $outFile -Raw) }
    if (Test-Path -LiteralPath $errFile) { $text += (Get-Content -LiteralPath $errFile -Raw) }
    return [string]$text
}

function Step([string]$Name) {
    Write-Host ""
    Write-Host ("[ci] === {0} ===" -f $Name)
}

function Assert-Exit([string]$What) {
    if ($script:LastExit -ne 0) {
        throw ("{0} failed (exit code {1})" -f $What, $script:LastExit)
    }
}

function Assert-NoScriptError([string]$Output, [string]$What) {
    if ($Output -match 'SCRIPT ERROR|Parse Error|Failed to load script') {
        throw ("{0} reported a script/parse error" -f $What)
    }
}

# The Godot Windows "console" executable is a thin wrapper around the real
# engine process, so kill the whole tree or the child can keep the UDP port.
function Stop-Tree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process -or $Process.HasExited) { return }
    & taskkill.exe /PID $Process.Id /T /F *> $null
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

# Waits until every artifact exists, is non-empty and its size has stopped
# changing. On a loaded machine (several workbenches exporting at once) the
# Godot console wrapper can return while the engine is still writing, so the
# artifacts - not the process exit code - are the source of truth for an export.
function Wait-Artifacts([string[]]$RelativePaths, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $present = $true
        $first = @{}
        foreach ($rel in $RelativePaths) {
            $full = Join-Path $RepoRoot $rel
            if (-not (Test-Path -LiteralPath $full)) { $present = $false; break }
            $len = (Get-Item -LiteralPath $full).Length
            if ($len -le 0) { $present = $false; break }
            $first[$rel] = $len
        }
        if ($present) {
            Start-Sleep -Seconds 2
            $stable = $true
            foreach ($rel in $RelativePaths) {
                $len2 = (Get-Item -LiteralPath (Join-Path $RepoRoot $rel)).Length
                if ($len2 -ne $first[$rel]) { $stable = $false; break }
            }
            if ($stable) { return $true }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

$serverProc = $null
try {
    Write-Host ("[ci] Godot: {0}" -f $Godot)
    Write-Host ("[ci] engine: {0}" -f $Engine)
    Write-Host ("[ci] repo:  {0}" -f $RepoRoot)
    Write-Host ("[ci] server: 127.0.0.1:{0}  db={1}" -f $Port, $DbRelative)

    # --- 1. contract verification -------------------------------------------
    Step 'link_shared -Verify'
    $out = Invoke-Captured -FilePath 'powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LinkScript, '-Verify')
    Write-Host $out
    Assert-Exit 'link_shared -Verify'

    # --- 2. import + parse checks -------------------------------------------
    # On a clean checkout the first import creates the class_name cache and, for
    # the server project, can exit non-zero while tearing down the 300MB addon
    # (a known shutdown crash). So the exit code is not the gate: the cache and
    # the parse checks below are.
    Step 'import both projects'
    Invoke-Captured -FilePath $Engine -Arguments @('--headless', '--path', 'server', '--import') | Out-Null
    Invoke-Captured -FilePath $Engine -Arguments @('--headless', '--path', 'client', '--import') | Out-Null
    foreach ($proj in @('client', 'server')) {
        $cache = Join-Path $RepoRoot (Join-Path $proj '.godot\global_script_class_cache.cfg')
        if (-not (Test-Path -LiteralPath $cache)) {
            throw ("import did not produce the class_name cache for {0} ({1})" -f $proj, $cache)
        }
    }
    Write-Host '[ci] class_name caches present for client and server'

    Step 'parse check: server'
    # --port/--db are mandatory here: without them the parse launch would open and
    # migrate the shared default user:// DB, which worktree isolation forbids.
    $out = Invoke-Captured -FilePath $Engine -Arguments @(
        '--headless', '--path', 'server', '--quit-after', '3', '--', '--server', '--port', "$Port", '--db', '.local/ci_parse.db')
    Write-Host ($out.Trim())
    Assert-Exit 'server parse check'
    Assert-NoScriptError $out 'server parse check'

    Step 'parse check: client'
    $out = Invoke-Captured -FilePath $Engine -Arguments @('--headless', '--path', 'client', '--quit-after', '5')
    Write-Host ($out.Trim())
    Assert-Exit 'client parse check'
    Assert-NoScriptError $out 'client parse check'

    # --- 3. unit tests -------------------------------------------------------
    Step 'unit tests (tests/run_tests.gd)'
    $out = Invoke-Captured -FilePath $Engine -Arguments @('--headless', '--path', 'server', '--script', $TestsScript)
    Write-Host $out
    Assert-Exit 'unit tests'
    Assert-NoScriptError $out 'unit tests'
    if ($out -notmatch '\[unit\] RESULT PASS') {
        throw 'unit tests did not report [unit] RESULT PASS'
    }

    # --- 4. headless bot against an isolated server --------------------------
    Step 'headless bot (isolated port/db)'
    foreach ($suffix in @('', '-wal', '-shm')) {
        Remove-Item -LiteralPath (Join-Path $RepoRoot ($DbRelative + $suffix)) -Force -ErrorAction SilentlyContinue
    }
    $serverLog = Join-Path $LocalDir 'ci_server.log'
    $serverErr = Join-Path $LocalDir 'ci_server.err.log'
    Remove-Item -LiteralPath $serverLog, $serverErr -Force -ErrorAction SilentlyContinue

    $serverProc = Start-Process -FilePath $Engine -WorkingDirectory $RepoRoot -PassThru -NoNewWindow `
        -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr `
        -ArgumentList @('--headless', '--path', 'server', '--', '--server', '--port', "$Port", '--db', $DbRelative)

    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $serverLog) {
            $text = Get-Content -LiteralPath $serverLog -Raw -ErrorAction SilentlyContinue
            if ($text -match ("listening on UDP {0}" -f $Port)) { $ready = $true; break }
        }
        if ($serverProc.HasExited) { break }
    }
    if (-not $ready) {
        if (Test-Path -LiteralPath $serverLog) { Write-Host (Get-Content -LiteralPath $serverLog -Raw) }
        if (Test-Path -LiteralPath $serverErr) { Write-Host (Get-Content -LiteralPath $serverErr -Raw) }
        throw ("CI server never reported listening on UDP {0}" -f $Port)
    }
    Write-Host ("[ci] server ready on UDP {0}" -f $Port)

    # The bot is stateless (it logs in / registers, so a retry just uses a fresh
    # account), and a very loaded machine can kill a short-lived engine early.
    # Retry once; the success condition is the frozen RESULT line, not just the
    # exit code.
    $botPassed = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $out = Invoke-Captured -FilePath $Engine -Arguments @(
            '--headless', '--path', 'client', '--', '--bot', '--host', '127.0.0.1', '--port', "$Port")
        Write-Host $out
        if ($script:LastExit -eq 0 -and $out -match '\[bot\] RESULT PASS') { $botPassed = $true; break }
        if ($attempt -lt 2) {
            Write-Host ("[ci] bot attempt {0} did not pass (exit {1}); retrying in 2s" -f $attempt, $script:LastExit)
            Start-Sleep -Seconds 2
        }
    }
    if (-not $botPassed) {
        throw 'bot did not report [bot] RESULT PASS'
    }

    if ($serverProc -and -not $serverProc.HasExited) {
        Stop-Tree $serverProc
    }
    $serverProc = $null

    # --- 5. exports ----------------------------------------------------------
    if ($SkipExport) {
        Write-Host '[ci] -SkipExport: exports skipped'
    }
    else {
        Step ("export ({0})" -f $Export)
        $expected = @()
        if ($Export -eq 'all' -or $Export -eq 'server') {
            $expected += 'server/build/mmorpg_server.x86_64'
            $expected += 'server/build/mmorpg_server.pck'
            $expected += 'server/build/libgdsqlite.linux.template_release.x86_64.so'
        }
        if ($Export -eq 'all' -or $Export -eq 'client') {
            $expected += 'client/build/mmorpg_client.exe'
            $expected += 'client/build/mmorpg_client.pck'
        }
        # Delete old artifacts first so a stale file can never look like a fresh
        # export, then try export.ps1. The engine (not the wrapper's exit code)
        # may finish slightly later, so fall back to waiting for the artifacts.
        foreach ($rel in $expected) {
            Remove-Item -LiteralPath (Join-Path $RepoRoot $rel) -Force -ErrorAction SilentlyContinue
        }

        $attempts = 2
        $exported = $false
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            $out = Invoke-Captured -FilePath 'powershell.exe' -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ExportScript, '-Target', $Export, '-Godot', $Godot)
            Write-Host $out
            if ($script:LastExit -eq 0) { $exported = $true; break }
            Write-Host ("[ci] export.ps1 exited {0}; waiting for artifacts to settle" -f $script:LastExit)
            if (Wait-Artifacts -RelativePaths $expected -TimeoutSec 300) {
                Write-Host '[ci] all export artifacts present; treating export as complete'
                $exported = $true
                break
            }
            if ($attempt -lt $attempts) {
                Write-Host ("[ci] export attempt {0} produced nothing; retrying in 3s" -f $attempt)
                Start-Sleep -Seconds 3
            }
        }
        if (-not $exported) {
            throw ("export failed: missing artifacts after {0} attempt(s): {1}" -f $attempts, ($expected -join ', '))
        }
    }

    Write-Host ""
    Write-Host "[ci] RESULT PASS"
    exit 0
}
catch {
    Write-Host ""
    Write-Host ("[ci] FAIL: {0}" -f $_.Exception.Message)
    exit 1
}
finally {
    if ($serverProc -and -not $serverProc.HasExited) {
        Stop-Tree $serverProc
    }
    Pop-Location
}
