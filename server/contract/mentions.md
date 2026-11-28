# DEA-517 修订 1 · 群聊提及与 DEA-519 共用未读提醒

`src/bb_auth_contract/chat_alerts.py` 定义共用汇总、跳转及精确可视确认，
`src/bb_auth_contract/mentions.py` 定义群 @ 明细与发送工具请求。
本修订替代此前仅群 @ 的汇总及确认路径。

## 发送与候选

复用群成员页的账号、昵称、头像。编辑器在原光标处插入可读文字，独立跟踪选中的账号。
`POST /messages` 在群正文请求上接受可选 `mentioned_accounts: string[]`，最多 100 个唯一
BB 账号。目标账号须仍为本群有效成员，否则整条发送返回 `422 validation_error`。
服务器按账号绑定。自己发出的消息已经由发送者看到，自己的提及或回复不产生提醒。
发送重试复用原 nonce 和账号集合，已有消息及省略字段的发送维持原语义。

## Flutter/Dart 到服务端

以下均使用现有 Bearer 会话授权、JSON POST 和 HTTP 200 成功响应。对于指定会话请求，
无会话查看权限、群已解散或已退出群返回 `404 not_found`。

| 路径 | 请求 | 返回 |
| --- | --- | --- |
| `/chat/alerts/summary` | `{after_conversation_id?, limit?}` | `{items: [{conversation_id, display_name, unread_mention_count, unread_reply_count, latest_alert}], next_cursor}` |
| `/chat/alerts/list` | `{conversation_id, before_position?, limit?}` | `{items: [alert], next_cursor}` |
| `/chat/alerts/mark_seen` | `{conversation_id, message_ids}` | `{unread_mention_count, unread_reply_count}` |
| `/chat/mentions/list` | `{conversation_id, before_position?, limit?}` | `{items: [{message_id, position, sender_account, sender_username, created_at, content}], next_cursor}` |

`alert` 为 `{message_id, position, mention, reply}`。同一条同时是回复和 @ 时，
两类计数各增一，跳转列表仍只有一条。此时一个按钮可使用回复文案。汇总昵称为群名或
私聊对方昵称。汇总只包含有未读提醒的会话，每会话一行，按会话 ID 升序，使用上一页
`next_cursor` 作为 `after_conversation_id`。明细按位置降序，使用 `next_cursor` 作为
独占的 `before_position`，`limit` 默认 50，范围 1–100，`null` 表示结束。
翻页读取实时集合。用户可通过既有 `GET /messages/{message_id}/context` 定位
未加载历史。群 @ 明细正文使用聊天有序图文 part。

客户端仅在聊天处于前台且消息实际进入可视区时提交精确 ID，可批量提交 1–100 个 ID。
同一 ID 可安全重试，清掉该条的两种提醒，其他消息继续保留。普通会话游标、打开群、
加载、预取、查询、定位失败均不影响提醒。常规群或消息事件、登录和回到前台时可刷新汇总。
退出及账号切换时丢弃对应显示状态。

## MCP

- 首项工具沿用 `list_unread_mention_groups`，范围扩展到群聊和私聊。请求沿用汇总分页，
  结果每会话仅有 ID、名称、两种未读数量，无正文或跳转元数据。
- `list_unread_mentions` 继续接受群会话 ID，返回该账号被明确提及的消息及分页。
- `send_group_mention` 接受 `conversation`（群引用）、有序 `content` 与非空
  `mentioned_accounts`。沿用发送的 `operation_id` 和 `get_operation` 恢复机制。

本地路由为 `/v2/chat/<工具名>`，沿用 `expected_identity`、owner capability 及
identity/result 回执。两个查询工具没有读状态副作用。可视确认是 Flutter 客户端入口。

## DEA-519 服务端接入

新回复的发送事务在消息入库后、提交前调用
`bb_server.chat_alerts.record_reply(db, conversation_id, position, sender, original_author)`。
发送重放直接返回已有消息。提交失败会同时回滚提醒，已退出群的原作者不会获得提醒。共享表 `chat_unread_alerts` 以 `(account, conversation_id, position)`
作主键，`mention` 与 `reply` 分别表示两个未读类型。回复明细可按当前账号、
已授权会话和 `reply=1` 查该表，再按会话与位置关联回复消息。引用关联与全部直接回复列表
由 DEA-519 持久化和查询。


## Dart 接线

`SharedConversationService` 提供 `listAlertSummary`、`listConversationAlerts`、
`markConversationAlertsSeen` 和 `listGroupMentions`。调用方可传入捕获的 `AuthIdentity` 来约束
批量可视确认只在原账号下提交。群聊发送使用 `ChatService.sendBody` 或
`ChatService.sendComposed`，`targetAccount` 使用群会话 ID，`mentionedAccounts` 传所选账号。
失败重试时保留原 operation ID 和同一账号集合。
