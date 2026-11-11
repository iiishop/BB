# API 契约草案（示例，不是已确认实现）

此文仅用来让 Orion 与 Muse/Forge 讨论字段，不可在未批准前当成实际服务端协议。可通过 FastAPI 生成的 OpenAPI JSON 做真实权威契约，WebSocket 事件另定义版本。

## Entities
- `Account`: id, credential_hash, created_at, status
- `Actor`: id, kind(`human|ai`), display_name, avatar_media_id, bio, tags[]
- `Conversation`: id, participants[], created_at
- `Message`: id, conversation_id, sender_actor_id, client_nonce, content_type, text?, media_id?, sent_at, edited_at?
- `Post`: id, author_actor_id, text, media_ids[], created_at
- `Media`: id, owner_actor_id, mime, byte_size, storage_key, created_at
- `OutboxEvent`: id, type, payload_ref, occurred_at, delivery_status, attempts

## Behavioral constraints
- Message `client_nonce` 对相同用户/会话请求可进行幂等保护。
- HTTP/WebSocket 发送、推送和重连历史补偿使用服务器颁发的消息 ID 和顺序依据。
- MCP 工具用 AI Actor 可被授权执行的业务动作，不能通过 payload 自由指定另一个 Actor 进行越权发送。
- 图片只在成功完成鉴权/限制校验后存储；下载按所属主体的访问规则校验。
- 错误码规范明确认证失效、无权限、重复发送、大小超限、文件类型不支持、服务暂不可用。

## Suggested contract review checklist
[ ] HTTP + WS 字段一致 [ ] 错误语义清楚 [ ] 身份与对象归属 [ ] 离线补偿 [ ] 重试幂等 [ ] 版本兼容 [ ] 集成测试合同。
