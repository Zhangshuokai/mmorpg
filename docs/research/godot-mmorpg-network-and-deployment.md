# Godot MMORPG 联网与部署调研归档

- 调研日期：2026-09-27
- 检索关键词：`godot 4 mmorpg dedicated server`、`godot high level multiplayer rpc`、`godot dedicated server docker deployment`、`nakama godot 4 client`、`godot user:// res:// data paths`、`godot 版本控制 .godot 忽略`
- 用途：为类《魔兽世界》MMORPG 项目确定联网架构与专用服务器部署方案。以下为已核实来源的要点摘录，未核实的内容不收录。
- **状态**：本文件是**调研事实归档**（不是计划书）。文中的方案已按 `AGENTS.md` 的架构决策落地到
  `server/`（权威世界/鉴权/存档）、`client/`（输入上传/插值渲染）与 `shared/`（RPC 契约）；
  实现现状与命令见根 `AGENTS.md`，未来规划见 `docs/roadmap.md`。

## 来源清单

| 主题 | 链接 |
| --- | --- |
| 服务端导出（官方） | https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html |
| 高层多人（官方） | https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html |
| 文件路径 res:// 与 user://（官方） | https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html |
| Nakama Godot 4 客户端 | https://heroiclabs.com/docs/nakama/client-libraries/godot/ |
| Nakama Docker 安装 | https://heroiclabs.com/docs/nakama/getting-started/install/docker/ |
| Nakama 架构总览 | https://heroiclabs.com/docs/nakama/getting-started/architecture/ |
| Godot 中文文档 | https://docs.godotengine.org/zh-cn/4.x/ |
| Godot 中文社区 | https://godotengine.net.cn/ |

## 一、联网模型（官方高层多人）

- Godot 高层多人 API 基于 **UDP**（默认 `ENetMultiplayerPeer`），另有 WebRTC / WebSocket 实现；TCP 不适合实时游戏状态同步。
- 公网联机必须在路由器/防火墙放行 **UDP** 端口，只开 TCP 无效；内网地址（`192.168.*.*`）非公网可达，需端口转发后配合公网 IP 连接。
- 节点通过 `multiplayer`（`MultiplayerAPI`）管理；服务端 `create_server(PORT, MAX_CLIENTS)`，客户端 `create_client(IP, PORT)`。
- 服务端唯一 ID 固定为 1，客户端为随机正整数。信号：`peer_connected`、`peer_disconnected`；客户端另有 `connected_to_server`、`connection_failed`、`server_disconnected`。

### RPC 约束（易踩坑）

- 用 `@rpc` 注解声明；调用 `rpc()` 广播或 `rpc_id()` 指定。
- 函数必须**在客户端与服务端脚本中都存在**，且 **NodePath 与签名（`@rpc` 声明、函数名、返回类型、节点路径）一致**；签名不符时报错信息可能指向无关 RPC。
- 同一脚本内**所有** RPC 一起做校验，**即使当前未使用也必须两边都声明**。
- 常用参数组合：`@rpc("authority", "call_remote", "reliable", 0)`（服务端下发权威状态）；
  客户端上传输入用 `("any_peer", ..., "unreliable_ordered")`。
  本仓库固定用 `"call_remote"` 而非文档示例里的 `"call_local"`——因为服务端**不兼任玩家**，
  RPC 不需要在本地也执行一次；输入用 `unreliable_ordered` 而非 `reliable`（每 20Hz 覆盖，不需要重传）。
- 传输模式：`unreliable`（可丢、乱序）、`unreliable_ordered`、`reliable`（有性能代价）。可用 channel 隔离聊天与玩法消息。
- 只有在 `Node` 派生类上才能用高层 RPC；`Resource` 等非 Node 类会运行时报错。

## 二、安全（官方“Secure multiplayer design”）

- **服务端权威**：不信任客户端上报的位置、计时、冷却、资源值；客户端只发“输入/意图”，服务端校验后下发状态。
- 对频繁触发的动作加校验与限流；应用 RPC 参数前先验证。
- 鉴权：`SceneMultiplayer` 的 `auth_callback` + `complete_auth()`；两端都 `complete_auth()` 后才算连接建立并触发连接信号。未认证前不要开放 RPC。

## 三、专用服务器导出（官方）

- Godot 4 起无需专用二进制：`--headless` 即可以 headless 显示服务器 + Dummy 音频驱动运行。
- 导出预设 Resources 页选 **Export as dedicated server**：自动加 `dedicated_server` feature tag、强制 headless；可用 **Strip Visuals** 将纹理/材质替换为占位符以大幅减小 PCK，或 **Remove** 移除仅客户端资源（⚠️ 谨慎，被引用文件移除后场景无法加载）。
- 也可只导出 PCK，与同名导出模板二进制放一起运行。
- 启动判定（至少用一种，便于 CLI 联调）：
  - `OS.has_feature("dedicated_server")`（注意大小写敏感）
  - `DisplayServer.get_name() == "headless"`
  - `OS.get_cmdline_user_args()` 检查 `--server`

## 四、部署（官方 Next steps）

- Linux 常驻：用 **systemd** 服务实现崩溃/重启自启与日志轮转；开启 `application/run/flush_stdout_on_print` 项目设置，便于 journald 收集运行日志。
- 弹性伸缩：可用 **Docker** 封装专用服务器（官方指明在自动伸缩场景更易用，细节超出教程范围）。
- 数据路径：写文件一律用 `user://`（导出后 `res://` 只读）；`user://` 位置由 `application/config/use_custom_user_dir` 与 `custom_user_dir_name` 决定。
- 平台注意事项：Android 导出需在预设中开 `INTERNET` 权限；HTML5 下高层联网功能受限（仅 WebSocket/WebRTC）。

## 五、备选后端：Nakama（Heroic Labs）

- 开源游戏后端，提供官方 **Godot 4 客户端库**（`/docs/nakama/client-libraries/godot/`），覆盖账号、好友、分组(公会)、实时聊天、排行榜、存储、比赛/权威多人等。
- 部署方式：Docker Compose（`/docs/nakama/getting-started/install/docker/`）、Windows/macOS/Linux 安装；也有托管云 Heroic Cloud。
- 定位：适合作为元系统（账号/社交/榜单）后端，配合 Godot 内置 ENet 做玩法实时同步；不替代客户端-服务端玩法权威逻辑。

## 六、版本控制约定（Godot 工程通用实践）

- **提交**：`project.godot`、`*.tscn`、`*.gd` / `*.cs`、`*.import`、`*.uid`。
- **忽略**：`.godot/`（Godot 4 导入缓存）、导出产物（`*.pck`、`*.zip`、`build/`、`export/`）。
- 纹理/音频等资源必须连同 `.import` 一起提交，否则克隆后资源失效。

## 七、结论 / 建议默认方案

1. 玩法实时同步：Godot 内置高层多人（ENet/UDP）+ 服务端权威。
2. 专用服务器：单独导出预设（Export as dedicated server），Linux + systemd 常驻，Docker 备选。
3. 元系统：先用自建轻量服务，规模上来再接 Nakama。
4. 安全：客户端只发意图，全部在服务端校验；接入 `SceneMultiplayer` 鉴权。
