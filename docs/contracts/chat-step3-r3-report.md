# DEA-466 Forge R3 implementation and cross-client result

R3 原生增量限定回归通过；**跨端契约验收 FAIL，不能进入独立 QA**。本报告是 Forge 自测。基于 `12ce1c054286315f76d7b38143060add6f3c39d2`，分支 `agent/forge/dea466-chat-r3`。最终完整 SHA、bundle 哈希见交接评论及证据 manifest。未修改 client/、全局 DSH、个人 profile 或凭据；保持 in_progress 与 assignee。

## Schema / API / state

- `docs/contracts/chat-step3.md` 为 R3 主契约；`server/contract/chat-local-schema.json`、`chat-cases.json` 与 Python 模型统一导出 presentation、四个内部接口、消费缺口和冲突/订阅样例。九个聊天 MCP 工具不变，内部接口不向模型开放。
- 本增量不改业务数据库结构；沿用基线 migrations 001–003 与 REST/OpenAPI。事件/消息/媒体/操作业务事实仍由 FastAPI/SQLite 持有；receipt、下载、本地事件属于 Dart 客户端。
- 保留原生持久接纳与 claim 恢复两原语。业务计划先 flush 稳定 operation_id，再 query/submit；恢复上下文携带原始输入引用、逻辑回合、计划及实际结果，通过真实 runtime-context 继续推理。没有伪造旧 tool 生命周期，也不再“计划完成便结束事件”。
- 实际 MCP 投影/模型请求的完整成员、文本段及图片数量建立展示映射；成功模型响应持久化后确认 receipt，ACK 仍独立且检查完整缺口。跨账号/会话结果在写入原生 tool/result 前拦截；被过滤、图片不支持或不完整投影不能提前确认。
- 新 `RuntimeBridge` 把持久本地事件交给原生 driver。接纳先于游标持久化；忙碌事件排队，匹配 wait 的消息进当前回合，下载完成/失败归属原 consumer。已通过 read/wait 展示的延迟通知关联原展示事实，不重复处理。
- 原生 `setupProductBridge` 实际挂载 Python MCP；工具调用超时 130 秒覆盖 120 秒 wait。宿主必须 await bridge 生命周期；没有新调度器、后台孤儿服务或个人部署发现。

## Compatibility / boundaries

固定 DSH **0.2.1-rc.5**、Cordis **4.0.5**、Linux x86_64；测试 Node **26.8.2**、Python **3.13.15**。完整源树 61,818 文件，SHA256 `6b975d17d879820246c72ef72fa84ab0206f23dc47f63b8ff8e244f0e9352556`。原始 target SHA256 `cf57e3ecd487ac5c2553455aaa5cef2c6fb41e6bd61be5aa455675d1d7193033`；补丁/helper/目标哈希见 `runtime-patch/lock.json`。先复制完整依赖，拒绝共享链接、已有目标、哈希/平台不符；仅补丁隔离副本。

R1 缺少成员/副作用证据的 dispatch 保持 legacy_uncertain；R2 已终态记录不改写/重跑。旧会话正常控制保留。恢复时与原计划完全相同的写意图映射原 operation，改名不能重发；不同参数可形成新操作。同一逻辑事件恢复中若确实要再次发完全相同内容，需新业务事件；不会猜测语义等价。Provider 可以重复推理，流式输出不直接发布平台消息；不声称跨 provider exactly-once。

## Executed commands / exits

以下从仓库根运行；`$DSH_SOURCE` 指固定原始包，`$RUNTIME` 指新建项目副本 `dsh-plugin/.runtime/dsh-rc5-r3-handoff`。所有 worker 在命令结束前收集/关闭。

| 命令 | 结果 | 日志 |
| --- | --- | --- |
| `uv run --no-project python dsh-plugin/runtime-patch/install.py --source "$DSH_SOURCE" --destination "$RUNTIME"` | 隔离安装已生成完成标记；随后 matrix 内全树 verify exit 0 | matrix/runtime-verification.json |
| `node dsh-plugin/runtime-patch/test.mjs "$DSH_SOURCE" "$RUNTIME"` | exit 0；25 worker / 8 SIGKILL；包含原负面基线 | r3-handoff-matrix.log |
| `node dsh-plugin/runtime-patch/test-boundaries-r2.mjs "$RUNTIME"` | exit 0；5 正常/过滤/工具失败控制；D1解除过滤可处理 | r3-handoff-boundaries.log |
| `node dsh-plugin/runtime-patch/test-continuation-r3.mjs "$RUNTIME"` | exit 0；24 worker / 8 SIGKILL；12并发、恢复再中断、二次重启、原输出不重发/新意图 | r3-handoff-continuation.log |
| `node dsh-plugin/runtime-patch/test-presentations-r3.mjs "$RUNTIME"` | exit 0；12 worker / 3 SIGKILL；确认丢回执不重跑模型、ACK缺口、接纳后游标中断 | r3-handoff-presentations.log |
| `node dsh-plugin/runtime-patch/test-mcp-r3.mjs "$RUNTIME"` | exit 0；7 模式，实际 Python MCP/native 投影；部分投影/图片拒绝/账号冲突、busy/wait/download | r3-handoff-mcp.log |
| `node dsh-plugin/runtime-patch/test-local-bridge.mjs` | exit 0；pending/query错误不重复提交 | r3-handoff-local.log |
| `node dsh-plugin/runtime-patch/test-v4-negative.mjs "$V4_COPY"` | wrapper exit 0；预期旧第二次重启 exit 1，不是产品通过 | r3-v4-negative.log |
| `uv run --project server --locked pytest server/tests -q --tb=short` | 103 passed / exit 0；既有 Starlette/httpx 弃用警告 | r3-server-final.log |
| `uv run --project dsh-plugin --locked pytest dsh-plugin/tests -q --tb=short` | 95 passed / exit 0 | r3-plugin-handoff.log |
| `uv run --directory server --locked ruff check src tests contract`；plugin 同类命令 | 各 exit 0 | r3-ruff-*.log |
| `uv run --project server --locked python server/contract/export_chat.py`；OpenAPI 导出；`git diff --check` | exit 0；OpenAPI无变化 | generated artifacts |

