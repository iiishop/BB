# DEA-467 客户端消费隔离与身份代际（Muse）

状态：客户端实现交接，不是独立 QA PASS。基线 `71b3a0c8292712f65abb66da5c2e777ed4fba542`，
只改 `client/`。共享契约按 Forge 的 `4fd57d679891428884a812b7e46f31392470d981` 对接。

## 1. 单一受保护协议与消费事实

- Owner 明确本轮没有部署、没有旧调用方。认证引导保留 `/auth/register|login`；
  旧 `/chat/*`、`/downloads/*`、`/operations/*`、`/events/*` 业务路由已删除，调用返回
  404，聊天/消费/下载/事件不再有“无身份但可用”的入口。资料工具走受保护的
  `/v2/profile/*`（六条，owner＋expected_identity）；旧 `/profile/*` 同样返回 404。
- 唯一消费 key：`(authenticated_account, consumer_id, peer_account)`。consumer id 由客户端
  生成并持久化（`c-<32hex>`），不是 session、不是凭据；`session_id` 只是 v2 create/bind 的
  路由映射。owner capability 只持久化 `sha256`。
- receipt、确认、ACK、事件 cursor、下载任务都绑定稳定 consumer；receipt 必须带
  `consumer_id`，不再按 `consumer_session` 字符串推断归属。消费水位只按 consumer 维度推进。
- 旧的 `account+peer` 水位、legacy alias 解析和 v1 文档迁移分支已移除；旧版本账本文档在
  打开时 fail closed（`unsupported chat ledger version`），不再生成备份或部分迁移。
  测试中的旧账本均为合成数据。

## 2. 身份与绑定

- `AuthSession.establish`/`clear` 每次轮换不透明 `auth_generation`；同账号重登、A→B→A、
  进程重建都会让旧值失效，`updateUser` 不轮换。
- `ExpectedIdentity {account, auth_generation, consumer_id, binding_revision}` 由
  `ChatService.identityFor(...)` 取得；不含 token。
- owner 入口 `POST /v2/consumers/create|get|bind` 需要 `X-BB-Consumer-Key` 与
  `expected_auth`。create 按 account＋key hash 幂等；bind 以 `expected_binding_revision`
  CAS，同 revision 竞争最多一个成功；owner/账号/版本不符统一 `stale_binding`。
- 客户端进程内的 UI 发送使用客户端自有的稳定 human consumer（`human:<account>`）；
  它不经过本地 HTTP，也不接受外部 `consumer_session` 作为授权。所有跨进程业务调用必须带
  owner 与四字段 `expected_identity`。
- ACK / confirm 的身份与绑定检查在同一个 ledger 锁内、写入之前完成；身份失效不写水位/
  确认，`beforeCommit` 是受控暂停点。服务层在入口捕获 `(AuthIdentity, ConsumerBinding)`，
  之后只使用捕获值，不再在 await 后读取全局 token。

## 3. 操作计划与恢复

- `ChatOperationRecord.expected_identity` 在首次网络提交前落盘。
- 显式 `operation_id` 跨账号查找：属于别的账号 → `stale_identity`，任何副作用前拒绝。
- 身份不匹配的计划只对账、不重发：先查服务器幂等事实；成功只记原账号，查不到则保留
  `uncertain` 并返回 `stale_identity`。已成功记录直接返回本地结果，恢复发送为 0。
- 不再支持 v1 账本文档迁移；只接受当前单一文档版本。重启恢复仍使用同一 ledger 的
  稳定 consumer、operation、receipt、确认和水位事实。

## 4. 错误

沿用 `{error:{code,message,fields}}`：

| 场景 | 状态/码 |
| --- | --- |
| 未登录 | 401 `unauthenticated` |
| account/auth_generation 不再是当前登录 | 409 `stale_identity` |
| consumer 归属/绑定版本/接管版本不符 | 409 `stale_binding` |
| ACK 缺展示事实 | 409 `consumption_gap` |
| 已删除的 v1 业务路由 | 404 `not_found` |

409 不代表远端一定未执行；调用方不得当网络故障自动重发。

## 5. v2 本地协议（共享契约 `dea467-local-v2`）

契约 SHA `4fd57d679891428884a812b7e46f31392470d981`（作者 Forge）。实现位于
`lib/services/chat_v2.dart`，由 `LocalAuthServer` 挂到 `/v2/`，只本机 loopback、全部 POST。

- `POST /v2/protocol/negotiate`：`{supported_versions:[2]}` → selected_version=2、
  contract、owner_header；无共同版本 426，未知字段/类型 422。协商不建立登录。
- `POST /v2/status`：`{protocol_version:2,auth:null|{account,auth_generation}}`，无 token。
- `POST /v2/consumers/{create,get,bind}`：需 `X-BB-Consumer-Key`（43 字符本地能力）与
  `expected_auth`；客户端只持久化 `sha256(key)`，先写 pending 预留再建 consumer。
  create 按 account＋key hash 幂等，重试不换 session/generation；get 只返回调用者能力
  覆盖的记录；bind 用 revision CAS，同 revision 竞争最多一个 200，其余
  `stale_binding`。返回 `{identity,session_id,active}`，`active` 由当前登录 generation 计算，旧
  generation 只返回旧快照；没有 legacy 迁移字段。
