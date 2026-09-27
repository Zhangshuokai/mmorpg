#Requires -Version 5.1
<#
.SYNOPSIS
    Creates (idempotently) the `shared/` directory junctions used by both Godot
    projects, and verifies shared-contract consistency.

.DESCRIPTION
    The repository keeps a single source of truth in <root>/shared. Godot needs
    it importable as res://shared inside each project, so we map it as a Windows
    directory junction:

        client/shared -> ../shared
        server/shared -> ../shared

    Junctions are NOT committed (.gitignore), so run this once per checkout /
    worktree before opening either project.

    With -Verify the script additionally checks that:
      * both junctions exist and point at <root>/shared;
      * no `@rpc` declaration exists outside shared/net/net_rpc.gd (the single
        RPC contract both ends must share verbatim).

.EXAMPLE
    powershell -File scripts/link_shared.ps1
.EXAMPLE
    powershell -File scripts/link_shared.ps1 -Verify
#>
[CmdletBinding()]
param(
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$SharedDir = Join-Path $RepoRoot 'shared'
$RpcFile = Join-Path $SharedDir 'net\net_rpc.gd'
$Projects = @('client', 'server')

if (-not (Test-Path -LiteralPath $SharedDir)) {
    throw "shared/ directory not found at $SharedDir"
}

function Normalize([string]$p) {
    return ([System.IO.Path]::GetFullPath($p)).TrimEnd('\')
}

$exitCode = 0

foreach ($proj in $Projects) {
    $projDir = Join-Path $RepoRoot $proj
    if (-not (Test-Path -LiteralPath $projDir)) {
        Write-Error "[fail] $proj/ does not exist"
        $exitCode = 1
        continue
    }

    $link = Join-Path $projDir 'shared'
    $expected = Normalize $SharedDir

    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') {
            $actual = Normalize ($item.Target | Select-Object -First 1)
            if ($actual -ne $expected) {
                Write-Error "[fail] $proj/shared points at $actual, expected $expected"
                $exitCode = 1
            }
            else {
                Write-Host "[ok]   $proj/shared -> $actual"
            }
            continue
        }
        Write-Error "[fail] $link exists but is not a junction/symlink; remove it manually"
        $exitCode = 1
        continue
    }

    New-Item -ItemType Junction -Path $link -Target $SharedDir | Out-Null
    Write-Host "[new]  $proj/shared -> $expected"
}

if ($Verify) {
    if (-not (Test-Path -LiteralPath $RpcFile)) {
        Write-Error "[fail] missing $RpcFile"
        $exitCode = 1
    }
    else {
        # Both projects must register the shared RPC script as the same autoload,
        # otherwise the NodePath (/root/Net) differs and every RPC signature
        # check fails with an error pointing at an unrelated function.
        $autoloads = @{}
        foreach ($proj in $Projects) {
            $projectFile = Join-Path $RepoRoot (Join-Path $proj 'project.godot')
            if (-not (Test-Path -LiteralPath $projectFile)) {
                Write-Error "[fail] missing $projectFile"
                $exitCode = 1
                continue
            }
            $match = Select-String -Path $projectFile -Pattern '^\s*Net\s*=\s*"([^"]+)"' |
                Select-Object -First 1
            if ($null -eq $match) {
                Write-Error "[fail] $proj/project.godot does not register the 'Net' autoload"
                $exitCode = 1
                continue
            }
            $autoloads[$proj] = $match.Matches[0].Groups[1].Value
        }
        if ($autoloads.Count -eq $Projects.Count) {
            # @() is required: Sort-Object -Unique yields a scalar when only one
            # distinct value survives, and indexing a string returns a char.
            $unique = @($autoloads.Values | Sort-Object -Unique)
            if ($unique.Count -ne 1) {
                Write-Error "[fail] Net autoload paths differ: $($autoloads.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value } )"
                $exitCode = 1
            }
            elseif ($unique[0] -ne '*res://shared/net/net_rpc.gd') {
                Write-Error "[fail] Net autoload path is '$($unique[0])', expected '*res://shared/net/net_rpc.gd'"
                $exitCode = 1
            }
            else {
                Write-Host "[ok]   Net autoload identical in both projects: $($unique[0])"
            }
        }

        $stray = @()
        foreach ($proj in $Projects) {
            $scripts = Join-Path $RepoRoot (Join-Path $proj 'scripts')
            if (-not (Test-Path -LiteralPath $scripts)) { continue }
            $hits = Select-String -Path (Join-Path $scripts '*.gd') -Pattern '^\s*@rpc' -ErrorAction SilentlyContinue
            if ($hits) { $stray += $hits }
            $scenes = Join-Path $RepoRoot (Join-Path $proj 'scenes')
            if (Test-Path -LiteralPath $scenes) {
                $hits2 = Get-ChildItem -LiteralPath $scenes -Recurse -Filter '*.gd' -ErrorAction SilentlyContinue |
                    Select-String -Pattern '^\s*@rpc' -ErrorAction SilentlyContinue
                if ($hits2) { $stray += $hits2 }
            }
        }
        if ($stray.Count -gt 0) {
            Write-Error "[fail] @rpc declared outside shared/net/net_rpc.gd:"
            $stray | ForEach-Object { Write-Error ("       " + $_.Path + ":" + $_.LineNumber) }
            $exitCode = 1
        }
        else {
            Write-Host "[ok]   all @rpc declarations confined to shared/net/net_rpc.gd"
        }

        $declared = @(Select-String -Path $RpcFile -Pattern '^func\s+([a-z0-9_]+)\s*\(' -AllMatches |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object)

        # The declared functions are the wire contract only if they still match
        # Protocol.RPC_NAMES; without this comparison the list in protocol.gd and
        # the real @rpc declarations can silently drift apart.
        $protocolFile = Join-Path $SharedDir 'net\protocol.gd'
        $expected = @()
        if (Test-Path -LiteralPath $protocolFile) {
            $content = Get-Content -LiteralPath $protocolFile -Raw
            $block = [regex]::Match($content, 'const\s+RPC_NAMES[^=]*=\s*\[(.*?)\]', 'Singleline')
            if ($block.Success) {
                $expected = @([regex]::Matches($block.Groups[1].Value, '"([^"]+)"') |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object)
            }
        }
        if ($expected.Count -eq 0) {
            Write-Error "[fail] could not read RPC_NAMES from $protocolFile"
            $exitCode = 1
        }
        else {
            $drift = @(Compare-Object -ReferenceObject $expected -DifferenceObject $declared)
            if ($drift.Count -gt 0) {
                Write-Error "[fail] RPC contract drifted between Protocol.RPC_NAMES and the @rpc declarations in net_rpc.gd:"
                $drift | ForEach-Object { Write-Error ("       " + $_.SideIndicator + " " + $_.InputObject) }
                $exitCode = 1
            }
            else {
                Write-Host ("[ok]   RPC contract matches Protocol.RPC_NAMES (" + $expected.Count + " entries)")
            }
            Write-Host ("[info] RPC contract: " + ($declared -join ', '))
        }
    }
}

if ($exitCode -ne 0) { exit $exitCode }
Write-Host "[done] shared contract linked."
