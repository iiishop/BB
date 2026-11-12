# DEA-467 客户端消费隔离与身份代际（Muse）

状态：客户端实现交接，不是独立 QA PASS。基线 `e311a0a15e8b04a03308d58942d722636a8ec7db`，
只改 `client/`。HTTP v2 路由/DTO 等 Forge 的共享 schema，本轮不新增。

## 1. 消费事实

- 唯一 key：`(authenticated_account, consumer_id, peer_account)`。
- `consumer_id` 由客户端生成并持久化（`c-<32hex>`），不是 session、不是凭据。旧
  `(account, consumer_session)` 通过 `consumer_aliases` 一对一解析到同一个 consumer；
  同一 `consumer_session` 字符串在另一个账号下是不同 alias。
- receipt、ACK 幂等分支、gap 校验、wait 结果都使用 consumer 维度。ACK 先做身份/绑定
  校验，再判定幂等；`through_position <= consumed` 不再绕过 scope 校验。
- 旧 v1 `account+peer` 水位不广播：迁移只从该消费者自己的连续有效 receipts 重建；不完整
  或歧义保留在 `legacy_consumption` 并报 `migration_required`，ACK 不推进。

## 2. 身份与绑定

- `AuthSession.establish`/`clear` 每次轮换不透明 `auth_generation`（随机字符串，不是从 0
  重置的计数）。同账号重登、A→B→A、进程重建都会让旧值失效；`updateUser` 不轮换。
- `ExpectedIdentity {account, auth_generation, consumer_id, binding_revision}` 由
  `ChatService.identityFor(consumerSession)` 取得；不含 token。
- `ChatLedger.bindConsumer` 是唯一绑定入口：首次 alias 建 consumer（revision 1）；
  **旧 alias 在重新登录后不会被隐式重绑**，必须显式提供当前 `expected_binding_revision`
  （或经 v2 owner `consumers/bind`）才递增 revision；只有客户端自有的 `human:<account>`
  alias 随自身登录轮换。按 consumer id 接管必须提供当前 revision，consumer 不能跨账号。
- ACK / confirm 的身份与绑定检查在**同一个 ledger 锁内、写入之前**完成；身份失效时不写
  水位/确认，`beforeCommit` 是受控暂停注入点，用于证明校验→写入之间被切换不会落库。
- 服务层在入口捕获 `(AuthIdentity, ConsumerBinding)`，之后只使用捕获值写账本/发请求，不再
  在 await 后读取全局 token。需要外部身份时传入 `expectedIdentity`，校验顺序为
  `stale_identity` → `stale_binding`。

## 3. 操作计划与迁移

- `ChatOperationRecord.expected_identity` 在首次网络提交前落盘。
- 显式 `operation_id` 跨账号查找（`accountForOperation`）：属于别的账号 → `stale_identity`，
  任何发送副作用前拒绝。
- 身份不匹配的计划只对账、不重发：先查服务器幂等事实；成功只记原账号，查不到则保留
  `uncertain` 并返回 `stale_identity`。已成功记录直接返回本地结果，恢复发送为 0。
- v1 账本文档在首次打开时迁移为 v2：先写 `ledger.json.v1-backup`，再原子写回；重开不再
  迁移；迁移后不再写旧字段。

## 4. 错误

沿用 `{error:{code,message,fields}}`：

| 场景 | 状态/码 |
| --- | --- |
| 未登录 | 401 `unauthenticated` |
| account/auth_generation 不再是当前登录 | 409 `stale_identity` |
| consumer 归属/绑定版本/接管版本不符 | 409 `stale_binding` |
| ACK 缺展示事实 | 409 `consumption_gap` |
| 旧水位无法从 receipts 证明 | 409 `migration_required` |

409 不代表远端一定未执行；调用方不得当网络故障自动重发。

## 5. v2 本地协议（共享契约 `dea467-local-v2`）

契约 SHA `45f003bc76a9618cc703d72c0fecdebe1904acfb`（作者 Forge）。实现位于
`lib/services/chat_v2.dart`，由 `LocalAuthServer` 挂到 `/v2/`，只本机 loopback、全部 POST。

- `POST /v2/protocol/negotiate`：`{supported_versions:[2]}` → selected_version=2、
  contract、owner_header；无共同版本 426，未知字段/类型 422。协商不建立登录。
- `POST /v2/status`：`{protocol_version:2,auth:null|{account,auth_generation}}`，无 token。
- `POST /v2/consumers/{create,get,bind}`：需 `X-BB-Consumer-Key`（43 字符本地能力）与
  `expected_auth`；客户端只持久化 `sha256(key)`，先写 pending 预留再建 consumer。
  create 按 account＋key hash 幂等，重试不换 session/generation；get 只返回调用者能力
  覆盖的记录；bind 用 revision CAS，同 revision 竞争最多一个 200，其余
  `stale_binding`。返回 `{identity,session_id,active,migration}`，`active` 由当前登录
  generation 计算，旧 generation 只返回旧快照。
