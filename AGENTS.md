# AGENTS.md

目标：基于 **Godot 4** 的类《魔兽世界》MMORPG（大型多人在线、服务端权威）。
当前状态：MVP 骨架 + **P0 系统已落地**——WB0 契约冻结/热点拆分 → Wave 1 数据迁移·备份、AoI/带宽、客户端预测、
安全硬化、CI/单测 → Wave 2 技能/战斗、物品/背包、多区域/实例。base tag：`contract-v2` → `wave1` → `wave2`。
后续规划见 `docs/roadmap.md`；测试说明见 `tests/README.md`。

> 本文只写**踩过坑、读多个文件才 infer 得出来**的东西。通用 Godot/GDScript 常识不写。

## 版本锁定（三者必须同时匹配）

- 引擎：**Godot 4.7.1-stable**（`Godot_v4.7.1-stable_win64_console.exe` / GUI 版同目录，本机
  `D:\code\game\godot_engine\`，**未加入 PATH**；脚本一律读 `$env:GODOT`，不要把绝对路径写进被提交的脚本）。
  - 验证：`& $env:GODOT --version` → `4.7.1.stable.official.a13da4feb`。
  - **本 agent shell 默认没有 `$env:GODOT`**：临时命令直接 `& 'D:\...\Godot_v4.7.1-stable_win64_console.exe' ...`；
    被提交的脚本/CI 只认 `$env:GODOT`（`ci.ps1 -Godot <path>` 可覆盖）。
- 引擎 ↔ **导出模板** ↔ `godot-sqlite` 三者必须一致，错配会静默破坏导出/插件。
  模板在 `%APPDATA%\Godot\export_templates\4.7.1.stable\`（缺 `linux_release.x86_64` 服务端导出必失败）；
  `godot-sqlite` v4.9，`compatibility_minimum = "4.7"`。
- 跑 GUI 客户端用非 console 版 `Godot_v4.7.1-stable_win64.exe`（少一个控制台窗口）；headless 用 console 版。

## 命令（顺序重要）

```powershell
$env:GODOT = "D:\code\game\godot_engine\Godot_v4.7.1-stable_win64_console.exe"   # 每个新 shell 都要设

# 0) 共享契约联接：每个 checkout/worktree 必做一次（幂等）；-Verify 是门禁
powershell -File scripts/link_shared.ps1          # 首次
powershell -File scripts/link_shared.ps1 -Verify  # 校验：联接 + Net autoload + @rpc 不外泄 + RPC_NAMES 对账

# 1) 首次/改动新脚本后必须 import，否则 class_name 未注册、headless 直接解析报错
& $env:GODOT --headless --path server --import
& $env:GODOT --headless --path client --import
```

- 解析检查（**没有独立 lint/typecheck**；headless 启动即报解析/加载错）：
  - 服务端：`& $env:GODOT --headless --path server --quit-after 3 -- --server`
  - 客户端：`& $env:GODOT --headless --path client --quit-after 5`
- 起服务端：`& $env:GODOT --headless --path server -- --server [--port N] [--db <path>] [--no-mobs] [--aoi-stats]`
  - `--db` 是**相对路径时按“项目目录”解析**（`--path server` 下 `.local/x.db` → `<repo>/server/.local/x.db`），
    不是进程 CWD。默认不传 `--db` 用 `user://mmorpg_server.db`。
  - 日志见到 `listening on UDP <port> ... tick 20Hz` 才算起来。
