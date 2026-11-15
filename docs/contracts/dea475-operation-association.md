# DEA-475 R8：operation 与消息关联方案

本轮是契约/入口取证，**没有实现新机制，也不是终验**。依据用户评论
`01a1dd79-dd9e-79f3-bc43-113f3c792100`、Orion 派发
`01a1dd7b-589a-785f-ab5d-e084fb92bc50` 及其状态时序补充
`01a1dd80-f5df-775d-bff3-fde3f5889797`。用户验收仍为原五项行为；以下权限、兼容、状态合并与回归是实现这些行为的必要条件，无额外产品需求。

## 版本、范围与结论

- 产品基线：`3a523a888663d7f67bed0951bce2da451b75db00`，PR #24。
- Forge run：`01a1dd7b-58ae-769c-951d-d3bb3e628b56`。
- 独立 checkout：`dea-475-d3bb3e628b56/workdir/BB`；分支 `agent/forge/d3bb3e628b56`。
- 本轮仅新增本文与同级 `dea475-operation-association-evidence/`；没有改产品、共享 fake、UI 或现有测试。
- Project description/resources 已读取；checkout 内无额外 AGENTS.md，遵循工作区 AGENTS.md。后续 Forge 唯一维护服务端/共享契约、客户端 models/services 与服务测试；Muse 唯一维护 UI 并集成到 `agent/muse/3057c1d77978`。

结论：已有 SQLite `operations` 是唯一权威关联，无需再建关联事实库。应按读取账号投影关联到消息，UI 按精确身份替换 local echo，移除全局 hold。**无条件增加可选 JSON 字段并不兼容全部旧调用方**：Dart 忽略未知字段，但旧 Python DSH 严格响应校验会拒绝。建议服务端显式协商扩展，保留默认旧响应；本地 v2 保持原外部格式和 consumer 隔离。

另一个独立修复点是状态更新顺序：确定提交事实优先于旧查询的失败/未知结果。仅补消息字段不能修复迟到 catch 重新建立 unresolved。

## 1. 当前事实来源、权限和读入口

行号均针对产品基线。`server/src/bb_server/app.py:172` 从 Bearer session 推导账号，不能由请求提供 sender。`storage.py:54` 提供只读快照和 `BEGIN IMMEDIATE` 写事务。

| 入口 | 实际返回 / 共同实现 | 当前权限与关联事实 |
|---|---|---|
| POST `/messages`、`/messages/attachments` | `chat.py:222` / `226` → `submit:96` → `Message` | 身份账号发送给存在的其他账号；媒体必须属于该 pair；请求 `client_nonce` 是幂等 operation ID，响应 Message 无关联 |
| GET `/operations/{operation_id}` | `chat.py:230` → `Operation`，实际只 `succeeded + message` 或 404 | WHERE `o.account = session.account`；对端、第三方不能读取发送者的 operation；同字符串可由另一账号独立使用 |
| GET `/conversations/{account}/messages` | `chat.py:246` → `chat_queries.history/select_history` → `MessagePage` | 按读取账号与 peer 的 pair；双向分页、升序消息；当前只解析 payload |
| GET `/messages/{message_id}` | `chat.py:272` → `chat_queries.message/find_message` → `Message` | sender 或 target；不存在/非参与者统一 404 |
| GET `/messages/{message_id}/context` | `chat.py:276` → `chat_queries.context` → `MessageContext` | 先 ACL 检查 anchor，同一快照查询前后页；所有嵌套 Message 当前均无关联 |
| GET `/conversations` | `chat.py:262` → `chat_queries.conversations` → `ConversationPage` | 只本人参与会话；`last_message` 是完整 Message，必须纳入共同投影 |
| GET `/users` | `chat.py:291` → `UserPage` | `last_message` 只是 Preview（id/sender/username/preview_body），不是 Message；不需要添加 operation |
| GET/WS `/events`、GET `/events/head` | `chat.py:event_page`，事件含 message_id/peer/position；head 是 cursor | account 过滤；事件只通知可取，不携带完整消息，也不表示已读；通过受权消息读取取得关联，不扩大事件 schema |

