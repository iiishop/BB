# STEP-3 客户端实现说明（Muse）

状态：客户端实现交接，不是独立 QA 或产品验收。基线为 Orion 给定的
`12ce1c054286315f76d7b38143060add6f3c39d2`（共同交接契约 R3），工作分支
`agent/muse/dea466-chat-client-r3`。只改 `client/`；`server/`、`dsh-plugin/`、
共享 schema 未改。

## 1. 交付范围

- 默认主页改为“当前服务器注册用户列表”（含未联系用户），保留左下角本人 Profile 入口。
- 一对一聊天：有序 text/image 正文；视频/音频/PDF 等独立附件；媒体选择、粘贴、视频封面、
  播放、另存为。
- 幂等发送：正文与每个独立附件各自使用稳定 `operation_id`；重试复用同一个 ID；已成功项
  不重发；部分成功保留成功项。
- 异步下载：提交立即返回 `task_id`/状态/计划路径；完成或失败可查询；下载完成事件归属
  发起下载的 consumer session。
- 持久事件流：`/events/subscribe`、`/events/read`、`/events/wait`；客户端把服务器事件
  补取并落入账号/consumer 级持久日志。
- 展示凭据与 ACK：`VisibleMessage.presentation`、`/chat/confirm_presentation`、
  `/chat/ack_messages` 显式 through-position；未确认位置报 `consumption_gap`。
- 完整保留 STEP-1 登录持久化、STEP-2 Profile/登出/心跳和三形态资料面板回归。

## 2. 文件结构

```text
client/lib/models/chat_models.dart         消息/用户/附件/下载/事件/凭据 DTO 与严格解析
client/lib/services/chat_api_client.dart   服务端 REST + 媒体 multipart/Range + 事件分页
client/lib/services/media_source.dart      path/url/base64/bytes 解析、MIME magic、封面抽取
client/lib/services/chat_ledger.dart       原子 JSON 账本：operation/download/event/receipt/ACK
client/lib/services/chat_service.dart      有序发送、幂等重试、read/wait/ACK/展示凭据
client/lib/services/download_manager.dart  预留路径、唯一命名、后台下载、完成/失败事件
client/lib/services/event_feed.dart        服务端事件补取到持久本地事件日志
client/lib/services/local_auth_server.dart 九工具 + R3 内部路由（保留 auth/profile）
client/lib/ui/chat/users_view.dart         注册用户列表、预览、在线状态、分页/刷新
client/lib/ui/chat/chat_page.dart          消息时间分组、附件卡、下载/播放/另存为
client/lib/ui/chat/chat_composer.dart      有序草稿、图片/文件、粘贴、失败重试
client/lib/ui/chat/message_bubble.dart     正文按序 text/image、附件卡、上下文菜单
client/lib/ui/chat/media_actions.dart      file_selector、剪贴板图片、视频封面、系统打开
client/lib/ui/home_view.dart               主页切换为用户列表（chat 非空时）
client/lib/main.dart / bin/bb_client_api.dart  共用同一 ChatService 与本地接口
```

## 3. 契约映射

### 3.1 服务端 REST（客户端调用）

| 用途 | 调用 |
| --- | --- |
| 注册用户列表 | `GET /users?after_account&limit` |
| 有序正文 | `POST /messages {target_account,client_nonce,content}` |
| 独立附件 | `POST /messages/attachments {target_account,client_nonce,media_id}` |
| 一对一历史 | `GET /conversations/{account}/messages?after_position&limit` |
| 操作查询 | `GET /operations/{operation_id}` |
| 媒体上传 | `POST /media` multipart `target_account,file,cover_media_id?` |
| 媒体读取 | `GET /media/{id}`（Bearer；Range 用于 probe，原文件不预下载） |
| 事件补取 | `GET /events?after_event_id&limit` |
| 事件提示 | `WS /events`（仅提示；持久事实仍来自 GET） |

### 3.2 本地控制接口（loopback，给 dsh-plugin）

保留的九工具：`POST /chat/list_users`、`/chat/send_message`、`/chat/send_attachment`、
`/chat/read_messages`、`/chat/wait_messages`、`/chat/ack_messages`、
`/downloads/start`、`/downloads/get`、`/operations/get`。

R3 新增内部路由（不导出为 MCP 工具）：

- `POST /chat/confirm_presentation {consumer_session,attempt_id,request_digest,receipt_ids}`
  → `{confirmed_receipt_ids}`；未知 404、跨会话 409、同 attempt 重试幂等。
