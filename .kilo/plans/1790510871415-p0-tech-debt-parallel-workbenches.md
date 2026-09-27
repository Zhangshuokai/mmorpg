# P0 技术债并行补完：契约冻结 + 热点拆分 + Agent Manager workbench 编排

> 目标：把 roadmap 第二节的全部 P0 系统切成可**真正并行**的 workbench，用 Agent Manager 托管 worktree，
> 逐 WB 合入主干。本文是执行计划，不含代码。落地实现须切到可写代码的 agent。

## 0. 范围与已确认决策

- **范围**：`docs/roadmap.md` 第二节全部 P0 系统（不是第四节 10 条债务，也暂不含 P1）：
  `S-D-3`、`S-D-1`、`S-D-2`、`S-O-5`、`S-N-4`、`S-N-5`、`S-N-7`、`S-N-1`、`S-N-2`、
  `S-G-1`、`S-G-2`、`S-G-5`、`S-E-1`、`S-E-2`、`S-O-1`、`S-T-1`、`S-T-2`。
- **契约策略**：契约先行冻结 + 热点文件再拆（`protocol.gd`/`net_rpc.gd`/DB schema 由 WB0 一次定版；
  `world.gd`、两端 `main.gd`、`bot.gd`、`network_client.gd` 在 WB0 拆成可独立占用的文件）。
- **隔离机制**：Kilo Agent Manager 托管 worktree，每个 workbench 一个 agent/分支；逐 WB rebase 后合入主干。
- **不变量（来自 AGENTS.md，WB 不得违反）**：`@rpc` 只在 `shared/net/net_rpc.gd`；`Protocol` 是数值/边界唯一真相源；
  两端 autoload 恒为 `/root/Net`；服务端权威、客户端只发意图；`godot-sqlite` 只在主线程。
- **并行前提**：Agent Manager 文档明确建议“先把共享契约/接口/文件布局在主干稳定，再切 worktree”——这正是 Wave 0 的存在理由。

## 1. 并行隔离的硬前置（不做则 worktree 会互相踩）

两个 worktree 同时跑服务端/bot 时会互相破坏，因为：

- **UDP 端口固定 7000**（`Protocol.SERVER_PORT`），第二个服务端直接 bind 失败。
- **DB 路径固定 `user://mmorpg_server.db`**，而 Godot `user://` 由 `project.godot` 的 `config/name`（`MMORPG Server`）
  决定，**所有 worktree 共享** `%APPDATA%\Godot\app_userdata\MMORPG Server\` → 同一 SQLite 文件被并发打开/写入。

因此 WB0 必须落地最小隔离（属 S-O-4 的一个切片，仅取“命令行覆盖”部分）：

- 服务端支持 `--port <n>` 与 `--db <abs path>`；`Protocol.SERVER_PORT` / 原 `user://` 仅作默认值。
- 客户端支持 `--port <n>`（`--host` 已有）。
- 每个 worktree 约定：端口按 worktree 序号分配（如 7100+），DB 用 worktree 内 `.local/mmorpg_server.db`。
- `.gitignore` 增加 `.local/`；`.kilo/worktrees/**` 也应忽略（Agent Manager 默认管理，确认一次）。

## 2. Wave 0（门槛，串行）：WB0 契约冻结 + 热点拆分 + 隔离

**这是唯一在所有并行分支之前合入主干的工作；必须纯重构、行为不变（bot 全绿）。**
WB0 不实现任何玩法/安全/网络新功能，只把“接口面”和“文件所有权”定死。

### 2.1 契约冻结（WB0 独占，之后只读）

- `shared/net/protocol.gd`
  - 登记全部 P0 所需常量与边界：zone/channel/instance id 与枚举、AoI 半径、每包字节预算、
    技能 id/GCD/冷却/射程/目标类型、物品与背包/装备上限、属性与公式参数、协议版本升到 2、
    auth v2 质询-应答 payload 键、DB schema 版本常量。
  - 只保留 **id 与边界**；数值迁往 `shared/data/`（S-D-3 的落点在 Wave 1）。
  - `RPC_NAMES` 全量登记 P0 新 RPC（`-Verify` 以此对账）。
- `shared/net/net_rpc.gd`：全量新增 P0 `@rpc` 函数 + 转发信号，**签名一次定版**。
  覆盖：技能/施法、物品/背包/装备、区域切换、预测所需输入确认（`s2c_*` 带 ack seq）、
  auth v2（仍走 auth_callback，不新增裸 RPC）。函数体只发信号。
- `shared/sim/movement.gd`（新，`class_name Movement`）：把 `world.gd._step_players` 的移动数学抽成纯函数
  （`settle(pos, move, yaw, dt)`、`clamp_bounds`、`resolve_obstacles`），**服务端改为调用它**（行为不变），
  客户端暂不调用（WB6 才接预测）。