共享定义是 `server/contract/src/bb_auth_contract/chat.py`、`chat_query.py`、`chat_v2.py`。
`Wire.extra="forbid"`，Message 当前无 operation 字段；服务端也以该模型校验响应，不能只往 SQL payload 塞字段。
`chat_v2.Operation` 比旧 `chat.Operation` 多允许 `uncertain`，并校验成功必须有结果、未知不得带成功消息/错误码。不能把服务端未实现的 pending/failed 写成服务端实跑状态。

### 客户端入口与序列化闭环

| 入口 | 实际类型 / 转换点 | 必须保留的边界 |
|---|---|---|
| `ChatApiClient.sendMessage/sendAttachment` | HTTP Message → `ChatMessage.fromJson` | 返回对象自身无 operation；调用上下文知道 nonce |
| `ChatApiClient.conversation/conversations/messageById/messageContext` | MessagePage / ConversationRecordPage / ChatMessage? / MessageContextRecord? | 所有嵌套 Message 进入同一 parser，不能漏掉 context、摘要；404 返回 null 不是证明发送未执行 |
| `ChatApiClient.getOperation` | `OperationResult?` | HTTP 404 → null；网络异常抛 AuthFailure；响应解析接受 pending/uncertain/succeeded/failed，未知 status 目前保守映射 pending |
| UI `ChatService.loadConversation` | `MessagePage`，`chat_service.dart:634` | 捕获账号与 auth generation，返回前检查身份；页面 initial/refresh/poll 都从此读取 |
| UI `ChatService.getOperation` → `_operationFor` | `OperationResult?`，656/674 | 账号级；可读服务器上本账号的记录；本地 download 分支另有 task_id，不能拿来匹配消息 |
| v2 `operationForIdentity` | `OperationResult?`，324 | 要有本地记录且原 consumer 相同；无记录/别的 consumer 返回 null，不回落到远端账号级记录 |
| `ChatQueryService` | history/direct/context/listConversations；`chat_query.dart` | 复用上述 API，consumer/binding/身份 fence；查询不消费，不新增正文事实库 |
| `ChatV2Router` send/read/wait/get_message/get_context/list_conversations | `Reply[Message]`、`Reply[ReadResult/WaitResult/VisibleQueryMessage/VisibleContext/ConsumerConversationPage]` | owner capability + expected_identity + binding；`local_auth_server.dart` 仅 loopback；原先无 operation 的消息外部 JSON 不应突然泄露 consumer 信息 |
| `ChatV2Router /v2/operations/get` | `Reply[chat_v2.Operation]` | 原 consumer 操作正向查询；别的 consumer 即使同账号仍 404 |
| 事件 poll、notification discovery | `event_feed.dart`、`chat_service.dart:383` 后续 history/query | 事件元数据保持原样；不会由事件自行构造 operation 身份 |
| `ChatMessage.fromJson` / `messageToJson` | `chat_models.dart:199/1164` | parser 忽略未知 key；serializer 会丢弃新增 key。必须同时维护，否则读到关联后落盘/再返回丢失 |
| 嵌套序列化 | `OperationResult.toJson:639`、`VisibleMessage.toJson:1132`、`ConversationSummary.toJson` | 共用 message serializer；外部旧格式与内部保留关联的格式须显式区分 |
| operation 持久化 | `ChatOperationRecord.toJson/fromJson`，`chat_ledger.dart:101` | 当前把 message 走同一 serializer；以 account→operations→operation_id 持久化，恢复需兼容缺字段的旧记录 |

`dsh-plugin/src/bb_dsh_plugin/guarded.py:91` 用共享严格 response model 校验本地 v2 返回。
本轮已实际启动 `client/bin/bb_client_api.dart`，请求发送/查询六种响应并用共享模型校验；不是 Flutter 内服务对象代替独立入口。

## 2. 所有关联/状态写入入口与事务顺序

搜索范围 `server/src` 与 `client/lib`：`INSERT/UPDATE/DELETE messages/operations`、`saveOperation`、`_succeed/_markUncertain/_markFailed` 及 UI pending/resolved/unresolved 写点，结合调用链审查。搜索不代替语义证明。

### 服务端唯一业务写入

`chat.py:submit` 是正文/附件/重试共同入口：

