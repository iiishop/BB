# DEA-493 一对一会话：分组、媒体预览、键盘联动与双栏

基线：BB `96cd0252fb66f2323daf1097630ebbabc3c4a6b8`。分支 `agent/muse/53c083bf36ab`。
本轮只改 `client/` 与 `client/test/`，未改 `server/`、`server/contract/`、`dsh-plugin/`。

## 1. 组件复用（同一实现，不是第二套外观）

| 表面 | 实际复用 | 证据 |
| --- | --- | --- |
| 手机会话列表 | `UsersListView` | `lib/ui/home_view.dart` 窄屏入口 |
| 桌面/折叠双栏左栏 | `UsersListView`（同一 StatefulWidget、同一 30s 轮询与“只看在线”） | `lib/ui/chat/chat_workspace.dart` `_listPane` |
| 手机聊天页 | `ChatPage`（路由） | `home_view.dart` `_openChat` |
| 桌面/折叠右栏 | `ChatPage`（`embedded: true`，仅去掉返回键） | `chat_workspace.dart` `_chatPane` |
| 气泡/媒体/输入/预览器 | `MessageBubble`、`ChatComposer`、`MediaViewer` | 两端都由 `ChatPage` 构造 |

双栏没有复制气泡、输入框、媒体卡或预览器代码；`ChatWorkspace` 只组合、选中和布局。
`chat_workspace_widget_test.dart` 断言双栏内出现同一个 `UsersListView` / `ChatPage` 类型。

## 2. 交互实现

- **连续消息分组**：`MessageBubble.showAvatar` 改为只在 run 首条为真；同 run 后续保留 32px
  占位保持同一条文字边。run 判定仍是“同一发送者、同一本地日期、间隔 < 5 分钟”。
  头像在组首气泡顶部对齐，底部圆角仍按 run 结束收紧。
- **图片**：正文图片进入现有 `MediaViewer`，列表用固定 4:3 槽位（200×150）预留空间，
  预览到达不会推移文字。
- **视频**：封面为主，居中播放标记；下方常驻“播放/下载/另存为”三个按钮移除，保留一行
  `文件名 · 大小` 小字。整张封面可点进入既有 `MediaViewer` 视频页；播放、下载、另存为仍在
  消息长按/桌面右键菜单。列表只取封面，不自动播放、不预取原视频。
- **原位转场**：点击缩略图时对 `RepaintBoundary` 取真实全局矩形与快照，用
  `PageRouteBuilder` 把该画面从列表位置展开到全屏，预览器在后半段淡入；返回时反向收缩。
  转场不改 `MediaViewer` 内部的播放、缩放、翻页、下载和手势。返回后滚动位置不变。
- **新消息入场**：默认 160ms，透明度 + 上移 6px；仅“此前不在屏上的 identity”触发，
  历史、刷新、滚动重建不重播；系统减少动画时完全跳过。
- **历史阅读**：距底 96px 内才跟随；翻历史时保持像素位置，显示“↓ N 条新消息”浮层，
  点击才回到底部。自己发送始终显示自己的气泡。
- **输入区**：有可发送内容时发送键使用 accent 深色，空输入为低对比边框色；失败仍在对应
  消息旁重试。附件入口保留。
- **键盘**：`resizeToAvoidBottomInset: false`，把 `viewInsets.bottom` 作为整列底部内边距
  （160ms 过渡），页头坐标不变，消息区与输入框一起抬升；键盘高度动画期间按 metrics 变化
  重新钉住底部，避免只抬输入框或二次跳。历史位置打开键盘不改滚动偏移。
- **桌面双栏**：≥900px 无折叠特征时双栏；左栏仍是现有列表，右栏是嵌入的 `ChatPage`。选中按
  account 保存，列表刷新/重排后高亮跟随同一联系人。每个打开过的会话用 `IndexedStack`
  保持 State，因此滚动位置、草稿文本和光标位置按会话独立恢复；A 收到新消息时不在 B 中
  强制滚底。隐藏页仍可轮询数据，但只把展示事实暂存；只有该页重新成为可见会话时才提交，
  避免后台轮询提前清掉 A 的未读。轮询在切走前已发起、返回时已隐藏的竞态同样按返回时的
  `active` 判定。
