# BB 客户端组件与功能地图

> 读者：接下来要在 `client/` 里加页面、改交互、复用组件的开发者（包括接手 DEA-495 后续项的人）。
> 这不是产品介绍，也不是验收报告；它回答“这个能力现在在哪、谁在调用、什么条件下生效、要复用该接哪里”。
>
> DEA-495 原始地图基线为 `609811ffdc090bd71b734dd8a1bdf674036cd870`。本次资料页、折叠判定及坐标转换按客户端候选 `f413e3d29b7c1d4a94646125b126e92f79c8e5c7` 更新。其他条目的行号沿用原始基线。

先读这三份再动手：

- 界面与交互基线：[PROJECT_CONTEXT](PROJECT_CONTEXT.md)、[ENGINEERING_GUARDRAILS](ENGINEERING_GUARDRAILS.md)
- 客户端现有行为：[资料页手机版](../client/docs/dea492-profile-phone.md)、[聊天转场](../client/docs/dea493-chat-transitions.md)、[会话列表](../client/docs/dea494-conversation-list.md)、[Space 客户端](../client/docs/dea481-client-space-ui.md)、[更新机制](../client/docs/dea479-update-mechanism.md)
- 共享契约（唯一机器权威在 `server/contract/`）：[profile-step2](contracts/profile-step2.md)、[chat-step3](contracts/chat-step3.md)、[dea471-media](contracts/dea471-media.md)、[dea481-space-v1](contracts/dea481-space-v1.md)、[dea485-profile-follow](contracts/dea485-profile-follow.md)

## 0. 三十秒导航

| 要做的事 | 先看 |
| --- | --- |
| 加一个新页面 / 面板 | §2 找到可复用外壳，§3 找现有入口链 |
| 改资料页三种呈现 | §3.5、§4.1、§4.3 |
| 改窗口宽度 / 折叠屏 / 平板布局 | §4.1、§4.2 |
| 改图片、视频、头像加载 | §2.1、§2.2、§4.5 |
| 加并发任务、批量下载、后台工作 | §5（`client/lib/tasks/task_scheduler.dart`） |
| 查某个能力为什么没出现 | §3 的“生效条件”列；Space/更新/Profile 都按能力或平台降级 |
| 想新写一个“通用”小部件 | 先查 §2；再查 §4.8 已正确复用列表 |

第 0 版验收项和本文的对应关系：

| 第 0 版要求 | 本文位置 |
| --- | --- |
| 1. 目录地图（每个目录管什么） | §1，含生成文件和相邻目录 |
| 2. 组件清单（契约、被谁用） | §2.1-§2.7；聊天、Space、资料、媒体、认证分表 |
| 3. 功能清单（入口、生效条件） | §3.1-§3.8；每行先给入口链再给条件 |
| 4. 复用边界（折叠、断点、尺寸、媒体、权限、错误） | §4.1-§4.7；每条给位置、处数、目标、须保留差异 |
| 5. `TaskScheduler` 两种模式、预算、FIFO、取消与场景 | §5.1-§5.6 |
| 6. 判据可落地（文件:行、处数、改成什么） | §4 每个表格行 + §6 的核对方式 |

资料页专项对照：分支与三种外壳见 §3.5、§4.3；折叠/姿态判定见 §4.1；断点见 §4.2；尺寸见 §4.4；媒体加载见 §4.5；权限见 §4.6；错误提示见 §4.7。

调用链总览（生产路径）：

```text
main()
  └─ BbRoot（服务器地址 + 服务栈）
      └─ BbClientApp
          └─ AuthFlow（恢复中 / 登录 / 注册 / 已登录）
              └─ HomeView（已登录外壳）
                  ├─ 聊天：UsersListView（手机）或 ChatWorkspace（宽屏/展开折叠）
                  │    └─ ChatPage → ChatComposer / MessageBubble / MediaViewer
                  ├─ BB 空间：SpacePage → feed / detail / compose / notifications / drafts / profile
                  └─ 个人资料：openProfilePanel → ProfilePanel（mobile / folded / desktop）
更新：UpdateScope 包在 BbRoot 外层，每个进程一份控制器；入口在资料页 → 设置。
独立入口：client/bin/bb_client_api.dart → LocalAuthServer（回环本地控制接口），不启动 Flutter 界面。
```

## 1. 目录地图

除特别说明，下表路径都相对 `client/lib/`。

| 目录 | 管什么 | 关键文件 | 边界 |
| --- | --- | --- | --- |
| `config/` | 编译期/运行期配置和 UI 无关的阈值 | `client_config.dart`（`defaultServerBaseUrl`、本地控制口默认 8787）、`media_policy.dart`（100 KiB 原图阈值）、`session_path.dart`（`BB_SESSION_FILE` 覆盖） | 不放网络请求、不放 Widget |
| `models/` | 与服务端/本地契约对应的纯 Dart DTO 和枚举 | `auth_models.dart`、`profile_models.dart`、`chat_models.dart`、`chat_media.dart`、`space_models.dart` | `space_models.dart:1` 是生成文件；不要手改，见 `client/tool/generate_space.py` |
| `services/` | 凭证、HTTP、业务服务、持久账本、本地控制接口；UI 和独立 Dart 入口共用 | 认证：`auth_api_client.dart`、`auth_service.dart`、`auth_session.dart`、`session_store.dart`；资料：`profile_api_client.dart`、`profile_service.dart`、`avatar_cache.dart`、`avatar_source.dart`；聊天：`chat_api_client.dart`、`chat_service.dart`、`chat_ledger.dart`、`chat_query.dart`、`event_feed.dart`、`download_manager.dart`、`presence_directory.dart`、`media_source.dart`、`media_stream_proxy.dart`；空间：`space_api_client.dart`、`space_service.dart`、`space_local_router.dart`、`space_download_log.dart`；传输：`http_transport.dart`；本地接口：`local_auth_server.dart`、`chat_v2.dart`、`client_identity.dart`；安装闸门：`install_safety_gate.dart` | 不 import Flutter UI；服务端是业务事实权威；客户端只做展示、凭证和本地账本 |
| `tasks/` | 通用并发调度 | `task_scheduler.dart` | 只有这一个文件；当前唯一消费者是更新下载（§5.5） |
| `ui/` | Flutter 界面、交互、客户端展示状态 | 顶层外壳：`auth_flow.dart`、`home_view.dart`、`login_page.dart`、`register_page.dart`、`server_setup_page.dart`、`auth_shell.dart`；子目录见下 | 不直接拼 HTTP；通过 Gateway/Service；不复制服务端业务规则 |
| `ui/chat/` | 用户列表、单聊、输入区、气泡、媒体查看器、草稿、剪贴板、在线状态 | `users_view.dart`、`chat_page.dart`、`chat_workspace.dart`、`chat_composer.dart`、`message_bubble.dart`、`media_viewer.dart`、`chat_photo_source.dart`、`viewer_video.dart`、`media_save.dart`、`media_actions.dart`、`chat_drafts.dart`、`chat_avatars.dart`、`chat_format.dart`、`conversation_order.dart`、`clipboard_paste.dart`、`pending_send.dart` | 照片查看器的通用行为在 `ui/media/`，不要在这里再写一套 |
| `ui/media/` | 聊天与 Space 共用的全屏图片/分页契约 | `photo_source.dart`、`photo_page.dart`、`photo_pager.dart`、`photo_format.dart` | 只负责“怎么显示字节”，不负责“字节从哪来”（那是 `PhotoSource` 实现） |
| `ui/profile/` | 三形态资料面板、头像/封面视觉、头像选择器 | `profile_panel.dart`、`profile_artwork.dart`、`avatar_picker.dart` | 资料修改动作只有一份；三种呈现只换外壳/页面体（§4.3） |
| `ui/space/` | BB 空间 feed、详情、编辑、通知、草稿、关注、作者主页、图片查看 | `space_page.dart`、`space_controller.dart`、`space_detail_controller.dart`、`space_detail_view.dart`、`space_compose_controller.dart`、`space_compose_page.dart`、`space_widgets.dart`、`space_layout.dart`、`space_gateway.dart`、`space_follow_store.dart`、`space_follow_button.dart`、`space_image_viewer.dart`、`space_avatars.dart`、`space_lists_view.dart`、`space_local_store.dart`、`space_people_sheets.dart`；`profile/` 下是作者主页（`space_profile_page.dart`、`space_profile_controller.dart`、`space_profile_posts_module.dart`、`space_profile_month_directory.dart`、`space_profile_gateway.dart`、`space_profile_adapter.dart`） | 线协议只认 `server/contract/space-v1.json` + 生成代码；UI 不手写第二套协议 |
| `ui/updates/` | 更新设置的展示层和宿主绑定 | `update_scope.dart`、`update_settings_host.dart`、`update_settings_page.dart`、`update_ui_mapper.dart`、`update_ui_state.dart`、`release_notes_view.dart`、`update_link_opener.dart` | 网络、分段下载、校验、安装事务在 `updates/`，不在 Widget 里 |
| `ui/widgets/` | 跨认证/资料/聊天/空间共用的小部件 | `profile_avatar.dart`、`auth_widgets.dart` | 放真正跨功能、无业务状态的东西；页面私有 Widget 留在各自文件 |
| `updates/` | 更新协议、版本比较、发布读取、分段下载、平台安装器、安装安全闸门 | `update_contract.dart`、`release_policy.dart`、`release_client.dart`、`release_download.dart`、`release_update_controller.dart`、`android_update_installer.dart`、`windows_update_installer.dart`、`download_lane_preference.dart` | 仅 Android/Windows 有 updater；Linux/macOS 走“不支持”说明页 |
| `validation/` | 与服务端一致的即时校验（只做输入前反馈） | `auth_rules.dart`、`profile_rules.dart` | 服务端仍是唯一判定方；不要在这里加服务端没有的规则 |