1. `BEGIN IMMEDIATE` 后查询 `(account, client_nonce)`；同请求哈希返回原消息，不新增事件；不同目标/内容/类型哈希冲突 409。
2. 验证 pair 和媒体权限，分配 pair 内 position。
3. INSERT message → INSERT operation 关联 → INSERT 双方 events → COMMIT。
4. 返回 HTTP 结果。提交后丢响应只能查原 operation 或用相同请求/nonce 重试。

任何事务内异常整体 rollback。`003_chat.sql` 的 operation PK 是 `(account,operation_id)`，message_id 是 FK；**没有反向 UNIQUE(account,message_id)**。当前唯一写入口每个新消息恰建一条关联，但新读取实现不能任意挑第一条损坏/歧义关联。历史已有 operations 时直接投影，不改 message payload；缺失关联不可按文本、媒体、时间回填。

本方案不要求数据回填或新的业务表。具体批量查法在实现时选定；若采用反查，考虑 page 批量查询，避免逐条 N+1。是否新增 `(account,message_id)` 索引应据实际查询计划决定，不预称已测性能、不为本轮添加额外验收门槛。

### 客户端持久状态共同修复点（Forge）

| 写入口 | 基线写入 | 拟议共同规则 |
|---|---|---|
| sendBody 上传进度/准备 | service:849/867 → saveOperation(prepared) | 上传副作用先于部分准备记录；不是消息提交。后续旧 prepared 不得覆盖已有 succeeded |
| sendAttachment 上传/cover/准备 | 1208/1228 → saveOperation(prepared) | 同上；媒体 ID 与原请求一起复用，不因查不到结果换 operation |
| `_submitBody` | 994/1013/1039/1054 succeeded；1027/1065 uncertain；1074/1081 failed | 初发、查询恢复、相同 nonce 自动重试都进入共同状态合并 |
| `_submitAttachment` | 1256/1271/1297/1311 succeeded；1285/1322 uncertain；1331/1338 failed | 与正文共享规则，不能另加一套附件判定 |
| v2 `operationForIdentity` | 358 远端成功 → `_succeed` | 先校验 scope，成功合并；原 UI `_operationFor` 远端返回不落盘，应统一成功记账语义但保留两种读取权限 |
| stale plan 恢复 | `_reconcileStalePlan:1433`、`_reconcileStaleAttachment:1458` | 只对原账号对账；可保留已发生的提交事实，不在新身份下重发；没有证明则 uncertain + stale 错误 |
| `_succeed/_markUncertain/_markFailed` | 1477/1492/1506，最终均 `ChatLedger.saveOperation:630` | 在 ledger 现有 `_mutate` 锁内读最新记录并合并；不能拿 await 前 record 无条件覆盖 |
| 重启读取、同账号/跨账号登录 | `ChatOperationRecord.fromJson`、`resumeForCurrentSession:193` | 本函数只恢复下载/事件，不自动重放所有 chat prepared；缺 message 关联时由确切 operation 结果恢复；不新增通用 Outbox |

当前 `saveOperation` 只有串行/落盘 rollback，没有语义上的“已成功不可降级”检查；这是源码确认的共同风险，**本轮未运行服务层竞争复现，不能写成已证实服务缺陷**。
旧 `accountForOperation` 还会跨本地账号扫描 nonce 并拒绝跨账号复用；服务器允许不同账号同 nonce。此历史本地保护原样保留，本次不能为扩展关联放宽账号切换保护，也不能把它当作服务器唯一性规则。

## 3. 拟议关联契约（待接续实现）

### 可协商的消息投影

建议传输扩展名称 `X-BB-Message-Association: 1`，新 `ChatApiClient` 在需要完整 Message 的请求上发送。支持的服务器在对应成功响应回显该 header；旧服务器忽略请求头且不回显。header 是格式协商，不是授权。

共享契约新增 `AssociatedMessage`（沿用 Message 内容，增加可选 `operation_id: OperationId | null`）及相应 page/context/conversation/operation 嵌套类型；原 `Message` 和本地 v2 默认契约保留。服务端声明并校验两种响应形状，选哪种由协商决定；导出 OpenAPI/fixtures 验证实现与模型一致，不用裸 Response 绕过契约。

