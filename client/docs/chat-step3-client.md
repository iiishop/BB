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
client/lib/services/media_stream_proxy.dart 点击播放的 loopback Range 流代理
client/lib/services/local_auth_server.dart 九工具 + R3 内部路由（保留 auth/profile）
client/lib/ui/chat/users_view.dart         注册用户列表、预览、在线状态、分页/刷新
client/lib/ui/chat/chat_page.dart          消息时间分组、附件卡、下载/播放/另存为
client/lib/ui/chat/chat_composer.dart      有序草稿、图片/文件、粘贴、失败重试
client/lib/ui/chat/message_bubble.dart     正文按序 text/image、附件卡、上下文菜单
client/lib/ui/chat/media_viewer.dart       DEA-471 全屏查看器、跨消息媒体序列、原图进度/重试
client/lib/ui/chat/media_save.dart         相册（MediaStore/Photos 预留）与桌面另存为分流
client/lib/ui/chat/viewer_video.dart       查看器内嵌视频会话、流字节进度与失败重试
client/lib/config/media_policy.dart        100 KiB 直出原图/缩略图边界（集中定义）
client/lib/models/chat_media.dart          会话媒体序列、稳定排序与索引查找
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
| 媒体读取 | `GET /media/{id}`（Bearer；原文件/Range；`?variant=thumb` 有界缩略图） |
| 媒体元信息 | `GET /media/{id}/metadata`（byte_size/mime/filename，不下载原文件） |
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
- 视频封面：文件选取保留真实 `path`；bytes-only 剪贴板/URI 来源先安全落临时文件，桌面用
  `ffmpeg` 抽取首帧、Android 用 `video_thumbnail`，完成后删除临时文件；无法抽取时明确拒发。
- 播放：**点击才建立** loopback 流会话，`MediaStreamProxy` 生成随机 token 的
  `http://127.0.0.1:<port>/stream/<token>`，按播放器 Range 请求带当前 Bearer 透传到
  `/media/{id}`，不预下载原文件。Android/iOS 用 `VideoPlayerController.networkUrl` 在线播放；
  Linux/Windows 将流 URL 交给系统播放器，并保留取消/停止、错误提示和重试。播放器失败时关闭
  流；另存为仍是独立操作。
- 另存为：`file_selector.getSaveLocation`，用户选目录/文件名；已存在时追加 ` (2)` 后缀，
  不静默覆盖；Agent 下载支持指定目录，默认按媒体类型分到 cache 子目录
  `images/videos/audio/documents/other`。
- 剪贴板：桌面先尝试 image/png、image/jpeg、video/mp4、video/webm 的二进制剪贴板目标
  （`wl-paste`/`xclip`），再解析 text/uri-list、`file://` 与绝对路径，只接受本地图片/视频；
  Android 通过 `bb/media_clipboard` 平台通道读取 ClipData 的 `content://` URI、MIME、
  文件名与字节，校验大小后进入同一草稿逻辑。图片进入正文，视频进入独立附件并真实抽封面。
  iOS 无本轮 runner，未接入；Android 真机仍需单独验证。

### 5.1 全屏查看器与大图懒加载（DEA-471）

契约来源：Forge 的 `docs/contracts/dea471-media.md` 与
`server/contract/src/bb_auth_contract/media.py`（`variant=thumb`、512 边上限、≤64 KiB JPEG、
ETag/304、415/503 错误）。客户端只消费契约，不改 `server/contract`。

- 序列：`buildConversationMedia` 按消息 `position`、再按消息内 `ImagePart` 顺序展开正文图片与
  图片/视频附件；点击项精确打开，左右滑动跨消息，顶部显示「第 N / 共 M」、发送者与时间，
  下滑或关闭/返回键退出。历史未完整加载时显示「仅显示已加载的 N 项」与重试，不虚报总数。
- 尺寸判定：正文图片只有 media_id，先取 `GET /media/{id}/metadata`；`<= 100 KiB`（含边界）
  直接取原图，`> 100 KiB` 取 `?variant=thumb` 作为列表与查看器首屏。阈值集中在
  `media_policy.dart`；元信息失败可重试，不当作小图直接拉原图。
- 原图：查看器左下角显示「原图 3.0 MB」，点击才 `GET /media/{id}`，按收到的字节/总长度显示
  百分比；失败回到「重试 原图 …」，不展示半张图。原图只在当前查看页面持有，不进入共享预览
  缓存；原图/缩略图/元信息缓存键均含 server/account/media/variant，和头像缓存分开，
  缩略图失败不会回退成远端原图。
