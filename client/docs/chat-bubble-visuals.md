# 聊天气泡、发送反馈与动效（DEA-475）

基线 `43967a2729eac456c09b0be7509d4fa888c49168`。本轮只改 Flutter 客户端展示层与本地发送反馈，
没有改 server/contract、DSH、头像/媒体下载或消息业务类型。

## 状态语义（先说事实）

| 界面状态 | 唯一依据 | 不表示 |
| --- | --- | --- |
| 发送中… | `ChatComposer` 已发起 composed send，等待 `sendComposed` 返回 | 服务端已接受 |
| 已提交（时间戳） | `sendComposed` 返回 `ChatMessage` | 对端收到、正文已读 |
| 未发送 · 点按重试 | 该项 `SendOutcome` 无 message；操作仍留在本地 | 消息已丢失或已发出 |
| 下载中… | 既有下载事件，本轮未改 | 发送成功 |

本地气泡的 identity 为 `seed-b` / `seed-aN`。重试复用同一 operation id，走既有 ledger 幂等与
`client_nonce` 去重；界面没有新增“已送达/已读”之类服务端未提供的事实。动画结束从不改变状态。

## 视觉参数

| 项 | 值 | 理由 |
| --- | --- | --- |
| 气泡圆角 | 18px，发送方底角在 run 结束时 6px | 保留方向感，避免每个气泡都画尾巴；同组连续消息更整齐 |
| 最大宽度 | `min(340, 视口宽 × 0.74)` | 手机 390px 时约 288px，桌面仍 340px，长文本不被拉成整屏 |
| 内边距 | 14 / 9 / 14 / 8 | 比旧版略紧，长段落不显松散；时间行单独占 14px |
| 连续消息间距 | 同 run 2px，新 run 10px | 用留白表达分组，不靠分隔线 |
| 头像/昵称 | 头像 32px，仅在 run 的最后一个气泡显示；隐藏时占位保持文字对齐；1:1 不重复昵称 | 减少连续消息的重复头像；对话人身份已在标题栏 |
| run 判定 | 同一发送者、同一本地日期、间隔 < 5 分钟 | 与既有 `shouldShowGapLabel` 的 5 分钟一致 |
| 时间/状态 | 11px，右对齐，发送方白字 78% 透明度；失败用 danger 色 | 时间可见但不抢正文；失败可辨识 |
| 底色 | 发送方 accent teal，接收方白底 + border；失败 dangerSurface | 沿用 `AppColors`/`AppRadius`，没有新增主题 |

浅色主题是产品当前唯一主题；没有引入第二套深色主题（避免本轮扩大主题范围）。

## 动效

| 触发 | 行为 |
| --- | --- |
| 真正的新消息（本地发送、轮询新增） | 240ms，透明度 0→1 + 上移 6px→0，`easeOutCubic`；每个气泡元素只启动一次，pending→已提交继续同一段动画 |
| 历史加载、刷新、切会话、滚动重建 | 不播放。已播放过的 identity/operation id 在首帧后即消费；pending 滚出再回来也不重播 |
| pending→已提交 | 继续同一段入场，不重启动画；状态行 150ms 淡换 |
| 系统减少动画（`MediaQuery.disableAnimations`） | 完全跳过入场动画与状态淡换 |

动画不等待、不阻塞请求：`_send` 先插入本地气泡并立即发请求，动画只跟随状态。列表滚动在
距底部 96px 内才自动跟随新消息；用户向上看历史时不会被拉走，自己发送则主动显示自己的气泡。
懒加载列表的 maxScrollExtent 会随构建增长，落底时先动画再少量 jump 纠正，避免停在半途。

## 并发与稳定身份

- 输入框与附件按钮在发送期间保持可用；连续发送各自生成独立 seed，互不取消。
- 每个本地气泡/已提交消息按 operation id 或 `id@position` 建 key；轮询与发送并发仍按
  `id@position` 合并去重，不重复气泡、不串会话。
- 失败项保留在 `_failed`，发送新消息不会清掉旧失败项。

## 未改动的边界

- 附件下载/播放/另存为、媒体查看器、剪贴板、图片/视频上传与顺序、通知与多会话 ledger 未改。
- 没有新增消息类型、没有改 API/DTO/契约；上传进度仍只在真实下载/上传事件存在时展示。
- Android/Windows 未运行；Linux 桌面实机截图只代表该环境。

## 证据（本轮）

- 真机式 Linux 客户端（Xvfb + 真实 FastAPI + 隔离合成账号）前后截图与录屏：见 issue 评论附件。
- Widget/单元：`client/test/chat_send_feedback_test.dart` 覆盖发送中→提交、失败→同 operation
  重试、入场只给新消息、减少动画、历史阅读不被拉底、连续两条在途、手机/桌面/1.6 倍文字无溢出。