相邻目录（不在 `lib/`，但改码时会碰到）：

| 路径 | 用途 |
| --- | --- |
| `client/bin/bb_client_api.dart` | 独立 Dart 入口，启动回环本地控制接口；不依赖 Flutter |
| `client/tool/generate_space.py` | 生成 `space_models.dart`、`space_methods.g.dart`、`space_schema.g.dart` |
| `client/test/` | 单元/Widget/真实 HTTP 桩测试；改组件前先搜这里有没有现成断言 |
| `client/integration_test/auth_flow_test.dart` | Linux 桌面端到端入口 |
| `client/docs/` | 按 DEA 记录的客户端实现说明；本文只做全局地图，两者互补 |

### 1.1 三条事实边界

1. `server/contract/` 是唯一机器契约；`models/space_models.dart`、`services/space_methods.g.dart`、`services/space_schema.g.dart` 是生成物，改契约要改生成器/契约，不直接改生成文件。
2. `AuthFailure`（`models/auth_models.dart:65`）是 UI、独立 Dart 入口、本地控制接口共用的错误信封；新增服务时不要另造错误类型。
3. 服务端持久化是消息、资料、帖子、事件的事实源；客户端账本（`chat_ledger.dart`）只记录客户端自己的 operation/download/display/receipt/ACK，不能当第二份业务库。

## 2. 可复用组件与契约

### 2.1 聊天与 Space 共用的媒体查看器

现有结构：

| 组件/契约 | 位置 | 契约 | 调用方 | 生效条件 / 复用规则 |
| --- | --- | --- | --- | --- |
| `PhotoSource` | `client/lib/ui/media/photo_source.dart:27` | `byteSize`、`heldOriginal`、`readCachedOriginal()`、`loadPreview()`、`loadOriginal()`、`changes`、`invalidated`；预览不得顺便下载原图 | `ChatPhotoSource`（`ui/chat/chat_photo_source.dart:24`）、`SpacePhotoSource`（`ui/space/space_image_viewer.dart:217`） | 新图源只实现这个接口；不要再写第三个全屏查看器 |
| `PhotoPageController` | `client/lib/ui/media/photo_page.dart:50` | 字节状态机：`loadingPreview → showingPreview → downloadingOriginal → ready/failed`；记住原图是否已取、是否失败、进度 | `MediaViewer`、`SpaceImageViewer` | 只处理字节；权限/删除由 `PhotoSource` 的 `changes/invalidated` 表达 |
| `PhotoPage` | `client/lib/ui/media/photo_page.dart:258` | 单页图片 + `InteractiveViewer` 缩放 + 失败重试；`failureLabel` 可换文案 | 两个 viewer | `failureLabel` 故意可配：Space 显示「原图加载失败」，聊天用默认「图片加载失败」 |
| `PhotoPager` | `client/lib/ui/media/photo_pager.dart:69` | 分页、缩放时暂停翻页、桌面左右箭头、方向键翻页、`Escape`（仅当传 `onDismiss`） | 两个 viewer | 桌面箭头只在 Windows/Linux/macOS 显示；手机保持滑动 |
| `PhotoPageRegistry` | `client/lib/ui/media/photo_page.dart:234` | 同一个 key 只建一个 `PhotoPageController` | 两个 viewer | 防止 pager 重建时重复拉图 |
| `PhotoViewerKeys` | `client/lib/ui/media/photo_pager.dart:19` | 每个 viewer 的 key 前缀，避免两个 viewer 同时挂载时冲突 | `MediaViewer.keys`（`ui/chat/media_viewer.dart:69`）、`SpaceImageViewer.keys`（`ui/space/space_image_viewer.dart:287`） | 新 viewer 用不同前缀 |
| `formatBytes` | `client/lib/ui/media/photo_format.dart:10` | 字节数 → `KB/MB` 文案 | 两个 viewer；`ui/chat/chat_format.dart:5` 重新导出 | 不要在聊天里再写一份 |
| `MediaDiskCache` | `client/lib/services/media_disk_cache.dart:18` | 进程级原图磁盘缓存，默认 256 MiB，按 `<variant>\|<id>` 或 `chat-original\|<mediaId>` 存 | `MediaViewer`（`ui/chat/media_viewer.dart:99`）、`SpaceImageLoader`（`ui/space/space_controller.dart:82`）、`HomeView`（`ui/home_view.dart:266`） | 全进程用 `sharedMediaDiskCache()`（`services/media_disk_cache.dart:190`）；不要 new 第二个实例，否则各自计数/淘汰 |
| `PhotoPreview` / `mediaNeedsExplicitOriginal` | 类型：`client/lib/ui/media/photo_source.dart:15`；阈值/谓词：`client/lib/config/media_policy.dart:12`、`:15` | 已知大小 > 100 KiB 时先给有界预览，等人点「原图」；≤100 KiB 直接原图 | `PhotoPageController.start`（`ui/media/photo_page.dart:112`）、`ChatPhotoSource.loadPreview`（`ui/chat/chat_photo_source.dart:70`）、`SpacePhotoSource.loadPreview`（`ui/space/space_image_viewer.dart:246`） | 唯一阈值在 `media_policy.dart:12`；不要新增第二个 100 KiB |

使用规则：

- 新功能要显示图片，先实现 `PhotoSource`，然后用 `PhotoPage` / `PhotoPager`。聊天和 Space 已经证明“同一套查看器、两种字节来源”可行。
- 全屏视频用 `ViewerVideoSession` / `StreamingViewerVideoSession`（`ui/chat/viewer_video.dart:48`、`:87`）：只有用户点播放才打开回环流；`requestBytes` 与 `mediaBytes` 必须分开显示（`ui/chat/viewer_video.dart:16`）。
- 保存图片/视频用 `MediaSaveService`（`ui/chat/media_save.dart:102`）：Android 走系统相册（`GallerySaveOutcome`，`ui/chat/media_save.dart:23`），其他桌面走保存对话框；Space 的 `defaultSpaceImageSaver`（`ui/space/space_image_viewer.dart:173`）也复用同一套平台分支。

### 2.2 头像和资料视觉

| 组件 | 位置 | 契约 | 调用方 | 生效条件 / 需保留差异 |
| --- | --- | --- | --- | --- |
| `ProfileAvatar` | `client/lib/ui/widgets/profile_avatar.dart:12` | `bytes`、`size`、`showBorder`、`loading`、`onTap`、`semanticLabel`；只画服务端返回的字节，加载/失败显示显式占位，从不自己造默认头像 | `ui/home_view.dart:340`、`:786`；`ui/profile/profile_panel.dart:1278`、`:2087`、`:2183`；`ui/chat/message_bubble.dart:974`；`ui/chat/chat_page.dart:1456`；`ui/profile/profile_artwork.dart:446` | 列表/气泡用 `thumb: true` 的字节（`ProfileGateway.loadAvatar`，`services/profile_service.dart:24`）；详情页用原图 |
| `ScallopedAvatar` | `client/lib/ui/profile/profile_artwork.dart:328` | 9 瓣花边圆环 + 落地转动；`playRing` 可关闭；尊重 `disableAnimations` | 共享资料页内容 `ui/profile/profile_panel.dart:1014` | 用于三形态资料封面与内容的交界处 |
| `ProfileSeaCover` | `client/lib/ui/profile/profile_artwork.dart:32` | 海浪封面；服务端字节优先，加载中/无图用打包的同一张 `assets/profile/default-cover.png`；顶部/底部 scrim 保证返回按钮可读 | 仅 `ui/profile/profile_panel.dart:996` | 服务端拥有封面；客户端不能画第二张默认图 |
| `SpaceAvatar` | `client/lib/ui/space/space_widgets.dart:20` | `author` + `SpaceAvatarScope` 提供的 `SpaceAvatarStore`；字节走已授权的 `ProfileGateway.loadAvatar`，没有字节时才显示确定性首字母占位 | feed 卡片 `ui/space/space_widgets.dart:398`；详情 `ui/space/space_detail_view.dart:341`、`:657`；点赞/访客 `ui/space/space_people_sheets.dart:124`、`:245`；作者主页 `ui/space/profile/space_profile_page.dart:437` | Space 不自己请求 `/avatars/...`，也不建第二份头像缓存；没有 `ProfileGateway` 的独立 Widget 测试才让首字母成为最终态 |
| `SpaceAvatarScope` | `client/lib/ui/space/space_avatars.dart:99` | 给一棵 Space 子树共享一个 `SpaceAvatarStore` | `SpacePage`（`ui/space/space_page.dart:330`）、`SpaceDetailView`（`ui/space/space_detail_view.dart:286`）、`SpaceProfilePage`（`ui/space/profile/space_profile_page.dart:395`） | 同一页面访问只请求一次；页面销毁即释放 |

头像缓存的唯一入口是 `ProfileGateway`/`AvatarCache`（`services/avatar_cache.dart:36`）：内存 LRU + 可选磁盘；只有 304 才复用缓存。聊天、Space、资料面板不要各自读文件。

### 2.3 认证壳与表单

