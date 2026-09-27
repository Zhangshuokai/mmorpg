# Godot MMORPG MVP 搭建计划

## 目标

在本仓库（当前仅有 `AGENTS.md` 与 `docs/`）从零搭建**服务端权威**的 3D MMORPG 骨架（类 WoW 第三人称视角），完成“**移动 + 战斗 + 登录/存档**”最小闭环。

## 范围

**In（本 MVP 交付）**
- 单区域：一块平面地面（`PlaneMesh` + `StaticBody3D`）+ 少量方块掩体；固定出生点。
- 专用服务器权威；多个客户端互相可见并移动。
- 极简账号（用户名 + 密码）与角色创建/选择，SQLite 持久化。
- 1 个职业、1 个近战技能、1 种怪；血量/伤害/死亡/复活闭环。

**Out（明确不做，避免范围蔓延）**
- 客户端预测/回滚、兴趣管理(AoI)、多区域/无缝地图。
- 公会/聊天/交易/邮件、装备/背包/掉落/经验。
- 正式美术资产（用胶囊体/方块/基础色占位）。
- Nakama 与 Docker/systemd 上线（仅保留导出预设与部署说明）。

## 已锁定决策

| 项 | 决策 |
|---|---|
| 引擎 | Godot **4.x stable**（安装时取最新稳定版并记录精确小版本；**导出模板必须同版本**） |
| 语言 | GDScript（不混用 C#） |
| 维度 | 3D 第三人称 |
| 工程结构 | 双工程 `client/` + `server/`，各自独立 `project.godot` |
| 共享契约 | 根 `shared/`；Windows 目录联接映射为 `client/shared`、`server/shared` |
| RPC 契约 | `shared/net/net_rpc.gd` 作为两端**同名 autoload `Net`**（NodePath 恒为 `/root/Net`），保证签名一致 |
| 网络 | Godot 高层多人 API（ENet/UDP），默认端口 **UDP 7000** |
| 鉴权 | `SceneMultiplayer.auth_callback` + `complete_auth()`（凭据走 auth payload，不用裸 RPC） |
| 存储 | `godot-sqlite`（`2shady4u/godot-sqlite`，1.4k★，MIT，Godot 4.x GDExtension）；DB 位于服务端 `user://mmorpg_server.db` |
| 移动同步 | 服务端权威；客户端只上传**输入**；服务端 20Hz 广播世界状态；客户端插值渲染（**MVP 不做预测**） |
| 客户端目标平台 | Windows 桌面 |
| 并发目标 | 单区域 ~10 并发，无 AoI |

> 说明：不做客户端预测是本 MVP 的有意取舍——保证“服务端权威”链路正确，代价是本地移动有输入延迟（LAN 下可接受）。预测/和解列为后续迭代。

## 目录结构

```
mmorpg/
  AGENTS.md
  .gitignore                     # 新增（见 T1）
  shared/                        # 单一真相源（提交）
    net/protocol.gd              # 常量：端口、tick、协议版本、枚举、通道
    net/net_rpc.gd               # 所有 @rpc 函数；两端 autoload "Net"
    model/entity_state.gd        # 实体状态 DTO（玩家/怪通用）
    model/character.gd           # 角色 DTO
  scripts/
    link_shared.ps1              # 创建目录联接（幂等）
  client/
    project.godot
    shared -> ../shared          # 联接（gitignore）
    scenes/ scripts/ ...
  server/
    project.godot
    shared -> ../shared          # 联接（gitignore）
    addons/godot-sqlite/...      # GDExtension（提交，注意 bin 分平台）
    scripts/ ...
    export_presets.cfg
  docs/research/                 # 已有调研归档；T7 追加
```

## 前置条件（T0，必须先做）

1. 从 https://godotengine.org/download/windows/ 安装 Godot 4.x Editor，并安装**同版本导出模板**（含 Linux 模板，用于服务端导出）。
2. `godot --version` 记录精确版本号；把它写进 `AGENTS.md`。
3. 从 https://github.com/2shady4u/godot-sqlite/releases 下载对应版本，解压到 `server/addons/godot-sqlite/`（客户端工程**不**装）。

## 实施任务（按序）

### T1 仓库骨架与忽略规则
- 新建 `shared/`、`client/`、`server/`、`scripts/`。
- 根 `.gitignore` 至少包含：`.godot/`、`build/`、`export/`、`*.pck`、`*.zip`、`client/shared`、`server/shared`。
- 注意：`AGENTS.md` 已记录 Godot 版本控制约定，勿把 `.godot/` 提交。

