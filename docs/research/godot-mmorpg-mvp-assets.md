# Godot MMORPG MVP — 可复用搭建提示词与参考来源

本文归档本仓库 MVP 的实现方式，并提供**可直接复用的提示词模板**。它是对
`docs/research/godot-mmorpg-network-and-deployment.md`（联网与部署事实核查）的补充：
那一篇讲“事实/坑”，本篇讲“怎么一步步搭出来”。

> 状态：MVP 已按本文落地并验证（见「五、本次实现的实际验证记录」）。
> 当前实现状态/命令看根 `AGENTS.md`，后续规划看 `docs/roadmap.md`。

> 版本锚点：Godot **4.7.1-stable**，`godot-sqlite` **v4.9**（`compatibility_minimum = "4.7"`）。
> 三者（引擎 / 导出模板 / GDExtension）必须同版本族，否则导出或插件加载会静默失败。

## 一、参考来源

| 来源 | 用途 | 链接 |
|---|---|---|
| Godot 官方 · High-level multiplayer | RPC 契约、`@rpc` 参数、auth 流程、服务端权威设计 | https://docs.godotengine.org/en/4.7/tutorials/networking/high_level_multiplayer.html |
| Godot 官方 · SceneMultiplayer | `auth_callback` / `send_auth` / `complete_auth` / `peer_authenticating` | https://docs.godotengine.org/en/4.7/classes/class_scenemultiplayer.html |
| Godot 官方 · ENetMultiplayerPeer | `create_server` / `create_client`，UDP-only | https://docs.godotengine.org/en/4.7/classes/class_enetmultiplayerpeer.html |
| Godot 官方 · 专用服务器导出 | `Export as dedicated server`、`dedicated_server` 特性标签 | https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html |
| godot-sqlite v4.9 | 数据库 API、`query_result` 语义、`create_table` 字典格式 | https://github.com/2shady4u/godot-sqlite |
| godot-sqlite demo | `foreign_key` 写法（`"hobbies.id"`）、`foreign_keys = true` | https://github.com/2shady4u/godot-sqlite/blob/master/demo/database.gd |
| WithinAmnesia/ARPG | 2D ARPG 模板（MIT）：**仅作结构参考**，非 3D MMO 起点 | https://github.com/WithinAmnesia/ARPG |
| Nakama Godot 4 客户端 | 后续元系统（账号/好友/公会）替代方案，本 MVP 未使用 | https://heroiclabs.com/docs/nakama/client-libraries/godot/ |

**结论（避免踩空）**：不存在可直接拿来用的 Godot 4 · 3D MMO 开源起点。必须用引擎原语自建。

## 二、本仓库实际落地产物（对照提示词）

| 层 | 文件 |
|---|---|
| 协议常量 | `shared/net/protocol.gd` |
| RPC 契约（唯一 `@rpc` 处） | `shared/net/net_rpc.gd`（两端 autoload `Net`，NodePath `/root/Net`） |
| DTO | `shared/model/entity_state.gd`、`shared/model/character.gd` |
| 联接脚本 | `scripts/link_shared.ps1`（`-Verify` 校验：联接 + `Net` autoload 一致 + `@rpc` 不外泄 + 与 `Protocol.RPC_NAMES` 一致） |
| 导出脚本 | `scripts/export.ps1`（先建 `build/`，再导出并校验产物） |
| 服务端 | `server/scripts/{main,db,auth,world,combat,persistence}.gd` |
| 客户端 | `client/scripts/{main,network_client,entity_view,player,mob,camera_rig,ui_login,hud,world_visuals,bot}.gd` |
| 场景 | `server/scenes/main.tscn`；`client/scenes/{main,player,mob}.tscn` |

---

## 三、提示词模板（每步可直接复用）

每个模板统一给出：**前置** / **产出文件** / **验证命令**。
验证命令里的 `$GODOT` 指 Godot **控制台版**可执行文件，请从环境变量取，不要写死路径：

```powershell
$env:GODOT = "<你的 Godot 控制台版 exe>"
```

### 提示词 1 · 生成 `shared/` 协议与 DTO

