DEA-467 集成基础与提交边界探针
============================

Orion 的 `5da7ef43c88d98e6eedba337181f2a48b29a9b54` 已按原历史快进合入
PR #12 分支，包含 Muse `41e7a72` 和 Forge `a79394e`。没有 reset、force push、
重建基线或第二个 PR。该客户端基础尚无 HTTP v2，不能把它当作完整接线版。
本轮仅新增探针/说明，不修改已整合的 client/ 或共享 v2 schema。

运行：

```bash
node dsh-plugin/probes/journal/settlement.mjs "$DSH_PACKAGE_ROOT" ./evidence
```

实际安装原版 DSH 的 driver、Session 和 storage；确定性模型和明确的客户端
确认/ACK **替身**。不修改任何外部实现。五项断言由 runner 退出码验证，日志
保留原生事件、投影、提交次数、水位与源码哈希；外部八文件执行前后比对。

| 边界 | 原生模型调用 | 消费提交 | 结果 |
| --- | --- | --- | --- |
| confirm 写入前返回失败，随后恢复提交 | 1 | 1 | 两次 confirm、一次 ACK；不重新推理 |
| ACK 已提交但回执失败，随后恢复提交 | 1 | 1 | 两次幂等 confirm/ACK；只提交一次 |
| confirm 期间身份代际改变 | 1 | 0 | 捕获旧确认后拒绝 ACK；journal 不写 completed |
| ACK 已按原身份提交，返回前身份改变 | 1 | 原身份 1、新身份 0 | 保留原事实；journal 不假报新身份完成，旧回放拒绝 |
| 空闲时关闭插件，之后原生 followup | 2 | 1 | 新原生回合不触发已销毁插件的确认/ACK；迟到插件回调拒绝 |

前三种失败提交中的 journal 保留 active/presented 与持久成功回合，代表未完成
本地提交，不把 provider 重新执行作为补救。恢复仍校验原绑定；身份变化不能
通过把旧 generation 恢复成相同值来绕开。客户端替身按捕获身份保存原消费事实，
这是接口前提控制，不是对实际 Dart 实现线性化的证明。

idle disposal 仅证明公开 Cordis 订阅移除及已关闭 bridge 拒绝回调，**不证明**
在途 provider/wait/download 的取消。完整 wait/被动仲裁、多进程 owner fencing、
session 重绑、下载恢复、迁移故障、真实模型与最终集成 Flutter/CI 仍未完成。

HTTP v2 缺路由继续硬失败；`live.py --v2` 不增加 skip、降级或假客户端。
只有 Muse 接线工件整合到最终明确 SHA 后，才运行并评价真实修复断言。
本轮部件探针通过不触发生产实现、automated_qa 或 issue 完成。
