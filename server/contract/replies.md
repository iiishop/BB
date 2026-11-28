# DEA-519 引用回复契约（修订 0）

HTTP 发消息沿用 Bearer 鉴权。现有 `POST /messages` 和 `POST /messages/attachments` 接受可选
`reply_to_message_id`。服务端从已授权的目标会话查找原消息，同一会话外、不存在或不可见的原消息均返回
`404 not_found`。无法发送时整条消息失败。发送重试复用原 nonce、原消息 ID 和正文；同一 nonce
改变原消息或正文返回 `409 conflict`。既有请求和消息可省略引用字段。

发送回执、历史、单条消息、会话末条消息和定位上下文中的用户消息可带
`reply_to: {message_id, sender_account, sender_username, preview}`。发送时记录预览；
系统消息作为原文时两个作者字段均为 null，预览为系统文本。引用只带一层。
点引用用原消息 ID 请求既有 `GET /messages/{message_id}/context`；点提醒用回复消息 ID 定位。
定位上下文包含带引用的消息时，`reply_relations` 为 `inline`。

以下 Bearer JSON POST 均返回 HTTP 200、`{items, next_cursor}`。

| 路径 | 请求 | 明细 |
| --- | --- | --- |
| `/chat/replies/unread` | `{conversation_id, before_position?, limit?}` | `items: [{reply, original}]`。仅当前账号作原作者、其他人作回复者且尚未逐条确认的回复。 |
| `/chat/replies/direct` | `{original_message_id, before_position?, limit?}` | `items: [reply]`。对有权限查看的原文返回全部直接回复，可分页取全。 |

`reply` 带 `id, position, sender_account, sender_username, created_at, kind, content, attachment`，
以及可选 `reply_to`。原文使用完整的现有消息结构。正文保留 part 顺序，附件保留元数据。
私聊要求会话一方，群聊要求当前有效成员；权限不足与目标不存在统一返回 404。
群聊未读提醒仅计入回复出现时仍有成员权限、且仍处于当时入群代次的原作者。同一回复会按自己的 ID
确认，回复同一原文的其他消息保留；自我回复仍出现在直接回复列表。
两项查询按回复的会话内位置降序，`limit` 默认 50、范围 1–100，
下一页将 `next_cursor` 用作排他的 `before_position`，null 表示结束。未读集合会随前台确认变化。
查询和历史定位均不改变提醒、常规未读或消费状态。前台逐消息确认和跨会话汇总由 DEA-517 共享入口处理。

## MCP 与独立 Dart 入口

| 工具 | 本地受保护 POST 路径 | 工具参数 |
| --- | --- | --- |
| `list_unread_replies` | `/v2/chat/list_unread_replies` | 同 HTTP 未读回复 |
| `list_direct_replies` | `/v2/chat/list_direct_replies` | 同 HTTP 直接回复 |
| `send_reply` | `/v2/chat/send_reply` | `{conversation, reply_to_message_id, operation_id, content}` |

Dart 在 `ChatV2Router` 的受保护分派中完成绑定校验，沿用 owner capability 和
`expected_identity` 请求、`{identity,result}` 回执。查询转发至表中的 Bearer HTTP 路径，
不生成展示回执或确认。发送沿用本地 v2 的有序文本和图片来源，返回正常聊天消息。
Dart 通过既有发送入口绑定身份、纳入原消息 ID 到本地操作意图并提交到服务端；未知结果用同一
`operation_id` 查询既有操作，避免重复发送。参数不接受发件账号。
服务端和工具参数模型位于 `src/bb_auth_contract/replies.py`。
