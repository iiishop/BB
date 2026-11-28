# DEA-517 群聊提及契约（修订 0）

请求和返回模型位于 `src/bb_auth_contract/mentions.py`，发送字段定义在
`src/bb_auth_contract/chat.py` 的 `SendMessage`。

## 发送与候选

复用群成员页的数据（账号、昵称、头像）。编辑器在原光标处插入可读文字，独立跟踪选中的账号。
`POST /messages` 在既有群正文请求上接受可选 `mentioned_accounts: string[]`，最多 100 个唯一
BB 账号。发送时账号须仍为本群有效成员，否则整条发送返回 `422 validation_error`。
同一账号多次选中只发送一个账号 ID。服务器没有昵称匹配或文本扫描。自己发出的消息已由发送者看到，
因此自我提及不产生自己的未读。发送重试复用原 nonce 和账号集合。已有消息及省略字段的发送维持原语义。

## Flutter/Dart 到服务端

以下均是既有 Bearer 会话授权下的 JSON POST，返回 HTTP 200。对于需指定群的请求，非有效成员或
已解散的群返回 `404 not_found`。数据以当前账号和本次入群为范围。

| 路径 | 请求 | 返回 |
| --- | --- | --- |
| `/chat/mentions/summary` | `{after_conversation_id?, limit?}` | `{items: [{conversation_id, group_name, unread_count}], next_cursor}` |
| `/chat/mentions/list` | `{conversation_id, before_position?, limit?}` | `{items: [{message_id, position, sender_account, sender_username, created_at, content}], next_cursor}` |
| `/chat/mentions/mark_seen` | `{conversation_id, message_ids}` | `{unread_count}` |

汇总只包含有剩余提及的群，按会话 ID 升序，使用上一页 `next_cursor` 作为
`after_conversation_id`。明细按群消息位置降序，使用上一页 `next_cursor` 作为独占的
`before_position`。两者 `limit` 默认 50，范围 1–100，`next_cursor: null` 表示结束。
翻页读取实时未读集合。普通会话未读游标、读取历史和定位上下文不改变提及集合。
`content` 使用聊天正文的有序图文 part。客户端可用明细的 `message_id` 请求既有
`GET /messages/{message_id}/context` 来定位未加载历史。

客户端仅在当前聊天处于前台且消息实际进入可视区时提交精确 ID，可批量提交 1–100 个 ID。
同一 ID 可安全重试。普通消息、其他群消息、既已清除及先前入群期的 ID 对计数没有影响。
打开群、加载、预取或定位失败均无需提交。常规入群/消息事件、登录恢复及重新进入前台时可刷新汇总，
成功标记后用返回数量立即更新该群。退出或失去账号/群权限时丢弃该身份下的待处理显示状态。

## MCP

`list_unread_mention_groups` 与 `list_unread_mentions` 分别复用汇总与明细的请求和返回。
本地受保护路由为 `/v2/chat/list_unread_mention_groups` 和 `/v2/chat/list_unread_mentions`，
沿用 `expected_identity`、owner capability 和 identity/result 回执。工具参数不接受账号。
查询不生成展示回执，不推进消费进度，也不标记已看。标记已看由前台客户端提交。
