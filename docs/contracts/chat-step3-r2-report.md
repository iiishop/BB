# DEA-466 Forge R2 实施回交

结论：**D1/D2 的限定回归通过；完整 R2 门槛仍为 FAIL / 未完成，不可记为产品或独立 QA PASS。** 已接续 server/ 与 dsh-plugin/ 产品代码，不再仅交 SDK 探针。保持 in_progress 与现有 assignee。

基线：`7c15f172cb8d6ed968629ac5ab41d9c989a8f1ea`。分支：`agent/forge/dea466-chat-r2`。最终 SHA、完整 bundle 与校验和在交付评论及附件清单中给出。

## 实现与契约

- `server/src/bb_server/chat.py`：已注册用户分页与私聊预览；有序图文和独立附件消息；会话历史；参与双方授权的媒体上传/读取/Range；持久事件补取与鉴权 WS；账号级操作幂等提交/查询。
- `003_chat.sql`：消息、操作回执、双方事件同一事务；pair position 唯一约束；媒体元数据。现有账号、Profile 与会话保留。迁移、文件落盘屏障及备份/恢复边界见正式契约文本。
- `server/contract/src/bb_auth_contract/chat.py`、`chat-local-schema.json`、`chat-cases.json`、`server/openapi.json`：共享请求/响应、原生与本地事件判别 schema、下载查询/状态和消费缺口样例；导出脚本可重生成。
- `dsh-plugin/src/bb_dsh_plugin/plugin.py`：新增九个本地工具，保留八个旧工具。120 秒 wait 不再被 HTTP 默认十秒截断；按顺序输出文本/真实 base64 图片块；读/等待不自动 ACK；504 保持不确定语义。
- 原生补丁保留持久接纳和 claim 恢复两原语。实际 request 成员/digest 决定 dispatch，过滤事件 deferred 可重放；attempt 与 logical_turn 分开；副作用计划先 flush，稳定 operation_id 先 query 后幂等 submit。无计划的纯推理可重试，provider 流不发布业务消息。
- `local-bridge.mjs` 限 127.0.0.1 客户端，白名单回执字段，查询失败不盲重试；下载 pending 与终态区分。未知副作用工具在事件回合中拒绝，普通非事件工具行为不改。
- `client/` 无改动；全局安装、共享依赖链接目标、个人 profile/凭据无改动。运行时从固定原始树复制到项目隔离目录，再应用版本化补丁。

## 可复现验证（最终执行）

工作目录均为仓库根；`<source>` 为已锁定的原始 DSH 安装树，`<copy>` 为 `dsh-plugin/.runtime/dsh-rc5-r2-validated`。

| 命令 | 退出码与结果 |
| --- | --- |
| `uv run --no-project python dsh-plugin/runtime-patch/install.py --source <source> --destination <copy>` | 0；固定版本/完整源码哈希校验、独立复制、无共享 inode/链接、补丁及完整树验证 |
| `node dsh-plugin/runtime-patch/test.mjs <source> <copy>` | 0；原始负面回归仍复现 FAIL；修补后 25 worker / 8 SIGKILL 的限定矩阵 PASS，含四接纳/领取点、恢复再中断、12 并发、完成重放、不同 account/session、旧普通会话 |
| `node dsh-plugin/runtime-patch/test-boundaries-r2.mjs <copy>` | 0；原正常 batch/co-claimed 控制、filtered-batch/co-claimed-filtered、工具失败均通过。过滤前状态 deferred；解除过滤后 completed；从未自动 ACK |
| `node dsh-plugin/runtime-patch/test-operations-r2.mjs <copy>` | 0；17 worker / 5 SIGKILL。持久计划后、提交前、提交后丢回执、调用意图后、provider 进入后；恢复、第二次重启、完成重放均只一个替身业务提交 |
| `node dsh-plugin/runtime-patch/test-local-bridge.mjs` | 0；下载接纳/pending/成功/失败，查询 503 不提交，回执不外泄多余字段。HTTP 客户端为替身 |
| `uv run --directory server pytest -q` | 0；103 passed，1 个既有 Starlette/httpx 弃用警告 |
| `uv run --directory dsh-plugin pytest -q` | 0；93 passed，包括真实 MCP stdio 运输；本地 HTTP 业务端为替身 |
| `uv run --directory server ruff check src tests contract/src contract/export_chat.py` | 0；初次检查发现旧测试 import 排序问题，已整理并复测 |
| `uv run --directory dsh-plugin ruff check src tests` | 0 |
| `uv run --directory server python -m bb_server.export_openapi openapi.json` | 0 |
| `uv run --directory server python contract/export_chat.py` | 0 |
| `git diff --check` | 0 |

