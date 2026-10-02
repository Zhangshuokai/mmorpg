#Requires -Version 5.1
<#
.SYNOPSIS
    Start, stop, and monitor the dedicated MMORPG server.

.DESCRIPTION
    A small lifecycle wrapper around the headless server so you do not have to
    remember the Godot invocation, and so a running server is observable:

      start    launch the server detached, wait until it logs
               "listening on UDP <port>", record its PID
      status   show RUNNING/STOPPED, the last ready line, and the log tail
      stop     kill the recorded PID
      restart  stop (if running) then start
      logs     tail the server output/error logs

    The PID and logs live under server/.local/ (gitignored), so `status`/`stop`
    work across shells and sessions. The server itself must be started once with
    `link_shared.ps1` already run and the project imported (see AGENTS.md).

    NOTE ON THE ENGINE EXE: $env:GODOT normally points at
    Godot_v4.7.1-stable_win64_console.exe. That is only a launcher and is
    unreliable for a detached process, so this script runs the real engine
    sibling (Godot_v4.7.1-stable_win64.exe) when it exists.

.PARAMETER Action
    start (default) | stop | restart | status | logs.

.PARAMETER Godot
    The Godot 4.7.1 executable. Defaults to $env:GODOT; pass it explicitly when
    the environment variable is not set.

.PARAMETER Port
    UDP port for the server. Default 7000.

.PARAMETER Database
    SQLite path passed to `--db`. Relative paths resolve under the *project*
    directory (server/), so the default becomes server/.local/mmorpg_server.db.
    (Named Database, not Db: -Db collides with the built-in -Debug alias.)

.PARAMETER NoMobs
    Pass `--no-mobs` (enemy-free multiplayer debug mode).

.PARAMETER AoiStats
    Pass `--aoi-stats` (once-a-second AoI/broadcast capacity line).

.PARAMETER Follow
    With -Action status: keep printing the status every -Interval seconds until
    Ctrl+C (a cheap monitor).

.PARAMETER Interval
    Seconds between -Follow refreshes. Default 5.

.PARAMETER Tail
    Log lines to show for status/logs. Default 20.

.EXAMPLE
    $env:GODOT = "D:\code\game\godot_engine\Godot_v4.7.1-stable_win64_console.exe"
    powershell -File scripts/start_server.ps1
    powershell -File scripts/start_server.ps1 -Action status -Follow
    powershell -File scripts/start_server.ps1 -Action stop
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs')]
    [string]$Action = 'start',

    [string]$Godot = $env:GODOT,

    [ValidateRange(1024, 65535)]
    [int]$Port = 7000,

    [string]$Database = '.local/mmorpg_server.db',

    [switch]$NoMobs,
    [switch]$AoiStats,

    [switch]$Follow,

    [ValidateRange(1, 3600)]
    [int]$Interval = 5,

    [ValidateRange(1, 1000)]
    [int]$Tail = 20
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$LocalDir = Join-Path $RepoRoot 'server/.local'
$PidFile = Join-Path $LocalDir 'server.pid'
$OutLog = Join-Path $LocalDir 'server.out.log'
$ErrLog = Join-Path $LocalDir 'server.err.log'


function Resolve-Engine([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Set the GODOT environment variable or pass -Godot <path to the Godot 4.7.1 console executable>."
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Godot executable not found: $Path"
    }
    if ($Path -match '_console\.exe$') {
        $real = $Path -replace '_console\.exe$', '.exe'
        if (Test-Path -LiteralPath $real) { return $real }
    }
    return $Path
}

function Get-ServerPid {
    if (-not (Test-Path -LiteralPath $PidFile)) { return 0 }
    $raw = Get-Content -LiteralPath $PidFile -Encoding ASCII -ErrorAction SilentlyContinue | Select-Object -First 1
    $parsed = 0
    if (-not [int]::TryParse([string]$raw, [ref]$parsed)) { return 0 }
    if ($null -eq (Get-Process -Id $parsed -ErrorAction SilentlyContinue)) { return 0 }
    return $parsed
}

