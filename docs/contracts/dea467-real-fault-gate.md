DEA-467 真实消费提交与故障门槛
============================

本轮先在 `bbadb4e` 接入实际客户端，再保留在途工作快进合入 Orion 的
`430ba10f0bbc90a65d981d55121269c24938e881`。最终测试的 client tree 就是
`430ba10:client`，没有修改 client/ 或 `45f003b` 的机器契约。
旧版先写后检查负例仅保留为历史证据，不当作新版本仍存在的缺陷。

复跑（需 Multica CLI 提供 daemon PID 检查；所有子进程前台收集）：

```bash
uv run --project server --locked python dsh-plugin/probes/journal/live.py \
  --faults --runtime "$DSH_PACKAGE_ROOT" --dart /path/to/existing/dart \
  --crypto /path/to/existing/crypto-3.0.7 --output ./evidence
```

使用原版 DSH；八个固定外部实现/声明文件前后哈希校验。`real-settlement.mjs`
采用实际 v2 read/confirm/ACK/consumption，已移除该路径的确认/消费账本替身；
模型仍为确定性替身，只验证成功回合后的提交边界，不宣称真实模型/视觉通过。

`client_fault_host.dart` 通过 BB 的公开构造器注入透明包装：真实 ChatApiClient
请求返回后暂停，真实 ChatLedger 方法调用前暂停，或传入现有 beforeCommit
回调在锁内暂停。其余 public 方法及身份校验原样转发，调用真实文件账本和
LocalAuthServer；不复制业务算法、不替换私有实现、不改产品文件或外部依赖。
测试控制端口只用于 arm/wait/release，日志只记边界名与 HTTP 状态。

最新集成版结果
--------------

runner 退出 **1**：18 项用例中 15 PASS、3 FAIL；三个失败对应下面两个问题，
不是把预期负例当作绿灯。NOT RUN 与总 gate 另行记录，不计入用例数。

| 边界 | 实测 |
| --- | --- |
| 真实 confirm 成功、插件回执丢失 | 一次模型请求、一次 user/message 投影；水位先 0 后 1，恢复只重做提交 |
| 真实 ACK 成功、插件回执丢失 | 一次模型请求/投影；真实水位已为 1，幂等恢复仍为 1 |
| confirm/ACK 入账前重绑 | 均 409 stale_binding；confirm 未写、ACK 水位为 0 |
| confirm/ACK 锁内 beforeCommit 时切换账号 | 均 409 stale_identity；确认/水位不提前提交 |
| 已接纳发送、远端提交后切换 | 成功事实仅归原账号，新账号无该计划；原账号重绑查询 succeeded，但错误仍为 401（FAIL） |
| 实际 wait 与被动事件同时读到位置 3 | 两者均返回 3，通知本身不消费；后到 4 后 ACK 3 仅消费到 3 |
| 下载已取到实际字节后重绑 | 原始 identity 保留，文件内容/hash/预留路径一致，其他消费者查询 404 |
| 下载取到字节后 SIGKILL，再冷启动/重绑 | 原任务恢复 succeeded，同一预留路径、真实内容一致，原来源事件 1 条，其他消费者 404 |
| 完整迁移/残缺 receipts | 完整连续迁移到 2；残缺保持 0、旧 ACK 409 migration_required |
| 备份写入失败→另一进程重开 | 真实文件系统异常，原 v1 文件逐字不变；解除障碍后冷启动迁移成功，备份原文一致 |
| 歧义迁移→旧 ACK→冷启动 | 迁移报告 requires_attention、初始水位 0，旧 ACK 却 200/2；冷启动仍为 2（两阶段 FAIL） |

迁移用例是合成 v1 文件、实际 ChatLedger 与实际 v1 HTTP ACK，独立于真实账号
链路；AuthSession 使用不发送到网络的合成 token。备份故障通过一个目录占用
备份文件路径产生真实 I/O 失败，随后重命名该目录、在另一进程恢复。它不代表
“备份完成到原子 rename 之间”或断电的所有中断位置已测。

需交客户端 owner 修复的两个最小反例
---------------------------------

1. `admitted-send-switch`：v2 send 调用真实 FastAPI，得到远端成功结果后在
   `send-after-remote-commit` 暂停；通过正常 `/auth/login` 切换，释放。客户端
   持久 operation 为 succeeded，业务库 sender 为原账号，原账号显式重绑查询
   仍成功，**HTTP 却为 401 unauthenticated**，契约应 409 stale_identity。
   这是错误分类问题，不是重复发送或跨账号写入证据。不能通过把成功事实改成
   failed 修复；需保留原账号结果，只改过期调用的对外语义。
2. `migration-ambiguous-prepare/recover`：构造 v1 账号级水位 2，两个 legacy
   session 都有各自 1、2 的 confirmed receipts；迁移明确判为歧义并留水位 0。
   对其中一个旧 session 调 `/chat/ack_messages` 到 2，无新展示/显式迁移解决
   却 200 且写入 2。另一进程重开保持该提前推进。`ChatLedger.commitAck` 当前
   仅在 receipt gaps 非空时检查 migration_required，因此绕过歧义标记。
   依据现有协调契约，未解决的歧义记录应报 migration_required、旧 ACK 不得
   绕过；由 Orion/Muse 处理，不自行放宽此保证或改共享 schema。

`bbadb4e` 的写前重绑两个反例，在 `430ba10` 已转为明确 PASS，附历史日志仅
用于前后对照。发送错误分类仍存在；新发现歧义迁移问题。完整备份/回滚产品
交付不能只凭正常迁移用例通过。

范围与未运行
------------

实际 wait/事件的共享消费事实已测，但没有证明原生工具 wait 与被动唤醒仲裁、
忙时连续到达的混合 session pending、跨进程消费者 owner 排他。下载测了同
账号重绑和崩溃恢复，未测下载中账号切换的完整链路。还需迁移其它中断边界、
真实模型/视觉、完整 MCP/媒体、集成版 Flutter、本最终 HEAD CI 与 Sentinel
独立 QA。Orion 报告的先前三层结果不外推至本轮新增探针。

完整门槛未通过，因此尚未接续通用 bundle、工具补全和安装生命周期的产品
实现。继续原 PR、in_progress；不进入 automated_qa、不部署、合 main 或发布。
