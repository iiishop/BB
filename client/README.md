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
flutter run -d linux
```

首次启动没有服务器地址时进入**服务器设置页**：填 `bb.example.com` 会自动用
`https://bb.example.com`，填 `192.168.0.104:18980` 这类局域网地址保持 `http://`；
手打协议时以手打的为准。地址写到会话文件同级的 `server.json`，登录页底部的
「服务器设置」可以再改，**切换服务器会清除属于旧服务器的会话凭据和聊天账本**。

开发时仍可用编译期地址跳过这一屏（保存过的地址优先级更高）：

```bash
flutter run -d linux --dart-define=BB_API_BASE_URL=http://127.0.0.1:8000
```

Android release 已在主 manifest 声明 `INTERNET`，并允许明文流量——自托管服务端通常
是局域网 HTTP，Android 从 API 28 起默认拒绝。对外可达的服务端请用 HTTPS 域名。

客户端自更新（DEA-479）已接入 Forge 的共享契约，详见
`docs/dea479-client-update.md`：进程根一次启动检查、Profile → 设置入口、Release 正文安全
呈现与显式确认链接、下载/安装/取消/重试、Android 系统安装适配与跨进程结果恢复；未发送
草稿和待发媒体在离开聊天页后仍会阻止安装。Windows 执行器与真机安装结果仍由各自负责人/
固定候选验收，客户端自测不代表真机通过。

登录成功后进入 STEP-3 首页：当前服务器全部注册用户的逐行列表（含未联系用户），点行进入
一对一聊天；窄屏页头左上角头像（与右侧账号同一行、在「消息」标题上方）打开 Profile，宽屏
保留左侧栏底部入口。消息页列表上方的「只看在线」开关在手机、折叠屏和宽屏都可用，默认
关闭，打开后只显示对端当前在线的会话，关闭即恢复完整列表；没有任何在线联系人（包括只有
当前账号）时提示「暂无在线联系人」且开关仍可操作。调整窗口宽度会保留当前筛选状态。切换
不改变最近消息排序，也不清除未读数。资料面板按视口分为三种形态：

- **手机（窄，< 600 逻辑像素）**：从左侧滑入，占满屏幕，左上角返回/系统返回键向左滑出；
- **折叠屏展开**：`MediaQuery.displayFeaturesOf` 中存在 `fold`/`hinge` 且
  `postureFlat` 时启用，用 `DisplayFeature.bounds` 作为切分点占左半屏，右半屏毛玻璃遮挡；
- **桌面（宽）**：居中浮动卡片（≤ 440px），不加黑色遮罩。

折叠判定永远优先于宽度断点；`didChangeMetrics`/`MediaQuery` 更新时展开、合拢会实时重排。
三形态共用新版封面、花边头像、昵称/账号、签名及主操作；头像、封面、昵称和签名均从
「编辑资料」进入同一组编辑入口。面板内容按自身宽高排列，桌面关闭和手机/展开屏返回方式保留。
折叠聊天的坐标反例、页面策略差异及真机最小采集项见
[`docs/dea496-profile-fold-investigation.md`](docs/dea496-profile-fold-investigation.md)。

Linux 默认窗口 1180×780，Windows 同样 1180×780。Windows 构建/运行与 Android 运行在本
环境均为 **NOT RUN**：Windows 没有 MSVC 工具链、Android 没有模拟器/真机；Linux 截图不代表
这两个平台。Windows release 包由 CI `Windows test package` 工作流从固定源码自建最小
FFmpeg（`ffmpeg/ffmpeg.exe`，LGPL-2.1+，仅内部解码组件 + zlib；应用目录解析、不依赖 PATH；
包内含许可与源码/构建配置材料），见 `docs/dea477-windows-package.md`；CI 产包不等于 Windows
原生验收。

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
- 本机图片来源按平台区分（DEA-482，`docs/dea482-avatar-picker.md`）：Android 用系统相册
  选择器（`file_selector` 的 `ACTION_OPEN_DOCUMENT` + 图片类型过滤，不申请存储/相册权限，
  按选择结果读字节上传，不假定存在真实路径）；桌面保留手填绝对路径并新增「选择图片」原生
  文件对话框。两个入口共用同一读取、≤5MB/magic bytes 校验、真实解码预览与「应用」提交链：
  选择只更新字段/预览，点「应用」才上传；取消选择、取消对话框与上传失败都不改服务端头像。