| 组件 | 位置 | 契约 | 调用方 | 生效条件 / 需保留差异 |
| --- | --- | --- | --- | --- |
| `AuthShell` | `client/lib/ui/auth_shell.dart:13` | 响应式认证外壳：窄屏品牌头 + 单列卡片；宽屏深青品牌面板 + 固定宽表单列 | 登录 `ui/login_page.dart:225`、注册 `ui/register_page.dart:175`、`:189`、已登录占位 `ui/signed_in_view.dart:31`、服务器设置 `ui/server_setup_page.dart:172` | 宽屏判据 `>= 960`（`auth_shell.dart:45`，宽度恰为 960 进 `_WideLayout`、959 进窄版）只服务认证页；不要拿它做聊天/空间断点 |
| `AuthCard` | `client/lib/ui/widgets/auth_widgets.dart:68` | 白色内容卡片 | `AuthShell` 两种布局（`auth_shell.dart:110`、`:167`） | 认证页统一卡面 |
| `AuthErrorBanner` | `client/lib/ui/widgets/auth_widgets.dart:95` | 可读、可朗读的表单级错误横幅 | 登录、注册、服务器设置 | 与服务端 `fields[].message` 对齐 |
| `AuthNotice` | `client/lib/ui/widgets/auth_widgets.dart:147` | 信息/警告 + 可选重试动作 | 登录（恢复结果）、服务器设置 | 恢复失败分“过期/存储不可用/网络”三态（`ui/auth_flow.dart:62`、`:63`） |
| `AuthPrimaryButton` | `client/lib/ui/widgets/auth_widgets.dart:221` | 全宽主操作，忙碌时保持高度 | 登录、注册、服务器设置 | 不要另写 loading 按钮 |
| `AuthTextField` | `client/lib/ui/widgets/auth_widgets.dart:260` | 可见标签、可选密码显隐、内联错误 | 登录、注册、服务器设置 | 错误来自服务端字段，不自己编 |
| `PasswordRules` | `client/lib/ui/widgets/auth_widgets.dart:345` | 密码规则实时清单 | 仅注册 `ui/register_page.dart:244` | 文案含义优先，图标只是辅助 |
| `BrandMark` / `BrandHeader` | `client/lib/ui/widgets/auth_widgets.dart:8`、`:38` | BB 方牌 / 窄屏字标 | `AuthShell`、`RestoringView` | 不复制品牌素材到别处 |

认证状态机是 `AuthFlow`（`client/lib/ui/auth_flow.dart:23`）：`restoring → login/register → signedIn`。`signedIn` 时如果有 `profile` + `heartbeat` 就进 `HomeView`（`auth_flow.dart:284-297`），否则退回 STEP-1 的 `SignedInView`（`:299`）——这是测试/旧入口的兼容分支，不是产品主路径。

### 2.4 聊天组件

| 组件 | 位置 | 契约 | 调用方 | 生效条件 / 需保留差异 |
| --- | --- | --- | --- | --- |
| `ChatWorkspace` | `client/lib/ui/chat/chat_workspace.dart:21` | 宽屏/展开折叠的两栏：左 `UsersListView` + 右已打开 `ChatPage`；按 account 记住选中和已打开列表；支持 `displayWidth`、`foldController`、`visible` | 仅 `HomeView._splitChatScaffold`（`ui/home_view.dart:388`） | `usesSplit`（`chat_workspace.dart:154`）：无折叠特征时 ≥900（`splitMinWidth`，`:67`），有竖向折叠特征时设备宽 ≥720（`foldedSplitMinWidth`，`:75`）。折叠屏用**设备宽**，桌面用扣除 92px rail 后的 pane 宽 |
| `UsersListView` | `client/lib/ui/chat/users_view.dart:28` | 全部注册用户、最近消息、未读、在线筛选；同一 Widget 同时是手机整页和宽屏左栏 | 手机：`ui/home_view.dart:503`；宽屏：`ui/chat/chat_workspace.dart:406` | 只有 gutter 随 pane 变（`users_view.dart:409`，<520 收紧）；行内容/尾部消息不可分叉。选中态用 account，不用行号 |
| `ChatPage` | `client/lib/ui/chat/chat_page.dart:31` | 单个一对一对话：历史分页、3 秒轮询、消息合并、已显示回执、输入/媒体、视频流 | 手机路由：`ui/home_view.dart:314`；宽屏：`ui/chat/chat_workspace.dart:443` | `embedded: true` 时不推路由、去掉返回；`active` 决定“已看到”是否立刻记为显示事实（隐藏 pane 只暂存，`chat_page.dart:712` 起） |
| `MessageBubble` | `client/lib/ui/chat/message_bubble.dart:89` | 一条消息的文本/图片/附件卡/发送反馈；`mine`、`peer`、操作回调 | `ChatPage`（`ui/chat/chat_page.dart:1711`） | 气泡里图片的宽度/预览/占位逻辑见 §4.4、§4.5；不要另写“消息卡片” |
| `ChatComposer` | `client/lib/ui/chat/chat_composer.dart:57` | 有序文本/图片 + 独立附件（视频/文件）；选择、粘贴、封面、失败重试、草稿、安装闸门 | `ChatPage`（`ui/chat/chat_page.dart:1533`） | 发送失败保留同 operation id 重试；安装事务进行中禁止编辑（`chat_composer.dart:107` 的 `safetyGateKey`） |
| `ChatComposerController` | `client/lib/ui/chat/chat_composer.dart:25` | 让聊天页重试某个失败项，复用同一 operation plan | `ChatPage` | 只用于重试，不复制发送逻辑 |
| `ChatAvatarController` | `client/lib/ui/chat/chat_avatars.dart:17` | 一次会话访问内每个账号最多请求一次头像；失败保持占位，下次访问重新校验 | `ChatPage` | 不要在每个气泡里直接 `loadAvatar` |
| `ChatDrafts` | `client/lib/ui/chat/chat_drafts.dart:84` | 进程级未发送草稿，按当前 `ChatService` 隔离；写入同时更新安装闸门 | `ChatComposer`；`main.dart:131` 用它阻止切换服务器 | 路由销毁只保存草稿，不清空；换账号/服务器不得串草稿 |
| `MediaViewer` | `client/lib/ui/chat/media_viewer.dart:28` | 一个对话的有序媒体序列，打开到点中的一项；图片走 `ChatPhotoSource`，视频走 `ViewerVideoSession`，保存走 `MediaSaveService` | `ChatPage`（`ui/chat/chat_page.dart:1217`） | 共享给 Space 的只有 `ui/media/`；聊天专属的是序列构建、发送者栏、保存/下载日志 |
| `MediaActions` | `client/lib/ui/chat/media_actions.dart:50` | 平台文件/图片/视频选择、封面、保存位置、打开外部 URL | `ChatComposer`、`ChatPage`、`SpaceImageViewer` | 平台差异集中在这里；不要在页面里直接调 `file_selector` |
| `MediaSaveService` | `client/lib/ui/chat/media_save.dart:102` | 选择相册还是保存对话框，返回落点/取消/失败 | `ChatPage`（`ui/chat/chat_page.dart:1037` 起）、`MediaViewer` | Android 相册插入失败要回滚/提示，不能假装成功 |
| `ViewerVideoSession` / `StreamingViewerVideoSession` | `client/lib/ui/chat/viewer_video.dart:48`、`:87` | 一次点击范围内的回环视频会话；`start` 才打开流，进度分当前 Range 和整段大小 | `MediaViewer` | 桌面/Android 播放路径；不支持的宿主退回外部播放器（`media_viewer.dart` 的平台选择） |

聊天状态边界：

- 未读/已显示/消费 ACK 是三件事。UI 只记录“已显示”（`ChatPage._flushDisplayed`，`ui/chat/chat_page.dart:722`），消费 ACK 只在本地 `v2` 路由里由模型显式调用（`services/chat_v2.dart:585`、`:603`）。不要把打开会话当作已读回执。
- 会话内轮询是 3 秒（`chat_page.dart:253`）；服务端事件流是另一条（`ChatService.start` → `EventFeed`，`services/chat_service.dart:189`）。
- 群聊/多聊不在当前客户端范围内；`ChatPage` 只接受一个 `peer`（`chat_page.dart:51`）。

### 2.5 Space 组件

