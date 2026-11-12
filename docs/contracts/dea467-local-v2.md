DEA-467 本地客户端 v2 接线契约
=============================

本增量落实 Orion 的客户端隔离契约。机器权威为
`server/contract/src/bb_auth_contract/chat_v2.py`，生成物为
`server/contract/chat-v2-openapi.json` 和 `chat-v2-cases.json`。
所有新增路由都由 **客户端 LocalAuthServer/业务服务** 实现；`server/contract/`
是共享包的所在位置，不表示 FastAPI 托管客户端身份。没有新服务端登录 API、
数据库迁移或业务副本。Muse 从本提交接线；Forge 不改 client/。

版本及调用约定
--------------

全部 POST、JSON、loopback-only。先 `/v2/protocol/negotiate`，输入
`{"supported_versions":[2]}`，输出 selected_version=2、contract=`dea467-local-v2`、
owner_header=`X-BB-Consumer-Key`。无共同版本返回 426 unsupported_version；
旧客户端 404 也表示未支持，bridge 不自动退回无身份保护的 v1。
协商本身不产生认证会话。各 `/v2/` 路由直接固定 v2，不能靠 body 字段降级。

`POST /v2/status {}` 返回 `{protocol_version:2,auth:null|{account,auth_generation}}`。
不返回 token、其他消费者、消息或秘密。account 是八位字符串，auth_generation
是客户端持久管理的非空 opaque string；登录、退出、同账号重新登录、A→B→A、
进程重建都使旧 generation 失效。登出期间 auth=null。
generation 只能用作相等比较，不能回收旧值或使用重启归零计数。

`expected_identity={account,auth_generation,consumer_id,binding_revision}` 必填于
全部受保护业务请求。业务 `account` 仍为 peer；二者不能互换。opaque 字段为
1..200 个 `[A-Za-z0-9_-]`，绑定 revision 为 1..2^53-1 整数，布尔/字符串不算整数。
超界需要显式新绑定，不能 wrap。未知字段、null、缺身份返回 422。v1 白名单不变。

绑定所有权与启动
----------------

现有 HTTP 无 OS peer identity。为满足“consumer ID 不能单独接管”，v2 增加
`X-BB-Consumer-Key` header：调用安装先生成 32 随机字节的无 padding base64url
本地 capability（43 字符），**先持久化、再 enrollment**。一个 key 对应一个稳定
消费者安装；需要第二个独立消费者时生成另一个 key。它不是用户密码、服务器
token 或 expected_identity 字段；不能访问服务端、不能登录，不能绕过账号校验。
插件仅在隔离 profile 的私有文件保存它；客户端仅保存 hash/验证材料，日志、
模型上下文、MCP 展示、错误、普通状态响应均不得包含它。测试 fixture key 仅为假值。
凭 key 只能访问其创建的消费者；知道 consumer ID/revision 不足以接管。

以下三条路由均需此 header 和当前 expected_auth：

| 路由 | 输入 | 输出/原子语义 |
| --- | --- | --- |
| `/v2/consumers/create` | expected_auth、session_id | 客户端随机生成 consumer_id，revision=1；按 account＋key hash 幂等。已有记录只返回原绑定，不更新 generation/session、不隐式接管。创建回执丢失可用同 key 重试，不制造新消费者。 |
| `/v2/consumers/get` | expected_auth、consumer_id | 返回调用者拥有的绑定，供冷恢复与 CAS 前查询；不改变绑定。错误 key/跨账号/未知 consumer 统一 stale_binding，不泄露存在性。 |
| `/v2/consumers/bind` | expected_auth、consumer_id、expected_binding_revision、session_id | 原子比较当前 revision 与 owner key，匹配才增 1，并绑定当前 generation 和 session。相同旧 revision 的竞争最多一成功，失败 stale_binding。即使同 session 也执行 CAS。 |

三者输出 `Binding={identity,session_id,active,migration}`；identity 是记录绑定时的
四字段快照，active 表示 generation 仍当前且绑定有效，migration 为 ready 或
migration_required。客户端重启后 get/create 可返回 active=false 的旧身份；
调用方必须显式 bind，不能把 status 的新 generation 拼进旧 identity。
bind 丢回执后先 get：若 session/新 revision/当前 generation 与自己预期吻合才
采用该结果，否则冲突交回，不盲增 revision。session_id 只是路由映射，不是
consumer ID，也不是 owner proof。绑定后旧 session/回调均 stale_binding。
同 key 的并发进程需要各自唯一 session_id；拿到新绑定的一方才是当前 owner。

注销/禁用先停止自有订阅、等待与回调，保留可对账的业务事实；当前版不提供
任意删除消费者账本端点。外部消费者不能通过 create/get 枚举其他记录。

业务路由及返回
--------------

OpenAPI 列出完整严格 DTO。`/v2/chat/{list_users,send_message,send_attachment,
read_messages,wait_messages,ack_messages,confirm_presentation,consumption}`、
`/v2/operations/get`、`/v2/downloads/{start,get}`、
`/v2/events/{subscribe,read,wait}` 全需 owner header＋expected_identity。
除消费字段换成 expected_identity 外，既有工具业务参数及图文顺序保持。
成功返回统一 `{identity,result}`，identity 为已校验的请求绑定；result 沿用既有
业务模型。download start 为 202，其余 200。消费查询 result 为
`{consumed_through,migration}`，查询不产生 receipt/确认/ACK。
operation 状态增加 uncertain，表示不能证明成功或失败；不是重试授权。