- 无协商：返回现有 JSON，**不出现新增 key，即使 null 也不出现**，所有旧严格调用方继续接受。
- 有协商：每个完整 Message 可带 operation_id，仅当 `reader == sender` 且已持久化 `(reader, operation_id) → message.id` 唯一匹配。body/attachment/重放成功/operation 内嵌 message/历史/单条/context/摘要全部使用同一个账号感知投影。
- 对端可读正文但不获发送者 operation；第三方仍 404 或其自己的空会话结果，不能因协商绕过原 ACL。
- 原账号的其他 session/设备能够获得本人关联，和现有服务器账号级正向查询一致；operation ID 不是凭据，也不得被当作鉴权能力。
- 对端、历史没有记录、扩展缺字段都视作“关联未知/不可见”，不等于消息未提交，也不等于已证明属于别的 operation。不从 payload、时间、文本或媒体内容推断。
- 不把 operation 写进共享 message payload；否则同一份 payload 会泄露给接收者。
- 直接成功回执与正向查询也可由服务层用原请求 operation ID + 返回 message 建立可验证关联；必须校验 sender/target/kind/operation 与捕获请求相符，不能只要 `message != null` 就认定任意查询结果成功。

### 内部模型与本地外部投影

`ChatMessage` 增加 nullable `operationId`，parse 校验合法类型/格式；关联仅对当前读取账号的本人消息可用于匹配。关联身份是 `(server origin, account, operationId)`，消息还须符合目标 pair；UI 生命周期再加 auth generation/会话 epoch。不得以全局裸 operationId 建 map。

内部 serialization（ledger）保留关联；旧账本缺字段仍读取。外部 `messageToJson` 默认保持旧格式，对 `VisibleMessage`、`OperationResult`、`ConversationSummary` 嵌套响应也一样。本地 `/v2/*` **本轮不增加该消息字段**：同账号别的 consumer 可以按既有权限读正文，但不能从关联投影旁路获取原 consumer 的 operation。其原 consumer 已可通过原 `/v2/operations/get` 获得结果。

这样新 UI 的 Dart 服务对象可直接消费账号授权关联，独立 Dart/MCP 外部格式及消费/已读语义保持原样。不得让“保留内部字段”默认扩散到旧 MCP 响应。将来若本地 consumer 需要该字段应另作 scope 合同，不在本轮扩大。

## 4. 兼容矩阵与需协调的限制

| 组合 | 取证/结论 | 新方案行为 |
|---|---|---|
| 基线 Dart 读附加 operation_id | 本轮 parser 实跑可接受，但再序列化丢失 | 旧 UI 无新能力；协议不崩。新模型/持久化必须同时接线 |
| 基线 Python DSH 读无条件附加字段 | 八种响应 fixture 均 `extra_forbidden`；实际 guarded transport 会转 502 | 不采用无条件添加；本地 v2 保持旧投影，不要求升级 DSH |
| 旧客户端 → 新服务器，无协商 | 本轮尚未实现/实跑 | 必须与原格式完全相容；旧客户端不会自动修复其全局 hold |
| 新客户端 → 新服务器，协商成功 | 本轮尚未实现/实跑 | 有权的本人消息可直接精确归并；对端/第三方不扩权 |
| 新客户端 → 旧服务器 | 原接口可继续读取、发送、正向查询 | 不把缺字段当不存在；已知回执/成功查询可恢复关联，无关已提交消息照常显示 |
| 新客户端 → 新服务器，历史没有关联记录 | 正常读取消息；没有可回填的事实 | 同上，不猜、不全局隐藏；当前代码正常创建的旧消息已有 operations，可投影，无需按年代一律判为缺失 |
| 新本地客户端 → 旧 Python/JS DSH | 新格式投影尚未实现；基线真实响应严格校验已过 | `/v2/*` 维持原格式、owner/consumer/binding；下载/注册登录/图文顺序不改 |
| 新客户端 → 旧本地账本；旧客户端重开新版账本 | 缺字段解析兼容；旧 serializer 可能丢新增元数据 | 关联可由服务器重取；不能把本地新增元数据变成唯一事实来源；不可宣称旧客户端具备 R8 行为 |