- `POST /events/subscribe {consumer_session,peer_account}` → 同名字段；注册不等于消费。
- `POST /events/read {consumer_session,after_cursor,limit=1..100}` →
  `{items:[{cursor,event}],next_cursor,has_more}`。
- `POST /events/wait {consumer_session,after_cursor,timeout:30|60|120}` → 同页字段 +
  `reason:events|timeout|cancelled|logout|disconnected`。

`send_message` 的有序内容支持 `{type:"text",text}` 和
`{type:"image",source:{base64|path|url,mime_type,filename}}`，由客户端解析并上传；
插件不直接访问文件/URL。`send_attachment` 支持 `source` 与可选 `cover`；视频无封面时
客户端用真实帧抽取，失败则明确拒绝发送。

## 4. 有序发送与幂等

1. 客户端把输入拆为正文（保留 text/image 相对顺序）与独立附件（视频/音频/PDF/其他）。
2. 正文先发送，再按原顺序逐项发送附件。
3. 正文 operation id = 批次种子 `-b`；附件 = `-a0`、`-a1`…；重试沿用。
4. 每个 operation 的 source digest 在首次提交前持久化；同 ID 不同目标/内容/kind → 409。
5. 图片先上传为不可变媒体资源，并把 media id 持久化到 operation；再次重试不重传。
6. 网络超时/502/504 视为 `uncertain`：先 `GET /operations/{id}` 对账，404 才用同一
   nonce 重发；两次仍不确定保持 `uncertain`，不伪装失败或成功。
7. 修正后的内容必须使用新的 operation id；已成功的 operation 再次调用直接返回原消息。

## 5. 媒体与展示

- 正文图片：客户端上传/读取并显示；MCP read 返回真实 `image` block（base64 + MIME），
  按原顺序夹在 text block 之间。
- 独立附件：消息只带元信息；`read_messages` 返回文本摘要，视频额外返回真实 cover image
  block；不下载原文件。
- 视频封面：桌面用 `ffmpeg` 抽取首帧；Android 用 `video_thumbnail`；无法抽取时发送失败。
- 播放：Android/iOS 用 `video_player`；Linux/Windows 下载后交给系统默认播放器
  （`xdg-open` / `cmd start` / `open`）。Linux 不使用 `video_player`，因为该插件没有
  Linux 实现。
- 另存为：`file_selector.getSaveLocation`，用户选目录/文件名；已存在时追加 ` (2)` 后缀，
  不静默覆盖；Agent 下载支持指定目录，默认按媒体类型分到 cache 子目录
  `images/videos/audio/documents/other`。
- 粘贴图片：Linux 依次尝试 `wl-paste` / `xclip` / `xsel`；缺少工具时明确提示不支持。
  Android/iOS 的图片剪贴板本轮为 **NOT RUN**（Flutter 平台通道只暴露文本）。

## 6. 展示凭据与消费 ACK

- 每次 `read_messages` / `wait_messages` 为每条消息返回
  `presentation:{receipt_id,content_digest}`。receipt 绑定当前登录 account + consumer +
  peer + message/position + 有序 blocks 摘要，持久化并可重复读取复用。
- `confirm_presentation` 只在插件确认“实际模型请求成功响应”后调用；客户端收到确认后
  持久化 `confirmed=true` 与 attempt 记录。读取/入队/返回工具结果本身不等于展示。
- `ack_messages` 必须覆盖从当前 consumed+1 到 through 的每一个位置；任一位置没有
  confirmed receipt → 409 `consumption_gap`。重复较小位置幂等；之后的新消息不被清除。
- 下载完成/失败不推进消息消费水位。

## 7. 持久事件

- 服务器 `GET /events` 只是事实来源；客户端把可读的 `message.available` 补取到
  account+consumer 持久日志，按源 event_id 去重，读/等待都不改消费水位。
- subscribe 只注册 consumer↔peer，不把注册当作历史已消费。
- `events/read` 从 after_cursor 读取；`events/wait` 先检查积压再等待，revision 计数闭合
  “读与等待之间到达”的间隙；超时原因明确为 timeout，不伪装成空成功。
- 下载完成/失败使用创建任务时的 consumer_session 写入同一条日志，补取后仍可唤醒原会话。

## 8. UI/UX

- 仍使用 STEP-2 的暖纸/墨色/单一 teal 设计 tokens：`AppColors`、`AppSpacing`、
  `AppRadius`；没有新增平行主题。
- 主页：`BB` 品牌行 + 账号 + “消息”标题 + 全部注册用户逐行列表；行内头像、username、
  在线点、最后联系时间、“谁：预览”（本人显示“我”），无历史显示“尚未联系 / 暂无消息”。
  列表按 account 升序 keyset 分页（limit 1–100），30s 静默刷新，支持下拉刷新和“加载更多”。
