#Requires -Version 5.1
<#
.SYNOPSIS
    Launch one or more MMORPG GUI clients, optionally logging them straight in.

.DESCRIPTION
    Opens the real (non-console) client executable pointed at a server, so no
    extra console window appears. With -User/-Password the client pre-fills its
    login fields and submits automatically; with -Character it also creates or
    selects that character and enters the world (via the client's --login-* args,
    see client/scripts/main.gd).

    Launched PIDs are recorded under client/.local/clients.pid so `-Action stop`
    can close them again.

    Engine exe resolution matches scripts/start_server.ps1: $env:GODOT normally
    points at the console launcher, and the real engine sibling is used instead.

.PARAMETER Action
    start (default) | stop (stop the clients recorded by a previous start).

.PARAMETER Godot
    The Godot 4.7.1 executable. Defaults to $env:GODOT.

.PARAMETER ServerHost
    Server address to connect to. Default 127.0.0.1. (Named ServerHost because
    $Host is a built-in PowerShell variable.)

.PARAMETER Port
    Server UDP port. Default 7000; must match the server's --port.

.PARAMETER User
    Login username. With -Count > 1 each client gets a numeric suffix
    (alice1, alice2, ...) so they are distinct accounts.

.PARAMETER Password
    Login password. If -User is given without -Password the client only pre-fills
    the username and waits for a human to type the password.

.PARAMETER Character
    Character name to create/select and enter the world with. Optional: without
    it the client stops at the character-select screen (login only).

.PARAMETER Register
    Register the account instead of logging in (use for a brand-new username).

.PARAMETER Count
    Number of client windows to launch. Default 1.

.EXAMPLE
    # One client, stops at character select (login only)
    powershell -File scripts/start_client.ps1 -User alice -Password secret1

.EXAMPLE
    # Two distinct accounts, each auto-entering the world
    powershell -File scripts/start_client.ps1 -User alice -Password secret1 `
        -Character Hero -Register -Count 2

.EXAMPLE
    powershell -File scripts/start_client.ps1 -Action stop
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'stop')]
    [string]$Action = 'start',

    [string]$Godot = $env:GODOT,

    [string]$ServerHost = '127.0.0.1',

    [ValidateRange(1024, 65535)]
    [int]$Port = 7000,

    [string]$User = '',

    [string]$Password = '',

    [string]$Character = '',

    [switch]$Register,

    [ValidateRange(1, 16)]
    [int]$Count = 1
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$LocalDir = Join-Path $RepoRoot 'client/.local'
$PidFile = Join-Path $LocalDir 'clients.pid'


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

function Start-Clients {
    $engine = Resolve-Engine $Godot
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    $started = @()
    for ($i = 1; $i -le $Count; $i++) {
        $useUser = $User
        $useChar = $Character
        if ($Count -gt 1) {
            if (-not [string]::IsNullOrEmpty($User)) { $useUser = "$User$i" }
            if (-not [string]::IsNullOrEmpty($Character)) { $useChar = "$Character$i" }
        }
        $arguments = @('--path', 'client', '--', '--host', $ServerHost, '--port', "$Port")
        if (-not [string]::IsNullOrEmpty($useUser)) { $arguments += @('--login-user', $useUser) }
        if (-not [string]::IsNullOrEmpty($Password)) { $arguments += @('--login-pass', $Password) }
        if (-not [string]::IsNullOrEmpty($useChar)) { $arguments += @('--login-char', $useChar) }
        if ($Register) { $arguments += '--login-register' }

        $proc = Start-Process -FilePath $engine -ArgumentList $arguments -PassThru
        $started += $proc.Id
        $describe = "client $i pid=$($proc.Id) -> $ServerHost`:$Port"
        if (-not [string]::IsNullOrEmpty($useUser)) { $describe += " user=$useUser" }
        if (-not [string]::IsNullOrEmpty($useChar)) { $describe += " char=$useChar" }
        if ($Register) { $describe += " register" }
        Write-Host "[client] $describe"
    }
    Set-Content -LiteralPath $PidFile -Value $started -Encoding ASCII
    if (-not [string]::IsNullOrEmpty($User) -and [string]::IsNullOrEmpty($Password)) {
        Write-Host "[client] no -Password given: type it in the window (username is pre-filled)."
    }
    if (-not [string]::IsNullOrEmpty($User) -and [string]::IsNullOrEmpty($Character)) {
        Write-Host "[client] no -Character given: pick a character in the window to enter the world."
    }
}

function Stop-Clients {
    if (-not (Test-Path -LiteralPath $PidFile)) {
        Write-Host "[client] no recorded clients"
        return
    }
    $pids = Get-Content -LiteralPath $PidFile -Encoding ASCII -ErrorAction SilentlyContinue
    $stopped = 0
    foreach ($raw in $pids) {
        $clientPid = 0
        if (-not [int]::TryParse([string]$raw, [ref]$clientPid)) { continue }
        if ($null -ne (Get-Process -Id $clientPid -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $clientPid -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[client] stopped $stopped window(s)"
}

switch ($Action) {
    'start' { Start-Clients }
    'stop'  { Stop-Clients }
}