**必须交 Orion 的能力限制**：在旧服务器/真正无关联历史中，如果发送回执丢失且原 operation 查询持续不可用，客户端观察到“本地 A 未决 + 本人消息 M”时，无法分辨 M 属于 A 还是同文的另一次 B。此时无法同时保证“不误配、不隐藏无关消息、local echo 与提交消息绝不重复”。加字段也不能修复一个不提供该字段的旧服务器。

安全兼容底线是照常显示已提交消息，保留 A 的未知/恢复入口，不猜配、不整体隐藏；在取得精确结果前可能暂有回显重复，**不声称满足全部 R8 验收**。建议完整 R8 保证以关联能力服务器为前提，旧服务器提供明确的有限兼容；若用户要求旧服务器也在所有故障下零重复，需 Orion 交用户决定替代呈现/支持边界，不能擅自删除回显、禁发或升级外部依赖。本轮无部署/升级授权。

## 5. 状态优先级、迟到响应和共同更新点

### 实际状态区别

| 观察 | 当前可达路径 | 含义 / 拟议合并 |
|---|---|---|
| send 成功 / 查询 succeeded + 合法 message / 本人历史带关联 | 前两项基线可达；第三项待实现 | 已提交事实。保持同 operation 的稳定消息身份；success 后弱观察不能退回未知/失败 |
| prepared + 远端 404 | `_operationFor` | 返回 pending，**当前 UI 实际可达**；不是“服务端声明 pending” |
| uncertain + 远端 404 | UI `_operationFor` 映射 pending；v2 `operationForIdentity` 映射 uncertain | UI uncertain 枚举是防御性边界（或未来统一映射）；不能标成当前 UI 真实网络返回 |
| 网络/超时查询异常 | getOperation 抛 AuthFailure；send 502/504 标 uncertain | 查询失败只改变本次查询可用性，不把提交事实改失败，不创建全局 hold |
| failed + 远端 404 | 本地明确失败记录 | 失败与错误码可用于重试提示；如存在更新的提交证明，旧失败不能覆盖 |
| 无本地记录 + 远端 404 | UI getOperation → null | 当前账号/快照未找到；不是对未决请求永不提交的证明 |
| stale_identity / stale_binding | 切账号、重登录、绑定变化后 | 当前调用失效，不是原业务操作失败；原账号成功仍可持久化，不能写入新页面 |

**优先级不是响应到达时间排序**。已验证的同 operation 提交是单调事实；成功后不同 message ID 是冲突/损坏，不能 last-write-wins。pending/uncertain/error/null 均不得撤销成功。未成功时，对旧请求的否定/未知观察也不能覆盖一次更新 retry 的结果。迟到正向成功仅在 operation、账号、目标匹配且无冲突时可用于原账号记账；UI 还要通过页面 scope fence。

Forge 维护服务层事实合并规则（复用现有 ledger/service，不造通用框架）：每个状态写入在锁内读最新 record；提交结果占优；校验 operation/账号/pair；防止旧 prepared/failed/uncertain 覆盖已成功；落盘失败维持原 `_mutate` rollback。`_operationFor` 与 `operationForIdentity` 共用结果校验/合并，**不共用/放宽授权入口**。

Muse 维护 UI 的展示生命周期：local echo、loading、动画和请求 ticket，不拥有第二份提交真相。按 exact operation/message 关联选择展示条目；未配到的已提交消息直接显示。对查询/刷新捕获 `(account, auth generation, peer, page epoch, operation, request ticket)`；所有 success/catch/finally 先检查适用范围。retry 启动推进 attempt/ticket，成功使旧否定结果失效；finally 只能清理自己的 in-flight ticket，不能删掉更新查询的 ticket，也不能通过“释放全局 hold”更新业务状态。

### UI 全写入口映射（仅方案，不写 UI）