### T2 共享契约 + 目录联接（先做技术验证）
- 写 `shared/net/protocol.gd`：`const SERVER_PORT := 7000`、`const TICK_HZ := 20`、`const PROTOCOL_VERSION := 1`、`enum Msg`、传输通道常量。
- 写 `shared/net/net_rpc.gd`：承载下表**全部** `@rpc` 函数，仅转发信号，不含玩法逻辑。
- 写 `shared/model/*.gd` DTO（纯数据，无 Node 继承）。
- 写 `scripts/link_shared.ps1`：用 `New-Item -ItemType Junction` 创建 `client/shared`、`server/shared`，幂等。
- **验证点（阻塞后续）**：在这两个最小工程里让 Godot 通过 `res://shared/...` 成功加载并实例化 `Net` autoload，两工程 autoload 名与路径一致。若联接不被 Godot 支持，回退方案：保留 `shared/` 为真相源，用 `scripts/sync_shared.ps1` 复制到两端并加“签名一致性”检查。

### T3 服务端工程（`server/`）
- `project.godot`：注册 autoload `Net` → `res://shared/net/net_rpc.gd`；开启 `application/run/flush_stdout_on_print`。
- `scripts/main.gd`：按 `DisplayServer.get_name() == "headless"` 或 `--server`（`OS.get_cmdline_user_args()`）启动服务器分支。
- `scripts/db.gd`：封装 `godot-sqlite`（`open_db`/`query_with_bindings`/`create_table`），数据库路径 `user://mmorpg_server.db`；启动时建表。
  - 密码：用内置 `HashingContext`（SHA-256 + 每账号随机 salt），**不存明文**。
  - ⚠️ `godot-sqlite` 非线程安全：DB 访问统一放主线程，或用互斥串行化。
- `scripts/auth.gd`：`multiplayer.auth_callback` 校验账号，`complete_auth(peer_id)`；失败则断开。
- `scripts/world.gd`：20Hz `_physics_process` 固定 tick；维护实体表（玩家 + 怪）；处理移动输入、碰撞、广播世界状态。
- `scripts/combat.gd`：服务端校验技能冷却/射程/目标存活后结算伤害；不信任客户端任何伤害/位置。
- `scripts/persistence.gd`：登录加载、登出/断线/每 N 秒保存角色位置与 HP。
- 场景：`Main`(Node) + `World`(Node3D，含地面/掩体/出生点) + Mob 场景。

### T4 客户端工程（`client/`）
- `project.godot`：注册同名 autoload `Net`；默认连接 `127.0.0.1:7000`（可用命令行/配置覆盖）。
- 登录/角色选择 UI：注册、登录、列出角色、创建角色、进入世界。
- 3D：`Player` 场景（`CharacterBody3D` 占位胶囊 + 摄像机 `SpringArm3D` 第三人称）；`Mob` 场景。
- 客户端**不**做本地权威模拟：本地玩家与远程实体一样由服务端状态驱动；对状态做插值/平滑；相机跟随本地玩家。
- 输入：`Input.get_vector` → 按 20Hz 通过 `c2s_input` 上传方向/yaw/按压位。
- HUD：自身与目标 HP；技能按钮触发 `c2s_use_ability`。

### T5 导出预设
- `server/export_presets.cfg`：Linux 预设，Resources 页选 **Export as dedicated server**（自动 `dedicated_server` feature tag + 强制 headless + 可 Strip Visuals）。
- `client/export_presets.cfg`：Windows 桌面预设。
- Q: GDExtension 二进制需覆盖目标平台（Linux 服务端要有 `.so`）。见“风险”。

### T6 本地联调验证
- 起服务端：`godot --headless --path server -- --server`
- 起两个客户端实例连 `127.0.0.1`，按下方验收清单逐项确认。

### T7 文档归档（对应“联网搜索相关提示词”）
- 追加 `docs/research/godot-mmorpg-mvp-assets.md`，含：
  - **参考来源**：官方高层多人/专用服务器文档、`godot-sqlite`、`WithinAmnesia/ARPG`（2D ARPG 模板，仅作结构参考）、Nakama 文档。
  - **MVP 搭建提示词模板（prompt）**，每步一段可直接复用的提示词，覆盖：
    1. 生成 `shared/` 协议与 DTO；
    2. 生成服务端权威移动与世界状态同步；
    3. 生成客户端 3D 控制器 + 第三人称相机 + 插值；
    4. 生成服务端战斗校验；
    5. 生成 `godot-sqlite` 账号/角色 DAO 与登录流程；
    6. 生成导出预设与本地双开联调脚本。
  - 每段提示词须写明前置产物、输入输出文件、验证命令。

## RPC 契约（两端必须逐字一致）

全部定义在 `shared/net/net_rpc.gd`（autoload `Net`）。客户端→服务端用输入/意图，服务端→客户端用权威状态。