- `shared/sim/formulas.gd`（新，`class_name Formulas`）：先保持当前数值语义（平伤），WB2 再数据驱动。
- `shared/data/data_tables.gd`（新）：loader 接口 + 启动校验签名；表文件按目录 glob 加载
  （`shared/data/tables/*.json`），**每个 WB 新增自己的表文件，互不改同一清单**，避免合并冲突。

### 2.2 热点文件拆分（WB0 产出的“文件所有权地图”）

拆分原则：facade 保留稳定接口，子系统各自成文件；服务/命中处理用**注册表**而不是集中 `match`，让后续 WB 不改公共文件。

| 现文件 | 拆分目标（新文件 → 归属 WB） |
| --- | --- |
| `server/scripts/world.gd` | facade 只留 `setup/_physics_process/生命周期`；`world_state.gd`（实体/输入/冷却容器 → WB0）、`world_movement.gd`（→ WB6 预测共用）、`world_mobs.gd`（→ 后续 P1 AI 预留）、`world_sync.gd`（广播/despawn → WB4）、`zones`（→ WB5） |
| `server/scripts/main.gd` | 只留装配；`bootstrap.gd`（迁移/备份启动钩子 → WB1）、`session_flow.gd`（登录/角色列表/创建/选择 → WB0）、`intent_router.gd`（Net 信号 → 注册表派发 → WB0/WB7） |
| `client/scripts/main.gd` | 只留装配；`world_view.gd`（实体表/spawn/despawn → WB6/WB5）、`input_controller.gd`（输入/seq → WB6）、`ui_flow.gd`（登录/角色面板流转 → WB0/WB2/WB3） |
| `client/scripts/network_client.gd` | `net_transport.gd`（连接/ENet → WB7）、`net_input.gd`（send_input+seq → WB6）、`net_auth.gd`（握手钩子 → WB7） |
| `client/scripts/bot.gd` | `bot.gd` 只做 runner/超时/汇总；`bot_checks/bot_check_*.gd` 按域拆（session/movement/net/combat/inventory），**运行时 glob 目录自动注册**；每个 WB 只加自己的 `bot_check_<域>.gd` |
| `server/scripts/combat.gd` | 保留为召唤入口；`skills.gd`（→ WB2） |
| `server/scripts/db.gd` | 抽出 `migrations.gd`（迁移框架 → WB1），`db.gd` 只留连接/查询封装 |

配套约定（写进 AGENTS.md 的小节）：

- `intent_router.gd` 用“RPC 名 → 处理器”注册表；服务在 `_ready` 自注册，后续 WB 不编辑 router。
- 迁移文件 `server/scripts/migrations/m_<seq>_<slug>.gd` 按 seq 排序执行；**seq 区段预约**：
  `0001` baseline（旧 schema 快照）、`0002–0099` WB1、`0100–0199` WB3、`0200–0299` WB2、
  `0300–0399` WB5、`0400+` 其他；预约表常量放 `migrations.gd`（WB1 拥有）。
- bot 断言基类 `bot_checks/bot_check.gd` + `DirAccess` glob 注册。

### 2.3 WB0 验收（必须全绿才算门槛通过）

```powershell
powershell -File scripts/link_shared.ps1 -Verify
& $env:GODOT --headless --path server --quit-after 3 -- --server
& $env:GODOT --headless --path client --quit-after 5
& $env:GODOT --headless --path client -- --bot --host 127.0.0.1
# 并发两个 bot 验证互见
& $env:GODOT --headless --path client -- --bot --host 127.0.0.1 --bot-user a --bot-require-peer
& $env:GODOT --headless --path client -- --bot --host 127.0.0.1 --bot-user b --bot-require-peer
# 验证隔离：第二个服务端用不同端口/DB 能同时启动
& $env:GODOT --headless --path server -- --server --port 7101 --db .local/iso.db
```

通过后打 tag（如 `contract-v2`）作为所有 workbench 的 base。

### 2.4 Agent Manager 落地文件（WB0 一并提交）

- `.kilo/setup-script.ps1`（每个 worktree 创建时执行；**放在主仓 `.kilo/`，不要放进 worktree 的 `.kilo/`**）：

```powershell
$ErrorActionPreference = 'Stop'
Set-Location $env:WORKTREE_PATH
powershell -File scripts/link_shared.ps1
New-Item -ItemType Directory -Force -Path .local | Out-Null
# 注意：首次 --import 需注册 class_name；300MB 插件可能拖长，若超 5 分钟把 import 移出 setup
if ($env:GODOT) {
  & $env:GODOT --headless --path server --import
  & $env:GODOT --headless --path client --import
}
```