| 入口 | 现行为 / 问题 | 共同更新点 |
|---|---|---|
| `_loadInitial:174`（含 refresh）、`_pollNew:250` | 都 split/写 held、cursor；poll 能越过被隐藏消息 | 同一逐消息关联 merge；已提交消息不依赖任意 pending 数；只有连续读取推进 fetchedThrough；refresh 不重放旧动画 |
| `_resolveFailedOperation:404` 成功 | resolved/map/merge/forget | 同一提交归并；保留稳定 key，关联必须同账号/pair |
| null/failed/pending/uncertain 分支 | 当前分支各自维护 unresolved | 同一 observation 合并规则；弱结果无权撤销成功；只改变对应 operation 的恢复提示 |
| `on AuthFailure` 与 generic catch:447/454 | 只检查 mounted，无条件再加 unresolved | 检查 scope/ticket/最新已提交状态，与正常返回走同一观察入口；Sentinel 已复现迟到错误反例 |
| finally:460 | 删除 resolving，可能 flush 全部 held | 仅释放当前请求 ticket；无业务事实写入、无全局释放机制 |
| `_retryUnresolvedLookups:389` | poll/refresh 后再查 | 只调度仍需对账的 operation，复用 ticket；不可因旧查询失败复活已结算项 |
| `_onSent:485`、`_onSentOperations:518` | 分别写消息/map | 与历史/查询共用提交归并；成功比任何旧查询强，local echo 原 key 不换成新入场 |
| `_onPendingChanged:529` | 清理集合、启动查询；晚 callback 可在清理后写回 | 展示清理不删除已知提交事实；最新 attempt/ticket 判定作用域，避免把集合成员存在性当唯一成功来源 |
| Composer `_applyResult:323`、`_retryOne:401`（含 catch/成功分支）、`_forgetCommittedOperation:486`、`_setPendingState` | pending/failed 队列与 onSent 回调；相同 operation 重试 | 共享“提交已确定”输入；不重新生成 operation，不因旧失败回调重建失败 bubble；没有关联不能按内容删另一条失败项 |
| dispose:155 / 切会话 / 身份变化 | mounted 只能挡已销毁实例，不是账号/pair fence | 失效 page epoch 和 tickets；回调不能把旧 peer/旧账号成功投到新页，原账号事实由 service 留存 |

以上合并点分别对应**服务事实持久化**与**UI 异步回调适用性**，不能仅修一个 catch，也不能认为 ledger 单调就自动解决 UI 旧回调。Orion 负责文件边界协调，Muse 接线后再固定集成 SHA。

## 6. 已取证结果与后续回归入口

本轮环境：Linux x86_64，uv 0.12.10，Python 3.13.15，Dart 3.13.7；`uv sync --project server --locked`、`flutter pub get --enforce-lockfile`，没有更改锁文件或外部依赖。FastAPI 0.162.4、Pydantic 2.14.3、uvicorn 0.54.0，来自锁定环境。

实跑命令（仓库根目录）：

```sh
uv run --project server --locked python docs/contracts/dea475-operation-association-evidence/baseline_probe.py
dart docs/contracts/dea475-operation-association-evidence/legacy_parser_probe.dart
uv run --project server --locked pytest server/tests/test_chat.py server/tests/test_chat_queries.py server/tests/test_chat_v2_contract.py -q --junitxml=docs/contracts/dea475-operation-association-evidence/server-baseline.xml
```

- 真实 Python `-m bb_server` TCP + SQLite：同文不同 operation、同 nonce 重试、变目标 409、本人/对端/第三方 ACL、正文/附件/历史/单条/context/会话摘要/事件、进程重启重放均通过。服务端完整消息不带关联；只有正向 operation 给结果。`baseline-results.json` 记录断言结论，2.86 秒。
- 实际独立 Dart bin 连接上述服务；两种 owner 注册两个不同 consumer；原 consumer 正向查询成功、同账号另一 consumer 404；六种实际响应通过共享 Pydantic 校验。
- 合成新增字段输入：旧 Dart parser 接受后丢弃，旧 Python 八种嵌套响应均拒绝。**这是候选格式的兼容性反例，不是新实现已通过**。
- 既有服务测试 **107 passed / 0 failed / 0 skipped**，4.44 秒；JUnit 留存。1 条 Starlette TestClient 的弃用警告，未改依赖规避。
- 首次 HTTP 探针错误地用同一 owner 两次 enrollment 建“两个 consumer”，断言失败；代码确认 enrollment 幂等返回原 consumer。修正为两个 owner、显式断言 consumer 不同后通过。这是探针前提纠正，不是修改产品使失败消失。
- 所有实跑仅合成账号、临时 session/数据库；进程已收回，凭据未输出/落入证据。新扩展、UI 接入、服务竞争场景均未实现/未验收；本轮 Android/Windows、真实 DSH 宿主/模型及真实 UI 跨客户端故障时序 NOT RUN。

