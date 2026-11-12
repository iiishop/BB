DEA-467 公开 journal / attempt 探针续报
======================================

**已找到可运行的原版宿主恢复路径；六项产品门槛尚未全部通过。**
本轮基于同一 PR #12、`eb2144d911193794b9f5b4757d7c58863b6d7ed5` 继续，
没有替换基线。公开 `Inbox.remove` + `runMaintenance` + BB 元数据 journal 能恢复
旧 pending/claimed 输入，避免其与新 attempt 双执行。真实 Dart/FastAPI 又复现
两项客户端契约缺口，下一步是协调 BB 客户端修改，不是等待 Owner 再次许可，
也不能宣称所有公开插件方案不可能。

Owner 最新授权生效：DSH/外部依赖固定。没有打补丁、monkey-patch、私有实现
替换、fork 或升级。`runtime-patch` 不作为运行依赖或候选交付；原报告的补丁和
更换上游版本候选已撤销。保留原生负例，并重新运行原 public-host runner。
注册/登录 MCP、其他业务工具、显式发送出站规则和生产实现均未修改。

被测公开方案
------------

安装版 DSH 0.2.1-rc.5 / Cordis 4.0.5，Linux x86_64 / Node v26.8.2。
关键 AgentLoop SHA-256 仍为
`cf57e3ecd487ac5c2553455aaa5cef2c6fb41e6bd61be5aa455675d1d7193033`。
runner 在执行前后检查 8 个固定实现/声明文件；不声称做了整个发行包供应链审计。
`sources.json` 记录被测宿主与探针哈希；真实链路另记录 client tree/services
及 server lock 哈希。新探针不导入 runtime-patch。

公开来源均是实际安装包 `node_modules/@deepseek-ai/`：

| 使用的接口 | 声明/来源 | 用途 |
| --- | --- | --- |
| `Inbox.remove(messageId: MessageId): boolean` | `dsh-agent/lib/types/runtime-types.d.ts` 的公开 `Inbox` | 只移除属于该业务事件的旧 pending；不清空其他输入 |
| `Agent.runMaintenance<T>(task: (signal: AbortSignal) => Promise<T>): Promise<T>` | 同上 | 在 idle 阶段持有原生维护边界；原生 driver 在任务结束后自行驱动新 followup |
| `Agent.followup(message: UserMessage): void` | 同上 | 每次尝试独立消息 ID；所有调度仍由原生 driver 执行 |
| `agent/pre-step` waterfall | 同上 | 写入 claim 与 turn 映射，返回 next()，不改写私有请求 |
| `llm/stream(options, next): AsyncIterable<StreamChunk>` | `dsh-llm/lib/types/index.d.ts` | 持久 dispatch intent 后调用 next()；只读冻结请求，不替换内容；成功 finish 与失败分开 |
| `session/event`、`sessions.flush`、`snapshotEvents` | `dsh-session` | 以持久 user/message、成功流和 completed turn 三者交叉验证提交边界 |
| `storageDomain.open` / table `put` | `dsh-storage-domain` | 插件只存 identity/event digest/attempt/operation plan 等元数据；每次 put 前用 schema.parse 校验 |
| `ctx.plugin` / `ctx.on` / `ctx.effect` | Cordis | 拥有与销毁订阅；emit 后的异步提交另行 drain，并收集错误，避免未处理 rejection |

journal 不存聊天历史，不是新的业务事实库；业务消息/发送结果仍由服务端和
客户端提供。模型是确定性替身。通用崩溃矩阵中的客户端确认、消费和发送账本
**也是明确的测试替身**，不用于声称实际 BB 多消费者通过。真实客户端测试单列。
探针仅支持其独占的 event-owned session；混合普通用户输入、完整工具/wait
调度、跨进程消费者租约均未作为产品能力实现。

关键写入次序：

1. 验证绑定和事件 digest，持久 received 元数据。
2. 冷恢复若已有 dispatch intent/不确定 provider 结果，仅保留 uncertain，禁止
   新 attempt；该消费者新事件也被挡住，不能借新 prompt 绕开不确定副作用。
3. 对确证未 dispatch 的旧 attempt，在维护边界中公开 remove 每个旧 ID，
   Session flush，再持久新 attempt ID，最后 followup + flush。恢复途中任一点
   退出都可从 journal 和 Session 重新对账。12 个同进程恢复重放共享一次恢复。
