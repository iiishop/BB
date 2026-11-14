DEA-474 通知与自主读取契约，revision 2
===================================

基线 `3fd908fa`，沿用执行规格 v1；Forge 单独维护以下跨语言状态。
本文冻结第二阶段接口及恢复顺序，实跑结果随最终候选另附。

本地 v2 新增三个严格、owner/expected_identity 保护的操作：

| 操作 | 输入 | 输出/权限 |
| --- | --- | --- |
| get_notifications | 无额外参数 | enabled、revision、skip_source_through；MCP 可见 |
| set_notifications | enabled: boolean | 相同值幂等，返回同一设置；MCP 可见 |
| notification_changes | after_cursor、可选 through_cursor、retry_cursors≤100、limit≤100 | settings、按会话新增数/当前入站未读/名称/最后预览、next_cursor、through_cursor、has_more、deferred；仅 bridge 内部 |

通知设置放在客户端 ledger 的 account.notification_settings；没有设置的账号默认开启。
订阅集合、来源扫描、消费确认与发送/下载记录不因此改变。设置关闭不禁用查询、wait 或发送。
false→true 在 ledger 提交锁内取服务端已认证账号的 `/events/head`，以该来源 event ID 为手动开启边界，
之后回补的旧来源事件同样跳过；已经 true 的重试不重取边界，因而不会丢失离线消息。
关闭无需联网；手动开启若无法取得服务端边界，原关闭状态保留并返回错误，不伪造成功。
同一锁内复验当前身份和绑定，开关并发次序由持久提交决定；新消息相对于服务端 head 快照决定归属。
设置按账号共享，consumer 重绑/程序重启不重置；没有向对端公开已读。

notification_changes 只从现有 local events 和权威消息/展示凭证求摘要，不建立第二消息库。
每个摘要包含 conversation、peer_account、display_name、new_count、incoming_unread、last_message 预览。
预览沿用 160 Unicode code points 上限，不取媒体、不造 receipt、不确认/ACK；聊天内容不可信。
读取窗口固定在 through_cursor，新来信归下一窗口，扫描不因持续流量无限延后。
更改设置期间取到的旧摘要全部丢弃，调用方从原游标重新按新设置计算。

bridge 通知 journal 与原正文/操作 journal 分开，保存账号+consumer、来源事件窗口、设置 revision、
按会话汇总的预览、固定 native ID、session/incarnation 和收集/投递状态。原正文凭证仍由客户端所有。
首次变化起固定聚合 1 秒（不按每条消息重置计时），一次离线窗口汇总成一个输入。
扫描分片持久化；同一条来源变化不会在崩溃恢复后重复计数。无新变化时绝不因未读仍存在再通知。

投递顺序：持久摘要 prepared → 持久 dispatch intent → 最后一次 owner/设置校验 → 原生 followup →
原生 session flush → 持久通知游标。最终设置校验是投递接纳点；此前关闭/切换 revision 取消未接纳摘要，
此后已经接纳的原生输入归宿主队列，不能撤销已经开始的模型回合。
重启先查同 native ID 的持久 session 事件/原生 inbox：有证据则完成本地游标提交，不重复 followup；
尚未写 dispatch intent 可恢复准备；已有 intent 却无法证明是否投递保持 uncertain，不猜测重放。
这是未知结果时的明确停止边界，不把 uncertain 伪装为已送达。身份/owner/存储错误不可吞掉。

自动 tick/poll 不再 read_messages、claim 正文或附加历史。通知输入本身永远不进入正文确认队列。
模型显式 read_messages/get_message/get_context/wait_messages 的完整结果，在真实模型投影与成功 turn/end
证据齐全后才沿用 confirm_presentation；稀疏 ACK 缺口不扩大已读范围。
read_messages 新增 unread_only=false：true 只展示本页实际入站且未成功展示的项；位置分页仍按原始页推进，
空过滤页不表示没有后续页，应按 has_more/next_position 继续。最近上下文用已有 before_position/get_context。
发送工具和稳定 operation_id 对账保持；最终模型文本不自动发送。

