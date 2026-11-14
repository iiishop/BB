DEA-474 多私聊契约与状态入口，revision 1
=====================================

范围依据：DEA-474 正文、Orion 执行规格 v1；基线 `c61dddb7f8500bc710cc39577bce049747ec2e25`。
本提交是第一阶段：会话引用、多订阅、回补、账号入站未读与 ledger 迁移。
唯一集成分支 `agent/forge/cf4d0bdb8837`，共享状态实现者 Forge。
通知开关/聚合/跳过/离线投递恢复、DSH 自主读取接入留给下一阶段，不能把本阶段测试解释为完整需求 PASS。

机器权威仍为 `server/contract/src/bb_auth_contract/{chat_v2,chat_query}.py`；
生成物 `chat-v2-{openapi,cases}.json`，查询 revision 为 `dea474-query-v1`。
本地协议保持 v2，原 owner header、expected_identity、CAS fencing、确认和发送幂等规则不变。
新增字段由新版共享包严格验证；客户端和 MCP bundle 应一起更新。旧客户端不支持新请求时不得降级绕过身份。

调用方契约
----------

私聊统一引用是 `{"type":"direct","id":"dm:<较小账号>:<较大账号>"}`，账号按八位字符串排序，
必须为两个不同账号。引用代表会话，不代表发言人；`sender_account` 独立保留。
群类型明确返回 422，既不分配假 ID，也不授予群权限。

`POST /v2/events/subscribe` 除 expected_identity 外，恰好选择以下一项：

| 输入 | 行为 |
| --- | --- |
| `peer_account` | 兼容原单 peer 配置；添加该会话，不删除旧订阅 |
| `conversation` | 同上；要求当前账号属于该规范私聊引用 |
| `discover:true` | 持久开启该 consumer 的授权会话发现；立即回补，随后轮询 `/conversations` 发现新私聊 |

响应 result 为 `{peer_account, conversation, discover}`；发现请求前两项为 null，
显式请求 discover=false。此处 discover 描述本次选择，不是重置持久订阅集合的命令。
集合只增不减；重复注册既不重置扫描进度，也不重复入队。既有单 peer 安装迁移后仍为显式模式，
不会自行扩大到全部私聊。未来 bridge 无 peer 配置应调用 discover=true；有明确 peer 配置应保持对应来源过滤。
从发现模式切换为明确 peer 时，调用方仍须按配置过滤已存在的持久事件，不能将历史订阅误当新权限。
发现只读当前账号的服务端会话，不扫描全站用户目录。没有聊天订阅也继续处理下载终态事件。

消息事件保留 version=2、origin_identity、peer_account、position，并增加 conversation。
旧持久事件不改 origin_identity；对外序列化时从原账号与 peer 得到同一个规范引用。
发送仍使用显式 target_account，读取仍用 account/message_id；不能从最近通知推断发送目标。

`POST /v2/chat/list_conversations` 保留 after_account/limit，新增：

| 参数 | 语义 |
| --- | --- |
| `order` | account（兼容默认）或 recent（活动时间降序、peer 升序打破相同时间） |
| `unread_only` | 默认 false；只保留 incoming_unread > 0 的会话 |
| `cursor` | recent/unread 查询返回的 opaque 快照游标；不能与非空 after_account 混用 |

每行增加 conversation、display_name、incoming_unread、latest_unread。
display_name 来自服务端资料，兼容旧服务端缺字段时退回真实 peer 账号。
latest_unread 是 null 或 `{message_id,sender_account,position,created_at,text,truncated}`；
预览最多 160 Unicode code points，图片/附件用类型标记，不下载媒体、不准备展示凭据。
160 的默认值用于辨认最近内容且限制模型输入体积；预览是非可信聊天内容，不能当宿主指令。
原 last_message/last_activity_at/latest_position/consumed_through/unconsumed_positions 保留。
`unconsumed_positions` 仍是双向恢复位置差，绝不是产品未读；调用方应使用 incoming_unread。

account 模式沿用服务端实时 keyset 分页，新活动不重排。recent 或 unread_only 使用首次请求收集的
不可变结果快照，后续来信、确认不重排该分页；刷新首页取得新状态。游标隔离到账号、auth_generation、
consumer、binding_revision、order 和过滤条件，五分钟过期，最多缓存 32 个续页游标。
过期/重启/被淘汰/错误 scope 返回 422 cursor，调用方刷新首页；没有偷偷恢复到其他账号。
快照仅在内存中，属于查询缓存，不是持久业务事实；继续分页可重试，同页结果不变。

状态事实与写入顺序
------------------

