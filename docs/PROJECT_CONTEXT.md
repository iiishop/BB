# Social Platform — Project Context

## Product
Flutter 独立的私人社交平台；体验参考常见即时聊天应用。用户是注册登录的真人账户，不是唯一写死的 Owner。社交 Actor 可以是真人也可以是 AI。第一个产品验收目标是：真人在 Android 客户端发送一条消息，后端持久化，DSH Bot 触发，通过 MCP 发回复，客户端即时展示，重新打开后消息仍存在。

## MVP 范围
- Profile：注册/登录（首版可邀请码）、头像、昵称、简介、标签、人类/AI Actor 页。
- Chat：文字、历史、WebSocket 推送、基本图片上传/预览、链接识别；可按 Issue 切阶段。
- Space：发布文字动态、浏览时间线、AI 主动发布日记或心情。
- 初期不要求：群聊、复杂好友关系、VoIP、视频转码、完整消息撤回、推送通知、通用多 Agent 自主平台。

## Technical architecture
- Flutter APP → HTTPS/WebSocket → Cloudflare Tunnel → FastAPI Backend。
- FastAPI + SQLite：认证、业务规则、媒体文件元数据、消息/帖子数据库和事件 Outbox。
- MCP：由授权工具调用平台业务服务；MCP 不维护自己的平行数据库。
- DSH Bot Runtime：处理消息/定时事件，调用模型、通过 MCP 行动。与 Multica 中用于开发 Muse 的 DSH Runtime 完全隔离。
- 平台数据库记录业务事实；DSH 会话/思维链不属于公开的 Chat 历史。

## Repo suggestion (not mandatory)
`apps/mobile/`, `services/api/`, `services/bot/`, `packages/contracts/`, `docs/design/`, `tests/e2e/`。

## Team
Orion (Codex) 调度；Muse (DSH DeepSeek Flash) **前端设计与实现全权负责**；Forge (Codex) 后端；Sentinel (Codex) QA；Owner 最终审批。

## Known test environment
无 Android 模拟器、无连接真机。Linux Flutter test、golden 与 Linux 桌面截图曾由其他 Agent 成功执行。Sentinel 必须重新验证现有机器；2026-11-11 用户补充实测记录：示例项目 Linux `integration_test` 已执行成功，统一三层测试约 25 秒，原始脚本见用户上传 `flutter-linux-android-setup`；对真实项目每次仍必须重新执行。Android APK 编译若有 SDK 可测，不能等同 Android 运行验收。