- 无头 bot（退出码 0 = 全通过；**客户端唯一自动化手段**）：
  `& $env:GODOT --headless --path client -- --bot --host 127.0.0.1 [--port N] [--bot-user NAME]
   [--bot-require-peer] [--bot-check-respawn] [--bot-multiplayer] [--bot-seconds S] [--net-latency MS] [--zone-check N]`
  - `--port` 必须与服务端一致（默认 7000）。
  - `--bot-require-peer`：要求“看到另一名玩家移动”→ **必须并发跑两个 bot**（先后跑测不出）。
  - `--bot-check-respawn`：等怪重生，多花约 10s。
  - `--net-latency MS`：只延迟“权威路径”（ack+快照），本地预测仍即时 → 用来验收预测（S-N-1）。
  - `--zone-check N`（1..`ZONE_MAX_CHANNELS-1`）：`bot_check_zones.gd` 的**开关**，不带它该模块不产出任何 CHECK；
    区域隔离的两个 bot 门禁：`--bot-multiplayer --bot-user zone_a --zone-check 1` / `... zone_b --zone-check 2`。
  - bot 先试登录、被拒后再注册；`--bot-user` 固定名可复现“账号跨重启仍在”。
- 契约后加/改 RPC 会同时影响两端；跑 `-Verify` 前先三处同步（见“架构决策”）。
- 单元测试：**必须用仓库绝对路径**触发 `--script`，相对路径会解析成 `res://tests/...` 而失败：
  `& $env:GODOT --headless --path server --script "<repo-root>\tests\run_tests.gd"`
  （跑在 server 工程下；runner 自动 glob `tests/*_test.gd`，按 `[unit] RESULT PASS` 判定。）
- 一键 CI（`-Verify`→导入→双工程解析→单测→bot→导出）：
  `powershell -File scripts/ci.ps1 -Godot $env:GODOT`（`-SkipExport` 走快循环；默认端口 7099）。
  - 干净克隆**必须**用它导出：Godot 不会建 `build/`（且被 gitignore），裸 `--export-release` 会失败。
  - 预设名固定 `Linux Server` / `Windows Client`；产物 `server/build/mmorpg_server.x86_64`、`client/build/mmorpg_client.exe`。
  - `ci.ps1` 内部用**非 console 版**引擎 `Start-Process -Wait`，因为 console 版在重定向输出下会返回 -1/提前返回。
- 启动/监控服务端（工具）：`powershell -File scripts/start_server.ps1 -Action start|stop|restart|status|logs [-Follow] [-Port N] [-Database <path>]`
  - PID/日志在 `server/.local/{server.pid,server.out.log,server.err.log}`；`-Action status -Follow` 是轻量监控（每 `-Interval` 秒刷）。
  - 参数名是 `-Database`（不是 `-Db`）：`-Db` 与 PowerShell 内置 `-Debug` 别名冲突会直接报错。
  - 该工具用**非 console 引擎**跑 detached 进程（console 版是 launcher，redirect 下不可靠）。
- 启动客户端（GUI，供登录）：`powershell -File scripts/start_client.ps1 -User NAME -Password PW [-Character NAME] [-Register] [-Count N] [-ServerHost H] [-Port N]`；
  `-Action stop` 关闭上次启动的窗口。客户端新增 `--login-user/--login-pass/--login-char/--login-register`（自动登录；给 `--login-char` 会建/选角色并进世界），
  实现见 `client/scripts/main.gd` + `LoginUI.set_credentials`。`-Count>1` 时用户名/角色名自动加数字后缀。
  地址参数名是 `-ServerHost`（`-Host` 会撞 PowerShell 内置的 `$Host`）。
- 图形化启动器（**配置可视化，无需命令行参数**）：`powershell -File scripts/launcher.ps1`
  - WinForms 窗口：引擎路径/端口/DB/`--no-mobs`/`--aoi-stats`/登录账号密码角色/窗口数都能在界面改，
    点“保存配置”写入 `.local/launcher.json`（gitignore），下次自动载入；启动/停止复用上面两个工具。
  - `-SelfTest` 校验配置读写；`-SmokeTest` 真实构建窗口后自动关闭（CI/agent 用，不弹窗等待）。
  - 打包成 exe：`powershell -File scripts/build_launcher_exe.ps1` → `build/MMORPG-Launcher.exe`（约 5KB 原生 C# 包装器，双击运行；
    放在仓库内即可，会转发参数并透传退出码；`build/` 已 gitignore，不提交）。
  - ⚠️ `scripts/launcher.ps1` 必须存为 **UTF-8 带 BOM**：PS 5.1 读无 BOM 脚本会按 GBK 解码，中文界面乱码
    （用 edit 工具改过该文件后要重新补 BOM；`build_launcher_exe.ps1` 也依赖被启动的 ps1，但 exe 本身编码无关）。
