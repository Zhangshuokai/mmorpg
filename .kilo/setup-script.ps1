#Requires -Version 5.1
<#
.SYNOPSIS
    Agent Manager per-worktree setup.

.DESCRIPTION
    Runs once when a managed worktree is created/imported, before the agent
    session starts, from inside that worktree (WORKTREE_PATH / REPO_PATH are
    provided by the task adapter).

    This file lives in the MAIN repository's .kilo/ directory - it must never be
    copied into a generated .kilo/worktrees/<name>/ checkout.

    Keep it short: the setup task has a 5 minute timeout. The heavy first
    `--import` (the ~300MB godot-sqlite addon) is deliberately left to the run
    script so setup cannot time out.

    What setup must do per worktree:
      * create the gitignored shared/ junctions - without them res://shared
        (and therefore both projects) does not exist;
      * create the gitignored .local/ directory used for isolated runtime state.
#>
$ErrorActionPreference = 'Stop'

# Junctions are not committed (see .gitignore), so every fresh checkout/worktree
# needs them. scripts/link_shared.ps1 is idempotent.
powershell -File scripts/link_shared.ps1

# Per-worktree isolated runtime state (never on the default user:// DB).
New-Item -ItemType Directory -Force -Path .local | Out-Null

Write-Host "[setup] shared junctions linked, .local ready"
