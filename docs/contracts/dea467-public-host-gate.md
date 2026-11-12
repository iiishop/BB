DEA-467 第一阶段：原版宿主能力与缺口
===================================

结论：**生产 bridge 的无补丁恢复门槛仍为 BLOCKED**。本次已实际验证
公开 bundle 安装、宿主加载、设置服务、禁用/卸载、持久存储、正常忙时排队及
故障恢复。失败结论限定于已测试的公开组合；不能推论所有公开插件方案均不可能。
这里没有生产实现、数据库迁移、Flutter 修改或共享 wire schema 冻结。

基线为 `2f5a0bb57fb7845c8b26eea6c3978f5a1845b403`。本次目标为 Linux x86_64、
Node v26.8.2、DSH 0.2.1-rc.5、Cordis 4.0.5；实际 AgentLoop `lib/index.js`
SHA-256 为 `cf57e3ecd487ac5c2553455aaa5cef2c6fb41e6bd61be5aa455675d1d7193033`。
它匹配历史 lock 的 **original** 字段，运行时六个 `bb*` 方法确实不存在；
不以版本相同代替补丁状态检查。不宣称核验了整个 npm 发布包供应链。
所有参与包的版本、关键实现/类型/文档哈希、探针文件哈希见本次附件 `sources.json`。

已读取安装包内 `dsh-agent-preset/skills/cordis-plugin-development/SKILL.md` 及
`references/{host-plugin,practices,verification}.md`。特别是 practices 明确：
`appendPluginRecord()` 保留给 DSH 实验包，格式迁移仅尽力保留；普通插件应从
既有事件派生状态或使用公开 storage service。因此不能把现有 recovery.mjs
直接搬入 bundle 后宣布消除了补丁依赖。

运行入口和证据
--------------

```bash
node dsh-plugin/probes/public-host/run.mjs "$DSH_PACKAGE_ROOT" ./probe-evidence
```

父进程前台收集每个 worker；只杀本轮创建且与 Multica daemon PID 不同的
确切子进程。宿主使用独立 profile/home/session/store，未加载 SurfCore、个人
配置或模型凭据。安装通过真实 `PluginManager.installBundle()`，profile 文件由
宿主服务写入。模型为明确的确定性替身；AgentLoop、Tools、Session、Loader、
Settings、PluginManager、StorageDomain 和 JSONL 均为原版实际实现。

退出 0 表示正向与负向断言均复现，**不是整个 issue PASS**。`commands.json`
保存脚本、退出码、输出；`boundaries.json` 保存模型输入和事件；`native-gate-*`
保存 9 个 worker、4 个 SIGKILL 和原始 crash-prefix。最终证据是完整 runner 的
最新成功输出，早期脚手架调试不作为验收结果。

2026-11-12 最终实跑：runner 退出 **0**，5 个直接子命令全部退出 0；其中 native
runner 收集 9 个孙 worker（4 个预期 SIGKILL、5 个退出 0）。证据目录标识
`dea467-public-KV71pz`。5 个新 JS 模块 `node --check` 均退出 0。恢复门槛保持
BLOCKED，已有测试结果没有被算作本轮 PASS；后端/MCP 全量 pytest 未运行，因
本轮只新增隔离诊断脚本与提案、未修改生产代码。

公开 API / 能力矩阵
------------------

下表路径均相对于安装版 `node_modules/@deepseek-ai/`。`sources.json.signatures`
给出本次读取的精确声明和行号，版本哈希固定其含义。