function Get-ServerArgs {
    $arguments = @('--headless', '--path', 'server', '--', '--server', '--port', "$Port", '--db', $Database)
    if ($NoMobs) { $arguments += '--no-mobs' }
    if ($AoiStats) { $arguments += '--aoi-stats' }
    return $arguments
}

function Start-Server {
    $running = Get-ServerPid
    if ($running -gt 0) {
        Write-Host "[server] already running (pid $running, port $Port)"
        return
    }
    $engine = Resolve-Engine $Godot
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    # Fresh logs per run so `status` never reports a stale ready line.
    Remove-Item -LiteralPath $OutLog, $ErrLog -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $engine -ArgumentList (Get-ServerArgs) `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog `
        -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
    Write-Host "[server] starting pid=$($proc.Id) port=$Port db=$Database"
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) {
            Write-Host "[server] FAILED to start (exit $($proc.ExitCode)); see $ErrLog"
            if (Test-Path -LiteralPath $ErrLog) { Get-Content -LiteralPath $ErrLog -Tail $Tail -Encoding UTF8 }
            return
        }
        if (Select-String -LiteralPath $OutLog -Pattern "listening on UDP $Port" -Quiet -ErrorAction SilentlyContinue) {
            Write-Host "[server] ready: listening on UDP $Port (pid $($proc.Id))"
            return
        }
    }
    Write-Host "[server] started but no ready line after 30s; check $OutLog"
}

function Stop-Server {
    $running = Get-ServerPid
    if ($running -le 0) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Write-Host "[server] not running"
        return
    }
    Write-Host "[server] stopping pid $running ..."
    Stop-Process -Id $running -Force -ErrorAction SilentlyContinue
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 250
        if ($null -eq (Get-Process -Id $running -ErrorAction SilentlyContinue)) { break }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[server] stopped"
}

function Show-Status {
    $running = Get-ServerPid
    if ($running -gt 0) {
        Write-Host "[server] RUNNING pid=$running port=$Port db=$Database"
    } else {
        Write-Host "[server] STOPPED"
    }
    if (-not (Test-Path -LiteralPath $OutLog)) {
        Write-Host "[server] no log yet ($OutLog)"
        return
    }
    $ready = Select-String -LiteralPath $OutLog -Pattern 'listening on UDP' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($ready) { Write-Host ("[server] last ready: " + $ready.Line.Trim()) }
    Write-Host "[server] --- $OutLog (tail $Tail) ---"
    Get-Content -LiteralPath $OutLog -Tail $Tail -Encoding UTF8
    if (Test-Path -LiteralPath $ErrLog) {
        $err = Get-Content -LiteralPath $ErrLog -Tail $Tail -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($err) {
            Write-Host "[server] --- $ErrLog (tail $Tail) ---"
            $err
        }
    }
}

function Show-Logs {
    if (Test-Path -LiteralPath $OutLog) {
        Write-Host "[server] --- $OutLog (tail $Tail) ---"
        Get-Content -LiteralPath $OutLog -Tail $Tail -Encoding UTF8
    } else {
        Write-Host "[server] no output log yet ($OutLog)"
    }
    if (Test-Path -LiteralPath $ErrLog) {
        $err = Get-Content -LiteralPath $ErrLog -Tail $Tail -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($err) {
            Write-Host "[server] --- $ErrLog (tail $Tail) ---"
            $err
        }
    }
}

switch ($Action) {
    'start'   { Start-Server }
    'stop'    { Stop-Server }
    'restart' { Stop-Server; Start-Server }
    'status'  {
        if ($Follow) {
            while ($true) {
                Write-Host ("=== {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
                Show-Status
                Start-Sleep -Seconds $Interval
            }
        } else {
            Show-Status
        }
    }
    'logs'    { Show-Logs }
}