- 业务 `/v2/chat/*`、`/v2/operations/get`、`/v2/downloads/*`、`/v2/events/*`：严格四字段
  `expected_identity`，成功统一 `{identity,result}`；身份校验顺序为解析 → 401 →
  `stale_identity` → `stale_binding`（含 revision/consumer 拼接检查）→ 业务。
- 消费查询 `/v2/chat/consumption` 只返回 `{consumed_through}`；`get_operation`
  只对同一 consumer 返回其计划（其他 consumer 404），不使用跨账号全局 operation 查找，
  恢复查询不改 `operation_id`、不重发。
- `ExpectedIdentity.fromJson` 严格拒绝未知字段、非契约字符集/长度、revision 越界与非整数；
  v2 业务一律在解析后才做登录/身份/owner 校验。
- v2 事件 `version=2` + `origin_identity`：事件在写入时快照绑定；v2 事件/下载以稳定
  consumer id 作为持久 key，重绑不重置 cursor。下载任务保存 `origin_identity`。不再有
  针对旧无来源记录的迁移/兼容分支。
- 六条 `/v2/profile/{view_avatar,update_avatar,view_nickname,update_nickname,view_signature,update_signature}`
  同样要求 owner header 与四字段 `expected_identity`，返回 `{identity,result}`；保留原参数、
  头像媒体和产品校验，异步完成后复核完整 binding。旧无身份 profile 路由 404。
- v2 错误 envelope 固定 `{error:{code,message,fields}}`，`fields` 只含 schema 字段名，
  不回显输入值；`conflict` 映射为 `idempotency_conflict`。

## 6. 共享 fixtures 与严格三层

`test/chat_v2_shared_contract_test.dart` 直接读取整合树的
`server/contract/chat-v2-cases.json` / `chat-v2-openapi.json`：校验版本与 owner header、
每条 OpenAPI 路由均已实现（未知路由 404）、全部 `invalid_inputs` 返回 422、错误表状态与
`{code,message,fields}` 形状，以及 probe 路径结果/identity 的 key 集合。

`QA_REQUIRE_INTEGRATION=1 bash scripts/run_flutter_tests.sh client`：analyze PASS、
flutter-test **318 passed / 6 skipped**、linux-integration **13 passed**，`RESULT=PASS`。

6 个既有 skip（未算通过）：

1. `live chat chain ordered text/image send, real blocks, receipts, ACK gap and ACL` —
   `BB_LIVE_SERVER_URL 未设置：未执行真实 FastAPI 聊天链路（SKIP，不算 PASS）`
2. `live chat chain attachment metadata only, async download, durable event and video cover`
   — 同上
3. `live chat chain wait returns an arriving message before timeout` — 同上
4. `live FastAPI auth register → login → persist → restore → expired credential` —
   `BB_LIVE_SERVER_URL 未设置：未执行真实 FastAPI 链路（SKIP，不算 PASS）`
5. `capture narrow, wide and folded Profile presentations` —
   `QA_SCREENSHOT_DIR 未设置：本次未生成截图`
6. `capture users home and chat thread in three form factors` —
   `QA_CHAT_SCREENSHOT_DIR 未设置：本次未生成截图`

## 7. 未接线 / NOT RUN

- 合并后的真实 `journal/live.py` 链路需 Orion/Forge 在集成 SHA 上重跑；本轮客户端单测覆盖
  本地 HTTP 与落盘重启，不等于真实 FastAPI/MCP/DSH 三端。
- 六条 `/v2/profile/*` 已在客户端实现并由本地测试覆盖；MCP 六工具改走受保护接口的
  stdio/HTTP 联调由 Forge 的契约与测试覆盖。旧 `/profile/*` 已 404，没有 v1 回退。
- 完整 wait/被动竞争、多进程消费者所有权、session/在途下载身份、真实模型/视觉、
  Windows/Android 与 Sentinel 独立 QA 未在本轮验证。

## 8. 单协议清理与既有修复（2026-11-12）

Owner 纠正“没有部署、没有旧调用方”后，本轮不再修补 v1 兼容权限，而是删除旧通路：

- 删除本地 `/chat/*`、`/downloads/*`、`/operations/*`、`/events/*` 业务路由；这些路径现在
  返回 404，只有 `/auth/register|login` 与 `/v2/*` 可执行业务。
- 删除 v1 账本文档迁移、`legacy_consumption`/`legacy_migration` 报告、歧义 ACK 特判、
  `consumer_aliases` 的外部别名解析入口与相关测试；旧版本文档 fail closed。
- 保留并继续测试：owner capability 的 create/get/bind CAS、稳定 consumer id、账号与
  绑定代次、operation 幂等/对账、receipt/confirm 原子性、消费缺口、重启恢复。