| 组件 | 位置 | 契约 | 调用方 | 生效条件 / 需保留差异 |
| --- | --- | --- | --- | --- |
| `SpaceGateway` | `client/lib/ui/space/space_gateway.dart:12` | UI 面向的唯一 Space 端口（overview/list/detail/comment/follow/draft/image/events/ack）；生产实现 `SpaceServiceGateway`（`:157`） | `HomeView`、`SpacePage`、`SpaceProfilePages` | UI 不直接说 HTTP；测试用契约形状的假实现 |
| `SpaceLayout` | `client/lib/ui/space/space_layout.dart:27` | 一次 Space 帧的断点、可用区、竖向/横向铰链、pane 分割、遮挡带 | `SpacePage`（`ui/space/space_page.dart:268`）、`SpaceComposePage`（`ui/space/space_compose_page.dart:129`）、`SpaceProfilePage`（`ui/space/profile/space_profile_page.dart:373`）、`ui/space/profile/space_post_detail_page.dart:149` | 只按宽度/显示特征做 UI 策略，不按设备名；断点值见 §4.2 |
| `SpaceAvatar` / `SpaceAvatarScope` | 见 §2.2 | 同上 | feed/detail/people/profile | 同上 |
| `SpaceImageGrid` | `client/lib/ui/space/space_widgets.dart:120` | 最多 9 张、三列、第九张带隐藏数；七/八张留短行 | 卡片 `space_widgets.dart:453`；详情 `space_detail_view.dart:375` | 只读 `SpaceImageLoader` 的缩略图；顺序即契约 |
| `SpacePostCard` | `client/lib/ui/space/space_widgets.dart:309` | 卡片：作者、正文四行渐隐、九宫格、引用卡、关注/点赞/评论/转发/删除入口 | feed `space_page.dart:479`；作者主页 `space_profile_posts_module.dart:234` | `following: null` 表示自己；`onFollow: null` 隐藏关注按钮；删除按钮只在 `post.canDelete`（`:427`） |
| `SpaceSectionHeader` | `client/lib/ui/space/space_widgets.dart:633` | 标题、副标题、发布、通知红点、草稿数、刷新、返回；`dense` 用于窄详情栏 | feed/通知/草稿 | `dense` 只隐藏副标题，不删动作 |
| `SpaceStateView` | `client/lib/ui/space/space_widgets.dart:769` | 加载/空/错误/离线的统一展示（图标、标题、消息、动作） | 各 Space 页面 | 错误文案来自控制器/`spaceErrorText`，页面不自己编 |
| `SpaceReferenceCard` | `client/lib/ui/space/space_widgets.dart:227` | 一层引用；来源删除时就地说明，不递归展开或读缓存正文 | 卡片/详情 | 服务端是“是否删除”的权威 |
| `SpaceImageViewer` | `client/lib/ui/space/space_image_viewer.dart:269` | 一帖的有序图片；`SpacePhotoSource`（`:217`）+ `SpaceImageLoader`（`:34`）做授权/删除/磁盘缓存；保存用 `defaultSpaceImageSaver`（`:173`） | `space_page.dart:232`、`space_detail_view.dart:242`、`space_profile_page.dart:307` | 只显示当前帖子的图片，不跨帖混排；图片失效显示失败态，不展示旧字节 |
| `SpaceFollowButton` / `toggleSpaceFollow` | `client/lib/ui/space/space_follow_button.dart:9`、`:118` | 关注/已关注；失败保持原状态并报告；取消关注要确认并点名目标 | 卡片 `space_widgets.dart:420`；作者主页 `space_profile_page.dart:474`；feed `space_page.dart:488` | 关注状态唯一来源是 `SpaceFollowStore`（`ui/space/space_follow_store.dart:20`），页面不自己存 |
| `SpaceFollowStore` | `client/lib/ui/space/space_follow_store.dart:20` | 一个登录账号的关注关系：服务端 `Post.authorFollowing` 种子、按目标串行写、未知结果用 `get_follow` 对账、`revision` 让 following feed 失效、处理 `follow.changed` | `HomeView._buildFollowStore`（`ui/home_view.dart:147`）创建，feed/作者主页共用 | 不要按页面各建一份；`isSelf`（`:65`）只是隐藏按钮的展示判断，不是权限 |
| `SpaceLocalStore` | `client/lib/ui/space/space_local_store.dart:9` | 未同步输入（草稿缓冲/评论草稿），scope = `baseUri\|account`；进程内 | `HomeView._spacePage`（`ui/home_view.dart:733`）；作者主页 | 只存“本地未提交”，不假装服务端已保存；发布成功同步清除 |
| `SpaceProfilePage` | `client/lib/ui/space/profile/space_profile_page.dart:44` | 作者主页：身份、关注、月份目录、说说列表、侧栏/抽屉；图片复用 `SpaceImageViewer` | `HomeView._openAuthorHome`（`ui/home_view.dart:240`）→ `openSpaceProfile`（`ui/space/space_page.dart:183`） | 侧栏阈值 `sideBySideMin = 840`（`space_profile_page.dart:104`）是这条内容自己的策略；month 目录与卡片用同一个固定时区偏移（`displayOffsetMinutes`） |

Space 状态边界：

- `SpacePage` 的一个 State 持有 feed/detail 栈/当前 section/滚动位置；布局变化只重建外壳（`ui/space/space_page.dart:25-30`）。detail 的 visit ID 在 `SpaceDetailController`（`ui/space/space_detail_controller.dart:15`）里，resize/刷新不能重新计数。
- 事件回放只有一个循环（`SpaceController`，`ui/space/space_controller.dart:71`）；不要给每张卡加轮询。
- `can_delete`/`can_*` 来自服务端 DTO（`models/space_models.dart:87`、`:186`）；UI 只按标志显示入口。自己计算“作者==我”不能替代权限判断。

### 2.6 资料面板

| 组件 | 位置 | 契约 | 调用方 | 生效条件 / 需保留差异 |
| --- | --- | --- | --- | --- |
| `openProfilePanel` | `client/lib/ui/profile/profile_panel.dart:94` | 返回 `ProfilePanelResult{changed, signedOut, logout, openSettings, openHomeAccount}`（`:67`）；根据 `resolveProfilePanelMode` 选择整屏路由或 dialog | `HomeView._openProfile`（`ui/home_view.dart:203`） | 手机走 `_PhoneProfileRoute`（`:163`），折叠/桌面走 `showGeneralDialog`；模式在打开时定路由类型，但 dialog 内部每帧重算模式/宽度 |
| `resolveProfilePanelMode` | `client/lib/ui/profile/profile_panel.dart:33` | 有 flat 折叠 → folded；否则宽度 <600 → mobile，否则 desktop | 面板打开、frame、转场 | 当前判据：`fold/hinge` + `postureFlat`（`display_features.dart` 的 `isFlatFoldFeature`），**不看方向**；宽度 600 是第二条判据。策略见 §4.1 |
| `foldedPanelWidth` | `client/lib/ui/profile/profile_panel.dart:52` | 折叠时左半宽：取折叠特征 bounds.left，clamp 280…width-1；否则 width/2 | `_ResponsiveProfileFrame`（`:323`） | 这里又单独要求 `height >= width && left > 0`（`:58`），用于定位左面板边缘 |
| `ProfilePanel` / `_ProfilePanelState` | `client/lib/ui/profile/profile_panel.dart:408`、`:498` | 共享资料状态与动作：加载资料/头像/封面、改昵称/签名、上传/移除头像、上传封面、查看其他账号、打开自己的主页、设置、退出；`_changed` 回传宿主 | 三种 frame | 三个外壳共用 `_buildContent`（§4.3） |
| `_ResponsiveProfileFrame` | `client/lib/ui/profile/profile_panel.dart:277` | 按当前模式套外壳：mobile 自己的 `Scaffold`+`ScaffoldMessenger`；folded 左栏+右侧模糊；desktop 居中的 440×700 卡片 | 手机路由/dialog | 三种外壳共用同一个 `ProfilePanel` 实例树；不要为折叠/桌面复制动作 |
| `_PhoneProfileRoute` | `client/lib/ui/profile/profile_panel.dart:163` | 360ms 淡入 + Hero 头像飞入 | 仅手机 | Hero 只在 PageRoute 间工作；dialog 里没有 Hero |
| `AvatarImagePicker` / `AvatarSourceReader` | `client/lib/ui/profile/avatar_picker.dart:35`、`services/avatar_source.dart:19` | 选择器返回 path/bytes；读取器统一处理 path/url/base64，5 MiB（封面 8 MiB）上限，校验 magic bytes | `ProfilePanel` 的头像/封面对话框 | 平台差异在 picker；上传/预览复用同一读取器 |

### 2.7 设计 token

`client/lib/app.dart`：`AppSpacing`（`:12`）、`AppRadius`（`:22`）、`AppColors`（`:32`）、`buildAppTheme`（`:62`）。新页面只用这些 token；聊天气泡的专用颜色（`chatPaper`、`bubblePeer`、`bubbleMine`）也在 `AppColors`（`:45-49`），不要在页面里写新的十六进制色。

## 3. 功能清单与入口

### 3.1 启动、服务地址与外壳

入口链：

```text
client/lib/main.dart:31  main()
  └─ :300 _resolveSessionFile()           // BB_SESSION_FILE > 平台目录
  └─ :38  UpdateScope                     // 每进程一份更新控制器
      └─ :53 BbRoot
          ├─ :100 _restore()              // 已保存地址 > 编译期地址
          ├─ :162 build()
          │   ├─ 无地址 → ServerSetupPage（ui/server_setup_page.dart:12）
          │   └─ 有地址 → _AppServices.create()（:220）→ BbClientApp（app.dart:243）
          └─ :128 _connect()              // 保存地址、切服务器、重建服务栈
```

生效条件：

- 地址顺序：`server.json` 保存值 → 编译期 `BB_API_BASE_URL` → 首次设置页。保存值优先（`main.dart:100-108`）。
- 切换服务器会清掉旧服务器的会话文件和聊天账本（`main.dart:270` `_resetCredentialState`），头像/媒体缓存保留（内容按账号/版本寻址）。有未发送草稿时拒绝切换（`main.dart:131-132`）。
- `HomeView` 的 92px rail（`ui/home_view.dart:73`）只在宽度 ≥720 时出现（`:601`）；窄屏用底部 `NavigationBar`（`:683`）。宽屏/折叠时传给 Space/Chat 的 `MediaQuery` 已扣除 rail，并平移 display feature（`:622-640`）。

### 3.2 认证

| 能力 | 入口/实现 | 生效条件与行为 |
| --- | --- | --- |
| 登录 | `ui/login_page.dart:13`；`AuthGateway.login`（`services/auth_service.dart:17`） | 只收 8 位账号 + 密码；成功进 `HomeView`；失败显示字段/表单错误；底部「服务器设置」（`login_page.dart:250`） |
| 注册 | `ui/register_page.dart:15`；`AuthGateway.register` | 昵称 + 密码 + 确认；成功后显示服务端分配的账号，再回登录（`register_page.dart:293`） |
| 恢复登录 | `ui/auth_flow.dart:115-166`；`RestoringView`（`ui/restoring_view.dart:8`） | 启动时仅 200 进入已登录；401 清凭据并提示重新登录；网络/超时保留凭据并提示“暂时无法验证”+ 重试；存储不可用单独提示（`:62-63`） |
| 已登录占位 | `SignedInView`（`ui/signed_in_view.dart:11`） | 只有没有 `profile`/`heartbeat` 的旧入口/测试走这里；产品路径是 `HomeView` |
| 心跳 | `HeartbeatController`（`services/heartbeat_controller.dart:33`） | 30 秒；连续 3 次失败显示“连接已断开，正在重连”（`ui/home_view.dart:851`），不登出；401 由 `AuthFlow` 处理过期（`auth_flow.dart:82-90`） |
| 退出 | 资料面板 `_logout`（`ui/profile/profile_panel.dart:880`）→ `AuthGateway.logout` | 服务端通知失败也清本地，但返回 `serverNotified=false` 并提示会话稍后过期（`auth_flow.dart:256`） |
| 校验 | `validation/auth_rules.dart:1` | 只做即时反馈；最终以服务端 422 为准 |