> 在 `shared/` 下建立客户端与服务端的**唯一契约**：
> 1. `shared/net/protocol.gd`：常量（端口 7000、tick 20Hz、协议版本、`MOVE_SPEED`、
>    近战射程/伤害/冷却、怪物数值、`MOB_ID_BASE`、地图尺寸与掩体坐标、
>    用户名/密码/角色名长度边界）与枚举（`EntityKind`、`ClassId`、`Buttons`、`Msg`）；
>    再提供 `auth_payload()` 把 `{user, pass, register, protocol}` 序列化为 UTF-8 JSON 字节。
>    用 `class_name Protocol`。**长度边界这类校验规则也要放这里**，客户端预检与服务端校验共用，避免两端各写一份。
>    另用 `const RPC_NAMES: Array[String]` 列出全部 RPC 名，供 `-Verify` 与 `net_rpc.gd` 对账。
> 2. `shared/net/net_rpc.gd`：**全工程唯一出现 `@rpc` 的文件**。逐字实现 13 个函数
>    （5 个 `c2s_*`、8 个 `s2c_*`），`c2s_*` 用 `@rpc("any_peer", "call_remote", "unreliable_ordered"|"reliable")`，
>    `s2c_*` 用 `@rpc("authority", "call_remote", ...)`；函数体**只发信号**，不含玩法逻辑；
>    每个 `c2s_*` 信号必须携带 `multiplayer.get_remote_sender_id()` 作为 `sender`（服务端身份以它为准）。
> 3. `shared/model/entity_state.gd`、`shared/model/character.gd`：纯数据（`extends RefCounted`），
>    各有 `to_dict()`（`character.gd` 用 `from_row()` 读数据库行）。
> 4. `scripts/link_shared.ps1`：用 `New-Item -ItemType Junction` 幂等创建 `client/shared`、`server/shared`；
>    `-Verify` 模式检查四件事：联接目标正确、两端 `Net` autoload 路径一致、
>    `client|server/(scripts|scenes)` 下不存在 `@rpc`、`net_rpc.gd` 声明的函数与 `Protocol.RPC_NAMES` 完全一致。

**前置**：无。
**产出**：`shared/net/*.gd`、`shared/model/*.gd`、`scripts/link_shared.ps1`。
**验证**：
```powershell
powershell -File scripts/link_shared.ps1 -Verify
$GODOT --headless --path server --import      # 首次必须 import，才会注册 class_name
$GODOT --headless --path client --import
```

### 提示词 2 · 生成服务端权威移动与世界状态同步

> 在 `server/` 实现世界层，**绝不读取客户端上报的位置/血量/伤害**：
> - `scripts/world.gd`（`extends Node3D`）：`_physics_process` 即固定 tick（服务端启动时把
>   `Engine.physics_ticks_per_second` 设成 `Protocol.TICK_HZ`，`project.godot` 里的 20 只是编辑器默认值）；
>   `entities: id -> EntityState`、`inputs: peer_id -> {seq, move, yaw, buttons}`、`sessions`、`cooldowns`、`respawn_at`。
> - 移动：`dir = Vector3(move.x, 0, -move.y).normalized().rotated(UP, yaw)`，乘 `MOVE_SPEED * delta`；
>   再做世界边界钳制 + AABB 最小平移推出（掩体）。
> - **先拒绝非有限输入**：`move.is_finite()` / `is_finite(yaw)` 不过就直接 return。
>   `Vector3.normalized()` 自带有限性兜底（返回零向量），但 `rotated(UP, INF)` 会经 `cos/sin` 产出 NaN，
>   NaN 位置的比较恒为 false，边界钳制与掩体推出都修不回来，还会被广播并写进存档。
> - 广播：每 tick `Net.s2c_world_state.rpc(tick, [每实体 to_net_dict()])`（仅 id/pos/yaw/hp/alive/target_id）。
> - 加入世界：`Net.s2c_enter_world.rpc_id(peer, ...)` → 给该 peer 逐个 `s2c_spawn_entity` → 给其他人广播新玩家 spawn。
> - 断线：`s2c_despawn_entity.rpc(id)`，并落库。
> - 客户端输入的 `seq` 做单调校验（防乱序覆盖）。
> - 怪物 AI、死亡/复活（玩家 5s、怪 8s，重生时 `s2c_spawn_entity` + `s2c_hp_update`）。

