# bb_client — BB Flutter client

Flutter 客户端，一套代码出 Linux/Windows 桌面与 Android APK（`linux/`、`windows/`、
`android/` runner 均已就位）。STEP-1 交付注册、登录、会话持久化；STEP-2 增加
**Profile（头像 / 昵称 / 签名）、三形态资料面板、六个 MCP 本地接口、服务端登出与心跳**。

```text
client/
  lib/main.dart              Flutter 入口（API 地址 / 会话 / 头像缓存目录）
  lib/app.dart               设计 tokens、ThemeData、根 Widget
  lib/ui/                    恢复中 / 登录 / 注册 / 首页 / Profile 面板与三形态外壳
  lib/services/              auth、profile、avatar 源与缓存、心跳、本地控制接口
  lib/models/                认证 + Profile DTO 与 {error:{code,message,fields}} 错误模型
  lib/validation/            与服务端一致的即时校验（服务端是唯一判定方）
  lib/config/                API base URL、本地接口地址、会话文件路径
  bin/bb_client_api.dart     独立 Dart 逻辑入口（Flutter UI 与本入口共用 services）
  test/                      单元 / widget / 真实 HTTP 桩 / 可选真实链路
  integration_test/          Linux 桌面端到端（真实 HTTP）与 STEP-2 Profile 流程
```

## 运行

```bash
flutter pub get
flutter run -d linux --dart-define=BB_API_BASE_URL=http://127.0.0.1:8000
```

登录成功后进入 STEP-2 首页：左下角头像打开 Profile。资料面板按视口分为三种形态：

- **手机（窄，< 600 逻辑像素）**：从左侧滑入，占满屏幕，左上角返回/系统返回键向左滑出；
- **折叠屏展开**：`MediaQuery.displayFeaturesOf` 中存在 `fold`/`hinge` 且
  `postureFlat` 时启用，用 `DisplayFeature.bounds` 作为切分点占左半屏，右半屏毛玻璃遮挡；
- **桌面（宽）**：居中浮动卡片（≤ 440px），不加黑色遮罩。

折叠判定永远优先于宽度断点；`didChangeMetrics`/`MediaQuery` 更新时展开、合拢会实时重排。

Linux 默认窗口 1180×780，Windows 同样 1180×780。Windows 构建/运行与 Android 运行在本
环境均为 **NOT RUN**：Windows 没有 MSVC 工具链、Android 没有模拟器/真机；Linux 截图不代表
这两个平台。

## 会话持久化与登出

登录成功后，客户端把 `{account, username, token}` 写入会话文件（**不含密码**），
重启时先读取该文件并调用 `GET /auth/session` 验证，验证通过才进入已登录页面：

| 服务端结果 | 行为 |
|---|---|
| `200 {account, username}` | 进入已登录页，账号信息以服务端返回为准 |
| `401 unauthenticated` | 清除本地凭据，回登录页并提示「登录已失效，请重新登录」 |
| 502/504（不可达/超时） | **保留**本地凭据，回登录页提示「暂时无法验证登录状态」并给「重试验证」，绝不显示为已登录 |
| 本地存储读写失败 | 统一返回 `500 session_storage_unavailable`：登录不报成功、恢复不进入已登录、退出失败保持已登录并提示 |

「退出登录」先调用服务端 `POST /auth/logout`（Bearer）删除当前 session 行，再清除本地
凭据并回登录页；服务端不可达时仍清本地凭据，并在登录页提示服务器未确认。
心跳每 30 秒一次 `POST /auth/heartbeat`：连续 3 次网络失败只显示「连接已断开，正在重连」，
**保留 token 与本地凭据，不退回登录页**；恢复后自动消失。只有 401 才清凭据回登录页。

会话文件位置（`BB_SESSION_FILE` 可覆盖，`--dart-define` 或环境变量均可）：

- Linux：`$XDG_DATA_HOME/bb/session.json` 或 `~/.local/share/bb/session.json`
- macOS：`~/Library/Application Support/BB/session.json`
- Windows：`%APPDATA%\BB\session.json`
- Android/iOS：应用私有 support 目录（`path_provider`）+ `session.json`

写入使用每次独立的临时文件再替换目标（POSIX 原子 rename；Windows 走备份-替换-回滚），
文件以 `0600`、父目录 `0700` 写入（POSIX），Windows 依赖用户配置文件 ACL。

## Profile 与头像缓存

- 服务端是头像唯一事实来源；客户端只在内存 + 磁盘缓存 PNG 与 `avatar_version`。
- 打开资料面板、读取他人资料、每次 MCP `view_avatar` 都会带 `If-None-Match` 重新校验：
  `304` 才复用缓存，`200` 立即覆盖；本人上传/删除成功后立即失效缓存。
- `PATCH /me/profile` 只发本步骤真正改动的字段；昵称 = username（trim 后 3–24 个
  Unicode code point），签名 trim 后 0–49，显式 `null` 表示清空。