- 改动后的推荐门禁：`-Verify` → 双工程解析 → 单测 → 起服务端 → `--bot`（网络/战斗另加 `--bot-require-peer` /
  `--bot-check-respawn`）→ 需要产物再加 `ci.ps1`。

## 目录与文件所有权

- 双工程，各有独立 `project.godot`（**不是**单一工程）：
  - `server/`：`main.gd`（**纯装配**）、`bootstrap.gd`（启动钩子：迁移+备份+数据表校验）、`migrations.gd`（迁移框架+seq 预约）、
    `db.gd`（连接/查询封装）、`auth.gd`、`rate_limit.gd`、`persistence.gd`、`persistence_inventory.gd`、
    `intent_router.gd`（c2s 校验+限流+注册表）、`session_flow.gd`、`world.gd`（facade）、
    `world_state.gd`/`world_movement.gd`/`world_mobs.gd`/`world_sync.gd`（世界子系统）、
    `spatial_grid.gd`/`broadcast_scheduler.gd`（AoI/带宽）、`combat.gd`/`skills.gd`（技能）、
    `inventory.gd`（背包）、`zones.gd`/`instance.gd`（区域/实例）。
  - `client/`：`main.gd`（**纯装配**）、`network_client.gd`（门面）、`net_transport.gd`、`net_auth.gd`、`net_input.gd`、
    `prediction.gd`（本地预测+和解）、`world_view.gd`、`input_controller.gd`、`ui_flow.gd`、
    `entity_view.gd`/`player.gd`/`mob.gd`、`ui_login.gd`/`hud.gd`/`ui_skillbar.gd`/`ui_inventory.gd`、
    `world_visuals.gd`、`bot.gd`（runner）、`bot_checks/bot_check*.gd`（运行时 glob 自动注册）。
- 共享契约在根 `shared/`，用 **Windows 目录联接**映射为 `client/shared`、`server/shared`：
  - `scripts/link_shared.ps1` 幂等创建，**不提交**；**每个 worktree 都要重跑**，否则 `res://shared/...` 不存在。
  - `client/shared/x.gd` 与 `server/shared/x.gd` 是**同一文件**；改哪边都是改根 `shared/`，别当副本。
  - `shared/sim/movement.gd`（`Movement`：两端共用的移动结算纯函数）、`shared/sim/formulas.gd`（`Formulas`：战斗公式）、
    `shared/data/data_tables.gd`（`DataTables`：glob 加载 + 校验）、`shared/data/tables/*.json`（一 WB 一文件，**无共享清单**）、
    `shared/model/{character,entity_state,item,inventory}.gd`、`shared/net/{protocol,net_rpc,auth_handshake}.gd`。
- `server/addons/godot-sqlite/`（约 300MB 多平台二进制）**必须提交**；客户端工程**没有** `addons/`，不要装。

## 架构决策（已固化）

- GDScript（不混 C#）；高层多人 **ENet/UDP**，默认端口 **7000**，世界 tick **20Hz**；**服务端权威**。
- **所有 `@rpc` 只在 `shared/net/net_rpc.gd`**，两端 autoload 同名 `Net`（NodePath 恒 `/root/Net`）。
  改契约是**三处同步铁律**：`net_rpc.gd`（函数+转发信号）＋ `Protocol.RPC_NAMES` ＋ 两端信号处理；
  `-Verify` 因 `RPC_NAMES` 不一致而失败。当前 **22** 条（含 `s2c_input_ack`/`s2c_inventory`/`s2c_zone_changed`/
  `s2c_cast_started`/`s2c_cast_interrupted`）。