**前置**：提示词 1。
**产出**：`server/scripts/world.gd`。
**验证**：
```powershell
$GODOT --headless --path server --quit-after 3 -- --server   # 打印 listening on UDP 7000
```

### 提示词 3 · 生成客户端 3D 控制器 + 第三人称相机 + 插值

> 在 `client/` 实现**不做本地模拟**的渲染端：
> - `scripts/entity_view.gd`（`extends CharacterBody3D`）：持有 `entity_id/kind/name/hp/max_hp/alive/targeted`；
>   `_process` 用 `global_position.lerp(target_pos, clamp(delta * Protocol.INTERP_SPEED, 0, 1))` 与
>   `lerp_angle(rotation.y, target_yaw, ...)` 插值；`apply_state()` 只覆盖 dict 中**实际存在**的键
>   （否则 `s2c_hp_update` 的局部更新会把死人“复活”）。
> - `scripts/player.gd` / `scripts/mob.gd` 继承 `EntityView`；`scenes/player.tscn`（胶囊）、
>   `scenes/mob.tscn`（方块），根节点带 `NameTag: Label3D`（`billboard=1`），碰撞体供鼠标拾取。
> - `scripts/camera_rig.gd`：独立节点（**不要挂在角色下**），`SpringArm3D` + `Camera3D`；
>   每帧跟随本地实体位置，yaw/pitch 由本地鼠标输入驱动。
> - 输入：`Input.is_physical_key_pressed(KEY_W/A/S/D)` 组成 `Vector2`，20Hz 上传
>   `Net.c2s_input.rpc_id(1, seq, move, yaw, 0)`；鼠标左键从相机发射 `intersect_ray` 拾取带
>   `entity_id` meta 的节点作为目标。
> - 静态地图（地面/掩体）由 `scripts/world_visuals.gd` 用 `Protocol` 的坐标构建，保证与服务器一致。
> - HUD：自身 HP、目标 HP、操作提示。

**前置**：提示词 1（`Protocol`）；2 已定义实体状态字段。
**产出**：`client/scripts/{entity_view,player,mob,camera_rig,world_visuals,hud,main}.gd`、`client/scenes/{player,mob}.tscn`。
**验证**：`$GODOT --headless --path client --quit-after 5`（无解析/加载错误即通过）。

### 提示词 4 · 生成服务端战斗校验

> 在 `server/scripts/combat.gd`（`extends Node`）实现**唯一**技能结算入口：
> 入参只有 `attacker_id`（来自 `sender`）与 `target_id`；依次校验：攻击者在世界中且是玩家、
> 存活、冷却 `world.cooldowns` 为 0、目标存在且存活、`distance <= MELEE_RANGE`、非自身；
> 校验通过才写冷却并调用 `world.apply_damage(target_id, Protocol.MELEE_DAMAGE, attacker_id)`。
> 任何伤害数值都**不在客户端**计算；拒绝时打印原因。
> 怪物反击同样走 `apply_damage`。

**前置**：提示词 2。
**产出**：`server/scripts/combat.gd`。
**验证**：`$GODOT --headless --path client -- --bot`（见提示词 6 的 bot 自检）。

### 提示词 5 · 生成 `godot-sqlite` 账号/角色 DAO 与登录流程

