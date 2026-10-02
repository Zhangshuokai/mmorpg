#Requires -Version 5.1
<#
.SYNOPSIS
    图形化启动器：配置 + 启动/停止服务端与客户端，无需命令行参数。

.DESCRIPTION
    WinForms 窗口，把所有启动配置（引擎路径、端口、数据库、登录账号/角色、
    --no-mobs/--aoi-stats 等）做成可视化表单，点击“保存配置”写入
    .local/launcher.json（被 gitignore），下次启动自动载入。

    实际的启动/停止仍复用 scripts/start_server.ps1 与 scripts/start_client.ps1，
    所以行为与命令行工具完全一致。

    运行：
        powershell -File scripts/launcher.ps1
        powershell -File scripts/launcher.ps1 -SelfTest   # 不弹窗，仅自检

    注意：本文件必须保存为 UTF-8 **带 BOM**。Windows PowerShell 5.1 读取无 BOM
    的脚本时会按 ANSI/GBK 解码，中文界面文字会变成乱码。

.PARAMETER ConfigPath
    配置文件路径。默认 <repo>/.local/launcher.json。

.PARAMETER SelfTest
    只校验配置读写与 WinForms 可用性后退出（供 CI/agent 使用，不显示窗口）。

.PARAMETER SmokeTest
    真实构建窗口并在约 0.6 秒后自动关闭，用于验证界面构建/事件绑定无错误。

.PARAMETER RepoRoot
    仓库根目录。通常无需指定：脚本会从自身位置（源码或打包后的 exe 所在目录）自动定位。
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$RepoRoot = '',
    [switch]$SelfTest,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'

# --- locate the repository root --------------------------------------------
# Works both as scripts/launcher.ps1 and as a ps2exe build (e.g.
# build/MMORPG-Launcher.exe): inside a compiled exe $PSScriptRoot is the exe
# folder, so we probe the candidate and its parent.
function Resolve-RepoRoot([string]$Hint, [string[]]$Candidates) {
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        if (Test-Path -LiteralPath (Join-Path $Hint 'scripts/start_server.ps1')) {
            return (Resolve-Path -LiteralPath $Hint).Path
        }
        throw "指定的 -RepoRoot 无效（缺少 scripts/start_server.ps1）：$Hint"
    }
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'scripts/start_server.ps1')) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        $parent = Split-Path -Parent $candidate
        if (-not [string]::IsNullOrWhiteSpace($parent) -and
                (Test-Path -LiteralPath (Join-Path $parent 'scripts/start_server.ps1'))) {
            return (Resolve-Path -LiteralPath $parent).Path
        }
    }
    throw '找不到仓库根目录（需要 scripts/start_server.ps1）。请用 -RepoRoot <path> 指定。'
}

$selfDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($selfDir) -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $selfDir = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($selfDir)) {
    $selfDir = (Get-Location).Path
}

$RepoRoot = Resolve-RepoRoot -Hint $RepoRoot -Candidates @(
    $selfDir, (Join-Path $selfDir '..'), (Get-Location).Path)
$ScriptsDir = Join-Path $RepoRoot 'scripts'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $RepoRoot '.local/launcher.json'
}
$ServerTool = Join-Path $ScriptsDir 'start_server.ps1'
$ClientTool = Join-Path $ScriptsDir 'start_client.ps1'
$GuidePath = Join-Path $RepoRoot 'docs/startup-guide.html'
$ServerPidFile = Join-Path $RepoRoot 'server/.local/server.pid'
$ServerOutLog = Join-Path $RepoRoot 'server/.local/server.out.log'

# --- config -----------------------------------------------------------------

function New-DefaultConfig {
    $engine = if ($env:GODOT) { $env:GODOT } else { '' }
    return [pscustomobject][ordered]@{
        godot       = $engine
        serverPort  = 7000
        database    = '.local/mmorpg_server.db'
        noMobs      = $false
        aoiStats    = $false
        clientHost  = '127.0.0.1'
        clientPort  = 7000
        user        = ''
        password    = ''
        character   = ''
        register    = $false
        clientCount = 1
    }
}

function Read-LauncherConfig([string]$Path) {
    $cfg = New-DefaultConfig
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
    try {
        $parsed = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json
        foreach ($name in $cfg.PSObject.Properties.Name) {
            if ($null -ne $parsed.PSObject.Properties[$name]) {
                $cfg.$name = $parsed.$name
            }
        }
    } catch {
        Write-Warning ("无法读取配置 {0}: {1}" -f $Path, $_)
    }
    return $cfg
}