### 3.3 会话（一对一聊天）

| 能力 | 入口/实现 | 生效条件与行为 |
| --- | --- | --- |
| 用户列表 | `UsersListView`（`ui/chat/users_view.dart:28`）→ `ChatService.listUsers`（`services/chat_service.dart:589`） | 显示当前服务器全部注册用户；在线状态来自 `PresenceDirectory`（`services/presence_directory.dart:31`）；「只看在线」由 `HomeView._onlineFilter` 跨手机/宽屏共享（`ui/home_view.dart:113`） |
| 打开会话 | 手机：`HomeView._openChat`（`ui/home_view.dart:295`）→ push `ChatPage`；宽屏：`ChatWorkspace._select`（`ui/chat/chat_workspace.dart:196`）→ embedded `ChatPage` | 打开时记录“已查看”显示事实（`home_view.dart:301`、`chat_workspace.dart:211`）；不是对外已读回执 |
| 历史 | `ChatPage._loadInitial/_loadOlder`（`ui/chat/chat_page.dart:360`、`:425`）→ `ChatService.loadConversation`（`services/chat_service.dart:819`） | 每页 100 条（`chat_page.dart:204`）；到顶分页；窗口失效用 ticket/epoch/peer 校验（`:346`）；不轮询全量 |
| 新消息 | `ChatPage._pollNew`（`ui/chat/chat_page.dart:476`） | 3 秒轮询；隐藏 pane 继续取数据但不把到达消息记为已显示；活跃时显示“新消息”pill（`:1827`） |
| 发送 | `ChatComposer`（`ui/chat/chat_composer.dart:57`）→ `ChatService.sendComposed`（`services/chat_service.dart:1703`） | 文本/图片保持插入顺序；视频/PDF 等独立附件；同 operation id 重试；失败气泡可重试；不确定状态不显示成功 |
| 草稿 | `ChatDrafts`（`ui/chat/chat_drafts.dart:84`） | 路由销毁/切会话保留；切服务器前必须发送或清空；安装事务期间阻止编辑 |
| 媒体 | 列表预览：`ChatService.loadListPreview`（`services/chat_service.dart:2345`）；全屏：`MediaViewer`；原图 >100 KiB 需点按；保存：`MediaSaveService`；播放：回环流 | 上传上限 32 MiB（`models/chat_models.dart:13`）；消息正文上限 64 KiB（`:10`）；图片格式 png/jpeg/webp；视频 mp4/webm 且需封面 |
| 在线/连接 | `PresenceDirectory` + `HeartbeatController` | 在线是服务端 90 秒窗口内的心跳结果，不是推送；连接断开横幅见 §3.2 |

### 3.4 BB 空间

| 能力 | 入口/实现 | 生效条件与行为 |
| --- | --- | --- |
| 进入 | `HomeView` 导航（`ui/home_view.dart:683-710`）→ `_spacePage`（`:724`）→ `SpacePage`（`ui/space/space_page.dart:31`） | 生产总传入 `SpaceGateway`；`active` 表示当前可见；离开再进会 reset 到「全部」并丢浏览位置（`space_page.dart:110-114`） |
| Feed | `SpaceController`（`ui/space/space_controller.dart:71`），scope `all`/`following` | 20 秒轮询 + 一条事件回放循环；following 为空不回落全局；服务器不支持空间时显示能力提示而不是空列表（`space_controller.dart`/`space_gateway.dart:421`） |
| 详情 | `SpacePage` → `SpaceDetailController`（`ui/space/space_detail_controller.dart:15`）→ `SpaceDetailView`（`ui/space/space_detail_view.dart:17`） | 打开时创建一个 visit ID，resize/刷新/重试复用；评论树只显示两层，不递归加载 |
| 发布/草稿 | `SpaceComposePage`（`ui/space/space_compose_page.dart:26`）→ `SpaceComposeController`（`ui/space/space_compose_controller.dart:61`） | 服务端草稿 + 本地缓冲；防抖保存、版本冲突、离线保留输入；图片上传顺序有显式上下移动；发布前检查附件就绪 |
| 通知/草稿列表 | `SpaceNotificationsView`/`SpaceDraftsView`（`ui/space/space_lists_view.dart:13`、`:204`） | 通知按“看到的那一版”逐条 ACK，「全部标读」是独立动作 |
| 关注 | `SpaceFollowStore` + `toggleSpaceFollow` | 自己不能关注自己（`space_page.dart:476` 只隐藏按钮；最终服务端拒绝）；失败不改显示状态 |
| 作者主页 | `openSpaceProfile`（`ui/space/space_page.dart:183`）→ `SpaceProfilePage` | 月份目录 + 说说；固定显示时区偏移；访客详情只对作者开放，非作者看到服务端拒绝而不是空列表（`space_people_sheets.dart:9`）；点赞列表同样以服务端授权为准 |
| 图片 | `SpaceImageViewer` + `SpaceImageLoader` | 每次读图重新校验授权/删除；删除后缓存失效；保存走同一平台路径 |
| 权限 | 服务端 DTO 的 `can_delete` 等 | UI 只按标志显示；不要用“作者==我”替代删除/评论权限 |

### 3.5 个人资料

入口链：

```text
窄屏消息页头头像（HomeView._headerAvatar, ui/home_view.dart:339-350）
宽屏 rail 头像（HomeView._rail, ui/home_view.dart:786）
  └─ HomeView._openProfile (:203)
      └─ openProfilePanel (ui/profile/profile_panel.dart:94)
          ├─ mobile  → Navigator.push(_PhoneProfileRoute) → _buildContent
          ├─ folded  → showGeneralDialog → _FoldedFrame → _buildContent
          └─ desktop → showGeneralDialog → _DesktopFrame → _buildContent
```

| 能力 | 生效条件与行为 |
| --- | --- |
| 手机整屏页 | 宽度 <600 且没有 flat 折叠；海景封面 + 头像跨封面下沿 + Hero（`_buildContent`、`ProfileSeaCover`、`ScallopedAvatar`） |
| 折叠左半 | 有 flat `fold/hinge`；左栏宽度取特征 bounds.left（clamp 280…），右侧模糊；面板内呈现共享封面、头像及操作 |
| 桌面卡片 | 宽度 ≥600 且没有 flat 折叠；440×700 居中浮层，透明 barrier |
| 头像 | 读取服务端原图；更换支持 path/url/base64；上传后重新拉取；移除后服务端返回默认 identicon |
| 封面 | 服务端 `GET /covers/{account}`；无自选封面返回默认海浪；每次打开用 ETag 重验；上传源 ≤8 MiB，展示响应 ≤512 KiB（`services/profile_api_client.dart:44-50`） |
| 昵称/签名 | 服务端 Profile；客户端 `profile_rules.dart` 只做即时反馈；账号只读 |
| 其他账号 | 资料页内输入账号 → 只读 `_OtherProfileDialog`（`profile_panel.dart:2420`）；不提供“替别人改”的入口 |
| 个人主页 | 返回 `openHomeAccount`，宿主关闭面板后打开 Space 作者主页（`ui/home_view.dart:227`） |
| 设置 | 返回 `openSettings`，宿主关闭面板后打开更新设置（`ui/home_view.dart:219`） |
| 退出 | 返回 `signedOut` + `LogoutResult`，宿主回登录 |

三种外壳内的编辑资料入口共用同一表单、上传和刷新路径。

### 3.6 更新

| 能力 | 入口/实现 | 生效条件与行为 |
| --- | --- | --- |
| 更新入口 | 资料页 → 设置（`profile_panel.dart:1129`、`:1482`）→ `HomeView._openSettings`（`ui/home_view.dart:277`）→ `UpdateScope.maybeOf` → `UpdateScopeData.buildSettingsPage`（`ui/updates/update_scope.dart:65`） | 只有资料面板关闭后才 push，避免设置页叠在 dialog 后 |
| 支持平台 | `UpdateScope._boot`（`ui/updates/update_scope.dart:92`） | Android/Windows 创建 `ReleaseUpdateController`；Linux/macOS 不创建，显示“不支持”说明页（`update_scope.dart:68`、`:97`） |
| 检查/下载/安装 | `ReleaseUpdateController`（`updates/release_update_controller.dart:11`）；`UpdateSettingsHost`（`ui/updates/update_settings_host.dart:21`）→ `UpdateSettingsPage`（`ui/updates/update_settings_page.dart:14`） | 每进程一个控制器；检查/下载/校验/安装分开；SHA-256 通过才交给安装器；安装前受 `InstallSafetyGate` 约束（草稿/未完成上传会阻止） |
| 下载并发 | `DownloadLanePreference`（`updates/download_lane_preference.dart:5`） | 可选 1/2/4/8 路，默认 8；一次下载的 lanes = min(偏好, 按 ≥2 MiB 切出的段数)，不足 2 路走单路（`updates/release_download.dart:15`、`:32-36`） |
| 分段下载 | `updates/release_download.dart:147` 的 `TaskScheduler` | 每段一个 caller 任务；失败取消其余；ETag/Range/长度校验；服务器不支持分段或断线回落单路 |
| 展示映射 | `mapUpdateSnapshot`（`ui/updates/update_ui_mapper.dart:12`） | 契约 phase → UI phase 的唯一翻译点；页面不认 `UpdateSnapshot` |