旧正文 journal 及 receipts/operations 不删除。未投影的旧自动全文输入恢复为等待自主读取，
不再用新版本自动重新投递；已有投影/成功回合仍按原证据对账。未知发送/展示继续保留原守卫。
通知 journal 新文件不存在时从事件 0 扫描，已成功展示的消息不生成旧通知。
账号设置是兼容 ledger v3 的新增可选字段；旧程序可能保留该字段但不执行通知规则，回退不得继续旧自动全文桥接。

等待 A 时 B 通知的实时性以原版 DSH 实测为准；BB 不改宿主内核或强制每个会话一个 session。
未绑定的 session 不可通过通知工具取得权限。真实模型凭据、Android/Windows 环境不在本次授权中。

写入入口与共同规则（revision 2 实现）
-----------------------------------

| 状态 | 所有入口 / 唯一规则 | 定向验证 |
| --- | --- | --- |
| account.notification_settings | v2 set → ChatLedger.setNotificationSettings；MCP set 复用该入口；无设置 UI 副本 | query service：关闭→未同步来信→开启、失败回滚、冷读；v2 routes：owner/身份/严格 bool |
| source/local feed | discover / explicit peer subscribe / background EventFeed 共用逐 peer cursor + source event dedup | 第一阶段 event_consumer_backfill；真实 standalone probe |
| notification window/cursor | Notifications.advance，固定窗口、分页/失败重试队列共同保存、revision 废弃、disabled 跳过 | notifications.test.mjs；真实 --product notifications |
| native reminder acceptance | advance 最终设置/owner 校验、followup、flush；resumePending 只重唤同 consumer 的已持久未认领 inbox | prepared/dispatching/pending/committed 四个真实进程切点 |
| exact account read facts | explicit get/read/context/wait → tool/result → llm stream 完整投影 → successful turn → confirmPresentationAttempt；摘要不进入该路径 | wait A/B、installed 有序图片、gap 三进程恢复 |
| consumer ACK | Bridge.settle → 原客户端连续凭证校验；稀疏失败仍保留成功展示事实 | gap 后显式补读，无后台补正文 |
| send/download operations | scoped tool wrapper → Operations durable intent → 客户端 stable ID → 对账 → 原结果 | 原 operation-result/download-result 进程崩溃用例；final 文本不发送 |
| old body reservations | recover：无 dispatch intent 的 claimed/prepared 转 awaiting_read；显式 claim 更新 session/receipt；未知投递不自动重放 | claimed、wait-claimed、pending 迁移切点 |
| binding/reconnect | Client.check + index refresh；已建立连接传输错误保留绑定，同账号再登录更新 generation，owner conflict 停止 | offline 三条聚合+客户端崩溃/重新登录；原 owner/CAS 回归 |

原版宿主实测：真实 wait_messages(A) 未返回时，B 摘要已入 nextTurn，provider 尚未处理；
A 收到来信结束 wait 后才处理 B。没有即时打断保证，最长受所选 wait timeout（30/60/120 秒）约束。
stock resume 恢复 inbox 不主动唤醒；resumePending 在公开 idle maintenance 中用原 ID/内容重新唤起
已证明仍未认领的 native inbox。已投影的不重放；无证据的 dispatch intent 保持 uncertain。
该 uncertain 会阻止本 consumer 后续提醒自动推进，查询/读取/发送仍可用；必须保留原宿主记录对账，
不能通过删除 journal 伪造成功。此边界与真实模型/设备未测项单独报告给 QA。

revision 2 补充：摘要生成遇到明确 peer-local not_found/upstream_unavailable/upstream_timeout/network_error 时，
返回 deferred(cursor, peer_account, error_code)。共享身份/owner/CAS/存储错误仍抛出，不按会话吞掉。
bridge 将失败事件游标与当前聚合批次同次原子写入，每次最多重试 100 个，未恢复项轮转到队尾；
其他会话可先投递。成功后只把该事件加回一次摘要，关闭/重开 cutoff 对重试同样有效。
list 和 notification 共用 ChatQueryService.summarizeConversation 的账号未读计算，避免第二份未读事实。
回归先复现“同步后 A 摘要查询 503 阻塞 B”，修后 B 先投递、冷启动保留 A、A 恢复仅补一次，
stale_identity/stale_binding/storage_unavailable 仍拒绝。消息扫描与摘要重试是不同入口，均保留测试。
