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
- `ChatLedger.bindConsumer` 是唯一绑定入口：首次 alias 建 consumer（revision 1）；新
  generation 递增 `binding_revision`；按 consumer id 接管必须提供当前 revision，且 consumer
  不能跨账号接管（`stale_binding`）。
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

## 5. 未接线 / NOT RUN

- HTTP v2 `expected_identity` 路由、版本协商、状态/绑定启动端点：等 Forge 机器契约，本地
  v1 路由保持严格 payload（不偷偷放宽白名单，`expected_identity` 仍被 422 拒绝）。
- 完整 wait/被动竞争、多进程消费者所有权、session/下载恢复、真实模型/视觉与最终集成 CI
  未在本轮验证；下载与会话恢复仍按现有实现记录为未完成项。
- 测试：`QA_REQUIRE_INTEGRATION=1 bash scripts/run_flutter_tests.sh client`；新增用例见
  `test/chat_consumer_isolation_test.dart`、`test/chat_identity_generation_test.dart`、
  `test/chat_ledger_migration_test.dart`。