### 3.7 独立 Dart 客户端 / 本地控制接口

| 能力 | 入口/实现 | 生效条件与行为 |
| --- | --- | --- |
| 独立进程 | `client/bin/bb_client_api.dart:41` | `dart run bb_client_api`；不启动 Flutter，不依赖 Widget；读取同一个会话文件/服务地址 |
| 本地接口 | `LocalAuthServer`（`services/local_auth_server.dart:32`） | 只绑定 `127.0.0.1`；注册/登录、`/v2/profile/*`、`/v2/chat/*`、`/v2/downloads/*`、`/v2/notifications/*`、`/v2/events/*`、`/v2/space/*`；token 从不出现在响应里 |
| v2 协议 | `ChatV2Router`（`services/chat_v2.dart:22`） | 严格解析：未知字段/显式 null/类型错误 422，然后 401、`expected_auth`/`expected_identity`、owner 能力、业务校验；路由清单见 `chat_v2.dart:315` 起 |
| Space 本地路由 | `SpaceLocalRouter`（`services/space_local_router.dart:7`） | `POST /v2/space/<action>`；必须带 `expected_identity` + owner key；复用 `SpaceService`，不另建协议 |
| 会话失效 | `LocalAuthServer.onUnauthorized`（`local_auth_server.dart:58`） | 真正的 401（`unauthenticated`，不是登录失败）才清内存和磁盘凭据 |

这个入口和 Flutter 界面是两个运行入口：改 UI 不能只用 Widget 测试替代独立进程冒烟；同理，独立进程通过不证明界面渲染。

### 3.8 “多账号”和服务器切换

当前客户端**没有账号切换器，也没有并行多账号**：

- 一个进程一份 `AuthSession`（`services/auth_session.dart:41`）和一份磁盘凭据；换账号 = 先退出再登录。
- 切换服务器会删除旧服务器的 `session.json` 和 `chat-ledger.json`（`main.dart:270-286`），重建 `_AppServices`（`main.dart:128-160`）。
- 账号相关本地数据按作用域隔离：聊天账本按 account（`services/chat_ledger.dart` 顶层 `accounts` 映射，`:211`），草稿按 `ChatService` 实例（`ui/chat/chat_drafts.dart:84`），Space 本地输入/图片缓存按 `baseUri|account`（`ui/space/space_local_store.dart:9`、`ui/space/space_image_viewer.dart:27`），下载记录按 scope（`services/space_download_log.dart:55`）。
- 因此“多账号”目前是**顺序登录 + 作用域隔离**，不是同一界面并排两个登录账号。

## 4. 复用边界表

这一节只列“本应只有一份、实际有多份或容易写第二份”的地方。每条都给处数、目标实现，以及不能为了统一而抹掉的行为差异。

### 4.1 折叠特征与局部坐标

`client/lib/ui/display_features.dart` 提供 `isFoldFeature`、`isVerticalFeature`、`isFlatFoldFeature` 和 `translateDisplayFeatures`。平移时只移动 bounds，保留类型和姿态。

| 调用方 | 页面策略 |
| --- | --- |
| Profile 的 `resolveProfilePanelMode`、`foldedPanelWidth` | flat fold/hinge 优先采用折叠外壳。竖向特征可用于定位左边缘；横向 flat 保留半宽回退。 |
| Chat 的 `splitFeatureOf`、`usesSplit` | 查竖向 fold/hinge，允许半开。有竖向分隔时按设备宽 ≥720 判定，无竖向分隔时按可用宽 ≥900 判定。 |
| Home 的 `_appScaffold`、`_splitChatScaffold` | 先减去当前 rail 位移，再按 Chat SafeArea 的原点平移。按钮和聊天边界使用 workspace 局部坐标。 |
| Space 的 `SpaceLayout.of` | 为 Space 页面计算可用区域，考虑 cutout、横向及宽遮挡。按 bounds 分类的页面规则保留在 `space_layout.dart`。 |

800 宽模拟窗口中，屏幕 x=400 的折痕经 92 宽 rail 和 24 左安全区转换为 workspace x=284。该用例复现了按钮偏移，双栏分支当时已生效；用户设备未进入双栏的触发条件仍待采集。[输入矩阵与采集点](../client/docs/dea496-profile-fold-investigation.md)

### 4.2 断点常量

| 值 | 实际位置 | 处数/语义 | 目标实现与备注 |
| --- | --- | --- | --- |
| 900 | ChatWorkspace、SpaceLayout | 桌面聊天与 Space 主从布局 | 分别按各自可用区域与内容策略判断 |
| 720 | ChatWorkspace、HomeView、SpaceLayout | 展开聊天设备宽、首页 rail、Space compact | 各调用方保留本地策略 |
| 600 | Profile、HomeView | 外壳宽度回退、页头头像 Hero | Profile 先判断 flat；页头按宽度选择头像包装 |

| 960 | `client/lib/ui/auth_shell.dart:45` | 1 处，认证专属 | 保留在认证模块，命名 `AuthShell.wideMinWidth`；不要并进聊天/空间断点 |
| 520 | `client/lib/ui/chat/users_view.dart:409` | 1 处，只是列表 gutter | 保留 pane 内局部策略并命名；不是全局断点 |
| 840 / 320 / 236 / 1200 | `client/lib/ui/space/profile/space_profile_page.dart:104-110` | 作者主页自己的目录/侧栏策略 | 840 是“月份目录侧栏”阈值，和 900 的 feed/detail 双栏不是一件事；保留独立命名，不要合并 |
| 1000 / 320 | `client/lib/ui/space/space_layout.dart:19`、`:16` | 发布页双列 / 最小 pane | 保留 `SpaceBreakpoints`；新页面引用已有常量，不写字面量 |

**需保留的行为差异**：

- Chat 的 720 判据用**设备宽**（`displayWidth`），900 判据用**pane 宽**；`chat_workspace.dart:154-163` 的注释解释了 800px 展开折叠屏为什么不能按 708px 判断。任何“统一用 MediaQuery.size”的重构都会在这里回归。
- HomeView 的 720 决定 rail 是否出现；Space 的 master-detail 在 rail 扣除后的宽度上计算。两者不是同一坐标系，先统一坐标系再谈合并常量。
- `SpaceLayout.compact`/`rail` 当前是死字段（`space_layout.dart:166-176`，全 `lib/` 无 `.compact`/`.rail` 读取）；改断点时要么接上，要么删除，别让下一个人以为 Space 在 720 会自己切单栏。

### 4.3 三种外壳共用资料内容

`profile_panel.dart` 中的 `ProfilePanel.build` 用 LayoutBuilder 取得当前面板约束并调用 `_buildContent`。封面、花边头像、昵称、签名和编辑操作随面板尺寸排列。手机保留 Hero 路由，展开屏保留左面板及右侧模糊，桌面保留居中卡片与关闭入口。

### 4.4 尺寸判定

| 实际位置 | 处数 | 现状/差异 | 目标实现 |
| --- | --- | --- | --- |
| `client/lib/ui/chat/message_bubble.dart:202-205`、`:331-332` | 2 套气泡宽度 | 文本 `min(340, width*0.74)`；图片 `min(width*0.66, 420)`；正文内嵌图再固定 `maxWidth: 220`（`:458`） | 在 `ui/chat/chat_format.dart` 或新 `chat_metrics.dart` 提供 `chatBubbleMaxWidth(context, {photo, inlinePhoto})`；保留图片列更宽、内嵌图 220 的差异 |
| `client/lib/ui/chat/message_bubble.dart:913-914`、`:946` | 2 个占位尺寸默认值 | `_MediaImage` 默认 220×120；`_BodyPhoto` 按比例/4:3（`:1155`） | 合并进 §4.5 的缩略图组件；占位尺寸随模式给默认，不散落 |
| `client/lib/ui/profile/profile_panel.dart:933` | 头像与动作 | 面板宽 <360 时头像为 92，否则为 104；宽 <340 或文字缩放 >1.35 时动作堆叠 | 三种外壳共用 |
| `client/lib/ui/profile/profile_artwork.dart:15` | 封面高度 | 面板高度的 25%，限制在 168–260 | 由共享内容传入实际面板尺寸 |

| `client/lib/ui/chat/users_view.dart:409` | 1 条 | <520 只收紧 gutter | 保留局部并命名；不要提升为全局断点 |
| `client/lib/config/media_policy.dart:12`、`:15` | 1 条（正确） | 100 KiB 原图阈值只有这一份 | 不要新增第二个阈值；新图源调用 `mediaNeedsExplicitOriginal` |
| `client/lib/models/chat_models.dart:13` | 1 条（正确） | 32 MiB 上传上限只有这一份 | 保留常量；文案里的 `32 MiB` 应改用 `formatBytes(chatMaxUploadBytes)`。当前有 6 处硬编码文案：`ui/chat/media_actions.dart:83`、`ui/chat/chat_composer.dart:438`、`ui/chat/clipboard_paste.dart:223`、`:512`、`:546`、`services/media_source.dart:235` |
| `client/lib/ui/space/space_layout.dart:58-84` | 1 条 | 双栏左宽 `0.44` clamp 380…560，并保证右栏 ≥320 | 保留空间专属比例；不要和聊天气泡/列表宽度混用 |

**需保留的行为差异**：同一窗口里，文本气泡、图片气泡、内嵌图、Space 卡片正文的宽度策略是刻意不同的；统一成一个 `maxWidth` 会改变换行和图片裁切。目标是“每类一份命名常量”，不是“所有内容一样宽”。

### 4.5 媒体加载