4. public pre-step 持久 claim；public stream 在 provider 调用前持久 intent 和
   request digest，成功流结束后持久 presented。不能由 request/user-message
   推断 provider 成功。崩溃后 provider 是否执行无法区分时停在 uncertain。
5. presented + 原生 completed turn + 相应 user/message flush 后才执行客户端
   confirm/ack。两者都幂等；确认或 ACK 已成功但插件记账前崩溃，冷恢复只对账
   和重做幂等提交，不重新调用模型。普通无文本成功流可提交，错误回合不提交。

逻辑 operation_id 与推理 attempt 独立。原生工具例将持久 assistant/message 的
origin session + seq + tool ordinal 作为计划来源；执行前 flush 并持久计划，
随后固定 operation_id。恢复枚举已存在计划，先 get_operation，不让模型重新
生成意图，不按正文去重。相同计划换正文拒绝。发送前 intent 已落盘但查询不存在
时也保留 uncertain，而不是把 404 当作可安全重发的授权。重新登录/未知绑定迁移
尚未实现，保持 fail-closed；不声称该原型已能恢复所有正常后续对话。

故障实测矩阵
------------

新 runner：**29 个 worker、14 次预期 SIGKILL、退出 0**。每次记录原生插入 ID、
模型请求 ID、user/message 投影、journal 状态和消费位置，不用新 ID 隐藏重复。

| 崩溃边界 | 恢复后新模型调用 | 总投影 | 状态/水位（客户端替身） |
| --- | --- | --- | --- |
| received journal 已写 | 1 | 1 | completed / 1 |
| attempt 已写、尚未插入 | 1 | 1 | 旧 attempt retired，新 attempt completed / 1 |
| pending 已持久接纳 | 1 | 1 | 两次插入、仅新 attempt 一次投影 / 1 |
| claimed、尚未 dispatch | 1 | 1 | 两次插入、仅新 attempt 一次投影 / 1 |
| 恢复中旧 pending 已移除、journal 尚未更新，再次崩溃 | 1 | 1 | 可重入恢复、无残留 pending / 1 |
| dispatch intent 已写、provider 调用前 | 0 | 1 | uncertain / 0，保守保留不可区分窗口 |
| provider 已进入 | 0 | 1 | uncertain / 0 |
| presented 已写、尚无成功回合 | 0 | 1 | uncertain / 0 |
| completed turn 已 flush | 0 | 1 | completed / 1 |
| 客户端确认后、插件继续前 | 0 | 1 | completed / 1 |
| 客户端 ACK 后、插件 completed 前 | 0 | 1 | completed / 1 |
| operation intent 后、发送前 | 0 | 1 | uncertain / 0，未发送 |
| 发送成功、插件收到结果记账前 | 0 | 1 | 发送账本一次 commit；恢复只查询，事件仍 uncertain / 0 |

另有 provider error 控制（水位 0）、正常沉默控制（水位 1）、busy 三事件/重复
通知（3 次请求，提交严格 `[1,2,3]`，排队时水位 0）、旧绑定回调拒绝、非法 journal
写入先校验拒绝。没有测试 SIGKILL 正好落在 storage backend 的单次系统调用内，
不宣称覆盖断电/磁盘损坏。公开 storage 类型说明冷读验证、写方承担合法性，
写前校验是本插件责任；前轮 README 概述与实测差异不能误读为库承诺自动验写。

其他公开路径也已实际尝试：

- replace 旧 pending 为新 ID 后 followup：被 pending ID 唯一性拒绝，0 请求。
- 保留旧 pending 再 steer 新 ID：同一个请求含新旧两份输入，不能用作去重恢复。
- 整体 cancel 再 followup：旧输入能清掉，但无关 pending 也被清掉，不能替代
  每 ID retirement。最终采用 remove，而非继续同一失败策略。

真实 Dart/FastAPI 结果与最小反例
------------------------------

`live.py` 启动当前仓库的真实服务端和独立 Dart 客户端，使用三个假账号。
`live-operation.mjs` 通过当前客户端 HTTP API 执行真实发送，在插件记账前
SIGKILL；重启 Dart 客户端和插件、创建新宿主 session，从持久计划取同一个
operation_id，只调用 `/operations/get`，得到 succeeded，**恢复发送调用为 0**。
该实测证明真实客户端支持这条已成功操作的对账路径。真实例的意图是合成的预先
授权计划；原生模型工具→持久 assistant 源→计划的组合另由替身矩阵覆盖。

