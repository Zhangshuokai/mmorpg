#Requires -Version 5.1
<#
.SYNOPSIS
    Build build/MMORPG-Launcher.exe, a native launcher for the MMORPG project.

.DESCRIPTION
    Compiles a tiny C# WinForms wrapper (no external download, no ps2exe needed)
    that:
      * locates the repository root from its own location (it must sit inside the
        repo, e.g. build/), then
      * starts `powershell -STA -File scripts/launcher.ps1` with no console
        window, and
      * waits for the launcher window to close, propagating its exit code.

    So the exe is just a double-clickable front-end for scripts/launcher.ps1;
    the script itself keeps doing all the work. Arguments are forwarded, which
    makes it testable: MMORPG-Launcher.exe -SelfTest / -SmokeTest.

.PARAMETER OutputPath
    Where to write the exe. Default <repo>/build/MMORPG-Launcher.exe.

.EXAMPLE
    powershell -File scripts/build_launcher_exe.ps1
    powershell -File scripts/build_launcher_exe.ps1 -OutputPath build/launcher.exe
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$Launcher = Join-Path $PSScriptRoot 'launcher.ps1'
if (-not (Test-Path -LiteralPath $Launcher)) {
    throw "Launcher script not found: $Launcher"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $RepoRoot 'build/MMORPG-Launcher.exe'
}
$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
}

$source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class MmorpgLauncher
{
    [STAThread]
    static void Main(string[] args)
    {
        string repo = FindRepo(AppDomain.CurrentDomain.BaseDirectory);
        if (repo == null)
        {
            MessageBox.Show(
                "Cannot find scripts/launcher.ps1.\nPlace this exe inside the repository (e.g. in build/).",
                "MMORPG Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.Exit(2);
            return;
        }

        string script = Path.Combine(repo, Path.Combine("scripts", "launcher.ps1"));
        string extra = "";
        foreach (string a in args)
        {
            extra += " \"" + a.Replace("\"", "\\\"") + "\"";
        }

        var psi = new ProcessStartInfo();
        psi.FileName = "powershell.exe";
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + script + "\"" + extra;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;

        try
        {
            var proc = Process.Start(psi);
            proc.WaitForExit();
            Environment.Exit(proc.ExitCode);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "MMORPG Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.Exit(3);
        }
    }

    static string FindRepo(string start)
    {
        string dir = start;
        for (int i = 0; i < 3 && !string.IsNullOrEmpty(dir); i++)
        {
            if (File.Exists(Path.Combine(dir, Path.Combine("scripts", "launcher.ps1"))))
            {
                return dir;
            }
            dir = Path.GetDirectoryName(dir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        }
        return null;
    }
}
'@

Write-Host ("[exe] compiling {0}" -f $OutputPath)
Add-Type -TypeDefinition $source -OutputAssembly $OutputPath -OutputType WindowsApplication `
    -ReferencedAssemblies 'System.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll'

if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "Compilation did not produce $OutputPath"
}
$size = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1KB, 0)
Write-Host ("[exe] done: {0} ({1} KB)" -f $OutputPath, $size)