> - `server/scripts/db.gd`：`SQLite.new()`，`path="user://mmorpg_server.db"`，`foreign_keys=true`，
>   `verbosity_level=0`，`open_db()`；`_create_schema()` 先查 `sqlite_master` 再 `create_table`
>   （列定义含 `data_type`，外键写 `"accounts.id"`）；封装 `select()/execute()/last_insert_id()`，
>   **只绑定值**，标识符为源码字面量。
> - `server/scripts/persistence.gd`：角色 CRUD（`characters_for`/`create_character`/`get_character`/`save_character`），
>   行列与 `CharacterSheet.from_row()` 对齐。
> - `server/scripts/auth.gd`：实现 `auth_callback` 的 `handle_auth(peer_id, payload)`：解析 JSON →
>   校验 `protocol` 与长度边界（边界取自 `Protocol`）→ 注册或登录 → **成功才 `multiplayer.complete_auth(peer_id)`**，失败
>   `multiplayer.disconnect_peer(peer_id)`。密码存储为 `SHA-256(salt || password)` +
>   `Crypto.generate_random_bytes(16)` 随机 salt，用 `HashingContext`。
> - **按账号限流**：失败计数 + 阈值后线性 backoff（前几次免费，否则「先试登录、失败再注册」的客户端流程会被自己锁死）；
>   计数要能过期、有硬上限，避免被伪造用户名撑爆内存。
> - 角色名用**白名单**校验（`[A-Za-z0-9_]`），不要用黑名单——零宽/双向控制符会原样进名字板。
> - 客户端侧：`multiplayer.auth_callback` 必须设为非空（否则 `peer_authenticating` 不触发），在
>   `peer_authenticating` 里 `send_auth(1, payload)` + `complete_auth(peer_id)`。
> - **非线程安全**：所有 DB 调用只在主线程（auth 回调、physics tick、Timer 都在主线程）。

**前置**：`server/addons/godot-sqlite/`（v4.9，`compatibility_minimum="4.7"`）。
**产出**：`server/scripts/{db,persistence,auth}.gd`。
**验证**：起服务端后首次连接会自动建库；重启服务端后用同一账号可再次登录（见提示词 6）。

### 提示词 6 · 生成导出预设与本地双开联调脚本

> - `server/export_presets.cfg`：`platform="Linux"` 且 `dedicated_server=true`，
>   `export_path="build/mmorpg_server.x86_64"`，`include_filter="addons/godot-sqlite/bin/*.linux.template_release*"`
>   （只固定 release 那份：GDExtension 导出机制已会把对应 `.so` 放到二进制旁，多打的 debug 库只是给 PCK 增重）。
> - `client/export_presets.cfg`：`platform="Windows Desktop"`，`export_path="build/mmorpg_client.exe"`。
> - 客户端内置无头自检 `--bot`：先以 `register=false` 登录（验证错误凭据被拒），失败后以
>   `register=true` 注册；拉取角色列表 → 创建/选择角色 → 进入世界 → 20Hz 上传输入 → 逼近怪物并
>   在射程内 `c2s_use_ability` → 断言收到 `s2c_combat_event`、`s2c_hp_update`、怪物死亡；
>   `--bot-require-peer` 时额外要求“看到另一个玩家移动”（验证双客户端互相可见）；最后打印
>   `CHECK ...=OK/FAIL` 与 `RESULT PASS|FAIL` 并以 0/1 退出。

**前置**：提示词 2–5。
**产出**：两个 `export_presets.cfg`、`client/scripts/bot.gd`、`scripts/export.ps1`。
**验证**：
```powershell
# 终端 1
& $GODOT --headless --path server -- --server
# 终端 2 / 3（并发，验证互相可见）
& $GODOT --headless --path client -- --bot --host 127.0.0.1 --bot-user a --bot-require-peer
& $GODOT --headless --path client -- --bot --host 127.0.0.1 --bot-user b --bot-require-peer
# 导出（需先安装同版本导出模板）；脚本会先创建 Godot 不会自动创建的 build/ 目录
powershell -File scripts/export.ps1 -Target all
```

---

## 四、导出模板安装（与引擎版本必须一致）

已在本机安装到 `C:\Users\<user>\AppData\Roaming\Godot\export_templates\4.7.1.stable\`
（35 个文件，`version.txt` = `4.7.1.stable`）。

`Export as dedicated server` 依赖 **同版本导出模板**，目录布局：

```
C:\Users\<user>\AppData\Roaming\Godot\export_templates\4.7.1.stable\
    version.txt
    linux_debug.x86_64
    linux_release.x86_64        # 服务端专用服务器导出必需
    windows_debug_x86_64.exe
    windows_release_x86_64.exe