- 客户端只发**输入/意图**（`c2s_*` 一律 `rpc_id(1,...)`），服务端只发权威状态（`s2c_*`）；**绝不采信**客户端上报的
  位置/伤害/HP。客户端做**本地预测**（`prediction.gd`）只为手感，位置仍以服务端为准（用 `s2c_input_ack` 和解）。
- 鉴权走 `SceneMultiplayer.auth_callback`（凭据在 auth payload 的 JSON 字节里，**不**走裸 RPC）：客户端 `auth_callback`
  也要非空，否则 `peer_authenticating` 不触发；失败只许 `disconnect_peer`，成功才 `complete_auth`。
- **`Protocol` 只留 id/枚举/边界**（S-D-3）：tick、`TICK_DT`、枚举、id 保留段、长度边界、schema 版本在 `Protocol`；
  **玩法数值在 `shared/data/tables/*.json`**（abilities/classes/items/mobs/player_base/world 已建表）。
  ⚠️ 遗留常量（`MOVE_SPEED`/`MELEE_*`/`MOB_*`/`PLAYER_MAX_HP`…）**仍在 `Protocol` 且仍被服务端直接使用**，
  S-D-3 迁移未全部完成——别假设它们已经“入表”。
- 保留 id 段：怪物 `MOB_ID_BASE=1000000+i`；实例 `INSTANCE_ID_BASE=2000000`；区域 id 见 `Protocol.ZoneId`。
- 客户端**不用 InputMap**（`client/project.godot` 无 `[input]`）：键位直接读 `Input.is_physical_key_pressed(KEY_W/A/S/D)`
  与 `_unhandled_input`（Esc/Space/1/Tab）。

## 世界流转（快速定位）

- 服务端入口 `server/scenes/main.tscn` → `scripts/main.gd`：`_ready` 设 `Engine.physics_ticks_per_second = Protocol.TICK_HZ`，
  装配 service + `IntentRouter` + `SessionFlow`，跑 `Bootstrap`（迁移/数据表校验）后开 UDP；`World` 是场景 `Node3D`，
  一次 `_physics_process` = 一个 20Hz tick，委托 `WorldState`/`WorldMovement`/`WorldMobs`/`WorldSync`。
- 客户端入口 `client/scenes/main.tscn` → `scripts/main.gd`：建 `WorldRoot`/`CameraRig`/`NetworkClient`/`WorldView`/
  `InputController`/`UIFlow` 并连 `Net` 信号；相机独立于角色跟随本地实体。
- 流程：连接（auth）→ `s2c_login_result` → `c2s_list_characters` → `s2c_character_list` →
  `c2s_create_character`/`c2s_select_character` → `s2c_enter_world` + `s2c_spawn_entity` → 20Hz `s2c_world_state`。
- **非有限输入防护是安全底线**：`WorldState.set_input` 用 `Movement.is_input_finite` 拒 INF/NaN（否则污染权威位置并进广播/存档）。
  WB6 预测端也必须同样处理。

## 数据 / 持久化 / 迁移

- 存储 `godot-sqlite`（**非线程安全**：所有 DB 访问只在主线程——auth 回调、physics tick、Timer 都在主线程）。
  密码只存 `SHA-256(salt||password)`（每账号随机 salt）。
- **改 schema 必须写迁移**：`server/scripts/migrations.gd` 维护 `schema_version` 表并按 seq 升序执行；
  `0001` baseline = 旧 schema 快照（幂等，旧库也能升）。**禁止删库重建了事**。当前版本 100（`0100_wb3_inventory`）。
- **seq 区段预约**（并行 WB 各占一段，否则撞 seq）：`0001` baseline、`0002–0099` WB1、`0100–0199` WB3、
  `0200–0299` WB2、`0300–0399` WB5、`0400+` 其他。迁移列表**只追加、不重排**。