| 能力与公开签名 | 来源 | 本次证据、替换能力与限制 |
| --- | --- | --- |
| `installBundle(spec: string, options?: InstallBundleOptions): Promise<ChangeResult>`；`setPluginEnabled(id: PluginEntryId, enabled: boolean)`；`removeBundle(name: string)` | `dsh-plugin-manager/lib/types/index.d.ts` | 本地 bundle 安装后重启真实加载；禁用后零工具、重启恢复后仅一工具、卸载后零工具。无 HMR 诚实返回 restart-required，运行中移除返回 stop-profile；先 deselect、重启再 remove 成功。可替代 native-setup 的安装容器部分，尚非完整 BB bundle。 |
| `describe(options?: SettingsDescribeOptions): SettingsDescriptor[]`；`update(ns: string, patch: object, expectedRevision?: number): Promise<void>` | `dsh-settings/lib/types/index.d.ts` | volatile 字段 `.get()` 读值，更新不重挂，旧 revision 拒绝，profile 重启回读一致。设置网页没有运行；自动表单描述不等于当前客户端会渲染表单，正式产品仍需真实 UI 入口。 |
| `ctx.effect` / `ctx.on`；`tools.register(definition: ToolDefinition): () => void` | `cordis`、`dsh-tools/lib/types/index.d.ts` | 每次挂载对应销毁，工具随 fixture 清理。没有真实 BB 连接/子进程，不能据此宣称其清理通过。 |
| `storageDomain.open(spec)`；table `put(key, value): Promise<void>` / `get(key)` / domain `close()` | `dsh-storage-domain/lib/types/{index,domain,spec}.d.ts` | 有效绑定写入后跨进程恢复。额外负例发现 `put()` 接受不合法 generation，冷启动 open 才报 invalid-record；实现只在 open 校验。插件必须在每次写前显式校验，不能只依赖 README 的概述。无跨 Session/客户端原子事务证据。 |
| `send(message: UserMessage, target: InboxTarget, wakeup: boolean): void`；`followup(message: UserMessage): void`；`steer(message: UserMessage): void`；`inject(message: UserMessage): void` | `dsh-agent/lib/types/runtime-types.d.ts` | 空闲启动和忙时三个 FIFO 回合通过。pending ID 重复被拒绝；完成后同 ID 原生 followup 再次产生插入及模型调用，因此不是终身幂等。inject 不唤醒；没有已接纳 ID 的公开无插入唤醒方法。 |
| `sessions.flush(session: Session): Promise<boolean>`；`session.snapshotEvents()`；`sessionPersistence.open(id, 'read').read()` | `dsh-session/lib/types/index.d.ts`、`dsh-session-persistence/lib/types/handle.d.ts` | 已接纳事实 flush 后可冷读、可对账；flush 不代表模型已看见，不代表消费提交。 |
| `agents.resume(options: ResumeAgentOptions): Promise<AgentHandle>`；`runMaintenance<T>(job: (signal: AbortSignal) => Promise<T>): Promise<T>` | `dsh-agent/lib/types/{index,runtime-types}.d.ts` | 四个 SIGKILL 边界真实恢复，详见下表；maintenance 挂起真实 wake，避免测试仅验证故意不唤醒的 send。 |
| `agent/request` waterfall；`session/event` 的 `turn/end`；`whenIdle(): Promise<void>` | `dsh-agent`、`dsh-agent-loop`、`dsh-session` 类型/实现 | 捕获正常请求/回合及 provider error。失败也有 turn/end，whenIdle 是整体静止，均不能单独推进消费。未验证公开 hook 能替代 patched modelResult 的全部提交语义。 |

崩溃恢复：本次重跑结果
----------------------

| 崩溃位置 | 冷恢复 + 同业务事件 12 次并发重放 | 新模型请求 | 消费水位 |
| --- | --- | --- | --- |
| 接纳前 | 从 absent 接纳并执行，1 次插入 | 1 | null |
| 接纳已 flush、回执返回前 | accepted_pending，1 次插入；再次 followup 同 ID 被 pending 唯一性拒绝 | 0 | null |
| 回执已 fsync、回合开始前 | accepted_pending，1 次插入，未自动重新驱动 | 0 | null |
| inbox 已领取、模型准备前 | accepted_unpresented，既非 pending，也没有 user/message；resume 仅补 interrupted 边界 | 0 | null |