消费唯一 key 是 `(authenticated account,consumer_id,peer)`。ACK 的 lower/equal
幂等分支也先验证完整 scope；read、wait、receipt、确认、订阅、被动事件全部用
这个事实源。receipt ID 必须解析到同账号/consumer/绑定的实际展示记录；同
attempt+digest 重放幂等，换 digest 或 receipt 集合不能扩张原确认。
成功展示、成功回合与消费提交分开，不能由模型请求发出推断展示成功。
正常沉默成功回合可完成；失败/uncertain 不能确认。只推进连续已确认位置。
wait 与被动事件可以通知相同事实，但通知不消费；bridge 按 event/message ID
去重，同一有效 owner 只领取一次。read 之后的新消息不随旧 ACK 被清掉。

事件 version=2，带 origin_identity；事件 cursor 隔离到 account＋consumer，
绑定切换不重置持久 cursor。历史通知可读取，但 origin_identity 不能被改写成
新绑定；旧 callback 不直接执行，用当前绑定重新读取事实、核实未消费后处理。
下载记录同样保存 origin_identity；仅 succeeded 有 actual_path。旧下载回调
只写原账号/consumer/task，绝不把文件或路径发布到新身份。重新绑定后的合法
原消费者可主动查询历史 task；返回外层 identity 当前，内部 origin_identity 原值。

业务线性化与恢复
----------------

顺序：解析严格 schema → 未登录检查 → expected_auth → owner/consumer/revision
校验 → migration/业务校验。身份切换与捕获账号、不可变凭据、owner/revision
必须在同一业务临界区线性化；HTTP wrapper 预检不能替代它。每个可 await 的
计划写入/发送/下载、确认/ACK 提交、wait/事件/下载返回处检查捕获上下文。
未接纳的旧身份请求须在副作用前拒绝；已接纳操作可以按捕获的原账号执行，
结果只落原账号账本。期间切换则不向新上下文返回成功，返回 stale 错误且保留
可查询结果。409 不证明服务器没执行，不能把已成功远端操作标为 failed。

插件逻辑 operation_id 在第一次执行前持久化，不由 attempt/session/代际重新
生成。计划归原账号与 consumer；同 ID 不同 payload 拒绝。原账号重登、取得
当前 generation 并显式 bind 后，可查询该 consumer 的历史 operation_id；
其他账号/consumer 查询 404。成功只对账，不再 send；pending/uncertain/网络
超时/查询 404 均不能授权不确定计划用新 ID 重试。服务端已有按账号幂等消息
事实继续使用，不另存插件业务消息表。消费者之间应使用唯一 logical IDs。

错误与兼容
----------

错误固定 `{error:{code,message,fields}}`，fields 只允许已知 schema 字段名，
不得回显输入值、秘密、其他账号/消费者信息。机器表含 status 与恢复动作。

| 状态/错误 | 含义 |
| --- | --- |
| 401 unauthenticated | 当前未登录；继续通过原注册/登录 MCP |
| 409 stale_identity | 账号或 auth_generation 不符 |
| 409 stale_binding | capability 缺失/错误、consumer 不属调用者、旧 revision 或 CAS 竞争 |
| 409 consumption_gap | 当前消费者缺连续展示确认，水位不动 |
| 409 migration_required | 无法证明 legacy alias/消费，保留原记录 |
| 409 idempotency_conflict | 同操作/attempt ID 的意图改变 |
| 404 not_found | 当前 scope 不存在；不证明远端未执行 |
| 422 validation_error / 426 unsupported_version | 严格输入错误 / 无共同协议版本 |
| 503 storage_unavailable / 502 upstream_unavailable / 504 upstream_timeout | 未提交不能报成功；不确定操作先对账 |

v1 的注册/登录、已有 MCP 工具名称保留。MCP 可以在本地改用 v2 transport，
不能向模型索取 token/key。v1 ACK/read/wait 的 consumer_session 仅可使用
客户端持久且一对一、当前仍有效的 legacy alias；header 验证该 alias owner。
alias 绑定到原 generation/revision，过期后不能把相同字符串重新指向新身份。
v1 send 等没有 consumer_session/expected identity 的调用不能在重绑后安全
判定原意图，必须 migration_required/协议升级，不能自动继承当前登录身份。
无 alias 的旧 ACK 返回 migration_required；有有效 alias 但缺 receipts 返回
consumption_gap。不为了兼容 200 放宽 v1 字段。

迁移与回滚交付要求
------------------

客户端修复需按以下顺序实现并实测，**本提交不声称已完成迁移**：停旧 writer、
备份账本及版本标记；事务/可恢复 staging 中保存 alias 证据与逐消费者连续
receipts 重建结果；提交新 ledger 版本后才启用 v2。账户级最大水位不得复制。
完整、一对一证据可迁移；残缺/冲突保留原证据并标 migration_required，不覆盖
旧备份、不伪造 receipt。重复启动/中断重跑保持同一结果，已完成迁移不重复应用。
旧 binary 必须拒绝新版本账本，不能混写。尚无新业务写入时可停服务并恢复
迁移前备份；已有新事实时只能向前修复/审计对账，禁止回滚旧快照丢数据。

验证与交付边界
--------------

`uv run --project server --locked python server/contract/export_chat_v2.py` 重新生成。
`uv run --project server --locked pytest server/tests/test_chat_v2_contract.py -q`
验证 fixtures、严格拒绝、所有 OpenAPI 引用及 v1 不变；**不是客户端修复证明**。
语义 fixtures 由客户端集成测试消费，CAS、切换线性化、迁移不能靠 schema 证明。
真实 probe 用 journal/live.py 的 `--v2` 模式；不支持 v2 时硬失败，不跳过/降级。
它与原模式的缺陷复现分开，真实集成 SHA 由 Orion 合并客户端工件后给出。
完整六项、受控在途切换/下载、真实模型及 Flutter/CI 仍分别验收。