- `.kilo/run-script.ps1`：按 worktree 名派生端口（如 hash 到 7100–7999）与 `--db .local/…`，避免 7000/共享 DB 冲突。

## 3. Wave 1（WB0 tag 后并行）

> 每个 WB 只改本表“文件所有权”列的文件；列到“只读”的公共文件一律不改（需改走 §5 契约变更协议）。

| WB | 系统 | 文件所有权 | 交付物 | 验收（在自身 worktree 跑通） |
| --- | --- | --- | --- | --- |
| **WB1 数据/持久化/备份** | S-D-3, S-D-1, S-D-2, S-O-5 | `shared/data/**`、`data_tables.gd`、`server/scripts/migrations.gd`、`migrations/**`、`db.gd`、`persistence.gd`、`bootstrap.gd`、`scripts/backup.ps1`、`scripts/restore.ps1` | schema_version + 顺序迁移（干净库与旧库都能升级）；事务/原子写；静态数据表 + 启动校验；备份/恢复脚本与恢复演练 | `-Verify` + 解析检查 + bot；删库重建 + 旧库升级两条路径；kill 后重启最近关键写不丢；备份能恢复出可运行 DB |
| **WB4 网络扩容 AoI/带宽** | S-N-4, S-N-5 | `server/scripts/spatial_grid.gd`（新）、`broadcast_scheduler.gd`（新）、`world_sync.gd` | 均匀网格空间分区 + AOI 半径筛选；优先级累加器 + 每包字节预算；未选中实体累加值保留 | 放大并发 bot（50+）时单 tick 广播随 AOI 收敛、单 tick 带宽有上限；不同 AOI 玩家互不看见无关实体 |
| **WB6 客户端预测/插值** | S-N-1, S-N-2 | `client/scripts/prediction.gd`（新）、`net_input.gd`、`input_controller.gd`、`world_view.gd`、`entity_view.gd`、`bot_checks/bot_check_movement.gd` | 本地预测 + 输入序号缓存；服务端回包带已处理 seq；丢弃已确认、重放未确认、平滑纠偏；其他实体抖动缓冲（≈3×发包间隔） | 注入 100–200ms 延迟（WB8 的损伤注入或自测）时本地输入反馈 <50ms 且与服务端收敛 <0.5m |
| **WB7 安全硬化** | S-E-1, S-E-2 | `server/scripts/auth.gd`、`rate_limit.gd`（新）、`shared/net/auth_handshake.gd`（新）、`client/scripts/net_auth.gd`、`net_transport.gd`、`intent_router.gd` 校验钩子 | 质询-应答（nonce + salt 派生证明，替换明文口令）；来源/连接级限流；全量 RPC 入参校验与频率上限 | 抓包无明文口令；同来源连错被阻断；畸形/超频入参被拒且有断言 |
| **WB8 工程化/测试/CI** | S-O-1, S-T-1, S-T-2 | `tests/**`（新）、`.github/workflows/**`（新）、`scripts/ci.ps1`（新）、`bot.gd`、`bot_checks/bot_check.gd` + registry | `--script` + `extends SceneTree` 单测框架（覆盖 shared 纯函数）；CI：`-Verify`→双工程解析→单测→bot→导出；bot 单模块注册机制 | 干净机器上一条命令跑完并产出 Linux 服务端 + Windows 客户端；单测覆盖边界钳制/AABB 推出/冷却射程公式 |

**Wave 1 冲突点已由 WB0 拆分消除**：`main.gd`/`world.gd`/`network_client.gd`/`bot.gd` 均已按表拆开，各 WB 不再共享同一文件。

## 4. Wave 2（依赖 Wave 1 的成果）

| WB | 系统 | 依赖 | 文件所有权 | 交付物 | 验收 |
| --- | --- | --- | --- | --- | --- |
| **WB2 技能/战斗数值** | S-G-1, S-G-2 | WB1（数据表）、WB4（AOI 广播） | `server/scripts/combat.gd`、`skills.gd`、`shared/sim/formulas.gd`、`shared/data/tables/abilities.json`、`classes.json`、`client/scripts/ui_skillbar.gd`（新）、`bot_checks/bot_check_combat.gd` | 多技能/GCD/冷却/施法条/打断；护甲/暴击/命中/抗性公式数据驱动 | bot 覆盖新技能的冷却、射程、非法目标、打断边界；公式有单测 |
| **WB3 物品/装备/背包** | S-G-5 | WB1（数据表 + 迁移） | `server/scripts/inventory.gd`（新）、`persistence_inventory.gd`（新）、`migrations/m_01xx_*`、`shared/model/item.gd`、`inventory.gd`、`shared/data/tables/items.json`、`client/scripts/ui_inventory.gd`（新）、`bot_checks/bot_check_inventory.gd` | 物品静态表；背包/装备持久化；增删改服务端裁决；客户端快照/增量 | 重登一致；越权移动/复制物品被拒（bot 负例断言） |
| **WB5 多区域/分线/实例** | S-N-7 | WB4（AOI）、WB1（`characters.zone`） | `server/scripts/zones.gd`（新）、`instance.gd`（新）、`world_state.gd` 的 zone 分组、`client/scripts/world_view.gd`（切图）| zone/channel/instance 三层；切区不重连、旧区实体清理；跨区实体 id 唯一 | 不同区域玩家互不可见；切区实体正确清理 |

