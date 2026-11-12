DEA-467 状态、查询与兼容提案（待 Orion 协调）
==========================================

这是第一阶段设计提案，不是生效的 wire contract，也不改变当前实现。
最新授权已允许持续公开插件探索，无需再等 Owner 选择路线；外部 DSH/依赖固定，
旧补丁路线撤销。恢复实测进展及当前客户端缺口见 `dea467-journal-recovery.md`。
六项完整门槛尚未通过；Orion 协调 Muse 的客户端字段后，才生成生效 v2 schema/fixture、
迁移与集成测试。沿用当前 Account（八位数字字符串）、Message、position、
operation_id、客户端认证所有权；不新增密码/token 存储或插件直连服务端路径。
register_account/login_account 始终是 MCP 工具。

三类进度与身份
--------------

| 事实 | 权威位置及 key | 推进条件 |
| --- | --- | --- |
| 平台消息/事件 | 服务端既有 SQLite；pair-local message.position、稳定 message.id | 业务事务持久化，不因 DSH 失败回滚已确认消息 |
| 客户端收到进度 | 客户端既有 ledger/source cursor，按当前认证账号隔离 | 可供本地授权查询的消息和事件已持久化；不表示 agent 消费 |
| bridge 接收进度 | 客户端 subscription / bridge durable journal；account + consumer_id | 对应本地事件及身份绑定已持久化且可恢复，对账完成后才推进事件 cursor |
| agent 消费进度 | 客户端既有消费 ledger 扩展；account + consumer_id + peer_account | 连续区间具备受验证的展示 receipts 和明确成功消费提交；不能跳过缺口 |
| 对外已读 | 本轮不存在 | 不实现 mark_read，不把 ACK/消费数显示为产品已读 |

`consumer_id` 提案为客户端为授权 bridge 实例生成并持久化的 opaque ID，绑定当前
账号；不是模型任意提供即可取得权限的授权凭证。插件从本地客户端得到当前绑定
和 `auth_generation`（登录、退出、账号切换或重新认证时变更的 opaque epoch）。
`session_id` 仅是当前宿主执行实例映射；多个 session 不自动共享消费者，多消费者
也不共享单一账号水位。一个稳定消费者同时最多一位活跃宿主 owner；需要 lease/
generation 校验及迁移规则，不能假设单进程锁就是跨进程保证。

每个等待、工具调用、展示确认和下载操作捕获 `(account, auth_generation,
consumer_id, binding_revision)`；客户端在开始及提交/返回边界再次验证。切换时
先递增代际并使旧绑定失效、取消等待与订阅，再激活新身份；旧网络结果即便已返回
也不投递到新上下文。旧账号成功操作继续记在旧账号 ledger，登录新账号不能查到
其结果。重登旧账号通过原 operation_id 对账，不把超时当失败重发。

session 重建只在显式稳定绑定恢复成功后延续消费；账号/peer 变化、owner 冲突或
找不到旧映射时要求重绑且保留旧记录。重建补上下文必须标为历史参考，不让已经
消费的历史再次触发副作用；新/恢复会话声明可查范围、截断和缺失。

接纳到消费的状态机
------------------

提案的业务 key 为 `(platform='bb', account, consumer_id, event_id)`；journal
保存 payload digest、peer、message ID/position、身份代际和每次 `attempt_id`，
不存密码/token，也不替代服务端聊天历史。状态区分：

`received → accepted → claimed → model_presented → turn_succeeded → committed`。

每条边必须有可恢复证据；失败/取消进入可诊断状态，provider 已执行但确认丢失
进入 `uncertain`。`turn/end` 的 error/interrupted/cancel 不能提交；正常沉默可以
提交，前提是所需输入已经验证展示且该成功回合结束。最终文本不是必要条件。
只有已连续提交的明确 position 才能推进消费；更晚消息必须留下。图片缺失只报告
缺失，不能生成「模型看过完整图文」证据或绕过现有 consumption_gap 校验。

`wait_messages`、read 和被动事件必须引用同一 presentation/消费事实：read/get
查询本身不 ACK，返回内容也不等于宿主已展示。主动 wait 正在匹配 peer 时，事件
必须交给该等待的当前执行上下文，不能额外 followup 造成双处理。忙时由原生 driver
排队，插件不另造 scheduler；本次只证明普通 FIFO，匹配 wait 与崩溃竞争尚未验证。
下载事件绑定原发起 consumer/session/身份代际，不按最新聊天对象猜测目标。

原始输入保留 `platform/account/consumer_id/conversation/peer/sender/created_at/
message_id/position/event_id` 和 `text,image,text,image` 顺序，不注入人格或回复
要求。预算裁剪返回 omitted IDs/ranges/reasons；图片保留稳定 media_id 并区分
`unavailable`、`unsupported`、`budget`，允许精确查询；不生成摘要替代原始事实。

出站所有权固定为显式发送工具；普通 DSH 最终文本不自动发送。客户端在执行前
持久化 operation_id 和 payload digest，bridge 将稳定逻辑操作映射到这个 ID；
相同 ID+不同内容拒绝。超时/回执丢失先 get_operation，pending/unknown 不能当
failed。真实失败是否可重试由错误类别决定。跨 provider 不承诺全局 exactly-once。

公开存储可保存插件 journal，该版本类型声明将验证放在冷读边界，写入调用者
负责保证值合法；因此本插件需在每次写前
显式验证，cold-open 错误保持 fail-closed。单条持久写不能与 Session flush 或
客户端消费提交自动形成一个事务，必须有准备/对账/幂等协议。这个跨边界证明仍
是宿主门槛的一部分，不能以「已经有 KV」宣称恢复解决。