- 保存：Android 通过 `bb/media_gallery` 通道写 MediaStore（`Pictures/BB`、`Movies/BB`，
  `bb_<timestamp>_<原名>`；API ≤ 28 运行时申请写权限），iOS 预留 `saveToPhotos` 接口；
  Linux/Windows 继续 `getSaveLocation`。成功提示带相册位置或完整路径，取消不提示。
- 视频：到达与打开查看器只取封面；中央播放才创建查看器内的 `StreamingViewerVideoSession`，
  经既有 loopback Range 流由 `video_player` 播放；失败可在查看器内重试，关闭或切页会释放
  播放器与流。释放顺序是先关闭已建立的 loopback 句柄，再异步 dispose 播放器：原生
  `createWithOptions` 尚未返回时关闭不会阻塞流释放，迟到的创建被 generation 丢弃。
  Android/iOS/macOS 使用官方 `video_player`；Linux/Windows 通过新增的 `fvp: 0.40.0` 提供
  同一 `video_player` 平台实现（随包 MDK 预编译库，不依赖系统 libmpv，不升级既有
  `video_player` 版本；`pubspec.lock` 只新增 `fvp`）。测试仅把锁文件已有的
  `video_player_platform_interface: 6.9.0` 提升为 dev 依赖，不改变版本。
- 进度语义：`MediaStreamProxy` 同时上报本次 Range 的 `requestBytes`/`receivedBytes` 与
  `Content-Range` 的整媒体 `mediaBytes`；生产会话收到第一块字节后进入 buffering，查看器
  显示「缓冲中…」+「本次 Range 接收 X / Y」，整段缓冲单独显示播放器 `buffered/duration`
  的「已缓冲 N%」。短 Range 完成绝不会被显示成整段视频 100%；1 字节 `probeMedia` 只用于
  大小/MIME 探测，不作为播放进度。
- 发送端本地预览：ChatComposer 把成功提交的正文图片 media id 映射回当前仍持有的本地 bytes，
  ChatPage 按当前账号绑定并做 8 条/24 MiB LRU；列表与查看器优先使用这些 bytes，不因衍生图
  未就绪而重新请求远端大图。接收端元信息/缩略图失败仍只显示占位与重试，不请求原图。
- 验证（固定基线 `452e88e`，契约 `agent/forge/9e751f104948` @ `fa876b9`）：
  - `flutter analyze`：0 issue。
  - `flutter test`：393 passed / 7 skipped。7 个 skip 的适用范围：
    1 个 DEA-471 live 契约用例（`BB_LIVE_SERVER_URL` 未设置）、3 个既有 live chat 用例、
    1 个既有 live auth 用例、1 个聊天截图用例（`QA_CHAT_SCREENSHOT_DIR` 未设置）、
    1 个 Profile 截图用例（`QA_SCREENSHOT_DIR` 未设置）；都不是本机代码失败。
  - 定向 25 tests：媒体序列/阈值、查看器导航与下载进度/重试/跨页隔离、聊天页接入、
    相册/桌面保存分流、server/account/media/variant 缓存隔离与缩略图失败不回退原图、
    发送端本地预览、查看器内嵌视频进度/重试/切页释放、真实 loopback Range 的请求/整媒体双计数，
    以及 production session 的「4/8 字节进入 buffering + Range 文案」与「原生 create 挂起时
    关闭先释放流」两条回归。
  - `BB_LIVE_SERVER_URL=http://127.0.0.1:8171 flutter test test/live_media_contract_test.dart`：
    1 passed；真实 Forge 服务端验证 metadata byte_size、512 边/≤64 KiB JPEG 缩略图、
    小图直取原图、原图字节一致、`Range bytes=0-0` 206 且总长正确、第三账号 404。
  - `flutter test integration_test -d linux`：14 passed；除查看器打开/关闭外，新增真实 FVP
    用例：点击播放后出现 `VideoPlayer` 画面、position 从 00:00 前进、服务端收到非
    `bytes=0-0` 的真实 Range；切到下一张后视频请求停止，返回视频页播放会重新打开流；
    关闭后退出查看器。
  - `flutter build linux --debug`：FVP/MDK 预编译库随包构建通过，Linux 包内有 libmdk/libffmpeg。
  - `flutter build apk --debug`：编译通过（Kotlin 通道与 fvp Android 插件打包）；真机仍 NOT RUN。
  - 截图：`.qa-artifacts/screenshots/dea471-media-viewer.png`，420×900 widget 渲染，
    不是 Android/Windows 运行截图。

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