- 聊天页：日期分组 + 5 分钟时间分隔；正文 text/image 严格按序；附件卡显示类型/文件名/
  大小/视频封面；右键/长按菜单“下载/播放/另存为”；空态、加载、错误、断线横幅沿用既有组件。
- 输入区：图片/附件/粘贴按钮 + 1–5 行输入框 + 发送；草稿条按插入顺序显示 text/image 与
  独立附件，可单项删除；部分失败保留失败项并显示“重试不发已成功项”。
- 视口：手机 390×844、宽屏 1440×900、折叠注入 `DisplayFeature` 1024×768 均无溢出；
  主页列表最大宽度 760，聊天最大宽度 860。

## 9. 实际执行与证据

以下命令均在本次工作副本真实执行，使用本机 Flutter 3.47.9 / Dart 3.13.7。

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | `No issues found!`，exit 0 |
| `QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client` | `RESULT=PASS`，exit 0；analyze PASS、flutter-test 241 passed/8 skipped、linux-integration 12 passed |
| `flutter test test/live_chat_e2e_test.dart`（`BB_LIVE_SERVER_URL=http://127.0.0.1:8171`，真实 FastAPI） | 3 tests passed，exit 0：有序图文、真实 blocks、receipt→ACK 409/通过、第三方 ACL、附件元信息、视频封面、异步下载文件内容、持久事件、wait 积压/提前到达 |
| 独立 `dart run bin/bb_client_api.dart` + 真实 FastAPI | `STANDALONE CHAIN: PASS`：本地登录、list_users、有序发送/重放、read/confirm/ACK、附件上传、`downloads/start` 202→`get` succeeded、`operations/get`、`events/subscribe/read/wait`、`wait_messages` 积压 |
| `uv run --project server --locked pytest server/tests -q --tb=short` | 103 passed，exit 0（仅既有弃用警告） |
| 截图测试 | 6 张 390×844 / 1440×900 / 1024×768（含 hinge）PNG，见 `client/.qa-artifacts/screenshots/` |

截图是 Flutter widget-test raster，不是 Android/Windows 运行截图；真实设备验收仍由
Owner/独立 QA 执行。

## 10. NOT RUN / 已知限制

- **Android / Windows 运行**：本环境无模拟器/真机、无 MSVC；一律 NOT RUN。
- **物理折叠设备**：只注入 `DisplayFeature` 渲染，没有真实折叠硬件运行。
- **真实模型/视觉/DSH 回合**：客户端只验证本机 FastAPI 与本进程事件/凭据/下载链；
  DSH 插件的真实模型展示、continuation、跨重启调度由 Forge/独立 QA 验证。
- **真实 MCP 插件链**：Nine-tool 本地契约由 Dart 测试覆盖；真实 dsh-plugin MCP 进程
  端到端仍 NOT RUN（属于 Forge/集成 QA）。
- **Android 图片剪贴板**：平台限制，NOT RUN。
- **Linux 内嵌视频播放**：`video_player` 无 Linux 实现，改为系统播放器；这是平台差异，
  不是“已通过 Linux 内嵌播放”。
- **分页上限**：聊天初始加载最多 6 页×100 条；更早历史不自动补拉，后续可扩展“加载更早”
  （不影响发送/读取/ACK 语义）。
- **事件日志不设丢弃窗口**：按契约保留，避免有限内存缓存丢旧事件；长期运行的清理策略
  未在本步实现。
- 服务器/共享 schema 未改；若 R3 正式 schema 字段名有差异，以 Forge 的共享 schema 为准，
  客户端再进行对齐（当前按 R3 文档实现）。

## 11. 本地运行

```bash
# 真实 FastAPI（示例）
BB_DATABASE_PATH=... BB_AVATAR_DIRECTORY=... BB_MEDIA_DIRECTORY=... \
BB_HOST=127.0.0.1 BB_PORT=8000 uv run --project server --locked bb-server

# Flutter
flutter run -d linux --dart-define=BB_API_BASE_URL=http://127.0.0.1:8000

# 独立 Dart 逻辑入口（MCP 使用）
dart run bb_client_api --server-url http://127.0.0.1:8000 \
  --port 8787 --session-file /abs/session.json \
  --avatar-cache-dir /abs/avatar-cache
```

`chat-ledger.json` 与 `chat-cache/` 默认位于会话文件同级目录；可用
`BB_CHAT_CACHE_DIR`（Flutter 编译期 `--dart-define` 或独立入口环境变量）覆盖缓存目录。