同时，下面两个负例是实际 HTTP 结果，不是静态推断：

1. A 消费者读取并确认两条消息，ACK 到 2；B 从未读取/确认任何 receipt，却对
   同 peer ACK 到 2 得到 **200 / consumed_through=2**，预期应为 409 gap。
   `chat_service.dart:ackMessages` 先读 `ledger.consumedThrough(account, peer)`，
   lower/equal 直接返回；`chat_ledger.dart` consumption 实际以 account+peer
   保存，consumer_session 没进入 key。稳定字符串替代临时 session 不能修正它。
2. 为旧账号计划准备 send 参数；携带 expected_account/auth_generation 会因
   当前严格字段白名单得到 **422**。随后登录另一个账号，提交原参数得到
   **200，sender_account 为新账号**。插件请求前读身份不能消除“最后一次读身份
   与业务提交之间切换”的窗口。插件自己的 check 不能代替客户端提交处原子校验。

影响：当前 v1 会让未看消息的另一个消费者继承水位；旧回调可能按新身份发送。
只在 bridge 再存一个“正确水位”不修复旧 ACK/wait 的业务事实，也不符合共享消费
要求；在插件重做认证更违反客户端认证所有权。需要修复 **BB 自身**，无需改 DSH。

给 Orion/Muse 的具体契约变更请求（待协调，非已冻结 v2）
---------------------------------------------------

- 客户端消费 key 升级为 `(authenticated_account, stable_consumer_id, peer)`；
  ACK lower/equal 判断、gap 校验、read/wait 和事件订阅全部引用同一 scope。
  旧账号级 cursor 不能无证据复制给全部消费者。只允许有可验证 receipts 的一对一
  legacy alias 迁移，不完整记录保持 migration_required；保留旧 ACK 工具校验。
- 客户端颁发并持久管理不透明 auth_generation / binding_revision；本地桥接获得
  仅身份与绑定状态，不获得 token。操作、查询、wait、receipt、ACK、下载边界接收
  expected identity/binding 并在执行业务前及返回/提交时验证。新协议走明确版本
  协商，旧字段白名单不原地放宽；stale binding 统一错误、不得被 bridge 当网络
  故障重试。账号切换先失效旧绑定与等待，再启用新身份。
- 旧操作继续在原账号按 operation_id 对账；新账号禁止查询/执行它。下载任务也
  保留原账号/consumer/代际/原 session 映射；旧结果不可路由给最新会话。
- 为上述两条最小反例新增正向修复断言，再补 A→B→A、并发切换、多消费者、
  session 重建、wait/被动竞争及下载回调。公共字段由 Orion 协调，客户端修改由
  其 owner 执行；Forge 没有直接修改 Flutter/客户端生产逻辑。

六项门槛状态
------------

| 验收项 | 当前证据 | 仍需完成 |
| --- | --- | --- |
| 1 接纳/领取恢复不双执行 | 公开宿主 + 12 重放 + retirement 再崩溃通过 | 多进程 owner lease / 任意混合 session |
| 2 稳定 operation 跨重启对账 | 原生工具计划控制 + 真实 Dart/FastAPI 对账通过 | 完整 MCP wrapper / 账号代际集成 |
| 3 uncertain、成功展示/回合/提交分开 | 失败、沉默、各边界水位通过（确认替身） | 真实媒体 receipts 与完整消费桥接 |
| 4 wait/事件/busy/连续位置 | busy 与重复重放通过 | wait 匹配仍 NOT RUN，不能宣称整项通过 |
| 5 切换/多消费者/重建/下载 | 真实客户端复现两项 FAIL；插件旧绑定拒绝控制通过 | 修复客户端契约并补重建/下载链路 |
| 6 journal/flush/确认恢复与清理 | 边界重入、写前校验、effect 销毁和旧 lifecycle 重跑通过 | 完整插件禁用在途资源、磁盘失败注入、迁移 |

因此尚不进入生产 bundle 实现或 automated_qa。当前工作继续在同一 PR；交回的是
可复现 BB 客户端缺口与明确跨端请求，不是外部宿主整体不可能结论或 Owner 审批请求。
真实模型/视觉、Flutter 三层、完整 MCP/三端、旧 ACK 迁移、UI 设置与最终集成 CI
未运行；固定依赖之外没有“修复环境”或升级。