- 截图渲染：`QA_CHAT_SCREENSHOT_DIR=.qa-artifacts/screenshots flutter test test/chat_screenshot_test.dart --update-goldens`。

## 视觉参考与版本

- 本轮基准是仓库自身：`docs/images/chat.png` 的既有聊天界面、`client/lib/app.dart` 的
  `AppColors` / `AppSpacing` / `AppRadius`，以及 `UsersListView` / `ChatPage` 现有层级。
  没有引入 Figma/Pencil、外部组件库或第三方品牌素材；Astryx 未被使用。
- 1:1 连续消息合并头像、发送方方向性圆角、底部对齐时间属于通用消息列表惯例，本轮按其
  可读性目标自选参数，不复制任何产品截图。
- 动效 240ms / `easeOutCubic` / 6px 上移与 Reduce Motion 跳过是本实现自选参数；未联网引用
  外部规范，不声称照搬 Material 或 Apple 的 token。
- **改前截图**由基线 `43967a2` 构建（不含本 PR）；**改后截图**由本 PR 固定 SHA 构建。两组用
  同一隔离 DB、同一组合成账号、同一四条消息、1180×780 与 390×844 同一窗口尺寸。上一轮
  “附件均最终 SHA 构建”的说法不准确，以本节为准。

## Sentinel 复验修复（revision 2）

1. **已接受但响应延迟时重复气泡**：不再按内容/时间猜测 operation。发送在途时，轮询或刷新
   读到的本人消息先暂存、不渲染；本地 pending 行保留。失败时以
   `GET /operations/{operation_id}`（现有权威接口）核对该 operation 是否 succeeded 及其
   message：只有该记录能证明消息归属。确认成功则绑定该 message 到 operation id 并移除本地
   失败/重试；否则释放暂存消息（它们属于其他 operation/设备），保留失败气泡与重试入口。
   同一 operation 的重复观察按 `id@position` 去重。该查询只读，不改契约、不写共享状态。
2. **异步失败抢走历史位置**：只有“新的 sending operation”出现时才强制显示自己的气泡，且
   立即 jump 不播放滚动动画；失败、重试、成功回执只在距底 96px 内跟随。用户开始拖动列表会
   使排队中的程序化滚动失效（epoch），不再与手势抢位置。
3. **pending→committed 重建 entrance State**：ListView 的直接子节点（日期分隔、时间分隔、
   消息行）都带上稳定 key，消息行以 operation id 为 key。跨日期插入分隔时同一 operation
   复用同一 `MessageEntrance` State；回归测试直接比较实际 State 对象，而非嵌套 key。

## Sentinel 复验修复（revision 3）

- **误配**：上一版内容/时间启发式会让另一 operation 的同文/同媒体消息吞掉本地失败。现改为
  “在途暂存 + `GET /operations/{id}` 权威关联”，不比较正文、媒体 id 或时间。覆盖 poll 与
  refresh 两条入口；同文、同媒体、乱序返回、真实同 operation 重复观察都有回归。
- **验证**：Sentinel `review_probes` 两套共 5 例通过；现有测试入口新增 5 例（同文 poll/refresh、
  同媒体、乱序返回、失败但 operation 已提交）。新增查询只读，未扩展接口。
- 视觉层级、动效参数与布局代码未改；最终 SHA 的静态前后截图与动态证据见 issue 评论。

## Sentinel 复验修复（revision 4）

- **查询在途窗口**：暂存条件从“存在 sending”扩大为“存在 sending 或 operation 查询在途”
  （`_shouldHoldSelfMessages`）。POST 已提交但网关丢失响应、`GET /operations/{id}` 仍延迟时，
  poll/refresh 读到的已提交消息继续暂存，页面只保留本地失败行；查询成功后才绑定并合一。
- **失败/重试交错**：查询失败时释放暂存消息（已提交事实可见）、本地失败与重试保留；查询
  成功则绑定并移除失败；查询在途时用户点重试，重试成功与查询返回都按 identity 去重，不重复。
- **覆盖**：新增 poll/refresh 查询窗口、查询失败后重试、查询与重试交错 4 例；Sentinel
  r3 `operation_lookup_window_test.dart` 2/2 通过（临时运行，未提交探针目录）。游标在暂存时
  仍连续推进，暂存消息按 identity 去重并在释放时合并；没有恢复任何内容启发式。

## Sentinel 复验修复（revision 5）