function Save-LauncherConfig($Cfg, [string]$Path) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $Cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# --- server status ----------------------------------------------------------

function Get-ServerPidNumber {
    if (-not (Test-Path -LiteralPath $ServerPidFile)) { return 0 }
    $raw = Get-Content -LiteralPath $ServerPidFile -Encoding ASCII -ErrorAction SilentlyContinue | Select-Object -First 1
    $parsed = 0
    if (-not [int]::TryParse([string]$raw, [ref]$parsed)) { return 0 }
    if ($null -eq (Get-Process -Id $parsed -ErrorAction SilentlyContinue)) { return 0 }
    return $parsed
}

function Get-ServerStatusText([int]$Port) {
    $serverPid = Get-ServerPidNumber
    $head = if ($serverPid -gt 0) {
        "服务端：运行中 (pid $serverPid, 端口 $Port)"
    } else {
        "服务端：未运行"
    }
    $lines = @($head)
    if (Test-Path -LiteralPath $ServerOutLog) {
        $ready = Select-String -LiteralPath $ServerOutLog -Pattern 'listening on UDP' -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($ready) { $lines += ("就绪: " + $ready.Line.Trim()) }
        $tail = Get-Content -LiteralPath $ServerOutLog -Tail 12 -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($tail) {
            $lines += '--- 日志 ---'
            $lines += $tail
        }
    } else {
        $lines += '暂无日志'
    }
    return ($lines -join [Environment]::NewLine)
}

# --- form helpers (script scope so event handlers can resolve them) ---------

$script:txtGodot = $null
$script:txtServerPort = $null
$script:txtDatabase = $null
$script:chkNoMobs = $null
$script:chkAoi = $null
$script:txtHost = $null
$script:txtClientPort = $null
$script:txtUser = $null
$script:txtPass = $null
$script:txtChar = $null
$script:chkRegister = $null
$script:txtCount = $null
$script:txtStatus = $null

function Get-FormConfig {
    return [pscustomobject][ordered]@{
        godot       = $script:txtGodot.Text.Trim()
        serverPort  = [int]$script:txtServerPort.Text
        database    = $script:txtDatabase.Text.Trim()
        noMobs      = $script:chkNoMobs.Checked
        aoiStats    = $script:chkAoi.Checked
        clientHost  = $script:txtHost.Text.Trim()
        clientPort  = [int]$script:txtClientPort.Text
        user        = $script:txtUser.Text.Trim()
        password    = $script:txtPass.Text
        character   = $script:txtChar.Text.Trim()
        register    = $script:chkRegister.Checked
        clientCount = [int]$script:txtCount.Text
    }
}

function Set-FormConfig($Cfg) {
    $script:txtGodot.Text = [string]$Cfg.godot
    $script:txtServerPort.Text = [string]$Cfg.serverPort
    $script:txtDatabase.Text = [string]$Cfg.database
    $script:chkNoMobs.Checked = [bool]$Cfg.noMobs
    $script:chkAoi.Checked = [bool]$Cfg.aoiStats
    $script:txtHost.Text = [string]$Cfg.clientHost
    $script:txtClientPort.Text = [string]$Cfg.clientPort
    $script:txtUser.Text = [string]$Cfg.user
    $script:txtPass.Text = [string]$Cfg.password
    $script:txtChar.Text = [string]$Cfg.character
    $script:chkRegister.Checked = [bool]$Cfg.register
    $script:txtCount.Text = [string]$Cfg.clientCount
}

function Update-StatusText {
    if ($null -eq $script:txtStatus) { return }
    $port = 7000
    [void][int]::TryParse($script:txtServerPort.Text, [ref]$port)
    $script:txtStatus.Text = Get-ServerStatusText $port
}

function Show-Error([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'MMORPG 启动器', 'OK', 'Warning')
}

function Invoke-SaveConfig([switch]$Quiet) {
    try {
        $cfg = Get-FormConfig
        Save-LauncherConfig $cfg $ConfigPath
        if (-not $Quiet) { [void][System.Windows.Forms.MessageBox]::Show("配置已保存到：`n$ConfigPath", 'MMORPG 启动器') }
        return $true
    } catch {
        Show-Error "保存失败：$_"
        return $false
    }
}

function Invoke-StartServer {
    $cfg = Get-FormConfig
    if ([string]::IsNullOrWhiteSpace($cfg.godot)) { Show-Error '请先选择 Godot 可执行文件。'; return }
    Invoke-SaveConfig -Quiet | Out-Null
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ServerTool,
        '-Godot', $cfg.godot, '-Port', "$($cfg.serverPort)", '-Database', $cfg.database)
    if ($cfg.noMobs) { $args += '-NoMobs' }
    if ($cfg.aoiStats) { $args += '-AoiStats' }
    Start-Process -FilePath 'powershell' -ArgumentList $args -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    Update-StatusText
}