## 11. 实际执行与证据

以下命令均在本次工作副本真实执行，使用本机 Flutter 3.47.9 / Dart 3.13.7。

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | `No issues found!`，exit 0 |
| `QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client` | `RESULT=PASS`，exit 0；analyze PASS、flutter-test 274 passed/8 skipped、linux-integration 13 passed |
| `flutter test test/live_chat_e2e_test.dart`（`BB_LIVE_SERVER_URL=http://127.0.0.1:8171`，真实 FastAPI） | 3 tests passed，exit 0：有序图文、真实 blocks、receipt→ACK 409/通过、第三方 ACL、附件元信息、视频封面、异步下载文件内容、真实 Range 在线流、持久事件、wait 积压/提前到达 |
| 真实 FastAPI 在线流 | `MediaStreamHandle` 以 `bytes=0-3` 请求真实 `/media/{id}` 返回 206 且字节一致；到达阶段未请求原视频 |
| 独立 `dart run bin/bb_client_api.dart` + 真实 FastAPI | `STANDALONE CHAIN: PASS`：本地登录、list_users、有序发送/重放、read/confirm/ACK、附件上传、`downloads/start` 202→`get` succeeded、`operations/get`、`events/subscribe/read/wait`、`wait_messages` 积压 |
| `test-live-r3.py`（集成基线脚本本地副本，仅把固定 client SHA 更新为被测 SHA，并加 daemon PID 已退出保护；断言未改） | **16/16 checks PASS / exit 0**：原 4 条失败（wait limit 422、冲突确认 200、缺口 ACK 200、新 consumer 0 条）全部消除；receipt→confirm→ACK、未展示 B 409、Dart 重启持久事件、SIGKILL→continuation→两次重放仅 1 条输出等正向控制保留 |
| `uv run --project server --locked pytest server/tests -q --tb=short` | 103 passed，exit 0（仅既有弃用警告） |
| 截图测试 | 6 张 390×844 / 1440×900 / 1024×768（含 hinge）PNG，见 `client/.qa-artifacts/screenshots/` |

真实 R3 联调使用集成版本 `dsh-plugin/runtime-patch/test-live-r3.py`。仓库内共享脚本仍固定校验旧 client `c684e29…`，且顶部 `os.getpgid(daemon_pid)` 在本次 runtime 的 daemon PID 已退出时会抛 `ProcessLookupError`；因此本轮在**未提交的本地副本**中只更新 client SHA 与 daemon 存活保护，未修改任何断言或产品代码。共享脚本的 PIN 需 Forge/Orion 在最终统一版本更新。

截图是 Flutter widget-test raster，不是 Android/Windows 运行截图；真实设备验收仍由
Owner/独立 QA 执行。

## 11.1 D1–D4 返工（Sentinel REJECT）

### D1 请求身份固定
- `AuthSession` 增加不可变 `AuthIdentity {account, token, generation}`：只在 establish/clear
  递增 generation，`updateUser`（昵称刷新）不递增。in-flight `wait`/`read`/chat `wait_messages`/
  媒体流/发送/下载均固定发起时的 account、token 与 generation，所有 `await` 后复核；
  绝不改用“当前账号”的 token。
- `/events/wait` 在账号切换、A→B→A、同账号重新登录时返回空 `items`、原 `after_cursor`、
  `reason=cancelled`；登出返回 `reason=logout`；请求开始即未认证仍 401。
- 旧请求不会返回 B 的 event 元数据、不推进 B 游标、不清理 B 的新登录；媒体流每次 loopback
  GET 复核身份并固定原 token；媒体缓存按 account 分区。
- 新增 `test/auth_identity_boundary_test.dart`（6 例：切换、A→B→A/重登录、登出、昵称刷新、
  在途 read、媒体流）。

### D2 下载终态持久归属
- `ChatLedger.finishDownload` 在单次锁内把“原 account+consumer 的 task 终态”和
  `pending_events` 待交付记录原子写入；`deliverPendingEvents` 再把 pending 追加到该账号
  source feed 并清除标记，一次 flush，失败整体回滚。
- `DownloadManager` 使用开始任务时捕获的 token；完成/失败无论当前登录是谁都写原账号。
  event 落库失败只保留 pending，不把成功文件改成业务失败；切回原账号 `get/read` 或重启会
  补取；公开 `get` 仍只查当前账号。