- **查询失败不是 operation 不存在**：`GET /operations/{id}` 网络/服务错误时，把 operation 放入
  `_unresolvedOperations`，继续暂存本人消息、保留本地失败与重试，不再释放成两条。只有权威
  404/空结果（operation 未提交）才释放暂存；succeeded 则绑定并移除失败。
- **恢复**：`_unresolvedOperations` 非空时继续 hold；后续 poll/refresh 自动重查（同一 operation
  不并发重复查询），成功后绑定并只显示一条；用户重试成功也走同一清除路径。
- **覆盖**：新增查询失败 poll/refresh、失败后后续轮询重查成功、查询与重试交错；Sentinel r4
  `operation_lookup_failure_test.dart` 2/2 通过（临时探针，未提交）。此前的同文/同媒体/乱序/
  查询窗口反例继续保留，未恢复内容启发式。

## Sentinel 复验修复（revision 6）

- **pending/uncertain 不是 not-found**：`GET /operations/{id}` 返回 `OperationStatus.pending` 或
  `uncertain`（本地 uncertain/prepared 记录、远端暂时 404）时，保留 `_unresolvedOperations`
  与暂存消息，失败气泡与重试继续显示；只有 `succeeded` 才绑定并移除失败，只有
  `failed`/权威 null 才释放暂存。
- **重查**：后续 poll/refresh 对未决 operation 重查（同一 operation 不并发重复查询）；若转发
  请求随后提交，下一次查询成功后只显示一条。重试成功也走同一清除路径。
- **覆盖**：新增 pending poll/refresh、uncertain、后续提交恢复；Sentinel r5
  `pending_operation_test.dart` 3/3 通过（含真实 ChatService 语义测试）。未恢复内容启发式，
  未改契约。

## Sentinel 复验修复（revision 7：大字状态行）

- 状态行不再用固定 `SizedBox(height: 14)`；改为 `minHeight: 14`，由文字缩放决定实际高度。
  失败/发送中的 `Row` 文本改为 `Flexible`，空间不足时换行而不是横向裁切。
- 时间、发送中、失败/重试共用同一状态槽；状态切换（sending→failed→time）时高度随内容变化。
- 回归：1.6 倍文字下用 `RenderParagraph` 与实际 `TextPainter` 比较高度，时间/发送中/失败三种
  状态都必须完整布局；390×844 下无异常。Sentinel r6 `scaled_status_test.dart` 2/2 通过。

## R8 阶段 A：UI 回调顺序（revision 8）

本阶段只修不依赖新字段的页面时序；`ChatMessage.operationId` 接入与全局 hold 删除留给下一阶段。

入口与规则：

- **发送成功**：`Composer._send → _applyResult → onSent/onSentOperations`。已提交消息先合并，
  operation 映射随后写入；不会因后续查询被降级。
- **发送失败/查询成功**：`_resolveFailedOperation` 先检查该 operation 是否仍是 failed pending；
  过期查询直接返回，不改 `_resolvedOperations`/`_unresolvedOperations`，不遮住其他消息。
- **查询 catch/finally**：catch 只在“仍存活 failed pending”时加入 unresolved；finally 只移除
  自己的 `_resolvingOperations` 条目，并按全局 hold 条件决定是否释放；不清理别人的请求。
- **重试**：`_retryOne` 复用幂等 ID；`_onPendingChanged` 在 failed→sending/移除时清理该
  operation 的 unresolved。迟到成功/错误查询不能重建未知状态。
- **poll/refresh**：`_loadInitial`/`_pollNew` 仍按全局 hold 暂存本人消息（本阶段保留的已知
  机制缺陷）；迟到查询完成后只按自己的 operation 更新；已推进的游标不倒退。
- **切会话**：`dispose` 后旧查询仅在 mounted 检查外返回，finally 不会触碰页面状态；新增
  dispose 后完成查询的回归。
- **未解决**：关联字段未接入前，“另一来源已提交本人消息被全局 hold 隐藏”的 Sentinel 红例
  继续保留，不通过扩大 hold 或改断言处理。等 Forge 关联提交后使用 `ChatMessage.operationId`
  精确关联并删除全局 hold。

本阶段新增迟到成功/错误查询后重试的永久回归、dispose 回归；Sentinel `b2473ec`
`association_test.dart` 的 2 个 late lookup 用例通过，13 个“无关 B 可见性”红例保留（10 pass /
13 fail，exit 1，符合修前边界）。未改 models/services，未交终验。

## 用户返稿记录

| 日期 | 意见 | 修改 | 适用场景 |
| --- | --- | --- | --- |
| — | 暂无返稿 | — | 本条为首次交付；收到返稿后按具体区域/场景记录，不升级为通用禁令 |
