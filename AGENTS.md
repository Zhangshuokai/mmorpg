# AGENTS.md

目标：基于 **Godot 4** 的类《魔兽世界》MMORPG（大型多人在线、服务端权威）。

## 仓库现状（重要）

- 这是**空仓库**：`main` 无任何提交，工作区内只有 `.kilo/`，没有 `project.godot`、代码或 `README`。
- 所有 Godot 命令都要在**项目初始化（存在 `project.godot`）之后**才有效；动手前先确认工程是否已建。
- 尚无根 `.gitignore`，只有 `.kilo/.gitignore`（仅作用于 `.kilo/`，且内容与 Godot 无关）。

## 技术栈默认选择（尚未在代码中固化，按此执行，除非用户另有指示）

- 引擎：Godot **4.x**。
- 脚本：优先 **GDScript**（官方文档与社区资源最全）；不要在同一套网络/RPC 逻辑里混用 GDScript 与 C#。
- 联网：先用 Godot 内置**高层多人 API**（ENet/UDP）实现服务端权威；账号、好友、公会、聊天、排行榜等元系统可后接 **Nakama**（Heroic Labs 开源后端，提供官方 Godot 4 客户端库与 Docker 部署）。

## 联网/架构要点（来自官方文档，别想当然）

- Godot 高层多人走 **UDP**：公网联机需在防火墙/路由器放行**UDP**端口，只开 TCP 无效。
- RPC 按 **NodePath + 签名校验**绑定：函数必须同时存在于客户端与服务端脚本，同名、同路径、同 `@rpc` 声明，**即使当前未使用也要两边都声明**，否则报错信息可能指向无关的 RPC。
- **服务端权威**：绝不信任客户端上报的位置/伤害/背包。客户端只发“输入/意图”，服务端校验后再下发状态。
- 鉴权用 `SceneMultiplayer` 的 `auth_callback` + `complete_auth()`，不要开放未认证的 RPC。

## 专用服务器与部署

- 导出：单独建“服务端”导出预设，Resources 页选 **Export as dedicated server**（自动加 `dedicated_server` feature tag、强制 headless，并可用 *Strip Visuals* 减小 PCK）。
- 启动判定：`OS.has_feature("dedicated_server")`、`DisplayServer.get_name() == "headless"`，或自定义参数（`OS.get_cmdline_user_args()` 检查 `--server`）。
- 写文件一律用 `user://`；导出后 `res://` 只读。
- Linux 常驻：systemd 服务 + 开启 `application/run/flush_stdout_on_print=true`（便于 journald 收集日志）；需要弹性伸缩再用 Docker 封装服务端。

## 版本控制（Godot 工程约定）

- 提交：`project.godot`、`*.tscn`、`*.gd` / `*.cs`、`*.import`、`*.uid`。
- 忽略：`.godot/`（Godot 4 导入缓存）、导出产物（`*.pck`、`*.zip`、`build/`、`export/`）。
- 纹理/音频等资源必须连同 `.import` 一起提交，否则他人克隆后资源失效。

## 常用命令（工程建立后按需补充）

- 运行专用服务端：`godot --headless -- --server`（前提：已实现 `--server` 启动分支）。
- 本机联调：一个实例 `godot --headless -- --server`，另一个实例连 `127.0.0.1`。
- 校验：Godot 无独立 lint/typecheck；改动后在编辑器内运行场景，或 CLI 跑对应场景确认无解析/加载错误。

## 参考链接

- 服务端导出：https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html
- 高层多人：https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html
- 中文文档：https://docs.godotengine.org/zh-cn/4.x/
- Nakama Godot 4 客户端：https://heroiclabs.com/docs/nakama/client-libraries/godot/