- 缓存目录默认是会话文件同级的 `avatar-cache/`，可用 `BB_AVATAR_CACHE_DIR` 覆盖。

## STEP-3 Chat 客户端

- **主页**：`GET /users` 的账号升序 keyset 分页（1–100），每行头像、username、在线状态、
  最后联系时间、最后消息“谁：预览”（本人显示“我”）；无历史显示“尚未联系 / 暂无消息”；
  30s 静默刷新 + 下拉刷新；列表按 account 路由，重名 username 不串会话。预览不下载附件原文件。
- **在线状态**：列表和已打开会话共用同一个 `PresenceDirectory`，只对当前页面实际展示的对端
  每 30s 读一次 `GET /users` 的 `presence`（服务端在线判定＝session 在 90s 内有过心跳），
  进入会话时立即读一次。因此对方登录/登出后最迟约 30s 反映到顶栏；对方停止心跳但未登出时，
  服务端的 90s 窗口加上一次刷新使离线显示最迟约 120s，这是定时刷新而非即时推送。列表页与
  单账号刷新在发起时各取一个递增 ticket，旧 ticket 的结果不能覆盖新结果（慢响应晚到也不回退）。
  读取所有权按账号隔离（不是一把全局锁）：一个账号的慢/被放弃请求不会阻塞新会话的首读；离开
  会话会作废该账号在途读取并释放所有权，重开同一会话立即重读且只接受新结果。读取失败保留最后
  一次确认值、不伪造离线，恢复后继续更新；收到消息不推断在线。迟到响应不落到新会话或已销毁页面。
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
- **键盘**：输入框聚焦时 Enter 发送、Ctrl+Enter 换行（Shift/Alt+Enter 留给编辑器），
  中文 IME 组词/选字期间 Enter 只确认候选不发送，长按 Enter/Ctrl+V 不重复提交；空内容不发。
  桌面输入框提示与实际快捷键一致，发送按钮 tooltip 显示“发送（Enter）”。
- **剪贴板**：输入框聚焦时 Ctrl+V 读取剪贴板文件/图片；不再有专用“粘贴图片或视频”按钮。
  Linux 先试图片/视频二进制剪贴板目标，再解析 text/uri-list/file:///绝对路径（可多文件）；
  Windows 由 `client/lib/ui/chat/clipboard_paste.dart` 调用 PowerShell 读取 CF_HDROP 文件列表
  （资源管理器多选）或把 CF_DIB 图片转成 PNG；Android 仍经 `bb/media_clipboard` 读取单个
  ClipData content URI 图片/视频。图片进入正文，视频（真实封面）与音频/PDF/ZIP/其他普通文件
  进入独立附件；多文件保持剪贴板顺序进入附件组（图片按序进入正文）、可逐项删除、不自动发送。文件不存在/是文件夹/为空/
  超过 32 MiB 时给出可见提示，不静默丢弃；未知类型以 `application/octet-stream` 走契约的
  `other`。webm/mp4 按容器真实轨道分类：只有音轨的“音频版 webm/mp4”不会进入视频封面流程，
  以普通文件 `other` 发送；容器无法解析时保持原 magic 分类。iOS 无本轮 runner，未接入。
- **在线播放**：附件到达只取封面；点击播放时才启动 `127.0.0.1` 随机 token 的 loopback 流代理，
  按播放器 Range 向带 Bearer 的 `/media/{id}` 透传，不预下载原文件。Android/iOS 用
  `VideoPlayerController.networkUrl` 在线播放；桌面把流 URL 交给系统播放器并保留“停止/取消”
  与重试；另存为仍是独立目录选择操作。桌面 GUI 播放未在本环境人工验收，见 NOT RUN。
- **UI**：日期/5 分钟时间分组、有序文本+图片、附件卡右击/长按“下载/播放/另存为”、
  输入区图片/文件入口与草稿顺序；手机 390×844、桌面 1440×900、折叠 1024×768 均无溢出。
- **气泡与发送反馈**：同发送者 5 分钟 run 只在最后一个气泡显示头像，18px/6px 方向圆角，
  气泡宽度 `min(340, 74% 视口)`；发送点击后立即出现本地气泡，状态为“发送中…”/“未发送 ·
  点按重试”/“状态待确认 · 点按重试”/已提交时间；服务器协商的
  `ChatMessage.operationId` 只用于本人、本对话的同 operation 合并，其他来源的已提交消息立即
  显示；无关联、不同 operation 或对端消息不参与本地回显匹配。重试复用同一 operation id；
  入场动画只给真正的新消息，历史/刷新/滚动不重播，`MediaQuery.disableAnimations` 时跳过；
  用户停在历史时轮询新消息不强制拉底。设计与参数见 `docs/chat-bubble-visuals.md`。

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

