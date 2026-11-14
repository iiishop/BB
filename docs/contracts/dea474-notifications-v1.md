DEA-474 通知与自主读取契约，revision 4
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

投递顺序：持久摘要 collecting（prepared 切点）→ 持久 dispatch intent → 最后一次 owner/设置/会话范围校验 →
原生 followup → 原生 session flush → 持久通知游标。最终校验是接纳点；此前关闭/切换 revision
取消未接纳摘要。`index.js` 为 Notifications 提供实时 peerAccount getter；新页、已有整个批次、
最终接纳及冷启动未认领 inbox 统一按当前范围过滤，不能仅过滤新页。已开始的模型回合不可撤销。

revision 3 的 `deliveryProtocol: 2` 增加模型前屏障：同 session 的 `llm/stream` 在任何通知进入 provider 前
先 owner check → session flush → owner check。flush 失败即拒绝模型调用。因此，同一 incarnation
的原生事件/inbox 在公开 idle maintenance 锁内均无该 native ID 时，才能证明没有模型/工具副作用，
把该 intent 恢复成 collecting，再用原 native ID 接纳。活动 driver 的 claim/projection 间隙不作缺席证明。
实际捕获到的 followup 之前异常（最终 GET、owner check 或 maintenance 未开始）直接回退 collecting；
followup 已调用后即使抛错也必须先对账，不能按异常类型猜测未入队。

重启先查同 native ID 的持久 session 事件/原生 inbox：有证据则完成本地游标提交，不重复 followup。
prepared、dispatching、enqueued、visible（模型前 flush 后）、pending、committed 六个进程崩溃切点
均要求恢复后只有一个 native input、pending 清空；不能再把 dispatching 永久停滞记为恢复通过。
已投影输入不重唤模型，模型成功与否不改变摘要仅为通知这一语义，也不确认正文或重试发送。

旧版本无 deliveryProtocol 标记的 dispatching/uncertain，或原 session incarnation 丢失，仍不能以
缺席证明未投递。保留 unknown 记录，继续读取通知设置；用户显式关闭或改变设置 revision 时，
把原批次留存在 `abandoned`（state=abandoned_by_settings），推进摘要扫描位置，但不伪造 delivered，
不删除业务/正文 journal，不重发旧摘要。手动开启沿用来源 head cutoff，后续新来信可以继续通知。
这是旧未知结果的明确跳过/恢复路径，不要求删除日志。查询/显式读取/发送仍受原权限和恢复守卫保护。

无需改变客户端 ledger 版本；新增字段随原子通知 journal 写入。旧 collecting 批次在首次接纳前可升级；
旧 dispatching 不自动升级。活动 protocol-2 记录不得交给没有模型前屏障的旧 bundle 继续运行后再恢复，
否则缺席证明的前提不成立；回退应停用插件并保留原宿主及 journal 做对账。身份/owner/存储错误仍抛出。

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

写入入口与共同规则（revision 4 实现）
-----------------------------------

| 状态 | 所有入口 / 唯一规则 | 定向验证 |
| --- | --- | --- |
| account.notification_settings | v2 set → ChatLedger.setNotificationSettings；MCP set 复用该入口；无设置 UI 副本 | query service：关闭→未同步来信→开启、失败回滚、冷读；v2 routes：owner/身份/严格 bool |
| source/local feed | discover / explicit peer subscribe / background EventFeed 共用逐 peer cursor + source event dedup | 第一阶段 event_consumer_backfill；真实 standalone probe |
| notification window/cursor | Notifications.advance，固定窗口、分页/失败重试队列共同保存；整批 scope 过滤、revision 废弃、disabled 跳过 | QA R1/R2 原断言 + notifications.test.mjs；真实 notifications admission/scope；installed 原生 settings A→B |
| native reminder acceptance | advance 最终设置/owner/scope 校验、followup、flush；resumePending 同 consumer 未认领 inbox 按当前 scope 用原 ID 重唤 | prepared/dispatching/enqueued/visible/pending/committed 六个真实切点；cold pending scope 回归 |
| provider exposure | Bridge 的同 session llm/stream → Notifications.beforeModel，通知曝光前原生证据必须 flush 成功 | flush 失败 provider=0；真实 provider 校验 notification-visible 先发生 |
| uncertain recovery | advance：同 incarnation + protocol2 + idle lock 缺席证明才重试；legacy/丢失 session 仅在显式设置变化时留档跳过 | live driver 间隙拒绝、incarnation 变化拒绝、followup 入队后抛错不重复、legacy off/on 后新消息 |
| exact account read facts | explicit get/read/context/wait → tool/result → llm stream 完整投影 → successful turn → confirmPresentationAttempt；摘要不进入该路径 | wait A/B、installed 有序图片、gap 三进程恢复 |
| consumer ACK | Bridge.settle → 原客户端连续凭证校验；稀疏失败仍保留成功展示事实 | gap 后显式补读，无后台补正文 |
| send/download operations | scoped tool wrapper → Operations durable intent → 客户端 stable ID → 对账 → 原结果 | 原 operation-result/download-result 进程崩溃用例；final 文本不发送 |
| old body reservations | recover：无 dispatch intent 的 claimed/prepared 转 awaiting_read；显式 claim 更新 session/receipt；未知投递不自动重放 | claimed、wait-claimed、pending 迁移切点 |
| binding/reconnect | Client.check + index refresh；已建立连接传输错误保留绑定，同账号再登录更新 generation，owner conflict 停止 | offline 三条聚合+客户端崩溃/重新登录；原 owner/CAS 回归 |