| 实际位置 | 处数 | 现状/差异 | 目标实现 |
| --- | --- | --- | --- |
| `client/lib/ui/media/*` | 1 套（已正确复用） | `PhotoSource` + `PhotoPage` + `PhotoPager` 同时服务聊天和 Space | 不要再写第三个查看器；新来源实现 `PhotoSource` |
| `client/lib/ui/chat/message_bubble.dart:845`（`_MediaImage`）与 `:1082`（`_BodyPhoto`） | 2 个缩略图 widget | 都：一次请求/媒体、失败占位、本地字节优先；但 `_BodyPhoto` 还做 4:3/真实比例、`AnimatedSize`，`_MediaImage` 固定 220×120。两者都直接调 `chat.loadListPreview`（`:880`、`:1137`） | 抽一个 `ChatThumbnail`（输入 `chat/mediaId/localBytes/mode`），保留 `bodyPhoto` 的比例/动画模式和 `pictureMessage` 的固定 tile 模式 |
| `client/lib/ui/chat/chat_photo_source.dart:24-113` 与 `client/lib/ui/space/space_image_viewer.dart:217-260` | 2 个 `PhotoSource` | Chat：heldOriginal 快路径、原图写 `chat-original\|id`、大小探测（`:100-113`）；Space：委托 `SpaceImageLoader`，带 epoch/generation 失效和 thumb/original 变体 | 抽 `CachedOriginalPhotoSource` 基类/helper 统一磁盘 key 读写；保留 Chat 的 heldOriginal、Space 的失效与授权重校验 |
| `client/lib/ui/chat/chat_photo_source.dart:70-78` 与 `client/lib/services/chat_service.dart:2345-2352` | 2 条预览决策路径 | 前者先 `loadMediaMetadata` 再 `loadMediaPreview(thumbnail:)`；后者 `loadListPreview` 也 probe metadata + `mediaNeedsExplicitOriginal` | 在 `ChatService` 暴露一个 `MediaPreviewPlan`（是否 derivative、字节大小），两处都读它；列表必须保留边界：≤102400 字节走 `mediaBytes` 原图，>102400（从 102401 起）才 `loadThumbnail`，viewer 仍要 derivative 标志 |
| `client/lib/ui/chat/viewer_video.dart:48`、`:87`（`ViewerVideoSession`/`StreamingViewerVideoSession`）与 `client/lib/ui/chat/chat_page.dart:1879`（`_VideoDialog`） | 2 套播放器 | 都用回环 URI；viewer 有独立进度/`requestBytes` vs `mediaBytes`/重试；`_VideoDialog` 只做 Android 内嵌 dialog，初始化/重试/释放自成一套 | 抽共享播放组件/控制器（打开、初始化、错误、重试、释放）；保留“全屏 viewer”和“Android 内嵌 dialog”两种 chrome，以及进度 labeling |
| `client/lib/services/media_disk_cache.dart:18` / `:190` | 1 个（正确） | 全进程 256 MiB，聊天原图和 Space 原图共用 | 新代码用 `sharedMediaDiskCache()`；测试可注入不同实例 |
| `client/lib/ui/chat/media_viewer.dart:99`、`ui/home_view.dart:266`、`ui/space/space_controller.dart:82` | 3 个注入点 | 都指向同一个 `sharedMediaDiskCache()` | 保持一个进程一个缓存；不要按页面 new |

**需保留的行为差异**：

- Chat 原图一旦发送，客户端持有 `heldOriginal`，打开 viewer 不应再走网络；Space 没有“刚发送的本地副本”，必须重新读授权图源。
- Space 图片可能因帖子删除/重连整体失效，`changes`/`invalidated` 必须继续生效；Chat 的 media id 不可变，不需要失效监听。
- 列表不是无条件用缩略图：`loadListPreview` 先 probe 大小，≤102400 字节走 `mediaBytes` 原图，>102400（从 102401 起）才 `loadThumbnail`（`services/chat_service.dart:2345-2352`、`config/media_policy.dart:15`）。统一预览逻辑时不能把这个边界改成 `<`、也不能让列表一律拉缩略图或一律拉原图。

### 4.6 权限判断

| 实际位置 | 处数 | 现状/差异 | 目标实现 |
| --- | --- | --- | --- |
| `client/lib/models/space_models.dart:87`、`:186`；`ui/space/space_widgets.dart:427`、`ui/space/space_page.dart:501`、`ui/space/space_detail_view.dart:355`、`:719`、`ui/space/profile/space_profile_posts_module.dart:248` | 1 组服务端能力位 + 5 个 UI 闸门 | 删除/评论等用服务端 `can_delete`/`can_*`；UI 不自行推断业务权限 | 保持服务端标志；可加一个 `SpacePostActions.canDelete` 小 helper 统一“标志 + 回调存在”，但不要把权限算到客户端 |
| `client/lib/ui/space/space_page.dart:476`、`ui/space/space_follow_store.dart:65`、`ui/space/profile/space_profile_controller.dart:45`、`ui/chat/chat_page.dart:350`、`:573`、`ui/chat/users_view.dart:692` | 6 个“自己/对方”身份判断 | 三处 Space 各自拿 `gateway.account`/`viewerAccount` 比较；聊天页比较 peer 和 self；用户列表标记自己。用于隐藏关注按钮/标记行/防串页，不是授权 | 由一个宿主传入的 `viewerAccount` 统一提供 `isSelf(account)`（Space）和 `isSelfAccount`（聊天）；保留“自己不能关注自己”的展示差异，但服务端仍是最终拒绝方 |
| `client/lib/ui/home_view.dart:183`、`ui/chat/users_view.dart:353`、`ui/auth_flow.dart:146`、`ui/space/space_gateway.dart:411` | 4 个 UI 401 判据 | Home/用户列表：401 → `onSessionExpired`；AuthFlow：401 → 清凭据回登录；Space：`isSpaceUnauthorized` → 控制器回调 + 文案。另有服务层 401（`services/auth_service.dart:116`、`:257`、`services/heartbeat_controller.dart:121`、`services/chat_api_client.dart:360`、`:573`） | 在 `AuthFailure` 上提供 `bool get isSessionExpired`（`models/auth_models.dart:65` 附近），UI 只调它；保留 AuthFlow 的“过期”文案和其他页的静默重登差异 |
| `client/lib/ui/profile/profile_panel.dart:849-878`、`:2420` | 2 个“看别人资料/主页”的只读入口 | 资料页可以按账号查看别人的只读资料；主页通过 Space 已授权接口 | 保持只读；不要因为客户端能查账号就认为能改别人资料 |

**需保留的行为差异**：

- 服务端 `can_delete` 是权限事实；`author == viewer` 只能用于“隐藏关注自己”这类 UX，不能替代删除/评论判断。
- Space 的 401 文案是“登录状态已变化，请重新打开空间”（`space_gateway.dart:445`），聊天/主页是静默回登录；统一谓词可以，统一文案会改变产品表达。
- 聊天页的 identity 判断（`chat_page.dart:346-350`）还承担“旧请求不落到新 peer”的竞态保护，不能简化成纯权限函数。

### 4.7 错误提示

| 实际位置 | 处数 | 现状/差异 | 目标实现 |
| --- | --- | --- | --- |
| `client/lib/services/auth_api_client.dart:134-166`、`services/profile_api_client.dart:290-318`、`services/chat_api_client.dart:538-578` | 3 份错误信封解析 | 都解析 `{error:{code,message,fields}}` 并构造 `AuthFailure`；Chat 还保留 `retryAfterSeconds` 并忽略坏 field，Auth/Profile 直接失败到 `upstreamMalformed` | 在 `models/auth_models.dart` 的 `toEnvelope`（`:86`）旁加 `AuthFailure.fromEnvelope(...)`；三个 client 调同一个解析，保留 Chat 的 retry/字段容错参数 |
| `client/lib/ui/space/space_gateway.dart:421-453` | 1 份 code→中文映射 | Space 统一把服务码翻成可操作句子；离线/未授权另有谓词（`:399`、`:411`） | 保留 Space 的映射表；把通用离线/未授权谓词抽到 `AuthFailure`/`ui/failure_copy.dart`，Space 只保留自己的文案 |
| `client/lib/ui/chat/chat_page.dart:1400`、`ui/chat/chat_composer.dart:942`、`ui/profile/profile_panel.dart:899`、`ui/updates/update_settings_host.dart:209` | 4 个 snackbar helper | Chat 两个只 show；Profile 先 hide 再 show；Update host 也是 hide+show；行为不完全一致 | 抽 `showTransientMessage(context, message, {replace})` 到 `ui/widgets/`；保留 Profile/Update 的 replace 语义，聊天不需要的不要强加 |
| `client/lib/ui/home_view.dart:198`、`ui/profile/profile_panel.dart:558` | 2 处相同兜底 | 「资料加载失败，请稍后重试」重复；聊天「消息加载失败，请稍后重试」`chat_page.dart:413`、用户列表 `users_view.dart:374` 各自一份 | 抽 `ui/failure_copy.dart` 的命名兜底常量/`failureText(error, fallback)`；保留各页面具体的兜底措辞（消息/资料/列表） |
| `client/lib/` UI 内 `catch (_)` | 52 处 | 多数是“不把异常原文暴露给用户”的守卫；但兜底文案和是否 401 处理各自为政 | 只把“401 判定 + 通用兜底文案”收口；不要为了消灭 52 个 catch 改成吞异常/统一成一句“操作失败”，那会丢可操作信息 |

**需保留的行为差异**：

- 认证/资料/聊天的 `AuthFailure.message` 是服务端可操作文案，直接展示；Space 故意把服务码翻成产品文案，两者不要互换。
- Chat 的 `retryAfterSeconds`（`chat_api_client.dart:538`）和 429/限流提示不能丢。
- 表单字段错误优先显示 `fields.first.message`（`profile_panel.dart:908-913`）；通用兜底不能盖掉字段级信息。