- 头像三来源（互斥，必须且只能一个）：本机绝对路径、http(s) URL（客户端下载、手动逐跳
  校验重定向、超时、≤5MB、仅 PNG/JPEG/WebP）、原始或 `data:image/...;base64,`。
- 缓存目录默认是会话文件同级的 `avatar-cache/`，可用 `BB_AVATAR_CACHE_DIR` 覆盖。

## 本地控制接口（给 dsh-plugin）

独立于 Flutter 视图运行，与页面共用 `AuthService`、`ProfileService`、DTO、错误处理、
会话、校验与头像缓存：

```bash
dart run bb_client_api \
  --server-url http://127.0.0.1:8000 \
  --host 127.0.0.1 --port 8787 \
  --session-file ~/.local/share/bb/session.json \
  --avatar-cache-dir ~/.local/share/bb/avatar-cache
# 等价环境变量：BB_API_BASE_URL / BB_CLIENT_HOST / BB_LOCAL_API_PORT /
#               BB_SESSION_FILE / BB_AVATAR_CACHE_DIR
```

- 只允许监听 `127.0.0.1`，非回环地址以退出码 64 拒绝；端口 0 由系统分配。
- 保留 `POST /auth/register`、`POST /auth/login`；新增六个 Profile 路由
  `POST /profile/{view_avatar,update_avatar,view_nickname,update_nickname,view_signature,update_signature}`
  （字段与错误码以 `server/contract/profile-local-schema.json` 和 49 组样例为准）。
- `view_avatar` 返回 `{account,mime_type:"image/png",data:<raw base64>,avatar_version}`；
  `update_avatar` 请求体上限 8 MiB，其余路由沿用 16 KiB；token 绝不出现在响应或日志。
- 非约定路径 `404`，非 POST `405`，非法 JSON/未知字段/长度错误 `422`，媒体类型 `413/415`，
  上游不可达/超时 `502/504`。
- 启动会恢复会话并在已登录时开始心跳；**MCP/本地 `/auth/login` 成功后同样立即启动 30s 心跳**，
  不要求重启入口。
- 认证路由收到真正的 `401 unauthenticated`（不是 `invalid_credentials`）时，清空内存会话与
  磁盘凭据并停止心跳；网络失败仍只累计漏拍。
- 心跳核心是纯 Dart（无 `package:flutter`），独立入口可直接 `dart run`；Flutter UI 只作为
  listener 使用，不拥有定时器。

`dsh-plugin/` 只调用本地路由，**必须显式设置** `BB_CLIENT_BASE_URL`，不直连 FastAPI、
不重试、不接触任何会话凭据。

## 测试

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter test integration_test -d linux
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client
```

- 默认 `flutter test`：193 例通过，4 例按环境 SKIP（真实 FastAPI 认证、真实 MCP 链路、
  真实独立入口链路、截图生成）。覆盖 49 组共享契约样例、Unicode code point 计数、三来源
  读取与校验、缓存 304/200 刷新、六条本地路由与 16 KiB/8 MiB 边界、心跳断线保留凭据、
  三形态 Profile 面板与编辑/登出流程。
- `test/standalone_entry_test.dart` 会真正启动 `dart run bin/bb_client_api.dart` 子进程：
  `--help` 必须 exit 0（QA-465-01 回归），本地登录后 1s 测试心跳自动开启，401 后内存与
  磁盘凭据都被清除且 token 不落日志。
- `integration_test/auth_flow_test.dart`：Linux 上真实 HTTP 的 STEP-1 流程 + STEP-2
  Profile 编辑、头像上传、服务端登出；`flutter test integration_test -d linux` 8 例通过。
- 真实链路（需自行启动 `bb_server`）：设置 `BB_LIVE_SERVER_URL`、`BB_MCP_PROBE=1` 与
  `BB_PROBE_PNG_BASE64` / `BB_PROBE_AVATAR_PATH` / `BB_PROBE_AVATAR_URL_PATH` 后运行
  `flutter test test/live_profile_e2e_test.dart`，走真实 MCP stdio → Dart 本地接口 → FastAPI。
- 独立入口真实链路：另设 `BB_LIVE_DB_PATH`，运行
  `flutter test test/live_standalone_mcp_e2e_test.dart`；测试启动独立 `dart run` 子进程，
  等待真实 30s 心跳落库，再由 MCP 六工具操作，最后服务端登出并验证 401 清凭据。

## 已知限制（本轮范围）

- 不做 token 过期/刷新；真正重新登录只有主动退出或服务端清理 24h 离线会话后 401。
- 不做好友/搜索/在线状态展示/头像裁剪/相册/聊天/动态/推送；「查看其他账号资料」是本轮
  为验证缓存刷新保留的最小入口。
- Android 真机与 Windows 构建/运行 **NOT RUN**；折叠屏形态为注入 `DisplayFeature` 的
  widget 渲染验证，未在真实折叠设备运行。
