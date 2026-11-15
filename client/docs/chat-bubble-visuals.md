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

## 用户返稿记录

| 日期 | 意见 | 修改 | 适用场景 |
| --- | --- | --- | --- |
| — | 暂无返稿 | — | 本条为首次交付；收到返稿后按具体区域/场景记录，不升级为通用禁令 |