- 业务 `/v2/chat/*`、`/v2/operations/get`、`/v2/downloads/*`、`/v2/events/*`：严格四字段
  `expected_identity`，成功统一 `{identity,result}`；身份校验顺序为解析 → 401 →
  `stale_identity` → `stale_binding`（含 revision/consumer 拼接检查）→ 业务。
- 消费查询 `/v2/chat/consumption` 返回 `{consumed_through,migration}`；`get_operation`
  只对同一 consumer 返回其计划（其他 consumer 404），不使用跨账号全局 operation 查找，
  恢复查询不改 `operation_id`、不重发。
- `ExpectedIdentity.fromJson` 严格拒绝未知字段、非契约字符集/长度、revision 越界与非整数；
  v2 业务一律在解析后才做登录/身份/owner 校验。
- v2 事件 `version=2` + `origin_identity`：事件在写入时快照绑定；缺少来源的旧事件读取
  返回 `migration_required`，不回写成新绑定。v2 事件/下载以稳定 consumer id 作为持久
  key，重绑不重置 cursor。下载任务保存 `origin_identity`，旧任务无来源时
  `migration_required`。
- v2 错误 envelope 固定 `{error:{code,message,fields}}`，`fields` 只含 schema 字段名，
  不回显输入值；`conflict` 映射为 `idempotency_conflict`。

## 6. 共享 fixtures 与严格三层

`test/chat_v2_shared_contract_test.dart` 直接读取整合树的
`server/contract/chat-v2-cases.json` / `chat-v2-openapi.json`：校验版本与 owner header、
每条 OpenAPI 路由均已实现（未知路由 404）、全部 `invalid_inputs` 返回 422、错误表状态与
`{code,message,fields}` 形状，以及 probe 路径结果/identity 的 key 集合。

`QA_REQUIRE_INTEGRATION=1 bash scripts/run_flutter_tests.sh client`：analyze PASS、
flutter-test **312 passed / 8 skipped**、linux-integration **13 passed**，`RESULT=PASS`。

8 个既有 skip（未算通过）：

1. `live chat chain ordered text/image send, real blocks, receipts, ACK gap and ACL` —
   `BB_LIVE_SERVER_URL 未设置：未执行真实 FastAPI 聊天链路（SKIP，不算 PASS）`
2. `live chat chain attachment metadata only, async download, durable event and video cover`
   — 同上
3. `live chat chain wait returns an arriving message before timeout` — 同上
4. `live FastAPI auth register → login → persist → restore → expired credential` —
   `BB_LIVE_SERVER_URL 未设置：未执行真实 FastAPI 链路（SKIP，不算 PASS）`
5. `real MCP drives the standalone Dart entry; login arms 30s heartbeat and 401 clears files`
   — 缺 `BB_LIVE_SERVER_URL/BB_LIVE_DB_PATH/BB_PROBE_*`（SKIP，不算 PASS）
6. `live profile chain seventeen MCP tools through real stdio, three sources, refresh, logout`
   — 缺 `BB_LIVE_SERVER_URL`（SKIP，不算 PASS）
7. `capture narrow, wide and folded Profile presentations` —
   `QA_SCREENSHOT_DIR 未设置：本次未生成截图`
8. `capture users home and chat thread in three form factors` —
   `QA_CHAT_SCREENSHOT_DIR 未设置：本次未生成截图`

## 7. 未接线 / NOT RUN

- 真实 `journal/live.py --v2` 链路尚未在整合 SHA 上运行，需 Orion/Forge 合并本客户端 SHA
  后执行；共享 fixtures 已由客户端测试消费，但不等于真实链路。
- 完整 wait/被动竞争、多进程消费者所有权、session/在途下载身份、迁移故障注入、真实
  模型/视觉、集成版 CI 与 Sentinel 独立 QA 未在本轮验证。
- 新增用例：`test/chat_consumer_isolation_test.dart`、`test/chat_identity_generation_test.dart`、
  `test/chat_ledger_migration_test.dart`、`test/chat_v2_local_server_test.dart`、
  `test/chat_v2_shared_contract_test.dart`、`test/chat_atomic_commit_test.dart`、
  `test/client_identity_contract_test.dart`。

## 8. 真实故障门槛修复（2026-11-12）

按 `docs/contracts/dea467-real-fault-gate.md` 修复两个最小反例（只改 client/）：

- `admitted-send-switch`：v2 send 在远端成功、回执返回前切换账号，服务层原先在
  `_succeed` 后抛 `unauthenticated`（401）。现改为 `stale_identity`（409）；`sendBody`
  与 `sendAttachment` 的“已接纳成功后再切换”及其他身份切换分支统一按 stale 分类，
  原账号的 succeeded operation 仍先落盘保留，真实未登录入口继续是 401，不做全局映射。