| 状态 | 唯一事实/入口 | 顺序与故障处理 |
| --- | --- | --- |
| 账号消息、显示名称 | FastAPI SQLite 既有 messages/users；`chat_queries` | 没有新消息库或未读表 |
| 订阅集合/发现开关 | ledger `subscribe`；本地 v2、内部旧会话接口、EventFeed 发现 | 在 ledger 锁内检查当前身份/绑定后写盘；重复为幂等 no-op |
| 每会话来源扫描进度 | `subscriptionCursor/setSubscriptionCursor`；EventFeed | 以 account+consumer+peer 隔离，新 peer 从 0 扫描；不沿用其他 peer 高水位 |
| consumer 聚合事件游标/去重 | `appendLocalEvent`、`deliverPendingEvents`、`finishDownload` | 先持久事件+source ID，再提交扫描进度；间隙崩溃重扫但不重复事件 |
| 精确正文展示 | `prepareReceipt` → `confirmPresentationAttempt` / 内部 UI `confirmReceipts` | 只从 confirmed receipts 推导账号 displayed message IDs；预览/列表/事件/读准备均不确认 |
| consumer 连续消费 | `ackMessages` → `acknowledgeConsumerThrough`；内部 `setConsumedThrough` | 原连续凭证与绑定校验保留；不是入站未读来源 |
| 发送/下载恢复 | 原 `saveOperation`、download operation/task、pending_events | 本次不改格式/幂等 ID/不确定结果语义 |
| 通知投递或跳过 | 下一阶段的账号设置与通知 journal | 不可借用 scan/event/ACK 水位；本提交尚未实现 |

账号入站未读是服务端实际入站消息 ID 减去该账号成功展示 ID 的集合大小，跨 consumer 一致。
出站消息不计入；读 B 不清 C；稀疏读位置 3 不清位置 1；确认成功但尚未 ACK 的精确位置已读，
consumer 连续恢复位点仍保持原值。查询使用一次展示事实快照及各行获取时的 latest_position 上界，
持续新消息不会让历史扫描无限延后；第一页收集不是跨所有会话的数据库全局快照。
目前通过现有 history API 分页计算，耗时随授权历史量线性增长；不下载媒体、不调用模型。
通知接入应复用增量事件，不把高频全历史列表扫描当心跳。若需要索引优化，仍应从服务端权威事实推导。

单会话 not_found/上游可用性故障保留该 peer 游标，并继续其他会话；身份、stale_binding、存储故障
不走通用 catch。显式调用抛出，定时调用保留 lastFailure 供诊断。下载 pending 先于订阅轮询排入队列。
原 consumerEventCursor/setConsumerEventCursor 仅保留旧内部访问/迁移证据，不再用于新扫描。

迁移与回退
----------

ledger v2 → v3：先验证旧根结构，为原始字节写入同目录 `.v2.bak`（临时文件 flush 后 rename），
再把每个单 peer 记录改成 `{discover:false, peers:{peer:{server_cursor,created_at}}}`。
旧 consumer source cursor 仅归原 peer；新的 peer cursor 为 0。账号、consumer/owner、历史事件、
去重、展示凭证、确认 attempt、消费位置、未完成发送/下载全部原样保留；消息仍在原 SQLite。
版本号与集合在一个临时文件 flush/rename 中提交，异常不发布内存新状态，下一次访问重试。
移除了 rename 失败时先删除正式文件的 fallback：不支持替换的文件系统报错并保留原数据。

v3 冷重开不重迁；v1/未知版本仍明确拒绝并保留；不声称旧程序能读 v3（旧版会拒绝）。
回退应先停止客户端和所有 ledger 写入者，再保留当前 v3 文件和备份，用 `.v2.bak` 恢复原文件后启动旧版。
备份之后的 v3 展示/操作状态不会自动反迁，不能用旧备份重发不确定操作；先在新版对账或保留新版恢复。
v2 备份与当前原文不一致时拒绝自动覆盖，交由维护者检查。备份不能在生产实例上未经批准恢复。
本实现沿用单客户端文件锁队列，不提供多进程共享 JSON 或网络文件系统 HA。

验证入口与调用方分界
--------------------

- `client/test/event_consumer_backfill_test.dart`：同 consumer 第二 peer 回补/重复订阅/新联系人/故障隔离。
- `client/test/chat_query_service_test.dart`、`chat_v2_query_routes_test.dart`：入站计数、稀疏展示、快照分页/绑定隔离、HTTP owner 和群拒绝。
- `client/test/chat_multisub_migration_test.dart`：合成 v2 全状态保留、故障→重试→冷启动、未知版本拒绝。
- `client/test/chat_ledger_commit_test.dart`：所有既有持久写入口加 setSubscriptionCursor/discovery，写失败→恢复→重试→冷启动。
- `chat-v2-cases.json`：新增 selector/group/foreign/reference/分页非法输入，现有 Python 与 Dart 共享契约入口共同消费。
- `uv run --project server --locked python server/probes/multichat_local.py`：真实 FastAPI + 独立 Dart bin，四个隔离合成账号，经同一 DTO 校验真实请求/响应，测试回补/发现/稀疏确认/显式发送/冷重启去重。不会访问个人凭据；不证明 DSH 或真实模型行为。

通知和宿主调用方下一阶段依此契约接入；不要复写 ledger 或复制入站未读规则。
本阶段未改 DSH 内核、外部依赖、界面视觉、群产品或对外已读。