- `Bootstrap` 启动时跑迁移+数据表校验，失败**拒绝启动**；迁移前会做一次 pre-migration 备份到 `.local/backups/`。
- 数据表按目录 glob（`DataTables.load_all`/`validate`），加表只加 `shared/data/tables/*.json`，不动共享清单。
- 备份/恢复脚本：`scripts/backup.ps1` / `scripts/restore.ps1`。

### godot-sqlite 易踩坑

- `query_result` 按值返回（跨查询安全）；`query_result_by_reference` 会被下次查询清空——遍历用前者。
- **只能绑定值**，表名/列名不能绑定；本仓库只在源码写死标识符，绝不拼接外部输入。
- `create_table(name, {列: {data_type, primary_key/auto_increment/not_null/unique/default/foreign_key}})`；
  外键 `"foreign_key": "accounts.id"` 需 `db.foreign_keys = true`；`auto_increment` 只在它是**唯一**主键时生效。
- `default` 字符串要内嵌单引号（`"'world'"`、空串 `"''"`），否则报误导性语法错。
- `verbosity_level = 0`（安静）→ **失败不会自己打印**，`create_table` 返回值必须显式检查。
- 复合主键/唯一约束 godot-sqlite 的 `create_table` 表达不了时，迁移里直接跑 DDL（见 `0100_wb3_inventory`）。

## 安全边界

- 登录是 **v2 质询-应答**（`shared/net/auth_handshake.gd`）：明文密码**不过线**，客户端只发 `SHA-256(salt||password)`
  （注册）或 `SHA-256(nonce||verifier)`（登录）。旧 v1 明文客户端**故意不支持**（协议版本 2）。
  - 想看真实上线的字节：客户端设环境变量 `MMORPG_AUTH_TRACE=1` 会打印 auth payload（用于自证无明文）。
  - **仍然没有传输机密性**（ENet/UDP 未加密）：注册 verifier 被抓到即“pass-the-hash”；公网前需再加传输加密。
- 限流**两个独立维度**，缺一不可：账号维度（`AuthService` 失败退避）＋ 来源维度（`RateLimitService`：按客户来源
  IP 的失败封锁 + token bucket）。`IntentRouter` 在进 handler 前对所有 c2s 做**结构校验 + 频率上限**
  （每 sender 每动作的 rate/burst 见 `RPC_RATES`）；语义校验仍留在各自 service。
- “服务端权威”只保证玩法状态不可伪造，**不提供传输机密性**。

## 测试

- 单测：`tests/*_test.gd`（`extends RefCounted`，暴露 `cases() -> Array[Dictionary]`，runner glob 自动注册）；
  覆盖 `Movement` 边界钳制/AABB 推出/非有限拒绝、`Formulas`、`CombatService` 冷却/射程/施法边界、`WorldState` 分片。
- bot 断言：`client/scripts/bot_checks/bot_check_<域>.gd`（继承 `BotCheck`，`evaluate()` 返回带
  `{order,name,ok,required,detail}` 的数组）。**输出契约**：`[bot] CHECK <name>=OK|FAIL|N/A` … 结尾
  `[bot] RESULT PASS`，`get_tree().quit(0|1)`——CI 依赖它，别改格式/退出码。
- 现有域：session / movement / combat / inventory / zones。

## Agent Manager（并行 worktree）

- setup/run 脚本是**主仓 `.kilo/` 下的项目文件**（Windows：`.kilo/setup-script.ps1`、`.kilo/run-script.ps1`），
  **不要**放进生成的 `.kilo/worktrees/<name>/`。