- **折叠屏**：存在竖向的 `DisplayFeatureType.hinge` 或 `DisplayFeatureType.fold`
  （零宽平折痕也算）且设备宽度 ≥720px 时默认双栏；横向折痕不当作左右分栏。双栏之间只留
  **20 逻辑像素**的分隔带（把手 16 + 两侧各 2 留白，横向点击区不出这条带），中间是一条
  分隔线加中段的一枚窄把手：双栏时把手在分隔线上、箭头朝左表示可展开；全屏时把手贴在
  左缘、箭头朝右表示可恢复。把手高 56，按下或键盘聚焦时才加深轮廓。遇到实体铰链时把手
  落在可触侧（铰链右缘之外）。展开时聊天区右边缘固定、左边缘从分隔带移到 0，使用
  `easeOutBack` 产生一次越界回弹（约一帧越过屏幕左缘）后停稳；内容宽度变化但不缩放文字
  或头像。减少动画时直接切换。

## 3. 契约边界

- 未改 REST/WS DTO、消息类型或服务端。
- **时长缺口**：共享 `Media` DTO（`server/contract/src/bb_auth_contract/chat.py`）只有
  `media_id/media_type/filename/mime_type/byte_size/cover_media_id`，没有视频时长字段。
  因此视频条显示封面、播放标记、文件名与大小，**不显示时长**；不伪造、不额外探测原视频。
  需要“已有时长”时由契约增加字段后再接。
- 选中会话复用既有 `markConversationViewed` 记录展示事实；自动选中首个会话不写 viewed。
  仍是展示记账，不是消费 ACK 或对外已读。

## 4. 自测与证据

命令（Linux 测试机，Flutter 3.47.9 / Dart 3.13.7）：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test test/chat_workspace_widget_test.dart test/chat_hidden_display_test.dart \
  test/chat_motion_input_test.dart
flutter test test/chat_send_feedback_test.dart test/chat_flow_widget_test.dart \
  test/chat_online_filter_test.dart test/chat_media_viewer_widget_test.dart