旧 ACK / 旧 session 迁移
-----------------------

提议协议能力协商为 v2；现有 v1 payload/路由继续使用。v1 的 `consumer_session`
不在原地改语义，v2 单独包含 consumer_id、身份代际和 binding_revision。
兼容期保留模型工具 `ack_messages`，新 bridge 正常路径通过内部自动消费接口，
两者都调用同一客户端校验/提交逻辑。不能直接删旧工具或放宽展示证明。

1. 客户端先备份并事务性创建旧映射表：`(account, consumer_session) → consumer_id`。
   每个旧消费者独立映射，绝不按账号合并或取多个 session 水位的最大值。
2. 同一迁移事务保留 peer 消费水位、展示 receipts/digests、事件 cursor、订阅、
   下载与 operation_id 归属。验证缺口和 digest 后迁移；不完整旧记录进入
   `migration_required/uncertain` 并保留原数据，不能猜测完成。
3. 宿主旧 `plugin:bb/delivery-v1` 记录只读导出到自有版本化 journal，记录来源
   session、seq、版本及 digest；不向原版 Session 添加新的实验 plugin record。
   导入幂等，未知版本拒绝；旧绑定没有认证代际时必须重绑，不能仅由 ID 自动授权。
4. v1 ACK 经确定的一对一 alias 解析后仍验证当前认证账号、peer、展示缺口；无法
   唯一解析时返回兼容错误并请求重绑，不把旧 ACK 写到新身份。重复 lower/equal
   ACK 继续幂等，读到更晚消息不清理它们。
5. 回滚期保留 alias 和原始备份；旧客户端不理解 v2 时禁止混写，回退需完成显式
   导出校验。ACK 退役必须另行宣布最低兼容版本、活跃旧 session 为零的证据及
   恢复/回滚测试通过；本阶段没有退役日期，也不删除工具。

新增查询提案
------------

全部经客户端本地业务层，再复用服务端同一授权消息查询层。认证账号只来自
服务端 session；请求里的 peer/consumer 不能替代对象权限。不存在与无权访问
统一 `{error:{code:'not_found',message,...}}` / 404；无认证 401，参数错误 422，
沿用既有安全错误 envelope，不泄露第三方正文、计数或游标信息。

| MCP / 本地 POST 候选 | 服务端候选 | 参数与结果语义 |
| --- | --- | --- |
| `list_conversations` / `/chat/list_conversations` | GET `/conversations` | `cursor?,limit=50(1..100),consumer_id?`；只返回当前账号已有会话，不是用户目录；peer_account、展示名、last_message、updated_at、next_cursor。显式 `pending_consumption:{count,through_position,consumer_id}`，不用含糊 unread/已读字段；无消费者时返回 null 并说明不可推断账号已读。 |
| `get_message` / `/chat/get_message` | GET `/messages/{message_id}` | 稳定 message_id；返回既有 Message + 有序媒体投影 + range/missing；检查当前账号是否为参与者，第三方 ID 与未知 ID 均 404。 |
| `read_messages` / 现有 `/chat/read_messages` | 现有 GET `/conversations/{account}/messages` | v2 `account,consumer_id,after_position? 或 before_position?,limit`；两边界互斥，所有返回仍按 position 升序。after 取最早的后续项；before 取最近的前序项后升序返回；v1 after 默认 0 原样保留。 |
| `get_context` / `/chat/get_context` | GET `/messages/{message_id}/context` | 中心 ID + `before_limit,after_limit`（各有上限，总预算明确）；中心与两侧来自同一查询事务/快照，结果含 range、双向 cursors、has_more_before/after、truncated、missing；现无回复关系时 `reply_links:[],reply_links_supported:false`，不新增回复 UI 或捏造引用。 |

会话列表建议采用 opaque keyset cursor，携带固定 snapshot_position/last message
anchor 与 `(last_activity,peer_account)` 排序键，绑定当前账号、查询参数和协议版本；
不能把可解码 cursor 当授权。分页期间有新消息时明确保持既定快照，刷新重新取得
快照；快照数据若不可重建则必须声明 stale_cursor 并重新开始，不能假装稳定分页。
消息页使用 pair-local position，区分从旧到新和从新向旧的检索边界；返回顺序始终
从旧到新，避免图文/历史顺序翻转。limit+1 判断剩余，不暗中生成历史摘要。

契约验证清单（尚未实现/运行）
----------------------------

- 相同 Message 经 get/read/context 保持 ID、正文、有序媒体、身份与时间一致；
  空会话、边界、双向分页、中心缺失、截断与并发新消息具备共享 fixture。
- A/B/C 三账号越权、同名账号目录、游标换账号/篡改、过期代际；任何查询不 ACK。
- 两消费者不同水位；session 重建映射；旧 ACK migration 中断再跑；未知版本及
  不完整展示记录拒绝；回滚不产生双写。
- 接纳前后、claim 后、模型失败/正常沉默、响应后确认中断、发送成功回执丢失；
  get_operation 解决不确定发送，不重复已确认副作用。
- read 后新到达、wait/被动竞争、busy FIFO、turn/end 与更晚 position 竞争、
  断线补取、账号切换和在途下载全部在最终同一集成 SHA 验证。

Schema/Migrations：本提交仅方案，无可执行迁移。API/Event Contract：全部标为
候选，等待协调；已有 v1 仍有效。Security：不读取真实聊天或凭据，不扩展权限。
Remaining risks：宿主原语路线、真实 UI、自动消费完成证明和跨持久层对账未通过。