模型与本地业务客户端在上述矩阵中明确为确定性替身；原生 Cordis、DSH、JSONL、图片存储、MCP SDK/stdio 都是真实实现。Sentinel 原反例及 R2 原脚本保留；V4 失败版本的锁、源码、patch、安装器在 `runtime-patch/regressions/v4-failure/`，可独立复制复现。

## Real Dart integration: FAIL with bounded positive evidence

按 Orion 补充读取 Muse bundle，SHA256 `fa51e5fc71552d9f5102627ce3c9ec076aed5ac3a7fbd62e6df188fc954a24c8`，在独立只读使用的 checkout 运行 **`c684e29371b0236dadecb05f8ff18802175502ef`**。没有修补客户端，也未以 fake backend 替代。实际 FastAPI/SQLite、独立 Dart 进程、本地账本、Python MCP、原生 DSH 都运行；仅 provider 为确定性替身。

复现命令（纯 Dart packages 文件由测试生成在隔离证据目录；读取已缓存 crypto 3.0.8，不修改 SDK）：

```sh
uv run --project server --locked python dsh-plugin/runtime-patch/test-live-r3.py \
  --client "$MUSE_CHECKOUT/client" --runtime "$RUNTIME" \
  --dart "$DART_SDK/bin/dart" --crypto "$PUB_CACHE/hosted/pub.dev/crypto-3.0.8"
```

**exit 1**，`r3-live-contract.log`；4 条失败断言归于 3 个问题：

1. `/events/wait` 带共享 `limit:50` → **422 extra field**；runtime 的等待路径被阻断。客户端 `local_auth_server.dart` 未接收该字段，服务层也未传递 limit。
2. 相同 `attempt_id` 首次确认 A，改 `request_digest` 与 receipt 为 B → **200，预期409**；随后本应存在缺口的 ACK2 也 **200，预期409**。`chat_service.dart` 先 confirmReceipts，再 `chat_ledger.dart::recordConfirmation` 无条件覆盖 attempt。需原子验证绑定/成员/摘要后才能确认，冲突不应产生任何确认副作用。
3. consumer A 已推进账号级 source cursor 后，新 consumer B 注册同 peer，已有两条未消费 incoming 的 `/events/read` 返回 **0条**。`event_feed.dart` 的账号级 source cursor 跳过注册前积压；需持久化注册补取起点并恢复可读未消费积压，不能把另一个 consumer 拉取当作该 consumer 已接纳。

真实链中通过的范围：MCP read→实际请求→成功响应→confirm→显式 ACK1；未展示 B 的 ACK2 返回409；已有订阅事件经真实 native 接纳/处理，Dart 重启后持久页相同；平台业务提交后 SIGKILL，Dart 重启恢复账本，原生 continuation 实际推理两次，再两次重启重放模型调用0，平台输出最终 **1条**。实际 ReadResult/LocalEventPage 通过共享模型校验。同账号其他 session 身份冲突409符合R3，不误报为跨账号404问题。

早版诊断曾把同账号跨 session 预期误写为404，已按R3纠正并完整重跑；最终仅上述三项问题。代码没有静默移除 `limit` 或降低确认语义来掩盖失败。需 Orion 协调 Muse 修复后统一精确版本再复验。此前 Orion 指出的历史分页/视频/播放/粘贴 UI 返工仍由 Muse 执行。

## Install / start / withdraw / evidence

安装、verify、宿主 create/resume setup、await pump/run 与撤回步骤见主契约 Reproduction。本轮所有服务/worker均由前台测试拥有并回收；SIGKILL 只针对本测试启动的独立进程组，先排除 daemon PID/进程组。无持久服务交付。

证据包只包含选定日志、原生会话、合成请求/图片和摘要；排除 live 测试 `private/` 中的合成登录凭据、数据库和客户端账本。未导出真实用户数据。账本行为通过实际API返回、重启及模型/业务计数验证，不伪造记录。

NOT RUN：真实模型/视觉、最终统一 SHA 的完整聊天/下载/ACK 三端恢复、真实认证切换时序、客户端异步下载文件/设备 UI 本轮复验、Flutter严格三层、Android/Windows运行、物理折叠、Owner人工验收、独立 Sentinel QA。本增量不能替代这些门槛，不进入 Owner Review、main、发布或 Done。