正常控制证明真实 driver 可完成回合；两个已完成的同 ID 原生提交会产生两个
模型请求。因此负例不是模型替身未启动。AdmissionProbe 在不重新插入已接纳输入的
策略下保留状态，绝不把缺口当已消费；这只是被测策略，**当前 DEA-467 并没有
禁止所有可证明安全的重插入恢复方案**，不能借用旧报告的更严格限制直接否决它们。

补丁替换清单
------------

| 当前实现 | 公开接口候选 | 状态 |
| --- | --- | --- |
| `native-setup.mjs` 的 MCP 配置/启动 | bundle manifest、PluginManager、Agent scoped MCP plugin + effect | 容器/生命周期可行；真实 MCP 子进程和所有业务工具需后续回归 |
| `bbConfigure`、`bbEventCursor`、`bbAdvanceCursor` | storageDomain 存稳定绑定与接收进度；客户端仍保有认证 | 存储原语实测可用；需校验、版本迁移与顺序提交，不能用 session ID 代替消费者 |
| `bbDeliver` / `bbDeliveryStatus` | 稳定业务 key + 客户端/插件 durable journal + 既有 inbox/session 事实对账 | 单进程接纳与重放有证据；跨事实提交和 claim 恢复未闭合 |
| `bbRecoverDeliveries` / 私有 `wakeDriver()` | 原版 resume/followup 或上游公开 recover/wake 原语 | 本次恢复负例阻塞直接替换；不得调用 private 方法伪装公开接口 |
| `claimed` / `shouldAppend` / `prepareContinuation` | inbox 事件、sessionProjections、agent/pre-step | 事件可观察不等于有受支持的事务/投影改写点；wait 匹配、重建、无重复模型投递未证实 |
| `beforeModel` / `modelResult` / `confirmPending` | request/stream 公开边界 + durability + 原客户端 presentation receipts | request intent、provider error、turn/end 不够；模型接收/回合成功/消费确认需分别证明 |
| `beforeTool` / `afterTool` / `recoverPlans` / `guardResult` | tools guard/execute/result；客户端 operation_id/get_operation | 候选可复用业务接口；公开 hooks 的稳定操作 ID、账号代际与不确定结果恢复未实测 |
| `appendPluginRecord(plugin:bb/delivery-v1)` | storageDomain 插件自有版本化 journal，引用原生事实 | 文档限制使直接复用不合适；先备份、只读旧记录、显式导入；不写新实验 Session 记录 |

交回候选方案与下一阶段门槛
--------------------------

1. 优先评估上游受支持的「按已接纳 ID 恢复/唤醒」和持久 claim→模型提交原语。
   必须明确生命周期、重复调用、旧 session 兼容与失败状态；需以上四个崩溃点
   全通过后再替换补丁。此处只是候选 API，未修改或向上游提交。
2. 公开插件的另一个候选是自有 durable journal、稳定业务 ID + 独立 attempt ID，
   在证明原输入未呈现或结果不确定后恢复提交，并用客户端 operation_id 对账副作用。
   该方案不自动等于降低保证，但必须证明 session 中重插入、busy/wait 竞争、
   provider 响应后崩溃和确认丢失都不会误消费或重复已确认发送；本次尚未验证。
   无法证明时保留 uncertain，不能盲重试或推进水位。
3. 保留现有已批准的补丁路线作为兼容基线，仅可另行批准的隔离环境验证。
   它不能满足「原版独立插件」门槛；本轮未运行 patched-host 对照，更未修改全局。

由 Orion 协调宿主路线和 `dea467-state-proposal.md` 后再决定继续范围。
本阶段不触发 Muse/Sentinel 实现或 automated_qa，不改变 issue 状态。

NOT RUN：真实模型/视觉、匹配 wait 与被动投递竞争、普通沉默回合的自动 ACK、
旧 ACK 迁移、跨消费者/账号切换真实链路、下载回原会话、三端联调、Flutter
三层、浏览器设置页、HMR、Android/Windows、断电/多进程 writer 竞争、最终集成 CI。
所有注册/登录/Profile/目录/消息/附件/下载工具及其现有契约保持不变。