- setup（5 分钟上限）：只做 `link_shared.ps1` + 建 `.local/`。首次 `--import`（300MB 插件）放 run script，避免超时。
- run：按 `WORKTREE_PATH` 派生端口 7100–7999 + `--db .local/mmorpg_server.db` 启动服务端；需用户 shell 已设 `$env:GODOT`。
- 每个 worktree 复制约 300MB 插件；并发别开太多，合并完可从 Agent Manager 移除 worktree（**分支/tag 保留**）。
- **禁止 `git stash`/autostash**：stash 跨 worktree 共享，会污染。冲突在 worktree 内 `merge`/`rebase` 主干后解决。
- ⚠️ Agent Manager 会把 `.kilo/setup-script.*` 写进 `.git/info/exclude`；要让 setup 脚本**入库**，需在其中加
  `!.kilo/setup-script.ps1`（本仓库已加）。

## 已知坑与经验（本仓库实测）

- **单元 runner 必须绝对路径**：`--script tests/run_tests.gd` 会失败（解析成 `res://tests/...`）；用
  `--script "<repo-root>\tests\run_tests.gd"`。
- **复跑 bot 要用干净 DB**：怪在多次击杀/重生后会漂到玩家身边，bot 只需移动 <1m 就进近战 → `movement`（要求位移 ≥1m）
  会 FAIL。换 `--db .local/<new>.db` 重跑即恢复。
- **`s2c_*` 是广播**：断言里按 `caster_id == self_id` 过滤（bot 的 cast 计数曾因此把另一个 bot 的施法算进自己）。
  bot 断言要**事件驱动**（观测到结果再发下一步），别用 wall-clock 重发，否则并发/卡顿时会 flaky。
- **`--db` 相对路径按项目目录解析**（`server/.local/...`），不是 CWD。
- **本机文本是 UTF-8 无 BOM + LF**：PowerShell 5.1 的 `Get-Content`/`Select-String` 会用 GBK 解码成乱码并吞换行；
  那是控制台问题，不是文件损坏——要读就加 `-Encoding UTF8` 或用 `read` 工具。git 的 `LF will be replaced by CRLF`
  只是 `autocrlf` 警告，照常提交。
- **`Protocol.MAX_CLIENTS=16`**：50+ bot 压测会撞上限（WB4 验收尚未放开）。
- 客户端预测的 `--net-latency` 是**本地延迟注入**（延后应用权威消息），不是真实网络损伤注入。

## 版本控制（Godot 工程约定）

- 提交：`project.godot`、`*.tscn`、`*.gd`、`*.uid`（新脚本 import 后生成，**要提交**）、`*.import`、
  `export_presets.cfg`、`server/addons/godot-sqlite/**`。
- 忽略：`.godot/`、`build/`、`export/`、`*.pck`、`*.zip`、`client/shared`、`server/shared`、`*.db*`、`.local/`、
  `.kilo/worktrees/**`。
- 纹理/音频必须连 `.import` 一起提交；数据库、密码、令牌、`.env` 一律不提交。

## 专用服务器与部署

- 预设 `server/export_presets.cfg`，`dedicated_server=true`（自动带 feature tag + 强制 headless）；`include_filter`
  只放 **release** 库，别把 debug 打进 PCK。
- 公网只放行 **UDP 7000**（ENet 仅 UDP，开 TCP 无效）；客户端默认连 `127.0.0.1`，`--host` 覆盖。
- 写文件一律 `user://`（导出后 `res://` 只读）；DB 必须在 PCK 之外可写。
- Linux 常驻：systemd + `application/run/flush_stdout_on_print=true`；目标机 `ldd --version` 若 glibc < 2.35 插件可能崩。

## 参考

- `docs/roadmap.md`（系统编号/优先级/技术债）、`docs/research/godot-mmorpg-network-and-deployment.md`（联网/部署事实）、
  `docs/research/godot-mmorpg-mvp-assets.md`（搭建提示词 + 验证记录）、`tests/README.md`（测试用法）。
- 服务端导出：<https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html>
- 高层多人：<https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html>
- godot-sqlite：<https://github.com/2shady4u/godot-sqlite>
