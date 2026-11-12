> 本文保留历史设计；Owner 已确认尚未部署。当前本地业务仅支持 `dea467-local-v2.md`，旧无身份路由、alias 及旧部署迁移要求已退役。

DEA-467 查询契约 revision 1
==========================

权威：`server/contract/src/bb_auth_contract/chat_query.py`、`chat_v2.py`；生成
`chat-v2-openapi.json`、`chat-v2-cases.json`。该增量由 Forge 单点制定，Muse
按本提交接线；既有 v2 identity/owner/error 及严格 v1 白名单不变。协商仍为
`dea467-local-v2`；查询能力新增路由，旧客户端缺路由必须报告未实现，不降级。

本地路由全部 POST，必须先校验 owner header 与完整 expected_identity，成功
均返回 `{identity,result}`。模型工具参数不含身份或 capability，由宿主提供。

| 工具 / 本地路由 | 额外参数 | result |
| --- | --- | --- |
| list_conversations / `/v2/chat/list_conversations` | after_account 默认空串，limit 1..100 默认 50 | ConsumerConversationPage |
| get_message / `/v2/chat/get_message` | message_id 1..200，`[A-Za-z0-9_-]+` | `{item:VisibleMessage,missing_media_ids:[]}` |
| get_context / `/v2/chat/get_context` | message_id，before_limit/after_limit 各 0..49 默认 10 | VisibleContext |
| read_messages / `/v2/chat/read_messages` | account，after_position 或 before_position，limit 1..100 | 既有 ReadResult |

服务端复用**同一个** SQLite 授权查询层 `bb_server/chat_queries.py`，不添加表：
GET `/conversations`、`/messages/{message_id}`、`/messages/{message_id}/context`，
以及扩展现有 GET `/conversations/{account}/messages`。服务端身份来自 Bearer
session；只读当前账号参与的私聊。不存在和无权限的消息统一 404 not_found。
客户端不需要扫完所有历史来猜 ID 是否存在：必须调用直接 lookup/context。
网络失败、上游分页未完成不得伪装成安全未命中。

会话与消费
----------

- 只列已有消息的私聊，不列用户目录。peer_account 升序 keyset 分页；新活动
  不重排会话。next_cursor 为最后 peer，仅有下一页时非 null。
- 此为实时 keyset、不是跨请求冻结快照；并发新建且 peer 小于游标的会话需从
  首页刷新，既有行不会因活动时间更新而重复。最后消息及时间来自该账号会话。
- 服务端返回 peer_account/last_message/last_activity_at/latest_position。
  客户端在**已验证 consumer/binding** 下补 consumed_through 和
  `unconsumed_positions=max(0,latest_position-consumed_through)`。
- position 是双向消息流位置，差值不是“收到的未读条数”，也不是发送给对方
  的已读回执。调用方任意 consumerId 不构成授权。身份切换须在异步返回前再查。

双向历史与上下文
----------------

- after_position 非负，before_position ≥1，最大 2^53−1；二者非 null 时互斥。
  均省略/null 等同 after 0。既有 after 调用参数与返回字段不变；v1 不新增字段。
- after 取严格大于位置的最早 limit 条；before 取严格小于位置的最近 limit 条。
  **两种方向均升序输出**。next_position 在 after 为末条、before 为首条；空页
  保持请求边界（默认 0）。has_more 针对请求方向；不跨边界跳过消息。
- context 在同一服务端读事务中查 anchor 与前后邻居，最多 99 条，按 position
  升序、包含 anchor。range 为实际首/末位置；before_has_more/after_has_more
  明确截断方向。继续向前用 before_position=range.start_position，向后用
  after_position=range.end_position。不会返回一个含糊的全局 truncated 布尔值。
- missing_positions 仅报告**返回范围内部**的存储位置缺口，最多 100 个；超出则
  missing_truncated=true。边界外未请求的消息不是 missing。当前无删除产品功能，
  故正常数据应无缺口；缺口故障测试通过真实 SQLite 数据产生。
- reply_relations 固定 `unsupported`，不推测回复关系，不新增 UI。
- 本地 VisibleMessage 沿用 message/blocks/presentation。按原内容顺序渲染实际
  图像；缺失媒体须填 missing_media_ids，不能把图像占位符当实际展示。仅对完整
  可验证展示发放 presentation；有缺图的消息不允许构造可消费 receipt。
- 所有查询可以准备展示 receipts，但不 confirm、不 ACK；最终消费属于桥接的
  持久成功回合结算。上下文里看见离散历史不允许跳过未呈现的位置。

MCP 兼容与接线
--------------

新增 `GuardedTransport` 从宿主提供的本地 owner capability/identity 发受保护
请求，验证响应 identity 一致；不注册、不持有账户 token、不自动重试/重绑。
受保护 MCP 模式保留注册/登录、Profile 六工具和既有业务工具，增加三个查询
工具；read_messages 采用同一双向参数。ACK/confirm/consumption/events 提交
是内部工具，不暴露给模型；没有额外的“模型最终文本自动发送”行为。

stdio 可用 `BB_CONSUMER_STATE_FILE` 指向宿主管理的私有 JSON，形状为
`{owner_key,identity}`；该文件不是账户密码/token。宿主绑定更新后需重启该
MCP 实例（旧实例会被客户端 revision 围栏拒绝）。未设置该变量时，既有 legacy
MCP 接口保持兼容，包括旧显式 ACK。v1 ACK 只能走已验证 alias/receipt 的现有
迁移约束；不能借此绕过 migration_required。产品 bundle 将默认使用受保护
模式和内部结算，legacy 模式暂保留以便迁移，不静默放宽白名单或承诺立即删除。

验证范围
--------

server 测试运行真实 FastAPI/SQLite：权限、两个方向分页、缺口、上下文一致、
消息活动不改变会话 keyset、查询不产生事件。MCP 新测试使用明确标注的 HTTP
transport double，证明请求/响应校验、无 ACK/重试、工具列表和有序内容；不代表
Muse 尚未接线的真实 Dart 路由或完整 DSH 安装/生命周期已经完成。
