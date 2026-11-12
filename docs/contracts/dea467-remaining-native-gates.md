DEA-467：原生调度与剩余客户端故障探针
====================================

本增量只修改 `dsh-plugin/probes/journal/` 与文档。共享机器契约仍为
`45f003b`；客户端修复来自 Muse/Orion 的 `a087f92`（client tree
`c63486c9945eb5223647b3c455faa56c0458d157`），按正常合并保留历史。
`dea467-real-fault-gate.md` 的 15 PASS / 3 FAIL 是 `49027e3` 的历史记录，
不能当成新修复树仍有这两个缺陷。

复跑命令
--------

```bash
uv run --project server --locked python dsh-plugin/probes/journal/live.py \
  --remaining --runtime "$DSH_PACKAGE_ROOT" --dart /path/to/existing/dart \
  --crypto /path/to/existing/crypto-3.0.7 --output ./evidence

# 在同一合并 SHA 回归原 18 项，断言不变：
uv run --project server --locked python dsh-plugin/probes/journal/live.py \
  --faults --runtime "$DSH_PACKAGE_ROOT" --dart /path/to/existing/dart \
  --crypto /path/to/existing/crypto-3.0.7 --output ./evidence

# bridge 混合回合改动的组件崩溃回归（明确为客户端替身）：
node dsh-plugin/probes/journal/run.mjs "$DSH_PACKAGE_ROOT" ./evidence
```

需要既有 uv 环境、Dart/crypto、Node、Multica CLI。迁移 rename 屏障额外需要
Linux x86_64、GDB Python 和允许调试自己启动子进程的 ptrace 权限。不满足时
入口 **FAIL**，不会静默 SKIP、降级 v1 或把缺工具记 PASS。测试不会安装、
升级、改写外部依赖。八个原版 DSH 文件前后哈希检查沿用原入口。

整合后结果
----------

在正常合入 `a087f92` 的探针树实跑，`--faults` **18 PASS / 0 FAIL，退出 0**；
`--remaining` **6 PASS / 0 FAIL，退出 0**。原三个红项已转正，未修改原断言。
新增 native turn 选择修正的组件回归为 29 workers / 14 SIGKILL，退出 0；
该项的客户端/模型替身性质不变。精确最终 SHA 和每个证据源文件哈希随 issue
附件提供，不能将其它树的 Flutter/CI 结果外推到本探针整合 SHA。

两个 runner 的 NOT_RUN 只描述各自入口，需一起阅读：例如 `--faults` 不运行
本文件六项，`--remaining` 不运行原 18 项；两者合并仍不代表下面列出的完整
产品、真实模型或独立 QA 门槛已完成。

六项新增断言
------------

| 用例 | 实际边界和必须成立的事实 |
| --- | --- |
| native-wait-passive | 原版宿主真实执行注册的 async 工具，工具发实际 v2 wait，同时 passive events/wait 竞争同一位置；一个插件 claim、一个工具唤醒。tool/result 非错误且实际进入下一次 provider 请求，成功 turn/end 与 Session flush 后才真实 confirm/ACK；水位 0→1，无额外 followup、无出站操作 |
| mixed-pending-recovery | 公共 send 保留无关 pending，再持久接纳自有输入；accepted 屏障处 SIGKILL。冷启动 12 个并发 reconcile 仅移除旧自有 ID，原无关输入、新 attempt、后到无关输入各投影一次；3 次模型调用，仅消费一次到 1 |
| native-busy-real-settlement | 第一次真实宿主 provider 请求暂停期间，FastAPI 再接纳两条输入；读取实际 receipts 后，每条重复通知 12 次，只保留两个 pending，忙时水位仍 0。释放后依次真实提交 1/2/3，3 次调用；重放不增调用 |
| multiprocess-owner-cas | 两个独立 Node 插件进程均 ready 后共同释放，以相同 revision 对同一实际客户端 CAS；一 200、一 409。旧绑定 ACK 409 stale_binding，错误 owner 409 stale_binding，水位 0；没有将一进程内 Promise 并发冒充多进程 |
| download-account-switch | 实际媒体上传/下载、fetch 字节后暂停，通过正常登录切换账号；释放后 succeeded、文件字节/hash/预留路径正确，origin_identity 原样保留。新账号无该 task、operation、event，查询 404 |
| migration-before-rename | 合成完整 v1 receipts，经实际 ChatLedger 迁移。GDB 在 **rename syscall entry** 暂停：原文件 v1、备份逐字相等、已 flush 的临时文件 v2；此时终止自己的 Dart inferior。新进程重开恢复 v2/水位 2，备份不变，再重开不改写 |

原生工具只使用确定性模型替身，实际 Cordis/AgentLoop/Session/Tools 与
Dart/FastAPI/文件系统都未替换。wait 和 busy 使用实际客户端消费账本，
没有将 component runner 的测试账本用作客户端修复证明。

迁移屏障仅观察系统调用参数/寄存器及隔离文件，随后 kill 自己启动的 inferior；
不写寄存器、内存、系统调用参数，不注入动态库，不替换 Dart 或 DSH 私有实现。
终止前核对 inferior PID 不等于 Multica daemon PID。此证据是进程终止恢复，
不等同于断电、Windows rename fallback 或所有文件系统的持久性证明。

探针实现修正与证据边界
----------------------

`JournalBridge` 原先将最新自有 turn 当作任何后续请求的 claim，混合会话中的
无关 turn 会误用旧 claim。现在记录当前公开 `agent/pre-step` turn，只对该
turn 的自有 claim 执行 journal/settlement；无关请求透传。只用公共事件和
inbox.remove/runMaintenance，未改宿主调度器。该改动由 mixed 用例和原
29-worker / 14-SIGKILL 组件矩阵回归覆盖。组件矩阵仍明确使用客户端替身。

六项通过不等于完整插件交付：

- wait 仲裁是**一个活动插件实例**的双通知竞争。它证明原生工具路径可行，
  尚未覆盖工具等待中的 claim/lease 崩溃、跨实例恢复接管及每种回调顺序；
  不能把该活跃实例的内存 reservation 宣称为持久分布式排他。
- 多进程 CAS 是多个插件争用**一个客户端 authority**，不是多个客户端进程
  同写 JSON 文件的排他保证；生产运行仍须坚持单客户端 authority。
- 混合 pending 恢复覆盖已接纳、未 dispatch 的输入；provider 不确定后的
  不盲重试证据在既有独立 attempt 矩阵，不能将未知模型结果推断成成功。
- 本轮不运行真实模型/视觉、全 MCP/媒体路径、完整 bundle/上下文会话工具、
  安装禁用卸载生命周期、Flutter、最终 CI 或 Sentinel 独立 QA。

输出 `remaining-gate: PARTIAL`；失败断言退出 1，六项限定通过退出 0。
`results.json`、`sources.json`、`request-trace.json`、`barriers.json` 及原生
会话事件是可审阅证据。`private/` 含合成凭据、owner capability、原始服务日志
与数据库，必须排除交付包；owner capability 从不传给模型或写入公开日志。