真实运行时：DSH 0.2.1-rc.5 / Cordis 4.0.5 / Node 26.8.2 / Linux x86_64；实际 JSONL 会话存储。Python 3.13.15。模型为确定性替身；业务矩阵的本地 HTTP 客户端为有落盘状态的合成替身。服务端 pytest 则直接验证真实 SQLite 事务、并发幂等、回滚、ACL、Range、重启、Unicode 预览和媒体错误处理。不要把两项证据拼接为真实三端通过。

原 Sentinel 附件 SHA256 已核对为 `1d4e0d4933cfef08aebb7b9bb5dbf8c8bb177008c762605fde829e3efe37fa50`；原脚本逐字保留在 `runtime-patch/sentinel/`。R2 expectation 层为单独文件，未改原反例以隐藏失败。

## 必须回交的契约冲突 / 尚未达到的门槛

1. **持久操作计划后的继续推理尚未实现。** 最初直接在恢复物理回合重放旧 `tool/call`，恢复当次看似成功，但第二次重启实际被 V4 验证拒绝：`tool/call ... has no advertised tool lifecycle`。失败日志、真实 JSONL、当时 helper 与最小 diff 均保留在证据包 `r2-operations-HD6cTC/` 和 `r2-operations.log`。当前修补版改为查询/完成原持久操作计划，追加真实回执，结束该逻辑事件；不伪造 native tool 历史，不让模型以新 ID 重发输出。但这**不等同于** R2 第 3 条“完成已存计划，再继续推理”，不能默认降低该要求。
2. **原生事件回合 ACK 仍拒绝。** 客户端实际展示/消费凭据链尚未接通；Python 工具已有明确 ACK、session/对话参数与 409 消费缺口契约，但不能把工具返回、request intent 或 turn/end 冒充展示。`consumed_through` 仍为 null。替身消费缺口测试只验证约定，不是实际客户端实现。
3. 原生 busy/匹配 wait/turn-end 与实际客户端持久事件流、下载成功/失败归属，仍缺共享集成版本。现有 `bbDeliver`、操作 bridge 与本地 schema 是实施接口，不是上述全链路已完成的证据。

建议 Orion 接续协调的最小增量：确定“恢复计划与回执如何作为新请求的真实恢复上下文”及“禁止重复最终输出”的语义，再扩展原生 continuation；与 Muse 固定实际展示 receipt 到消费 ACK 的客户端交接接口。不能只增另一张去重表、把调用重命名，或撤掉上述验收。此处回交有具体失败证据与可审查实现；不请 Owner 提前批准，不再无限换公开 SDK 路线。

## 证据位置与 NOT RUN

证据附件包含最终 `recovery-jKyEM8/`、`r2-boundaries-X5GUbB/`、`r2-operations-dOyLWQ/`，命令日志、原始 session JSONL、SIGKILL 前缀、provider 进入证据、锁文件，以及上述失败尝试。所有会话、账号和素材均为合成数据。记录存在内部重试与多次原生 turn，稳定业务身份不变。

NOT RUN：真实模型/视觉；实际 Flutter/Dart 客户端下载与展示/ACK；完整聊天/MCP/DSH 恢复；Flutter 三层；Android/Windows 运行；物理折叠设备；Owner 人工验收；独立 Sentinel QA。未合 main、未发布、未改 Done/Owner Review。