- 默认 `flutter test`：合并最新 main 并加入 Windows 内置 FFmpeg 解析回归后为
  **980 passed / 20 skipped / exit 0**（2026-11-22 Linux 测试机；DEA-493 候选）。新增覆盖
  1000 条真实分页下发送/接收并发补取无缺口、events/wait limit 边界、原子展示确认/冲突/全组
  拒绝/重启幂等、新 consumer 独立补取、有序图文发送、幂等/冲突、read→receipt→ACK 缺口、
  附件只读元信息、异步下载内容、持久事件、wait 积压/提前到达、用户列表分页/预览/在线状态、
  图片/视频剪贴板、真实 ffmpeg 视频封面、点击在线流 Range 与“到达不请求原视频”、本地发送
  气泡→提交同 identity、失败同 operation id 重试、入场只给新消息、减少动画、历史阅读不被拉底、
  连续两条在途、1.6 倍文字无溢出、已接受消息被轮询先读到时与本地气泡合并为一条、
  刷新期间响应延迟不重复、正文已提交/附件仍在途的部分成功窗口、失败/成功回执不拉走历史读者、
  跨日期分隔插入时 entrance State 保持、不同 operation 的同文/同媒体消息不吞掉本地失败、
  两条发送乱序返回、失败后由 `GET /operations/{id}` 确认已提交、operation 查询在途期间
  poll/refresh 不重复、查询失败与 pending/uncertain 保持未知并保留暂存与重试、后续轮询重查
  恢复、重试与查询交错、1.6 倍文字下时间/发送中/失败状态行完整可读、迟到查询不能在重试
  确定成功后重建未知状态、切会话 dispose 后迟到查询不改状态、精确 operation 关联下其他来源
  同文/同媒体消息不被全局暂存隐藏、未知/明确失败状态文案、重试后再次失败时旧查询不覆盖、
  仍 mounted 时切换对话旧查询不落新页、切换对话时旧 refresh/poll 的成功或错误都不落新页、
  已打开会话在线状态随共享来源在 30s 内更新且列表行同步、读取失败保留最后确认值不伪造离线、
  关闭会话后迟到响应不改下一个会话、presenceOf 按账号 keyset 只读目标一行、慢到的旧单账号读取
  不覆盖列表新结果（保持会话与关闭重开两种导航）、旧列表页不覆盖新单账号读取、unwatch 作废
  在途读取、真实 HTTP 下切换账号后旧账号在途 presence 读取被拒且新账号独立解析同一对端、
  新会话在旧账号请求未完成时立即发起自己的首读、关闭后重开同一会话立即重读且旧响应不覆盖。
- DEA-493 会话体验回归：`chat_workspace_widget_test.dart` 覆盖桌面/折叠双栏直接复用
  `UsersListView` + 嵌入 `ChatPage`、按账号选中高亮、切换会话恢复滚动位置/草稿/光标、
  折叠全屏的果冻越界与状态恢复、开关避开铰链、竖向零宽折痕同样有开关、手机仍走路由；
  `chat_hidden_display_test.dart` 覆盖隐藏会话不清未读、轮询在切走后返回不记展示、重新可见
  才提交暂存展示；`chat_motion_input_test.dart`
  覆盖键盘整体升降与页头固定、历史打开键盘不跳、`↓ N 条新消息` 提示、组首头像、160ms 入场、
  发送键强调、视频画面卡与长按菜单、媒体原位转场与返回位置。同轮全量 `flutter test`
  **980 passed / 20 skipped / exit 0**；`xvfb-run -a flutter test integration_test -d linux`
  **14 passed / exit 0**（Linux 桌面真实进程，不代表 Android/Windows 真机）。