function Invoke-StopServer {
    & $ServerTool -Action stop
    Update-StatusText
}

function Invoke-StartClients {
    $cfg = Get-FormConfig
    if ([string]::IsNullOrWhiteSpace($cfg.godot)) { Show-Error '请先选择 Godot 可执行文件。'; return }
    Invoke-SaveConfig -Quiet | Out-Null
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ClientTool,
        '-Godot', $cfg.godot, '-ServerHost', $cfg.clientHost, '-Port', "$($cfg.clientPort)",
        '-Count', "$($cfg.clientCount)")
    if ($cfg.user) { $args += @('-User', $cfg.user) }
    if ($cfg.password) { $args += @('-Password', $cfg.password) }
    if ($cfg.character) { $args += @('-Character', $cfg.character) }
    if ($cfg.register) { $args += '-Register' }
    Start-Process -FilePath 'powershell' -ArgumentList $args -WindowStyle Hidden
}

function Invoke-StopClients {
    & $ClientTool -Action stop
}

# --- UI ---------------------------------------------------------------------

function New-Group([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Text
    $g.Location = New-Object System.Drawing.Point($X, $Y)
    $g.Size = New-Object System.Drawing.Size($W, $H)
    return $g
}

function New-Label([string]$Text, [int]$X, [int]$Y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.AutoSize = $true
    return $l
}

function New-TextBox([int]$X, [int]$Y, [int]$W) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, 24)
    return $t
}