```

安装方式（任一）：
1. 编辑器 → `Editor` → `Manage Export Templates` → `Download and Install`；
2. 或手动下载 `Godot_v4.7.1-stable_export_templates.tpz`（约 1.2 GB），解压后把
   `templates/` 下的文件放到上面的目录（`version.txt` 内容应为 `4.7.1.stable`）。

命令行验证模板是否就位：
```powershell
Get-ChildItem "$env:APPDATA\Godot\export_templates\4.7.1.stable" | Select-Object Name
```

## 五、本次实现的实际验证记录

| 验收项 | 命令 | 结果 |
|---|---|---|
| 版本一致 | `$GODOT --version` | `4.7.1.stable.official.a13da4feb` |
| 契约一致 | `powershell -File scripts/link_shared.ps1 -Verify` | 联接正确 + `Net` autoload 两端同为 `*res://shared/net/net_rpc.gd` + `@rpc` 未外泄 + 与 `Protocol.RPC_NAMES` 逐项一致（故意改坏一项时返回 1，已反向验证） |
| 双工程无解析错误 | `--headless --path {server,client} --quit-after N` | 无 ERROR/WARNING |
| 服务端监听 | `--headless --path server -- --server` | `listening on UDP 7000 (max 16 clients, tick 20Hz)`（启动日志会回显从 `Protocol.TICK_HZ` 应用的 tick） |
| 登录/持久化 | 起服务端 → `--bot --bot-user NAME` → 重启服务端 → 同账号再跑 | 第二次第一次尝试即登录成功，且回到上次保存的坐标 |
| 干净 DB 建表 | 删库后重跑 bot | 账号/角色表按当前 schema 重建，插入（含所有 NOT NULL 列）成功 |
| 双客户端互相可见 | 并发两个 `--bot ... --bot-require-peer` | 双方均 `remote_player_moved=OK`（对方移动 3.75–7.25m） |
| 战斗/死亡/复活 | 同上次；`--bot ... --bot-check-respawn` | `combat_event=OK`、`mob_kill=OK`、`mob_respawn=OK`（击杀后约 8s 同 id 重生）、`local_hp=OK`、`local_name=OK` |
| 服务端不采信客户端 | `Select-String` 扫描 c2s 发送内容 | 只有 `move/yaw/buttons`、`target_id`、角色名/ID；服务端自行算位置与伤害 |
| 非有限输入防护 | `--script` 探针（`extends SceneTree`） | `INF yaw` 会产出 NaN 位置且 `clampf` 修不回；`set_input` 的有限性校验能拦住 |
| 登录限流 | `--script` 探针直接调 `AuthService` | 前 3 次允许 → 锁定 → backoff 后解锁 → 成功登录清计数 |
| 导出 | `powershell -File scripts/export.ps1 -Target all`（先删掉 `build/` 复现干净克隆） | Linux ELF + `.pck` + `libgdsqlite.linux.template_release.x86_64.so`；Windows exe + `.pck`；**导出的客户端 exe 跑 bot 自检 RESULT PASS** |

注：导出路径目录（`server/build`、`client/build`）需先存在且被 gitignore，Godot 不会自动创建，
所以用 `scripts/export.ps1`（先建目录再导出并校验产物），不要直接跑裸 `--export-release`。

## 六、已知取舍（不要当成 bug）

- **无客户端预测**：本地角色同样由服务端状态驱动，LAN 下移动有约 1 个 RTT 的输入延迟。这是 MVP 的有意取舍。
- **凭据明文过线**：Godot 高层多人是**未加密的 ENet/UDP**，密码随 `auth_callback` payload 明文传输
  （服务端只存 `SHA-256(salt||password)`）。**仅限 LAN / 可信网络**；公网前必须改质询-应答或加密传输。
- 无兴趣管理（AoI）、无多区域、无公会/聊天/交易/背包/掉落/经验（属于 MVP 明确不做的范围）。
- 全部美术为占位几何体（胶囊/方块/纯色），无外部资产。
- 这些取舍的后续处理方式、优先级与技术债清单见 `docs/roadmap.md`。