- DEA-477 按键/剪贴板回归：`chat_composer_shortcuts_test.dart` 覆盖 Enter 只发送一次、Ctrl+Enter
  换行不发送、IME 组词时 Enter 不发送、空/纯空白不发、长按 Enter 不重复、专用粘贴按钮消失；
  `chat_clipboard_paste_test.dart` 覆盖 Windows 剪贴板 listing 解析与脚本转义、多文件任意类型
  （PDF/ZIP/音频/图片）顺序、图片转 PNG、文件夹/空文件/超 32 MiB/不可读的可见提示、Ctrl+V 不自动
  发送、正文保留、逐项移除、文本粘贴按光标插入；异步粘贴还覆盖延迟读取保留编辑/合并重叠请求、
  读取中发送后迟到文件不自动发送、dispose 后迟到结果不抛错。音频反例：真实 audio-only WebM
  （Opus、无视频轨）经 Windows 文件列表 seam + Ctrl+V 进入准备链路后保持可取消、可发送，
  准备规则在“声明 video 但无视频轨”时降级为 `application/octet-stream`。`chat_media_input_test.dart`
  增加多 URI 去重、m4a 不误判、真实 audio-only webm/mp4 轨道检测与 video webm/mp4 保持视频。
- `test/ffmpeg_tool_test.dart` 覆盖 Windows 从应用目录解析 `ffmpeg/ffmpeg.exe`、旧式同目录布局、
  开发构建回退 PATH、非 Windows 保持系统 ffmpeg、显式覆盖优先级；CI `Windows test package`
  还在真实 Windows 上校验 ZIP 内容、无系统 FFmpeg 冒烟与中文/空格路径复验。
- 严格命令 `QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client`
  需要可用的 Linux 显示服务；本环境 Xvfb segfault，DEA-477 本轮只实跑 `flutter analyze`
  （`No issues found!`，exit 0）与 `flutter test`；`linux-integration`、Windows/Android 真机与
  桌面 GUI 运行均 **NOT RUN**。
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
- D2 重启恢复：完整响应先在内存计算并持久化期望 size/SHA256，再写任务专属暂存与
  `.terminal` 准备记录，最后通过目标目录内临时文件复制/校验/同文件系统 rename 落位；
  支持跨文件系统，不覆盖目标；先持久化 `.terminal/<task>.cleanup.json`
  `state:"intent"`（完整 account/consumer/task + 随机 nonce 路径），排他创建成功后
  原子确认 `state:"owned"`。只有 owned 记录可复用/清理；intent 对象已存在时保留、
  不 openWrite/delete，身份不匹配/记录缺失不推导、不 glob，终态后同名用户文件保留。
  恢复先验证最终文件或可信暂存与独立期望值；无记录截断/损坏暂存、记录损坏、目标替换
  保持 pending，不发成功事件。
- 503 `storage_busy`：读取 `Retry-After`（缺省 1s）复用同一 nonce 重试最多 3 次；
  `storage_io_error`/其他 503 不重试并给可区分的硬错误文案；新增 5 例覆盖去重与超限。
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
- Windows 原生剪贴板读取（PowerShell CF_HDROP/CF_DIB）只做了 listing/脚本/文件收集层单测，
  真实 Windows 运行时 **NOT RUN**。Windows 发布包自带从固定源码自建的 `ffmpeg/ffmpeg.exe`
  （LGPL-2.1+，仅解码 + zlib，应用目录解析、不依赖 PATH，含许可/源码材料）；Linux/macOS 仍
  使用系统 `ffmpeg`（各自分发方式未变）。粘贴入口只处理
  “文件/图片 + 纯文本”，不读取第三方软件私有格式或仅存在于虚拟剪贴板的对象。
- Windows 测试包（CI artifact）未做 Authenticode 签名，首次运行会弹 SmartScreen；免安装
  ZIP 删除目录即移除应用与随包 FFmpeg。真实 Windows 交互（Enter/Ctrl+Enter、IME、截图/
  多文件粘贴、视频封面→发送）仍需用户实测，见 `docs/dea477-windows-package.md`。
- Android 真机与 Windows 构建/运行 **NOT RUN**；折叠屏形态为注入 `DisplayFeature` 的
  widget 渲染验证，未在真实折叠设备运行。Android 剪贴板通道已实现，但未在真机验证；
  Linux/Windows 的在线流交给系统播放器，桌面 GUI 实际播放未在本环境人工验收；这两项均
  如实 NOT RUN，不记 PASS。
- 事件日志不设有限内存丢弃窗口，长期清理策略未实现。
- 真实 DSH 模型展示、continuation、九工具真实 MCP 端到端仍由 Forge/集成 QA 验证，本客户端
  只覆盖本机 FastAPI 与本地 loopback 契约。