| 函数 | 模式 / 传输 | 方向 | 说明 |
|---|---|---|---|
| `c2s_input(seq:int, move:Vector2, yaw:float, buttons:int)` | `any_peer` / `unreliable_ordered` | C→S | 仅输入意图 |
| `c2s_use_ability(target_id:int)` | `any_peer` / `reliable` | C→S | 目标由服务端校验 |
| `c2s_list_characters()` | `any_peer` / `reliable` | C→S | 返回角色列表 |
| `c2s_create_character(name:String, class_id:int)` | `any_peer` / `reliable` | C→S | 服务端校验重名 |
| `c2s_select_character(char_id:int)` | `any_peer` / `reliable` | C→S | 进入世界并加载存档 |
| `s2c_login_result(ok:bool, reason:String)` | `authority` / `reliable` | S→C | 登录结果 |
| `s2c_character_list(characters:Array)` | `authority` / `reliable` | S→C | |
| `s2c_enter_world(self_id:int, spawn:Vector3, hp:int)` | `authority` / `reliable` | S→C | |
| `s2c_spawn_entity(state:Dictionary)` | `authority` / `reliable` | S→C | 玩家/怪通用 |
| `s2c_despawn_entity(id:int)` | `authority` / `reliable` | S→C | |
| `s2c_world_state(tick:int, entities:Array)` | `authority` / `unreliable_ordered` | S→C | 20Hz，仅位置/yaw/hp |
| `s2c_combat_event(id:int, target_id:int, damage:int, target_hp:int)` | `authority` / `reliable` | S→C | 伤害由服务端结算 |
| `s2c_hp_update(id:int, hp:int)` | `authority` / `reliable` | S→C | |

> 登录凭据不走 RPC，走 `auth_callback`。上表所有函数必须同时存在于两端；任一缺失都会导致签名校验失败并报无关错误。

## 数据库 Schema（服务端 `user://mmorpg_server.db`）

```
accounts(id INTEGER PK AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
         password_hash TEXT NOT NULL, salt TEXT NOT NULL, created_at TEXT)
characters(id INTEGER PK AUTOINCREMENT, account_id INTEGER NOT NULL,
           name TEXT UNIQUE NOT NULL, class_id INTEGER NOT NULL,
           level INTEGER DEFAULT 1, xp INTEGER DEFAULT 0, hp INTEGER DEFAULT 100,
           pos_x REAL, pos_y REAL, pos_z REAL, zone TEXT, updated_at TEXT,
           FOREIGN KEY(account_id) REFERENCES accounts(id))
```

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 双工程 RPC 签名漂移（官方报错会指向无关 RPC） | 所有 `@rpc` 集中在 `shared/net/net_rpc.gd`，两端同名 autoload，NodePath 一致 |
| Windows 目录联接不被 Godot 识别 | T2 先做最小验证；失败则回退为“复制 + 签名一致性检查脚本” |
| `godot-sqlite` 与 Godot 小版本不兼容 | T0 验证 demo 能开库；锁定同时支持 Godot 与插件的版本 |
| Linux 服务器 glibc < 2.35 时插件崩溃 | 部署前 `ldd --version`；必要时自行重编译插件 |
| GDExtension 二进制未随导出带上 | 服务端导出预设显式包含 `addons/godot-sqlite/bin/*.linux*` |
| `godot-sqlite` 线程安全 | DB 访问只走主线程或互斥串行化 |
| 无客户端预测导致操作延迟 | MVP 接受；列为后续迭代（输入缓冲 + 和解） |
| 读写型 DB 不可打入 PCK | DB 固定放 `user://`，不入 PCK |

## 验收（Definition of Done）

1. `godot --version` 与 `AGENTS.md` 记录一致。
2. 两个工程均能打开且无解析错误；`Net` 在两端的 autoload 路径一致。
3. 服务端 `godot --headless --path server -- --server` 启动并监听 UDP 7000。
4. 双客户端连接后能互相看到对方移动，位置与服务端状态一致（插值误差可接受）。
5. 注册 + 登录写入 SQLite；错误密码被拒；账号重启服务端后仍可登录。
6. 创建/选择角色；断线重连后位置与 HP 恢复。
7. 攻击怪物：服务端结算伤害、怪物死亡并刷新；客户端 HP 同步更新。
8. 全局搜索确认服务端**不**采信客户端上报的位置/伤害（只收输入）。
9. 导出预设可产出 Linux 专用服务器构建与 Windows 客户端构建。

## 未决 / 可调（非阻塞）

- 职业/技能/怪物数值均为占位（1 职业、1 技能、1 怪），数值可随时调整。
- 移动模型（是否加入客户端预测）为后续迭代开关，不影响当前契约。