function New-Button([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    return $b
}

function Show-Launcher {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'MMORPG 启动器'
    $form.ClientSize = New-Object System.Drawing.Size(620, 690)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    # 引擎
    $grpEngine = New-Group '引擎' 12 10 596 74
    $grpEngine.Controls.Add((New-Label 'Godot 可执行文件（console 或 GUI 版均可）' 14 22))
    $script:txtGodot = New-TextBox 14 44 470
    $btnBrowse = New-Button '浏览...' 492 42 88 25
    $grpEngine.Controls.Add($script:txtGodot)
    $grpEngine.Controls.Add($btnBrowse)
    $form.Controls.Add($grpEngine)

    # 服务端
    $grpServer = New-Group '服务端' 12 92 596 112
    $grpServer.Controls.Add((New-Label '端口' 14 24))
    $script:txtServerPort = New-TextBox 14 44 70
    $grpServer.Controls.Add($script:txtServerPort)
    $grpServer.Controls.Add((New-Label '数据库（相对路径按项目目录解析）' 100 24))
    $script:txtDatabase = New-TextBox 100 44 470
    $grpServer.Controls.Add($script:txtDatabase)
    $script:chkNoMobs = New-Object System.Windows.Forms.CheckBox
    $script:chkNoMobs.Text = '无怪物（--no-mobs）'
    $script:chkNoMobs.Location = New-Object System.Drawing.Point(14, 78)
    $script:chkNoMobs.AutoSize = $true
    $grpServer.Controls.Add($script:chkNoMobs)
    $script:chkAoi = New-Object System.Windows.Forms.CheckBox
    $script:chkAoi.Text = 'AoI 统计（--aoi-stats）'
    $script:chkAoi.Location = New-Object System.Drawing.Point(200, 78)
    $script:chkAoi.AutoSize = $true
    $grpServer.Controls.Add($script:chkAoi)
    $form.Controls.Add($grpServer)

    # 客户端
    $grpClient = New-Group '客户端' 12 212 596 150
    $grpClient.Controls.Add((New-Label '服务器地址' 14 24))
    $script:txtHost = New-TextBox 14 44 130
    $grpClient.Controls.Add($script:txtHost)
    $grpClient.Controls.Add((New-Label '端口' 156 24))
    $script:txtClientPort = New-TextBox 156 44 60
    $grpClient.Controls.Add($script:txtClientPort)
    $grpClient.Controls.Add((New-Label '用户名' 228 24))
    $script:txtUser = New-TextBox 228 44 150
    $grpClient.Controls.Add($script:txtUser)
    $grpClient.Controls.Add((New-Label '密码（留空则手动输入）' 390 24))
    $script:txtPass = New-TextBox 390 44 180
    $script:txtPass.UseSystemPasswordChar = $true
    $grpClient.Controls.Add($script:txtPass)

    $grpClient.Controls.Add((New-Label '角色名（留空则停在角色选择）' 14 78))
    $script:txtChar = New-TextBox 14 98 170
    $grpClient.Controls.Add($script:txtChar)
    $script:chkRegister = New-Object System.Windows.Forms.CheckBox
    $script:chkRegister.Text = '注册新账号'
    $script:chkRegister.Location = New-Object System.Drawing.Point(198, 100)
    $script:chkRegister.AutoSize = $true
    $grpClient.Controls.Add($script:chkRegister)
    $grpClient.Controls.Add((New-Label '窗口数量' 330 78))
    $script:txtCount = New-TextBox 330 98 50
    $grpClient.Controls.Add($script:txtCount)
    $form.Controls.Add($grpClient)

    # 操作
    $btnStartServer = New-Button '启动服务端' 12 372 116 32
    $btnStopServer = New-Button '停止服务端' 134 372 116 32
    $btnStartClients = New-Button '启动客户端' 256 372 116 32
    $btnStopClients = New-Button '停止客户端' 378 372 116 32
    $form.Controls.Add($btnStartServer)
    $form.Controls.Add($btnStopServer)
    $form.Controls.Add($btnStartClients)
    $form.Controls.Add($btnStopClients)

    $btnSave = New-Button '保存配置' 12 412 116 32
    $btnReload = New-Button '重新载入' 134 412 116 32
    $btnRefresh = New-Button '刷新状态' 256 412 116 32
    $btnGuide = New-Button '打开启动说明' 378 412 116 32
    $form.Controls.Add($btnSave)
    $form.Controls.Add($btnReload)
    $form.Controls.Add($btnRefresh)
    $form.Controls.Add($btnGuide)

    # 状态
    $grpStatus = New-Group '状态' 12 454 596 224
    $script:txtStatus = New-Object System.Windows.Forms.TextBox
    $script:txtStatus.Location = New-Object System.Drawing.Point(14, 24)
    $script:txtStatus.Size = New-Object System.Drawing.Size(566, 188)
    $script:txtStatus.Multiline = $true
    $script:txtStatus.ReadOnly = $true
    $script:txtStatus.ScrollBars = 'Vertical'
    $script:txtStatus.WordWrap = $false
    $script:txtStatus.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $grpStatus.Controls.Add($script:txtStatus)
    $form.Controls.Add($grpStatus)

    # 事件
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Godot 可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:txtGodot.Text = $dlg.FileName
        }
    })
    $btnSave.Add_Click({ [void](Invoke-SaveConfig) })
    $btnReload.Add_Click({ Set-FormConfig (Read-LauncherConfig $ConfigPath); Update-StatusText })
    $btnRefresh.Add_Click({ Update-StatusText })
    $btnGuide.Add_Click({ if (Test-Path -LiteralPath $GuidePath) { Start-Process $GuidePath } else { Show-Error "找不到 $GuidePath" } })
    $btnStartServer.Add_Click({ Invoke-StartServer })
    $btnStopServer.Add_Click({ Invoke-StopServer })
    $btnStartClients.Add_Click({ Invoke-StartClients })
    $btnStopClients.Add_Click({ Invoke-StopClients })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $timer.Add_Tick({ Update-StatusText })
    $form.Add_Shown({ Set-FormConfig (Read-LauncherConfig $ConfigPath); Update-StatusText; $timer.Start() })

    if ($SmokeTest) {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 600
        [System.Windows.Forms.Application]::DoEvents()
        $form.Close()
        $form.Dispose()
        Write-Host '[launcher] 冒烟测试通过（界面构建无错误）'
        # ps2exe 的 GUI 宿主不会因脚本结束而退出，必须显式终止进程。
        [System.Environment]::Exit(0)
    }

    [void]$form.ShowDialog()
    $form.Dispose()
    [System.Environment]::Exit(0)
}

# --- entry ------------------------------------------------------------------

if ($SelfTest) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("launcher-selftest-{0}.json" -f (Get-Random))
    $cfg = New-DefaultConfig
    $cfg.serverPort = 7301
    $cfg.user = '自检用户'
    $cfg.register = $true
    $cfg.clientCount = 2
    Save-LauncherConfig $cfg $tmp
    $back = Read-LauncherConfig $tmp
    $ok = ($back.serverPort -eq 7301) -and ($back.user -eq '自检用户') -and ($back.register) -and ($back.clientCount -eq 2)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if (-not $ok) {
        Write-Error '[launcher] 自检失败：配置读写不一致'
        [System.Environment]::Exit(1)
    }
    Write-Host '[launcher] 自检通过（配置读写 + WinForms 可用）'
    [System.Environment]::Exit(0)
}

Show-Launcher