```

新增/更新的定向用例：

- `chat_workspace_widget_test.dart`：双栏复用、按会话滚动/草稿/光标恢复与高亮跟随、
  折叠双栏→全屏→双栏的果冻越界和状态恢复、铰链避让、零宽 `fold` 仍有开关、
  展开后历史锚点与草稿/光标保持、手机仍走路由。
- `chat_hidden_display_test.dart`：隐藏会话收到新消息不清未读、轮询在切走后返回即使请求
  已发起也不记展示、页面重新可见时提交暂存的展示事实。
- `chat_motion_input_test.dart`：键盘整体升降与页头固定、底部重钉、历史打开键盘不跳、
  纯文字输入不撑高输入区、
  “↓ N 条新消息”计数与点击回底、组首头像、160ms 入场、发送键强调、视频无常驻按钮/
  长按菜单/进入并返回原位、图片原位转场。
- 既有 45 例发送反馈、列表在线筛选跨尺寸、媒体预览器、消息顺序/历史测试保持通过。

截图与录屏：`test/chat_transition_screenshot_test.dart`（opt-in）生成
`dea493-workspace-dual.png`、`dea493-foldable-dual/full/restored.png`、
`dea493-fold-00..13.png`、`dea493-keyboard-closed/00..10/history-open.png`、
`dea493-new-messages-pill.png`；帧序列由 ffmpeg 合成 GIF/MP4 后随 issue 评论交付。
这些是 **Flutter widget test 渲染帧**，不是 Android/Windows 运行时录屏。

## QA 返工（QA r1）

两份反例已进入常规测试，均改在原组件上：

1. **隐藏会话提前记展示**：`ChatPage` 增加 `active`，`_recordDisplayed` 拆为
   `_stageDisplayed`/`_flushDisplayed`；隐藏页只暂存，重新可见时提交。轮询/刷新都在
   返回时按当时的 `active` 判定，因此“发起轮询后才切走”也不会落账。`ChatWorkspace`
   只给当前选中会话传 `active: true`。
2. **零宽折痕没有开关**：`ChatWorkspace` 的拆分特征从只认 `hinge` 扩展到竖向的
   `hinge` 或 `fold`；零宽 `fold` 走同一套分隔带、把手和展开动画。
3. **输入文字时输入区被草稿条撑高**：QA 锚点探针暴露纯文字也触发 64px 草稿条。
   现在草稿条只对应已暂存的图文 part / 附件，纯文字只影响发送键强调，输入区高度保持
   稳定；历史锚点在双栏→全屏→双栏后仍可见。

## QA 返工（QA r2）

两份反例都在**真实登录首页**（`main.dart` 传入 Space 服务 → 外层 92px 导航栏 +
`IndexedStack` 页面栈）里复现，修复同样落在原组件：

1. **Space 遮挡聊天时仍记展示**：选中会话只回答“哪一个会话”，不回答“是否可见”。
   `HomeView` 把当前分区可见性传给 `ChatWorkspace.visible`，`ChatPage.active` 改为
   `visible && account == _selected`。频道被 Space 盖住时轮询/初载/刷新只暂存，切回聊天
   分区重新变可见时才 `_flushDisplayed` 提交。
2. **带导航栏时全屏停在 x=92**：`HomeView` 的页面栈改为画在导航栏之上的
   `Positioned(left: rail)`，导航栏在下层；分栏坐标统一使用“导航栏右侧”的本地帧
   （`MediaQuery.displayFeatures` 按当前 rail 宽度平移），因此双栏分界落在真实铰链上。
   展开时两者共用 `HomeView` 的 `_foldController`：页面栈左移、rail 被盖住，聊天左缘
   从 gutter 走到屏幕 x=0，右缘固定；`easeOutBack` 的越界回弹仍由聊天自身完成
   （rail 侧按 clamp 处理，不会出现负宽度）。折叠特征消失（改窗口/旋转）时下一帧把
   controller 归零，避免导航栏被永久藏起。
   轨道槽位固定为 `Stack` 第 0 个子节点（窄屏用 0 宽占位），避免手机/桌面切换时错位
   重建 Space 状态树。

回归：`test/chat_hidden_display_test.dart`“Space 分区覆盖外壳时不能提交聊天展示事实”、
`test/chat_workspace_widget_test.dart`“登录外壳把聊天展开到屏幕最左并盖住导航栏”
（含全局坐标、右缘固定、导航栏不可命中、阅读位置/草稿恢复、双向切换）。
两例在修复前的 `d5a7571` 上均失败：未读被写成已展示（`Set:['m31']`），全屏后聊天左缘为
`680`（即屏幕 92 偏移下的 588）。

## QA 返工（QA r3）

1. **同一张图出现在两条消息里 → 重复 GlobalKey**：转场锚点原来只用 media id 做 token，
   两条真实消息引用同一 media 时，两个 `RepaintBoundary` 拿到同一个 `GlobalKey`，
   `ListView` 直接抛 `Duplicate GlobalKey`。现在 token 是“这一次出现”——
   `media:<message.id>:<partIndex 或 attachment>`；气泡把 message 和内容槽位一起传给
   `originKeyFor`，`_openMedia` 用同一 token 取锚点，所以点哪张缩略图就从哪张展开。
   列表里 `chat-media-<mediaId>` 的 ValueKey 仍按媒体（彼此父节点不同，只用于测试定位）。
2. **800px 展开屏只剩列表**：720 是**设备**展开宽度，而登录外壳先扣掉 92px 导航栏再判断，
   只剩 708 → 判成单栏。`ChatWorkspace.usesSplit` 与 `canExpand` 增加 `displayWidth`：
   有竖向折痕时用设备宽度判断 720，没有折痕时仍按工作区宽度判断 900（桌面阈值语义不变）。
   `HomeView` 传外层 `constraints.maxWidth`，`foldCapable`（rail 收起动画）同口径。
   800×840、x=400 零宽折痕：双栏、右栏起于 400+20（当时 56 的分隔带；现为 400+10）、展开到屏幕 x=0 后
   能恢复同一双栏。
   顺带修正：`usesSplit` 有折痕时不再要求工作区自身 ≥720，否则宽展开设备同样会被截断。

回归：`test/chat_motion_input_test.dart`“同一张图出现在两条消息里：两块缩略图各自作为
转场起点”（分别点开并核对转场首帧矩形属于被点的那一块）、
`test/chat_workspace_widget_test.dart`“窄展开屏仍分栏：导航栏不能吃掉 720 断点”。
两例在修复前的 `942fdf8` 上分别报 `Duplicate GlobalKey` 和
`Found 0 widgets with key [chat-workspace-chat-pane]`。

## 折叠屏窄把手（本次）

- `ChatWorkspace.foldGap` 从 56 收到 20：分隔带 = 把手 16 + 左右各 2；`foldHandleWidth=16`、
  `foldHandleHeight=56`。分隔带就是两栏各自让出的全部宽度，横向点击区不超出它，所以旁边
  的列表行和消息气泡照常可点、可滚。分带位置按设备分界算：折痕让 20 跨在折痕两侧各
  10（把手压在折痕上）；实体铰链让列表止于铰链左缘、把手与整块点击区落在铰链右侧可触区，
  铰链本身不计入这 20。判定按 `DisplayFeatureType`：Flutter 的 `hinge` 就是物理不可触间隔，
  宽度可以只有 4~7 逻辑像素，用宽度阈值判断会把把手压到窄铰链上。折痕布局去掉列表右边框，
  只保留分隔带中间那一条线。
- 把手是分隔线中段的一个白色圆角胶囊 + 12px 方向箭头，沿用 `AppColors.border` /
  `AppColors.surface` / `AppColors.accentDeep`；只有按下（InkWell highlight）或键盘聚焦时
  边框才变成 `accentDeep`。
- 全屏时把手贴在屏幕左缘（带 2px 内缩），展开动画最后约 60px 才淡入；收起时等聊天区
  扫离分隔带后再淡入，避免把手在过渡中浮在消息上。
- `Stack` 子节点顺序固定为“列表 → 分隔线 → 聊天 → 把手”。此前把手在两个状态间切换
  `if` 分支会让聊天页在 `Stack` 里换位置，`ChatPage` 被重建，阅读位置被重置到底部——
  这也是“展开后阅读位置丢失”的真实原因，不是重排。

回归：`test/chat_workspace_widget_test.dart` 新增“the fold grip fits the 20 lp divider
band and points the right way”（零宽折痕：占宽 ≤20、高 56、在分隔带内、箭头方向、全屏贴
左缘）、“the grip keeps clear of a real hinge and of both panes”（实体铰链：把手在可触侧
不压铰链、同高处的列表行仍可点、紧邻分隔带的纵向拖拽仍滚动消息），以及按 4/7/8/40 逻辑像素
铰链参数化的“a N lp hinge keeps the grip and its hit band on the touchable side”
（列表止于铰链左缘、把手不与铰链相交、带外占宽 ≤20、双向切换）。窄铰链两例在
`e7eca23` 上失败（列表 502、把手压铰链），修复后通过。


## 视觉返工（参考图对照）

按本单线程的参考图重做页头以下的共享聊天组件，手机与双栏同一实现（`ChatPage` /
`MessageBubble` / `ChatComposer`），没有第二套外观：

- **底色与气泡**：会话底色 `AppColors.chatPaper`（暖奶白），对方气泡 `bubblePeer`（米色），
  自己气泡 `bubbleMine`（很淡的灰青绿）；两侧正文统一 `AppColors.ink` 深色、
  `FontWeight.w400`、15.5/1.45。组首气泡在靠头像一侧带 7×10 小尖角。
- **收宽**：气泡用 `IntrinsicWidth` + `maxWidth`，短句随文字收宽、长句到上限换行；
  自己发言靠右且**不再有头像占位**，他人同一组只在首条露头像，后续文字与图片左缘对齐。
- **时间**：逐条时间脚注移除，改为每组起始一行居中的时间（当天第一组带“今天”），
  键 `ChatPage.groupTimeKey`。发送中/失败提示与点按重试仍留在气泡内。
- **正文照片**：只有图片的消息渲染成独立照片块 —— 原比例（读 PNG/JPEG/GIF 头取尺寸，
  未知时按 4:3 预留）、约消息区 2/3 宽、圆角直接裁在照片上、无气泡底与时间；
  点击仍进既有预览器并从原位展开/返回。加载完成到真实比例时用 160ms `AnimatedSize` 过渡。
- **输入区**：左侧圆形加号（`ChatComposer.attachMenuKey`）收纳原有“图片/附件”入口，
  中间细描边胶囊输入框，右侧圆形发送键（深青底 + 右箭头）在有草稿时点亮。
- 截图工具：`test/chat_visual_reference_test.dart`（opt-in）用同一手机尺寸与同一内容
  生成改前/改后对照，以及双栏版本。

回归：`test/chat_bubble_visuals_test.dart` 覆盖收宽、尖角、时间居中、自身无头像占位、
照片原比例/宽度/无气泡、输入区结构与发送键强调；相关旧用例（发送反馈、头像、输入快捷键）
按新设计更新。

## 5. 未测 / 限制

- 无 Android 真机或模拟器（`adb devices` 为空）；未在 Android 实机验证 IME 动画、返回手势、
  视频播放器与折叠屏铰链。折叠屏证据来自注入 `DisplayFeature` 的 widget 渲染。
- 未在 Windows 桌面运行；桌面双栏证据是 Linux widget 测试视口。
- 未验证真实物理键盘/输入法、系统字体、真实视频时长（契约无字段）。
- 全量 `flutter test`、`flutter analyze` 结果以最终候选 SHA 在 issue 回填。
