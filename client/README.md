# bb_client — BB Flutter client

Flutter 客户端，一套代码出 Linux/Windows 桌面与 Android APK（`linux/`、`windows/`、
`android/` runner 均已就位）。STEP-1 交付注册、登录、会话持久化；STEP-2 增加
**Profile（头像 / 昵称 / 签名）、三形态资料面板、六个 MCP 本地接口、服务端登出与心跳**；
STEP-3 增加**注册用户主页、一对一有序图文/独立附件、媒体选择/封面/播放/另存为、
幂等发送、异步下载、持久事件、展示凭据与消费 ACK**。STEP-3 细节见
`docs/chat-step3-client.md`。

```text
client/
  lib/main.dart              Flutter 入口（API 地址 / 会话 / 头像缓存目录）
  lib/app.dart               设计 tokens、ThemeData、根 Widget
  lib/ui/                    恢复中 / 登录 / 注册 / 首页 / Profile 面板与三形态外壳
  lib/services/              auth、profile、chat、媒体源、下载、持久事件、本地控制接口
  lib/models/                认证 + Profile + Chat DTO 与 {error:{code,message,fields}}
  lib/ui/chat/               用户列表、聊天页、有序输入区、气泡/附件、媒体动作
  lib/services/chat_ledger.dart  账号级 operation/download/event/receipt/ACK 持久账本
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

登录成功后进入 STEP-3 首页：当前服务器全部注册用户的逐行列表（含未联系用户），点行进入
一对一聊天；左下角头像仍打开 Profile。资料面板按视口分为三种形态：

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

## STEP-3 Chat 客户端

- **主页**：`GET /users` 的账号升序 keyset 分页（1–100），每行头像、username、在线状态、
  最后联系时间、最后消息“谁：预览”（本人显示“我”）；无历史显示“尚未联系 / 暂无消息”；
  30s 静默刷新 + 下拉刷新；列表按 account 路由，重名 username 不串会话。预览不下载附件原文件。
- **历史/并发**：初次加载连续拉取全部分页（不再固定 6×100 截断）；`_fetchedThrough` 只由
  连续服务器页推进，`_displayedMax` 仅表示本地已显示水位，本地发送不推动拉取游标；初始化/3s
  轮询/发送并发时统一按稳定 `id@position` 合并、排序、去重，补取中的新消息不会跳过 601–1000。
- **正文**：`POST /messages` 的 content 是有序 text/image；图片先由客户端上传为媒体资源，
  发送/存储/接收/UI/MCP read 均保持原顺序。空正文不发消息。
- **独立附件**：视频/音频/PDF 等走 `POST /messages/attachments`；消息只带元信息，默认不下载
  原文件；视频带真实封面（桌面 ffmpeg 抽帧、Android 项目内 `bb/video_cover` MethodChannel）。文件选择保留真实
  `path`，bytes-only 剪贴板/URI 来源会安全落临时文件再抽帧并清理。
- **幂等**：正文与每个附件各自使用稳定 operation id；重试复用同一 id，成功项不重发；
  409 冲突、uncertain 先查询再原样重试；部分成功保留成功项。
- **异步下载**：`/downloads/start` 立即返回 202 + 计划路径；`/downloads/get` 查询完成/失败；
  完成/失败事件写到发起任务的 consumer session；默认按媒体类型分 cache 子目录，重名追加
  序号，拒绝目录穿越，不静默覆盖。
- **持久事件/展示/ACK**：`/events/{subscribe,read,wait}`、`/chat/confirm_presentation`、
  `/chat/ack_messages`；receipt 绑定账号/consumer/peer/message/有序 blocks；未确认的位置
  ACK 返回 409 `consumption_gap`；下载完成不推进消息水位。
- **剪贴板**：桌面先尝试图片/视频二进制剪贴板目标，再解析 text/uri-list、file:// 或绝对路径
  （仅本地文件）；Android 通过 `bb/media_clipboard` 平台通道读取 ClipData content URI 的
  图片/视频。图片进入正文，视频进入带真实封面的独立附件；iOS 无本轮 runner，未接入。
- **在线播放**：附件到达只取封面；点击播放时才启动 `127.0.0.1` 随机 token 的 loopback 流代理，
  按播放器 Range 向带 Bearer 的 `/media/{id}` 透传，不预下载原文件。Android/iOS 用
  `VideoPlayerController.networkUrl` 在线播放；桌面把流 URL 交给系统播放器并保留“停止/取消”
  与重试；另存为仍是独立目录选择操作。桌面 GUI 播放未在本环境人工验收，见 NOT RUN。
- **UI**：日期/5 分钟时间分组、有序文本+图片、附件卡右击/长按“下载/播放/另存为”、
  输入区图片/文件/粘贴与草稿顺序、失败重试提示；手机 390×844、桌面 1440×900、折叠
  1024×768 均无溢出。

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
- 保留 `POST /auth/register`、`POST /auth/login`；STEP-2 六个 Profile 路由
  `POST /profile/{view_avatar,update_avatar,view_nickname,update_nickname,view_signature,update_signature}`
  （字段与错误码以 `server/contract/profile-local-schema.json` 和 49 组样例为准）。
- `view_avatar` 返回 `{account,mime_type:"image/png",data:<raw base64>,avatar_version}`；
  `update_avatar` 请求体上限 8 MiB，其余路由沿用 16 KiB；token 绝不出现在响应或日志。
- STEP-3 增加九工具 `/chat/list_users`、`/chat/send_message`、`/chat/send_attachment`、
  `/chat/read_messages`、`/chat/wait_messages`、`/chat/ack_messages`、`/downloads/start`、
  `/downloads/get`、`/operations/get`，以及 R3 内部路由 `/chat/confirm_presentation`、
  `/events/subscribe`、`/events/read`、`/events/wait`；后四条不导出为 MCP 工具。
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

- 默认 `flutter test`：最新严格 runner 为 **265 passed / 8 skipped / exit 0**。新增覆盖
  1000 条真实分页下发送/接收并发补取无缺口、events/wait limit 边界、原子展示确认/冲突/全组
  拒绝/重启幂等、新 consumer 独立补取、有序图文发送、幂等/冲突、read→receipt→ACK 缺口、
  附件只读元信息、异步下载内容、持久事件、wait 积压/提前到达、用户列表分页/预览/在线状态、
  图片/视频剪贴板、真实 ffmpeg 视频封面、点击在线流 Range 与“到达不请求原视频”。
- 严格命令：`QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client`
  → `RESULT=PASS`（analyze PASS、flutter-test PASS、linux-integration 13 PASS）。
- `test/qa_metrics_test.dart` / `qa_session_race_test.dart` 保留独立 QA 的失败回归：
  打开面板后实时缩放/折叠重排、旧会话延迟 401 不得清掉新登录会话。
- `test/qa_resize_transition_test.dart`、`profile_transition_reflow_test.dart` 保留并覆盖
  跨形态后的退出动画：mobile/folded 向左滑出（含 100ms 中间帧）、desktop 保持淡出/缩放、
  重排后继续编辑不丢资料。
- `test/standalone_entry_test.dart` 会真正启动 `dart run bin/bb_client_api.dart` 子进程：
  `--help` 必须 exit 0（QA-465-01 回归），本地登录后 1s 测试心跳自动开启，401 后内存与
  磁盘凭据都被清除且 token 不落日志。
- `integration_test/auth_flow_test.dart`：Linux 上真实 HTTP 的 STEP-1 流程 + STEP-2
  UI 链路 + STEP-3 用户主页→聊天→图片渲染→文本发送 + 真实 ffmpeg 粘贴视频生成封面并混排；
  `flutter test integration_test -d linux` 13 例通过。
- STEP-3 真实链路（需自行启动 `bb_server`）：`BB_LIVE_SERVER_URL=http://127.0.0.1:8171
  flutter test test/live_chat_e2e_test.dart`，覆盖真实 FastAPI 的有序图文、receipt/ACK、
  第三方 ACL、视频封面、异步下载与持久事件；本次实际 3 例通过。
- D1 在途身份固定：`/events/wait` 切换账号/同账号重登录返回空 `items`、原游标、
  `reason=cancelled`，登出 `logout`；read/媒体流/发送/下载固定发起 token，B 事件不泄漏。
- D2 下载终态：task 终态与 origin consumer 待交付事件在同一账本锁内提交；切换/重启后
  原账号补取，成功文件不会因事件失败被改成业务失败。
- D1 媒体流在途身份：HEAD probe / GET upstream await 后再次复核身份，切 B 返回 401，
  不输出 A 的 body/headers；新增 GET/HEAD 回归。
- D2 终态首次写盘失败：传输成功后独立提交账本终态，最多重试 3 次；持久化失败保留
  可恢复状态，绝不改记 `downloadFailed`；新增注入一次写盘失败后恢复成功的回归。
- D3 Android：移除不兼容的 `video_thumbnail`，项目内 `MediaMetadataRetriever` 抽帧；
  `flutter build apk --debug` 实际产出 APK（见 docs）。
- 真实 Dart/native R3 联调：`test-live-r3.py`（本地副本仅更新 client SHA 与 daemon 保护）
  **16/16 checks PASS, exit 0**；原 wait limit、冲突确认、缺口 ACK、新 consumer 积压四条失败
  全部消除，receipt→confirm→ACK、Dart 重启持久事件及 SIGKILL→continuation 单输出控制保留。
- 独立入口真实链路：启动 `dart run bin/bb_client_api.dart` 后经本地 `/auth/login` 与
  `/chat/*`、`/downloads/*`、`/events/*` 访问真实 FastAPI；本次实际 `STANDALONE CHAIN: PASS`。
- 真实链路（需自行启动 `bb_server`）：设置 `BB_LIVE_SERVER_URL`、`BB_MCP_PROBE=1` 与
  `BB_PROBE_PNG_BASE64` / `BB_PROBE_AVATAR_PATH` / `BB_PROBE_AVATAR_URL_PATH` 后运行
  `flutter test test/live_profile_e2e_test.dart`，走真实 MCP stdio → Dart 本地接口 → FastAPI。
- 独立入口真实链路：另设 `BB_LIVE_DB_PATH`，运行
  `flutter test test/live_standalone_mcp_e2e_test.dart`；测试启动独立 `dart run` 子进程，
  等待真实 30s 心跳落库，再由 MCP 六工具操作，最后服务端登出并验证 401 清凭据。

## 已知限制（本轮范围）

- 不做 token 过期/刷新；真正重新登录只有主动退出或服务端清理 24h 离线会话后 401。
- 不做群聊、好友申请/搜索、动态、产品已读回执、跨机器文件传输、附件自动解析。
- Android 真机与 Windows 构建/运行 **NOT RUN**；折叠屏形态为注入 `DisplayFeature` 的
  widget 渲染验证，未在真实折叠设备运行。Android 剪贴板通道已实现，但未在真机验证；
  Linux/Windows 的在线流交给系统播放器，桌面 GUI 实际播放未在本环境人工验收；这两项均
  如实 NOT RUN，不记 PASS。
- 事件日志不设有限内存丢弃窗口，长期清理策略未实现。
- 真实 DSH 模型展示、continuation、九工具真实 MCP 端到端仍由 Forge/集成 QA 验证，本客户端
  只覆盖本机 FastAPI 与本地 loopback 契约。