### Sentinel 修前证据纳入（非 Forge 重跑）

已通过认证 attachment CLI 读取附件 `01a1dd80-64ea-7a35-a567-9df0c393224b` 的 `evidence/RESULTS.md`、`probe.patch`、机器报告与 JUnit。探针 SHA `b2473ec14ab5f372f42f178d613dc542421fff6d` 未发布到 origin，使用附件而非声称远程可 fetch。校验 patch 只写指定 review 目录，日志/XML SHA256 与报告一致；机器统计 **23 tests / 14 failures / 0 errors / 0 skipped**（9 通过），记录 exit 1。详见 `sentinel-evidence-check.json`。

两类红断言必须保留：① 一项 sending/查询错误/pending/防御性 uncertain 时，其他来源的本人已提交消息在 poll/refresh 后可见；② retry 已成功后，迟到查询 502 不能重新建立未决状态并隐藏后续消息。覆盖同文、同 PNG 不同 media ID。以上为实际控件 + 合法服务替身，不声称真实 HTTP 故障复现。本轮不重复其全套测试，不更改其失败证据；集成时由 Muse 将行为断言纳入现有测试。

### 实现阶段按入口补永久回归

| 最低有效层 / 现有入口 | 需要增加或保留的断言 | 本轮覆盖性质 |
|---|---|---|
| `server/tests/test_chat.py`、`test_chat_queries.py` | 协商/默认投影；正文/附件/重放/正向查询/历史/摘要/单条/context 一致；本人有、对端无、第三方不可读；缺关联不猜；事务回滚/重启 | 原 ACL/幂等/回滚已有实跑；新投影待实现。事件不改 schema，受原回归覆盖 |
| `server/tests/test_chat_v2_contract.py`、共享 fixtures/exporter | 新扩展响应校验；旧 local v2 shape 不变；严格旧模型对默认输出仍接受 | 原契约实跑；八类新增 key 拒绝已证明，扩展未测 |
| `client/test/chat_v2_shared_contract_test.dart`、`chat_v2_local_server_test.dart`、`chat_v2_query_routes_test.dart` | 内部 parser/serializer 保留关联、外部 local v2 全嵌套默认省略；不同 consumer 不泄露；新客户端遇旧服务端/旧账本 | 独立入口六路基线实跑，完整新矩阵待补 |
| `client/test/chat_ledger_test.dart`、`chat_ledger_io_rollback_test.dart`、`chat_atomic_commit_test.dart` | prepared/成功/失败/未知全部 save 入口共用单调合并；成功后旧观察/旧写不得降级；落盘失败→恢复→重试→冷启动 | 本轮源码枚举；服务竞争时序 NOT RUN；不能复用 UI 替身当持久层证明 |
| `chat_identity_generation_test.dart`、`chat_identity_capture_race_test.dart`、`chat_v2_query_rebind_test.dart`、`chat_admitted_send_switch_test.dart` | 账号/consumer/绑定/会话失效，原账号提交不丢、不投错页；同 operation 同意图重试 | 现有入口已确认存在，本轮未重复 |
| `client/test/chat_send_feedback_test.dart` + Sentinel 修前探针 | 两类红断言及同 operation 一条/不同 operation 不误配；迟到 success/null/failed/pending/uncertain/异常；poll/refresh/retry/切会话；动画/滚动旧回归 | 独立探针23项是修前来源证据，修后仍须实跑，不将内部 hold 断言替代行为 |
| `scripts/run_flutter_tests.sh client`、现有 CI | 接入完成后固定 SHA 跑受影响自动检查；真实 UI 仅补受影响路径录制，保留既有媒体/头像/通知回归 | 不新增 job，不重复全量作为本轮方案门槛，旧 R6/R7 证据按原版本保留 |

下一负责人 Orion：确认本文契约路线和旧服务端能力边界后协调 Forge 服务实现与 Muse UI 接入。保留 DEA-475 `in_progress`、原 assignee；本轮不移动状态、不合并、不部署、不发布。