原版宿主实测：真实 wait_messages(A) 未返回时，B 摘要已入 nextTurn，provider 尚未处理；
A 收到来信结束 wait 后才处理 B。没有即时打断保证，最长受所选 wait timeout（30/60/120 秒）约束。
stock resume 恢复 inbox 不主动唤醒；resumePending 在公开 idle maintenance 中用原 ID、按当前
scope 过滤后的内容重新唤起已证明仍未认领的 native inbox。已投影的不重放；未知结果按上文
protocol-2 缺席证明或显式设置跳过路径处理。真实模型/设备未测项不能替代这些恢复断言。

revision 2 补充：摘要生成遇到明确 peer-local not_found/upstream_unavailable/upstream_timeout/network_error 时，
返回 deferred(cursor, peer_account, error_code)。共享身份/owner/CAS/存储错误仍抛出，不按会话吞掉。
bridge 将失败事件游标与当前聚合批次同次原子写入，每次最多重试 100 个，未恢复项轮转到队尾；
其他会话可先投递。成功后只把该事件加回一次摘要，关闭/重开 cutoff 对重试同样有效。
list 和 notification 共用 ChatQueryService.summarizeConversation 的账号未读计算，避免第二份未读事实。
回归先复现“同步后 A 摘要查询 503 阻塞 B”，修后 B 先投递、冷启动保留 A、A 恢复仅补一次，
stale_identity/stale_binding/storage_unavailable 仍拒绝。消息扫描与摘要重试是不同入口，均保留测试。


revision 4：扫描位置、批次与 deferred 的原子一致性
------------------------------------------------

`scan = batch?.scanned ?? cursor` 是下一次 notification_changes 的 after_cursor。
唯一持久入口 Notifications.save 在同次原子写入中只保留 `deferred.cursor <= scan`。
超过该位置的失败事件不算“已扫描历史重试”，由保留的来源事件普通扫描重新发现；不提前推进
cursor、不删除来源事件、不清空真正旧的失败项。readPage 仍最多带 100 个合法旧游标并轮转队列。
客户端的 `retry_cursor <= after_cursor`、身份与 owner 校验完全不变，不捕获或吞掉 422。

| 写入入口 | 扫描与重试的共同规则 | 覆盖 |
| --- | --- | --- |
| 分页扫描/聚合、peer 过滤、空页 deferred 更新 | 保存 batch.scanned 后裁剪，保留 cursor 与 scanned 之间已经扫描的失败事件 | 分页/聚合与冷开既有测试；新增带旧失败队列的聚合 |
| collecting 时发现 revision 变化 | 清 batch 后 scan 回退到 committed cursor；仅保留更早的失败，领先事件重扫 | collecting 热/冷两条永久回归；真实 Dart HTTP+stock DSH |
| 最终 admission 关闭或 revision 改变 | 同一个 save 规则处理 batch=null；禁止独立清批次留下领先 retry | admission 热/冷两条永久回归；真实 Dart HTTP+stock DSH |
| native 证据确认/接纳成功、空摘要/disabled/scope 跳过、显式留档 unknown | 同次提交 cursor 和 batch；失败队列只保留当前已扫描历史 | 原六个进程切点、off/on、scope、unknown 回归；真实通知入口 |
| intent 写入、pre-call 失败回退 collecting、protocol-2 恢复、legacy uncertain 保留 | batch.scanned 不回退，保留其合法失败队列 | R1/R2 及六个切点回归，共用 save |
| open 载入旧坏 journal | 验证原身份/版本后使用相同裁剪规则；若有领先项，先原子修复落盘，再发首个请求 | cursor=0 与 cursor>0/已有旧 deferred × enabled/disabled 四条永久回归及真实客户端 HTTP |

无需 ledger/schema 升级。兼容原通知 journal version 1：已存在的 `cursor=0, batch=null,
deferred=[1]` 恢复后仍 cursor=0，仅将 1 交回普通扫描；cursor=2、deferred=[1,3] 则保留旧 1，
重新扫描 3。有效 batch.scanned 以内的 deferred 即使大于 committed cursor 也不能误删。
修复失败时仍抛出存储错误；未写成功的 journal 可在下一次 open 重做幂等修复，不依赖删除文件。

新增八条正确行为断言在 a7ed910 修前失败，修后原断言通过。notifications.test.mjs 的 double
现在与 Dart 一样在 enabled 判断之前拒绝非法 retry 范围，并模拟 disabled/head cutoff 和真实重试。
同一默认 pytest → Node 入口收集，无新增 CI job。

真实组合验证入口：`BB_PRODUCT_CASES=notifications BB_NOTIFICATION_CASES=deferred uv run --project server
--locked python dsh-plugin/probes/journal/live.py --product --faults --runtime <原版DSH> --dart <Dart>
--crypto <crypto目录> --output <隔离目录>`。该入口运行真实 FastAPI、独立 Dart LocalAuthServer/ChatService、
官方 MCP 和原版 DSH；仅由仓库 probe 的公开 DI 注入 A 元数据 503，模型为确定性替身。
四个 case 覆盖 collecting/admission 设置切换、cursor=0/含旧失败的坏 journal，真实 HTTP 先确认
非法范围 422，再确认正确恢复、关闭期间不补、新 B 先投递、A 恢复一次且旧失败不丢。
默认 `BB_PRODUCT_CASES=notifications ... --product` 保留真实 bin 和原六个进程切点回归。