- 新增 `test/download_terminal_event_test.dart`（成功/失败事件 origin 归属、B 不可见、
  `get` 修复已保存但事件缺失的旧任务）。

### D3 Android debug 构建
- 移除 `video_thumbnail` 依赖（其 jcenter/旧 AGP 配置与 AGP9/Kotlin2.4 不兼容），改为项目内
  `bb/video_cover` Android MethodChannel：`MediaMetadataRetriever` 抽取首帧并 PNG 编码；
  保留真实视频封面功能，不修改全局 SDK/pub 缓存。
- `android/app/build.gradle.kts` 使用项目内公开 debug keystore（`android/debug.keystore`），
  避免只读 `$HOME/.android` 阻塞构建；`gradle.properties` 固定受控 JVM 参数与无 daemon/
  configuration-cache 构建。实际 `.flutter-sdk/bin/flutter build apk --debug` 产出
  `build/app/outputs/flutter-apk/app-debug.apk`（158,063,243 bytes，exit 0）。

### D4 正式 live 测试工具数
- `live_profile_e2e_test.dart` 与 `live_standalone_mcp_e2e_test.dart` 从旧 `tool_count=8`
  改为**精确 17 个工具名集合**；保留 Profile、四来源头像、心跳、登出/401 断言，未关闭
  MCP probe。
- 真实 FastAPI + 真实 stdio MCP 分别执行三文件：auth 1 passed、profile 1 passed、
  standalone 1 passed（34s，30s 心跳）；顺序/单独执行均 exit0。三文件一起并行运行会争用
  MCP/uv 临时状态，故交接命令按文件顺序执行并如实记录。

## 11.2 R4 边界修复（Sentinel REJECT）

- **媒体流在途身份**：`MediaStreamProxy` 在 HEAD 的 `probeMedia` await 之后、GET 的
  `outbound.close()` await 之后再次复核 `session.isCurrent(identity)`；旧身份在受控上游
  响应放行后返回 401，不再输出 A 的 body/headers。新增 GET/HEAD 阻塞上游后切 B 的回归。
- **下载终态首次写盘失败**：`DownloadManager._run` 将“传输/保存”和“账本终态提交”分开；
  文件保存成功后，`finishDownload` 的持久化异常最多重试 3 次，全部失败时保留可恢复的
  pending/running 状态并返回，绝不再进入传输失败的 `failed/downloadFailed` 分支。新增
  注入一次 `FileSystemException` 后恢复账本的回归；相邻“成功已落盘、事件发布失败”
  重开补取仍为一条 `downloadSucceeded`，PASS。
- Sentinel `qa-r4-boundaries.dart` 六项检查：**6/6 PASS / exit 0**（GET/HEAD 401、终态失败恢复
  succeeded、两条 replay dedup、pending-publish 控制）。
- 严格 runner 更新为 **274 passed / 8 skipped**（新增 2 条边界测试），Linux integration 13。

### R5/R6/R7 准备、期望值与跨文件系统落位

- 完整响应在内存时，先持久化绑定 task/account/consumer/media 的**期望长度/SHA256**
  `cacheRoot/.staging/<task_id>.expect.json`；再写任务专属暂存并核对，再写 `.terminal`
  `version:2` 准备记录，最后落位。无记录的残留暂存绝不重算“期望值”晋升成功。
- 落位通过**目标目录内任务专属临时文件**复制、flush、按期望摘要校验，再同文件系统 rename；
  临时文件名带随机 nonce，以 `File.create(exclusive:true)` 排他创建；目标已有未知对象时
  换 nonce，绝不覆盖。支持跨文件系统（如 `/dev/shm`），不依赖调大重试或仅限 cache。
- **意图先于对象、所有权确认后复用**：先原子写 `.terminal/<task_id>.cleanup.json`
  `state:"intent"`（task/account/consumer + 精确 nonce 路径），再 `create(exclusive:true)`；
  成功后原子更新为 `state:"owned"` 才允许复用/删除。
- 记录为 `intent` 且对象不存在时可重新排他创建；对象已存在但未确认 owned 时保留对象+
  记录、拒绝 openWrite/delete。创建成功但 owned 确认失败同样保留不确定，不删未知对象。