- `migration-ambiguous-prepare/recover`：`ChatLedger.commitAck` 现在在幂等短路和
  receipt gap 之前先检查 legacy 迁移歧义；迁移报告对歧义记录保存 `consumer_ids`，
  受影响的旧 consumer 无论 receipts 是否连续、ACK 是否 lower/equal 都返回 409
  `migration_required`，水位保持 0。备份与 `legacy_consumption` 原证据不改；未受影响且
  有自己连续 receipts 的消费者仍可 ACK，完整迁移 scope 的幂等 ACK 不回归。

真实故障门槛在修复树实跑（`live.py --faults`，真实 v2 客户端/FastAPI/文件账本/原版 DSH，
模型为确定性替身）：**18 项用例全部 PASS，退出 0**，其中 `admitted-send-switch` 观测
409 stale_identity、原账号 plan succeeded、新账号无 plan、恢复查询 succeeded；
`migration-ambiguous-prepare` 观测 409 migration_required、水位 0、备份原文一致；
`migration-ambiguous-recover` 观测 409（stale_identity）且水位 0。`fault-gate` 仍报
PARTIAL，NOT RUN 为原生 wait/被动仲裁、备份完成到 rename 之间的迁移中断、真实模型、
集成版 Flutter 与 CI。证据目录的 `sources.json` 记录实际 client tree。

严格三层：`QA_REQUIRE_INTEGRATION=1 bash scripts/run_flutter_tests.sh client` →
analyze PASS、flutter-test **318 passed / 8 skipped**、linux-integration **13 passed**，
`RESULT=PASS`。8 个 skip 仍为第 6 节列出的 6 个真实服务/MCP 用例和 2 个截图用例，不计通过。

## 9. 统一会话/消息/上下文查询服务（共享契约 900429c 接线）

`client/lib/services/chat_query.dart` 是客户端统一查询服务（`ChatService.query`），
Forge 的共享查询契约（`4b91a5b`/`900429c`）唯一制定字段与语义；客户端不新增第二套 DTO。

- 服务端 `GET /conversations`、`GET /messages/{id}`、`GET /messages/{id}/context` 与
  双向 `GET /conversations/{account}/messages` 是唯一查询事实来源；客户端不再扫描历史来
  猜消息是否存在。
- 本地 v2 路由 `/v2/chat/list_conversations`、`/v2/chat/get_message`、
  `/v2/chat/get_context` 先严格校验 owner header 与四字段 `expected_identity`，再调用
  查询服务；成功统一 `{identity,result}`。
- `list_conversations`：仅已有私聊、peer 账号升序 keyset；服务端返回
  peer/last_message/last_activity_at/latest_position，客户端在已验证 consumer/binding 下
  补 `consumed_through` 与 `unconsumed_positions`（双向流位置差，不是收到的未读条数，
  也不是对外已读）。调用方任意 consumerId 不构成授权。
- `get_message`：服务端直接 lookup，不存在/无权统一 404；返回 ` {item,missing_media_ids}`。
  `get_context`：同一读事务内返回 anchor 与前后邻居（最多 99），明确 `range`、
  `before_has_more`/`after_has_more`、`missing_positions`/`missing_truncated`，回复关系固定
  `unsupported`。两向都用 `VisibleMessage`；缺图只填 `missing_media_ids`，该消息不给
  presentation，绝不把图像占位符当完整展示。
- `read_messages` 增加 `before_position`，与 `after_position` 非 null 互斥；两向升序，
  before 的 `next_position` 是首条位置，空页保持请求边界；旧 after 调用与 v1 白名单不变。
- 查询可以准备展示 receipts，但不 confirm、不 ACK、不推进水位。查询完成处（异步查询/
  媒体读取之后、结果暴露之前）复核完整 `expected_identity` 与当前 ledger binding：
  账号/auth_generation 变化 → 409 `stale_identity`，同账号同 generation 但 revision
  变化（CAS 重绑）→ 409 `stale_binding`；失败查询本次新建且未确认/未绑定 attempt 的
  receipts 会被丢弃，替换绑定不能消费旧查询的虚假完整展示。已确认或已绑定 attempt 的
  历史 receipt 保留。
- 回归：`test/chat_query_service_test.dart`（直接 lookup/context、consumer 富化、双向
  历史、缺口、身份）、`test/chat_v2_query_routes_test.dart`（严格 DTO、owner/identity、
  有序媒体与缺图不发放 receipt、before 分页、查询不消费）、
  `test/chat_v2_shared_contract_test.dart` 消费 `server/contract` 的 OpenAPI/fixtures
  （路线、invalid_inputs、错误表与三个查询结果 key 集合）。
