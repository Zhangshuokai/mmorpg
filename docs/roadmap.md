# 未来展望 / 技术债

> 本文件是**计划与债务清单**（未来展望），不是现状说明，也不是调研事实。
> - 当前实现状态、目录职责与全部命令：根 `AGENTS.md`
> - 已核实的联网/部署事实：`docs/research/godot-mmorpg-network-and-deployment.md`
> - 搭建提示词模板与验证记录：`docs/research/godot-mmorpg-mvp-assets.md`

一句话现状：单区域 MVP 闭环已跑通（注册/登录/存档、20Hz 权威移动、近战战斗、死亡复活、双客户端互见），
入口为 `server/scripts/main.gd`（服务端装配）与 `client/scripts/main.gd`（客户端装配），
唯一自动化手段是客户端内置的 `--bot` 无头自检。

## 一、下一步（按价值/风险排序）

### 1. 客户端预测与和解（体验最大缺口）
- 现状：本地角色也完全由服务端状态驱动（`client/scripts/main.gd` 只上传输入，`client/scripts/entity_view.gd` 做插值），
  LAN 下就有约 1 个 RTT 的可见输入延迟；这是有意取舍，不是 bug。
- 做法：本地维护预测位置 + 输入缓冲，收到权威 `s2c_world_state` 后回滚重放并平滑纠偏；`Protocol.TICK_DT` 已是统一 tick 单位。
- 前置：把移动结算抽成 `shared/` 里的纯函数，让 `server/scripts/world.gd` 与客户端共用同一套公式（避免两端各写一份而漂移）。
- 验收：注入 100–200ms 人工延迟时，本地输入到画面反馈 < 50ms，且与服务端位置收敛（误差 < 0.5m）。

### 2. 兴趣管理（AoI）与多区域
- 现状：`world.gd._broadcast()` 每 tick 给所有 peer 发送**全部实体**的完整状态；实体表是单个字典；地图是 60×60 固定平面。
- 做法：按 AOI 半径筛选可见实体；按 zone/分线切分世界状态与实体表（DB 已有 `characters.zone` 列，`Protocol` 目前没有 zone 常量）。
- 验收：并发 50+ bot（`--bot` 放大跑）时单 tick 广播量随 AOI 收敛；不同区域玩家互不可见。

### 3. 元系统（聊天 / 好友 / 公会 / 排行榜）
- 现状：只有账号与角色；除 `s2c_login_result`/`s2c_character_list` 外没有社交 RPC。
- 做法（二选一，不要混着做）：
  1. 自建：在 `shared/net/net_rpc.gd` 加 RPC（**必须同步更新 `Protocol.RPC_NAMES`**，否则 `-Verify` 失败）、
     `server/scripts/` 加服务、SQLite 加表（注意风险 1）；
  2. 接 **Nakama**（官方 Godot 4 客户端）承接元系统，玩法实时同步仍留在自建服务器；先写清账号/角色映射与 Docker 部署方案。
- 验收：聊天跨客户端可见；新表在干净 DB 与已有 DB 上都能工作。

### 4. 内容扩展（多职业技能 / 更多怪 / 掉落 / 经验 / 背包）
- 现状：占位数值全部集中在 `shared/net/protocol.gd`；结算集中在 `server/scripts/combat.gd`；
  DB 有 `level`/`xp` 列但无逻辑；无装备/背包/掉落表。
- 做法：把数值从常量搬成数据表（`Protocol` 只保留 id 与边界），技能支持多冷却/多射程/多目标类型，新增掉落与背包表。
- 前置：先解决风险 1（无迁移机制），否则每次改 schema 都会丢玩家数据。
- 验收：扩展 `client/scripts/bot.gd` 的 CHECK 集覆盖新技能与掉落（已有 `--bot-*` 框架可直接加断言）。

### 5. 安全与传输硬化（公网前置条件）
- 现状：密码明文过线、限流只有账号维度、无传输加密（详见 `AGENTS.md`「安全边界」）。
- 做法：登录取质询-应答（服务端 nonce + `SHA-256(salt||password)` 派生证明）或换加密传输；限流加来源维度；
  所有 RPC 入参按不可信输入校验（可参考 `world.gd.set_input` 对非有限值的拒绝）。
- 验收：抓包看不到明文口令；同来源连续错误凭据被阻断。

### 6. 运维与交付
- 现状：导出预设与 `scripts/export.ps1` 可用，但无 CI、无 systemd/Docker 落地、无崩溃自启、无日志轮转。
- 做法：CI 串起「`-Verify` → 双工程解析检查 → `--bot` 自检 → 导出」；产出 Linux 服务端 + Windows 客户端；
  服务端 systemd 常驻（`flush_stdout_on_print` 已开），弹性伸缩再用 Docker。
- 前置：构建机需装**同版本**引擎与导出模板（见 `docs/research/godot-mmorpg-mvp-assets.md`）。
- 验收：干净机器一条命令产出可用产物；进程被 kill 后自动重启。

### 7. 工程化补齐
- 现状：没有单元测试框架；唯一自动化是无头 bot，只覆盖网络/玩法链路，不覆盖 UI 与纯函数。
- 做法：为 `shared/` 的纯函数（边界钳制、AABB 推出、冷却/射程校验）补 GDScript 单测
  （可用 `--script` + `extends SceneTree` 的方式跑）；UI 至少维护一份人工验收清单。
- 验收：`-Verify` + 单测 + bot 三件套能在 CI 一键跑完。

## 二、技术债 / 风险（按严重度）

1. **无 schema 迁移机制**：`create_table` 只在表不存在时执行，改列只能手工迁移或删库重来
   （DB 在 `%APPDATA%\Godot\app_userdata\MMORPG Server\mmorpg_server.db`）。→ 加迁移表/版本号。
2. **全量广播、无 AoI**：成本是 O(实体 × peer)，单区域 10 人可用，50+ 必须先做第 2 项。
3. **凭据明文过线**：公网前必须处理（第 5 项）。
4. **限流仅账号维度**：无法阻断撞库/注册风暴（第 5 项）。
5. **仓库体积**：`server/addons/godot-sqlite/` 约 300MB 多平台二进制必须提交；按平台裁剪 `bin/` 可瘦身但会破坏其他平台导出。
6. **客户端无 UI 自动化**：`--bot` 不覆盖登录/角色面板交互，UI 改动需人工过一遍。
7. **协议无协商**：`Protocol.PROTOCOL_VERSION` 仅比对，不兼容升级会直接拒连（可行但不友好）。
8. **存档非事务**：每 10s + 断线保存，服务端崩溃最多丢 10s 进度。

## 三、明确不做（除非需求变化）

- 帧同步 / rollback netcode、无缝开放世界、跨服、公会战等大型系统。
- 在 MVP 阶段引入 C#、ECS 框架或自研 UDP 协议（先保持引擎原语）。
- 正式美术资产（当前全部为占位几何体：胶囊 / 方块 / 纯色）。
- 任何客户端权威的玩法判定（与本项目「服务端权威」决策冲突）。