- 清理只读取 `owned` 记录并核对**完整 account/consumer/task 身份**；intent、任一项不匹配、
  记录损坏或缺少记录均不删除、不推导、不 glob。终态后后来出现的同名用户文件不会被
  `get` 删除；旧 `<final>.part-<task_id>` 无可靠归属记录时保留不迁移。
- 清理失败保留 cleanup 记录，重启/再次 get 重试；终态成功与唯一事件不被改写，最后才删记录。
- 恢复：准备记录的最终文件哈希匹配则原路径补终态；仅暂存匹配则安全落位；无准备记录时
  必须有独立期望记录且暂存完全匹配才可恢复。无记录截断/损坏暂存、记录损坏、摘要不符、
  目标替换、旧 pending 非空目标均保持 pending 不确定，不发成功事件；旧 v1 标记兼容。
- 准备/期望/暂存只在终态+pending event 持久化后清理；故障恢复可重复重启，事件 ID 稳定。
- 新增期望记录/跨文件系统/截断暂存不成功/目标替换/第三方文件清理边界回归；严格 runner
  更新为 **274 passed / 8 skipped**，Linux integration 13。

### 11.3 storage_busy 503 重试

- `ChatApiClient` 从 503 响应读取 `Retry-After`（秒，缺省 1），错误模型保留
  `retryAfterSeconds`；仅 `code=storage_busy` 重试，最多 3 次，退避后复用**同一
  client_nonce/operation_id**，服务端去重仍为 1 消息/1 operation。
- `storage_io_error` 与其他 503 不重试：分别给“存储写入失败，请稍后重试或联系管理员”和
  “服务暂不可用，请稍后重试”的硬错误文案；busy 超限给“存储繁忙，请稍后再试”，与真实
  IO 错误区分。
- 新增 5 例：busy 3 次后成功、busy 超 3 次失败、io 不重试、其他 503 不重试、
  `Retry-After` 解析；断言同一 nonce、只有一次成功消息/operation。
- 严格 runner 更新为 **274 passed / 8 skipped**，Linux integration 13。

## 12. NOT RUN / 已知限制

- **Android / Windows 运行**：本环境无模拟器/真机、无 MSVC；一律 NOT RUN。
- **物理折叠设备**：只注入 `DisplayFeature` 渲染，没有真实折叠硬件运行。
- **真实模型/视觉/DSH 回合**：客户端只验证本机 FastAPI 与本进程事件/凭据/下载链；
  DSH 插件的真实模型展示、continuation、跨重启调度由 Forge/独立 QA 验证。
- **真实 MCP 插件链**：Nine-tool 本地契约由 Dart 测试覆盖；真实 dsh-plugin MCP 进程
  端到端仍 NOT RUN（属于 Forge/集成 QA）。
- **Android 真机**：`bb/media_clipboard` 通道与 `video_player` 在线播放已实现，但无设备，
  NOT RUN；不以 Linux 结果代替。DEA-471 的 `flutter build apk --debug` 已在本环境编译通过
  （含 `bb/media_gallery` 与查看器内嵌播放代码），但安装、相册权限、真机播放/缓冲进度仍需
  真机复验。
- **桌面内嵌视频**：Linux 已用 `fvp 0.40.0`（随包 MDK）实跑真实播放；Windows 同一实现已接
  入但没有 MSVC/Windows 环境，NOT RUN，不能把 Linux 结果当作 Windows 通过。
- **桌面在线播放 GUI**：loopback Range 代理、点击触发、权限/取消与系统播放器交接已自动
  验证；实际播放窗口/解码未在无交互环境人工验收，NOT RUN，不记作已通过。
- **iOS**：无本轮 runner，剪贴板、在线播放与 Photos 保存路径均未接入；`saveToPhotos`
  通道接口已在 Dart 侧预留，本机调用会返回 unsupported。
- **Android 相册落盘（DEA-471 U6）**：MediaStore 插入、命名、API ≤ 28 权限分支已写入
  `MainActivity.kt`，但本环境 `adb devices -l` 无设备，真机「系统相册可见」NOT RUN；
  不以 widget/APK 结果代替。当前 Linux 主机也无法验证 Android 权限弹窗与拒绝分支。

- **事件日志不设丢弃窗口**：按契约保留，避免有限内存缓存丢旧事件；长期运行的清理策略
  未在本步实现。
- 服务器/共享 schema 未改；若 R3 正式 schema 字段名有差异，以 Forge 的共享 schema 为准，
  客户端再进行对齐（当前按 R3 文档实现）。

## 13. 本地运行

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