> WB2/WB3/WB5 之间文件不重叠；`world_state.gd` 归 WB5、`world_view.gd` 归 WB5 都晚于 WB6 合入，按 §6 顺序 rebase。

## 5. 契约变更协议（tag 之后）

契约已冻结，任何 WB 需要新增常量/RPC/DB 列时：

1. **不得**直接编辑 `shared/net/protocol.gd`、`net_rpc.gd`。
2. 向集成者（main）提“契约变更请求”：列出常量/RPC/列名与理由。
3. 集成者在主干落一个**只含契约**的小提交（同步三处铁律：`protocol.gd` + `net_rpc.gd` + `RPC_NAMES`），跑 `-Verify`。
4. 所有活跃 worktree 把主干 rebase 进来（在 worktree 内解决冲突，**禁止 `git stash`/autostash**——worktree 间共享 stash）。

## 6. 合入顺序与门禁

- **合入顺序**：WB0 → (WB1, WB4, WB6, WB7, WB8 任一顺序) → (WB2, WB3, WB5)。
  实际以“分支 rebase 到当前主干后 `-Verify` + 解析检查 + bot 全过”为准；冲突在 worktree 内解决后再 Apply/merge/PR。
- **每个 WB 合入前门禁**（在自身 worktree 执行）：
  `link_shared.ps1 -Verify` → 双工程 `--headless --quit-after` → `--bot`（涉及网络/战斗加 `--bot-require-peer`/`--bot-check-respawn`）。
- **Wave 3 集成验收**（主干上，每个 WB 无需自己跑）：
  - 50+ bot 并发压测（S-N-4/N-5 容量基线）；
  - 网络损伤注入验证预测/插值（S-N-1/N-2，配合 WB8 或独立工具）；
  - `scripts/ci.ps1` 全绿并产出双平台导出（S-O-1）；
  - bot 巡检覆盖 P0：技能/CD/射程、背包越权负例、跨区隔离、鉴权拒绝、崩溃恢复。

## 7. 风险与开放问题

1. **首次 `--import` 耗时**：`server/addons/godot-sqlite` 约 300MB，worktree 首次 import 可能超 setup 的 5 分钟上限 → 把 import 移到 run script 或首次手动执行；WK 只保 `link_shared` + `.local/` 创建。
2. **磁盘占用**：每个 worktree 复制 ~300MB 插件；并发 worktree 数受磁盘限制，建议 Wave 1 控制在 4–5 个。
3. **Godot `user://` 共享**：即使加了 `--db`，任何遗漏的 `user://` 写入（未来）仍会跨 worktree 冲突；约定“worktree 内一律用 `--db <worktree 路径>`，不要依赖默认 `user://`”。
4. **AoI 与预测的交汇**：WB4 广播裁剪 + WB6 预测都以共享移动纯函数为准；若两者对“权威位置”的定义漂移会引入回滚抖动 → 要求 WB6 复用 `shared/sim/movement.gd`，WB4 不复制移动逻辑。
5. **数据表数值 vs Protocol 常量**：S-D-3 要求数值入表、Protocol 只留 id/边界；WB0 冻结时若把数值留在 Protocol 会违背目标 → WB0 只加 id/边界，数值一律 WB1 起落表。
6. **协议版本升级到 2**：WB0 冻结后即与旧客户端不兼容（S-E-3 才做协商区间，属 P1）；开发期可接受，但需在 AGENTS.md 标注“此分支不与旧客户端互通”。

## 8. 明确不做（本次）

- roadmap 第三节 P1/P2 系统（S-N-3、S-E-3、S-G-3/4/6/7…、S-O-2/3/4/6、S-C-*、S-A-* 等）。
- 第 8 条“仓库体积”裁剪（会破坏其他平台导出），维持现状提交 300MB 插件。
- 帧同步/rollback、C#/ECS、正式美术资产（沿用 roadmap 第五节）。
