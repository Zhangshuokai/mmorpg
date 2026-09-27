# AGENTS.md

目标：基于 **Godot 4** 的类《魔兽世界》MMORPG（大型多人在线、服务端权威）。
当前状态：**MVP 骨架已落地**（双工程 + 共享契约 + 移动/战斗/登录存档闭环，全部本地验证通过）；
后续规划见 `docs/roadmap.md`。

## 版本锁定（三者必须同时匹配）

- 引擎：**Godot 4.7.1-stable**（控制台版 `Godot_v4.7.1-stable_win64_console.exe`，本机安装于
  `D:\code\game\godot_engine\`，**未加入 PATH**；任何脚本都读 `$env:GODOT`，不要写死路径）。
- 验证命令：`& $env:GODOT --version` → `4.7.1.stable.official.a13da4feb`。
- 引擎 ↔ **导出模板** ↔ `godot-sqlite` 三者版本必须一致；错配会静默破坏导出或插件加载。
  - 导出模板已装在 `%APPDATA%\Godot\export_templates\4.7.1.stable\`（缺 `linux_release.x86_64` 时服务端导出必失败）。
  - `godot-sqlite` v4.9，其 `gdsqlite.gdextension` 里 `compatibility_minimum = "4.7"`；升引擎小版本必须一起换插件。

## 仓库现状（MVP 已落地）

- 双工程，各自独立 `project.godot`（**不是**单一工程）：
  - `server/`：专用服务器（Linux 导出 + 本机 headless）。服务逻辑在 `server/scripts/`：
    `main.gd`（装配 + 会话流程）、`db.gd`、`auth.gd`、`persistence.gd`、`world.gd`（20Hz 权威世界）、`combat.gd`。
  - `client/`：Windows 桌面客户端。`main.gd`（实体表 + 相机 + 输入）、`network_client.gd`（连接/握手/发送）、
    `entity_view.gd`/`player.gd`/`mob.gd`（插值渲染）、`ui_login.gd`/`hud.gd`、`world_visuals.gd`、`bot.gd`（无头自检）。
- 共享契约在根 `shared/`，用 **Windows 目录联接**映射为 `client/shared`、`server/shared`：
  - 联接由 `scripts/link_shared.ps1` 幂等创建，**不提交**；**每个 worktree 都要重新跑一次**（否则 `res://shared/...` 不存在）。
  - `client/shared/x.gd` 与 `server/shared/x.gd` 是**同一个文件**，改哪边都是改根 `shared/`，不要当副本维护。
- `server/addons/godot-sqlite/`（约 300MB，多平台二进制）**必须提交**；客户端工程**没有** `addons/`，不要往里装。
- `class_name` 作用域：`Protocol`/`EntityState`/`CharacterSheet` 两端都可见；`DBService`/`AuthService`/
  `PersistenceService`/`WorldService`/`CombatService` 只在服务端工程注册，客户端**不能**引用。
- 文档分工：`docs/research/*` = 已核实的调研事实（不是计划书）；`docs/roadmap.md` = 未来展望/技术债。

## 架构决策（已固化，改动前先想清楚）

- GDScript（不混 C#）；Godot 高层多人 **ENet/UDP**，端口 **7000**，世界 tick **20Hz**；服务端权威。
- **所有 `@rpc` 只在 `shared/net/net_rpc.gd`**，两端注册为**同名 autoload `Net`**（NodePath 恒为 `/root/Net`）。
  新增一个 RPC 需要同时改三处：`net_rpc.gd` 的函数 + 转发信号、`Protocol.RPC_NAMES`、两端的信号处理；
  `-Verify` 会因 `RPC_NAMES` 不一致而失败。
- 客户端只发**输入/意图**（`c2s_*` 一律 `rpc_id(1, ...)`）；服务端只发权威状态（`s2c_*`）。
  绝不采信客户端上报的位置/伤害/HP。
- 鉴权走 `SceneMultiplayer.auth_callback`（凭据在 auth payload 的 JSON 字节里，**不**走裸 RPC）；
  客户端侧也必须设非空 `auth_callback`，否则 `peer_authenticating` 不触发；校验失败只许 `disconnect_peer`，
  成功才 `complete_auth`（见 `auth.gd` 的 `handle_auth`/`_reject`）。