### 4.8 已正确复用，不要另写

- 图片/视频查看器：`ui/media/` 已被聊天和 Space 共用（§2.1）。
- 头像：`ProfileAvatar` + `ProfileGateway.loadAvatar` + `AvatarCache`；Space 的 `SpaceAvatar` 也走同一授权入口（§2.2）。
- 聊天宽屏：`ChatWorkspace` 只做两栏编排，内部确实是 `UsersListView` + `ChatPage`（`ui/chat/chat_workspace.dart:15-20`、`:406`、`:443`），没有第二套聊天实现。
- Space 关注：`SpaceFollowStore` 被 feed 和作者主页共用（`ui/space/space_follow_store.dart:20`；`ui/home_view.dart:147`）。
- 在线状态：`PresenceDirectory` 被列表和会话共用（`ui/home_view.dart:99`）。
- 更新事务：`ReleaseUpdateController` + `InstallSafetyGate` 是进程级唯一实现；页面只映射展示。
- 磁盘缓存：`sharedMediaDiskCache()` 是进程唯一实例。

## 5. `TaskScheduler`

文件：`client/lib/tasks/task_scheduler.dart`（136 行）。当前唯一消费者：更新包分段下载（`client/lib/updates/release_download.dart:147`）。测试：`client/test/task_scheduler_test.dart`（5 个用例）。

### 5.1 接口

| 符号 | 位置 | 语义 |
| --- | --- | --- |
| `enum TaskExecution { worker, caller }` | `task_scheduler.dart:5` | 任务在哪跑：新 isolate 还是调用方 isolate |
| `TaskCancelled` | `:7` | 取消的统一异常；排队中和运行中都可能以它结束 |
| `TaskScheduler({required int maxConcurrent})` | `:13-17` | `maxConcurrent` 必须 ≥1，否则 `RangeError` |
| `TaskHandle<T> submit<T>(FutureOr<T> Function() task, {TaskExecution execution = worker})` | `:25-33` | 入 FIFO 队尾并立即尝试派发；默认 worker |
| `Future<T> TaskHandle.result` | `:59` | 成功值或错误；取消时为 `TaskCancelled` |
| `void TaskHandle.cancel()` | `:63-73` | 排队中：移出队列，立即 `TaskCancelled`；运行中：worker 杀 isolate，caller 只设标志 |
| 内部 `_dispatch` / `_release` | `:35-46` | 单一预算：worker 和 caller 共用 `_running`；每完成一个就补位 |

### 5.2 两种执行模式

| 模式 | 怎么跑 | 能共享什么 | 不能做什么 | 取消语义 |
| --- | --- | --- | --- | --- |
| `worker`（默认） | 每个任务 `Isolate.spawn` 一个新 isolate，跑完 `Isolate.exit` 回传结果 | 只能捕获可跨 isolate 发送的值/函数；worker 内可做纯 CPU/阻塞计算 | 不能碰 Flutter UI、调用方 isolate 的 `HttpClient`/`RandomAccessFile`/打开的文件句柄、不可发送对象（`ReceivePort` 等）；捕获了会在 spawn 时 `ArgumentError` | 排队中直接取消；运行中 `kill(immediate)`，worker 退出后结果报 `TaskCancelled`，槽位随 `_run` 的 `finally` 释放 |
| `caller` | 在调用方 isolate 里以 microtask 执行，返回 future | 可共享调用方资源（HTTP 连接池、文件、会话、缓存），适合异步 I/O | 不会自动中断正在进行的 I/O；任务必须自己检查取消标志/关闭资源；同一预算下多个 caller 任务会并发改共享状态，需自己串行化 | 排队中直接取消；运行中只设 `_cancelled`，任务自己的 future 结束后才报 `TaskCancelled` 并释放槽位（`task_scheduler_test.dart:130` 覆盖） |

选型规则：

- 纯 CPU、可发送的独立工作 → `worker`。
- 需要复用调用方连接池/文件句柄/会话、或本质是异步 I/O → `caller`；同时自己实现“取消检查点”（例如 `release_download.dart` 的 `ensureActive`）。
- 不确定捕获是否可发送时，不要靠“试试看”；`Isolate.spawn` 的失败会以 `ArgumentError` 出现在 `result` 上（测试 `task_scheduler_test.dart:113` 覆盖）。

### 5.3 并发预算、FIFO、取消、错误

- **并发预算**：只有一个 `_running` 计数（`:21`），worker 和 caller 共享 `maxConcurrent`；没有每类任务独立预算，也没有动态调整。`submit` 立即 `_dispatch`（`:31`），所以先提交的任务先占槽。
- **FIFO**：队列是 `Queue`，`addLast`（`:30`）/`removeFirst`（`:37`）。FIFO 只保证**派发顺序**；因为并发，完成顺序不一定 FIFO。没有优先级、插队、暂停/恢复、队列长度查询。
- **取消排队任务**：`_queued.remove(this)` 成功 → `_task=null`、`_scheduler=null`、`completeError(TaskCancelled)`（`:64-69`）；不会占用运行槽。
- **取消运行中的 worker**：`_worker?.kill(immediate)`（`:71`）；`_runWorker` 的 port 以 exit/错误结束，`_run` 把取消统一成 `TaskCancelled`。
- **取消运行中的 caller**：没有 worker 可杀；只设标志。`_run` 在任务 future 结束后检查 `_cancelled`，所以结果可能是“任务实际已完成，但调用方收到 `TaskCancelled`”（`:85-88`）。取消不是回滚，副作用可能已发生。
- **错误**：任务抛错 → `result` 以同一 error/stack 完成（`:87-88`），槽位释放，队列继续；worker 内未捕获异步错误 → `RemoteError`（`:108-120`）；spawn 失败 → `ArgumentError`；所有路径都在 `finally` 释放槽位。
- **一个任务一个 isolate**：没有 worker 池复用；适合“任务粒度较大”的场景，大量微任务会付出 spawn 成本。

### 5.4 适用 / 不适用

适用：

- 固定上限的并行分段下载/上传（当前更新下载就是 8 段）。
- 一批独立、粗粒度的 CPU 工作，结果可发送。
- 需要 FIFO 排队 + 有界并发 + 可取消的批处理。
- 调用方需要复用连接池/文件的异步 I/O，且能自己实现取消检查点。

不适用：

- 需要低延迟的每帧/每消息小任务（spawn 成本高）。
- 需要长期驻留的 worker 池、优先级、动态扩缩容、进度流、重试/退避策略（调度器不提供）。
- 任务要直接操作 Flutter UI、BuildContext、平台 channel。
- 需要“取消即中断”的 caller I/O：调度器不会替你关 socket/文件；必须像 `release_download.dart` 一样自己 `cancelTasks`/`close(force: true)`。
- 没有观察 `result` 的 fire-and-forget：错误会留在 future 上，可能变成未处理异步错误；要么 await，要么显式 catch。

### 5.5 当前消费者与测试

`client/lib/updates/release_download.dart`：

- 以 `lanes` 创建 scheduler（`:147`），每段 `submit(..., execution: TaskExecution.caller)`（`:163`）；用 caller 是因为共享 `HttpClient`、`RandomAccessFile`、ETag/取消状态。
- 任一段失败：记录第一个错误、`cancelTasks()` 取消其余、`client._http.close(force: true)`（`:155-161`）；`Future.wait` 等全部结束再 flush/close（`:167`）。
- 取消：`_cancelRanges` 在下载期间暴露为 `cancelTasks`（`:144`），上层取消时逐 handle `cancel()`（`:124-128`）。
- lanes 来源：`DownloadLanePreference`（默认 8，可选 1/2/4/8），并按包大小/2 MiB 段数收敛（`release_download.dart:15`、`:32-36`）。

测试覆盖（`client/test/task_scheduler_test.dart`）：

1. 两个同步阻塞任务在独立 worker isolate 上重叠（`:39`）。
2. FIFO 跳过已取消的排队任务；失败释放槽位（`:60`）。
3. 运行中 worker 取消释放槽位并返回错误（`:97`）。
4. spawn 失败与 worker 未捕获错误都释放槽位（`:113`）。
5. caller 取消后槽位保持到 I/O 结束（`:130`）。

### 5.6 使用清单

1. 先判断任务是 CPU 还是 I/O；CPU 且可发送 → `worker`，否则 `caller`。
2. 给一个真实的 `maxConcurrent`，不要用 1 假装串行、也不要用无限大。
3. 每个 caller 任务自己写 `ensureActive`/取消检查，并在取消时关闭自己打开的资源。
4. 必须 await `result`；批量用 `Future.wait`，错误路径先取消其余任务再收集第一个错误。
5. 取消后不要假设副作用没发生；需要幂等/去重就复用业务 operation id，而不是靠调度器。
6. 不要把它当通用任务平台/消息队列/定时器。

## 6. 本文的核对方式与限制

- 行号核对：对每个 `client/lib/...dart:<行>` 用脚本检查文件存在、行号 ≤ 文件行数；对重复项再用 `grep -n` 核对符号所在行。基线见文首。
- 链接核对：本文引用的 `docs/`、`client/docs/` 相对链接均检查目标文件存在。
- 变更范围：DEA-495 原始交付只新增 `docs/client-map.md`；`git diff --name-only` 只应有这一个文件，没有 Dart/服务端改动。
- 未做：DEA-495 文档核查没有运行 Flutter/真机/更新器；本文不构成 QA 结论。§4 的“目标实现”需要下一轮改码时由对应 owner 排期和验证。
- 易漂移点：断点、折叠判据、`TaskScheduler` 行为都以源码为准；如果本文与源码冲突，先信源码并更新本文。