- 之前 `admitted-send-switch` 的 `stale_identity` 分类修复保留。旧 `live.py --faults` 的
  migration-ambiguous 用例依赖已删除的迁移分支，不再作为当前树的门槛；未重跑旧全矩阵。

严格三层（清理后）：analyze PASS、flutter-test **318 passed / 6 skipped**、
linux-integration **13 passed**，`RESULT=PASS`，退出 0。

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
  before 的 `next_position` 是首条位置，空页保持请求边界；旧 v1 白名单已随业务路由删除。
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

## 10. 单协议回归（R1/R2 收敛，2026-11-12）

R1/R2 不再用 v1 权限特判解决，而是消除旧通路本身：

- R1：旧 `consumer_session` 的 v1 confirm/ACK 路由已删除，不存在“旧 alias 重新取得当前
  绑定”的入口；所有确认/ACK 必须走 `/v2/chat/confirm_presentation|ack_messages`，带
  owner header 与四字段 `expected_identity`，CAS 重绑后的旧身份按 `stale_binding` 拒绝。
- R2：v1 账本迁移与旧 `account+peer` 水位已删除，不再产生可被新 consumer 继承的
  legacy receipts/alias；旧账本文档打开即 fail closed。稳定 consumer 只能通过 owner
  create/bind 建立，消费水位按 `(account, consumer_id, peer)` 持久化。
- 第一方进程内 UI 仍使用客户端自有的稳定 human consumer，直接调用 `ChatService`，不经过
  本地 HTTP；MCP/bundle 六资料工具已改走受保护的 `/v2/profile/*` 契约。

回归 `test/local_single_protocol_test.dart` 用真实 `LocalAuthServer` HTTP 和真实落盘账本：
旧 `/chat/*`、`/downloads/*`、`/operations/*`、`/events/*` 全部 404；无 owner 的 v2 业务
非 200，无 identity 为 422，owner+identity 为 200；关闭服务并从同一账本重启后，
`/v2/consumers/get` 与业务调用仍返回同一稳定 consumer。

严格三层：analyze PASS、flutter-test **318 passed / 6 skipped**、linux-integration
**13 passed**，`RESULT=PASS`，退出 0。


## 11. 请求凭据、401 归属与提交顺序修复（F1/F3/F4，2026-11-13）

- **F1（请求身份/凭据捕获）**：`ChatService.requireIdentity` 在等待 ledger 锁后重新校验
  `session.isCurrent(captured)`；`/v2/chat/list_users` 改为传 `expected_identity`，
  `listUsers` 使用该身份捕获的 token 并在返回前复验，不再从可变 session 重新取凭据。
  Profile v2 的六条调用也把捕获的 `AuthIdentity` 传入 `ProfileService`，token/默认账号从
  捕获值取得，异步完成后再次校验；旧请求不会用新账号凭据执行或返回。
- **F3（内存/持久提交顺序）**：`commitAck`、`bindConsumerOwner`、`bindConsumer` 在修改
  内存前快照，flush 失败恢复快照；重试不会命中未持久化的水位/revision，冷重开与磁盘一致。
  真实文件 I/O 失败通过把账本路径替换为同名目录制造，恢复文件后重试并冷重开验证。
- **F4（401 失效归属）**：v2 router 把 AuthFailure 转成 DTO 后，`LocalAuthServer` 统一检查
  401 `unauthenticated` 并调用 token-aware `onUnauthorized(token)`；回调只在当前 token 仍
  等于请求捕获 token 时清理。`AuthService.signOut` 删除凭据文件后只清理本次捕获的 token；
  若删除期间已完成新登录，旧回调会先恢复新凭据的磁盘副本，再保留新内存登录。`restoreSession`
  的 401 也按原 stored token 清理，不再无条件清空并发新登录；删除失败分支同样保留新登录并
  维持原有“显式登出失败保留内存”语义。当前凭据失效会清空内存/磁盘并让 `/v2/status` 变 null。
  回归 `test/f4_clear_race_test.dart`（删除成功）与 `test/f4_clear_failure_test.dart`
  （删除失败）均在旧 401 暂停点完成新登录，断言内存与磁盘都保留新 token。补写自身也有
  异步窗口：`_repersistNewLogin` 每次落盘后核对当前 token，若写入期间又完成新登录则重写
  最新 token；`test/f4_repair_overwrite_test.dart` 在旧 B 补写暂停时登录 C，最终内存与
  磁盘都保持 C。

回归：`test/chat_identity_capture_race_test.dart`（锁等待/捕获后切号）、
`test/chat_ledger_io_rollback_test.dart`（真实 ACK/bind 写盘失败+冷重开）、
`test/local_v2_unauthorized_test.dart`（当前 401 清理与并发新登录保护）；
真实 FastAPI A/B/C 对照：修复前旧 A 请求返回 200 且含 B-C 私聊预览，修复后返回 409 且
无该预览。严格三层：analyze PASS、flutter-test **318 passed / 6 skipped**、
linux-integration **13 passed**，`RESULT=PASS`，退出 0。