- 存储：`godot-sqlite`；DB 固定 `user://mmorpg_server.db`；密码只存 `SHA-256(salt||password)`（`HashingContext` + 每账号随机 salt）。
- `Protocol` 是数值唯一真相源：tick、移动速度、射程/伤害/冷却、怪物数值、地图与掩体坐标、
  用户名/密码/角色名长度边界（客户端预检与服务端校验共用，别在两端各写一份）。
- 怪物实体 id 用保留段 `Protocol.MOB_ID_BASE + i`，避免与随机 peer id 冲突。
- 客户端**不做**客户端预测（有意取舍：LAN 下有可见输入延迟，插值在客户端做）。
- 客户端**不用 InputMap**：`client/project.godot` 没有 `[input]` 段，键位直接读
  `Input.is_physical_key_pressed(KEY_W/A/S/D)` 与 `_unhandled_input`（Esc/Space/1/Tab）。

## 骨架如何运转（快速定位）

- 服务端入口 `server/scenes/main.tscn` → `scripts/main.gd`：`_ready` 里把
  `Engine.physics_ticks_per_second` 设成 `Protocol.TICK_HZ`，装配各 service，开 UDP，挂 `Net` 信号；
  `World`（`world.gd`）是场景里的 `Node3D` 子节点，一次 `_physics_process` = 一个世界 tick（20Hz 广播）。
- 客户端入口 `client/scenes/main.tscn` → `scripts/main.gd`：建 `WorldRoot`/`CameraRig`/`NetworkClient`，
  连 `Net` 信号；实体 id → `EntityView` 存在 `entities` 字典里；相机独立于角色节点跟随本地实体。
- 客户端→服务端流程：连接（auth payload）→ `s2c_login_result` → `c2s_list_characters` → `s2c_character_list`
  → `c2s_create_character`/`c2s_select_character` → `s2c_enter_world` + 逐个 `s2c_spawn_entity` → 20Hz `s2c_world_state`。

## godot-sqlite 注意事项（易踩坑）

- `query_result` 按值返回（跨查询安全）；`query_result_by_reference` 会被下一次查询清空——遍历用前者。
- **只能绑定值**，表名/列名不能绑定：本仓库只在源码里写死标识符，绝不拼接外部输入。
- `create_table(name, {列: {data_type, primary_key/auto_increment/not_null/unique/default/foreign_key}})`；
  外键写法 `"foreign_key": "accounts.id"`，需 `db.foreign_keys = true`；`auto_increment` 只在它是**唯一**主键时生效。
- `default` 的字符串常量要内嵌单引号（`"'world'"`、空串 `"''"`），否则报误导性的语法错误。
- 本项目 `verbosity_level = 0`（安静）——**失败不会自己打印**，所以 `create_table` 的返回值必须显式检查。
- **非线程安全**：所有 DB 访问只在主线程（auth 回调、physics tick、Timer 都在主线程）。
- `create_table` 只在表不存在时执行 → **没有迁移机制**：改 schema 要么写迁移，要么删库重建（见下）。
- 本机 DB 实际位置：`%APPDATA%\Godot\app_userdata\MMORPG Server\mmorpg_server.db`（删除即重置所有账号/角色）。
- 无加密（SQLCipher 需另找分支）。

## 专用服务器与部署

- 预设：`server/export_presets.cfg`，`dedicated_server=true`（自动带 `dedicated_server` feature tag + 强制 headless）。
  Linux 库由 GDExtension 导出机制自动放到二进制旁；`include_filter` 只固定 **release** 那份，别把 debug 库也打进 PCK。
- 启动判定：`DisplayServer.get_name() == "headless"` 或 `OS.get_cmdline_user_args()` 含 `--server`。
- 公网只需放行 **UDP 7000**（ENet 仅 UDP，开 TCP 无效）；客户端默认连 `127.0.0.1`，用 `--host` 覆盖。
- 写文件一律 `user://`（导出后 `res://` 只读）；PCK 必须是可写 DB 之外。
- Linux 常驻：systemd + `application/run/flush_stdout_on_print=true`（journald 收日志）；弹性伸缩再用 Docker。
- 目标机 `ldd --version`：glibc < 2.35 时插件二进制可能崩溃，需自行重编译。

## 版本控制（Godot 工程约定）

- 提交：`project.godot`、`*.tscn`、`*.gd`、`*.uid`、`*.import`、`export_presets.cfg`，以及 `server/addons/godot-sqlite/**`。
- 忽略：`.godot/`、`build/`、`export/`、`*.pck`、`*.zip`、`client/shared`、`server/shared`、`*.db*`。
- 纹理/音频必须连同 `.import` 一起提交；数据库、密码、令牌一律不提交。

## 常用命令（注意顺序）

```powershell
# 1) 让 Godot 可被找到（示例路径，按本机改；脚本只读 $env:GODOT，不要写死进脚本）
$env:GODOT = "D:\code\game\godot_engine\Godot_v4.7.1-stable_win64_console.exe"

# 2) 联接共享契约：每个 worktree 必做一次，幂等
powershell -File scripts/link_shared.ps1

# 3) 首次导入：必须先做，否则 class_name 未注册、headless 直接报解析错误
& $env:GODOT --headless --path server --import
& $env:GODOT --headless --path client --import
```

> 本仓库文本文件是 **UTF-8 无 BOM + LF**（含中文注释）。用 PowerShell 5.1 的
> `Get-Content`/`Select-String` 读会按 GBK 解码，显示成乱码并**吞掉换行**造成行数偏少——
> 那是控制台问题不是文件损坏，别去"修"编码（要读就加 `-Encoding UTF8` 或用 `read` 工具）。

- 解析检查（没有独立 lint/typecheck，headless 启动就会报解析/加载错误）：
  - 服务端：`& $env:GODOT --headless --path server --quit-after 3 -- --server`
  - 客户端：`& $env:GODOT --headless --path client --quit-after 5`
- 起服务端：`& $env:GODOT --headless --path server -- --server`（日志里确认 `listening on UDP 7000 ... tick 20Hz`）。
- 自动化联调（无头 bot，退出码 0 = 全通过；**客户端唯一自动化验证手段**）：
  `& $env:GODOT --headless --path client -- --bot --host 127.0.0.1 [--bot-user NAME] [--bot-require-peer] [--bot-check-respawn]`
  - `--bot-require-peer`：要求“看到另一个玩家移动”→ 必须**并发**跑两个 bot。
  - `--bot-check-respawn`：等被击杀的怪重生（约多花 10s）。
  - bot 会先试登录、被拒后再注册，所以 `--bot-user` 用固定名可复现“账号跨重启仍在”。
- 契约一致性：`powershell -File scripts/link_shared.ps1 -Verify`
  （校验：两端 `shared` 联接正确 + `Net` autoload 路径一致 + `@rpc` 不外泄 + 与 `Protocol.RPC_NAMES` 完全一致）。
- 导出：`powershell -File scripts/export.ps1 -Target all`
  （Godot **不会**创建 `build/` 目录且它被 gitignore，裸 `--export-release` 在干净克隆上会失败；脚本已处理并校验产物）。
- 改完代码的推荐顺序：`-Verify` → 两工程解析检查 → 起服务端 → bot 自检（必要时 `--bot-check-respawn`）→ 导出。

## 安全边界（务必知晓）

- **凭据明文过线**：高层多人是**未加密 ENet/UDP**，密码随 auth payload 明文传输（服务端只存哈希）。
  **仅限 LAN / 可信网络**；公网前必须改质询-应答或加密传输。
- 登录限流：`AuthService` 按账号做失败退避（前 3 次免费，之后线性 backoff，表有上限），**无 IP 级限制**。
- “服务端权威”只保证玩法状态不被伪造，**不提供传输机密性**。

## 参考链接

- 本仓库：`docs/roadmap.md`（未来展望/技术债）、`docs/research/godot-mmorpg-network-and-deployment.md`（联网/部署事实）、
  `docs/research/godot-mmorpg-mvp-assets.md`（搭建提示词模板 + 验证记录）
- 服务端导出：https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html
- 高层多人：https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html
- godot-sqlite：https://github.com/2shady4u/godot-sqlite
- Nakama Godot 4 客户端（后续元系统）：https://heroiclabs.com/docs/nakama/client-libraries/godot/
