# DEA-498 共享会话与通知接口

`server/contract/src/bb_auth_contract/` 定义机器契约。`group.REMOTE` 登记远端群管理与通用通知 JSON POST。Dart 本地 API 与 MCP 使用 `chat_v2.GROUP_BUSINESS`，加上既有 `BUSINESS`。完整候选图为 `server/contract/chat-v2-group-openapi.json`。既有 `chat-v2-openapi.json` 继续登记现已接通的本地路由，新路由由 DEA-503 同步接通、注册和启用。

## 共享会话与消息

- `ConversationRef` 为 `{type: "direct", id: "dm:<low>:<high>"}` 或 `{type: "group", id: "group:<32小写十六进制>"}`。群号为独立 8 位查找键。会话列表、草稿、游标、订阅及缓存以完整会话 ID 隔离。
- 远端继续使用 `POST /messages` 和 `POST /messages/attachments`。JSON 必须恰选 `target_account`（旧私聊）或 `conversation`。上传继续使用 `POST /media`，multipart 的选择字段是 `target_account` 或 `conversation_id`（会话 ID 字符串）。元数据与下载 URL 沿用原路径。
- `GET /chat/conversations?after_id=&limit=50` 用会话 ID keyset，私聊与有效成员的群一起返回。空群 `last_message=null`、`latest_position=0`。沿用旧 `GET /conversations?after_account=...` 以及 `GET /conversations/{account}/messages` 查询私聊。共享历史为 `GET /chat/conversations/{conversation_id}/messages`，沿用 `after_position`、`before_position`、`limit`。按消息 ID 的单条和上下文继续使用 `/messages/{message_id}` 及 `/context`。
- 直聊消息保留 sender_account/target_account；群用户消息带 conversation、sender_account、sender_username。系统消息带 conversation、kind=system、结构化 system 事件及可直接展示的 text，无发言人。系统消息进入历史与列表预览，排除在入站未读及模型聚合之外。接收者持有或缓存正文时，群访问状态必须先核实。会话事件只携带定位信息。
- 群会话列表项含 `history_through` 与 `membership_revision`。加入时在事务内记下此前最后一个位置。旧历史可在有成员资格时主动查询，prev UI 未读及模型预览只接收当前成员周期的入站用户消息。退群、移除、解散与重新入群时停用或更新前一成员周期的待交付数据。客户端持久账本额外使用成员周期区分同一个群的先后加入，保留私聊历史凭证、水位与操作格式。
- 远端 HTTP `/events`、`/events/head` 及 WebSocket `/events` 使用 `include_groups=true` 接收群事件。群消息事件带 conversation，访问事件带 conversation、active、membership_revision、history_through；收到撤权立即失效缓存、窗口和待投递。未启用的订阅仍收到既有私聊格式。群媒体发送前仅上传者可取，消息存活且调用方仍为群员时可查询和下载，旧私聊媒体权限沿用。
- 本地聊天工具名沿用。read/wait/ack/consumption 选 `account` 或 `conversation`，发送类选 `target_account` 或 `conversation`。守护 owner/expected_identity 及确认操作边界沿用 DEA-467。调用方已读、消费水位和聚合进度分开。群授权发生在服务端，并用新鲜成员周期控制本地数据可见性。

## 群管理与通用通知

- 创建使用 operation_id 幂等；名称裁掉两端空白后必须非空。远端头像使用 JSON base64 与 mime_type，Dart 本地工具用已有 Source（由本地客户端读取）。资料按群号查找，解散后仍可查看；后续管理动作按 conversation。目录和成员列表只返回各自的资料投影。陌生用户只可查基础资料及申请。
- 邀请与申请返回关联请求 ID。同人同群同一待处理状态协调交叉请求；邀请动作仍只归受邀人，申请动作仍只归群主。加入边界、系统消息和结果通知随业务提交一次写入。
- 通知有持久 `id`，操作请求提交 `notification_id` 和 `action_id`。只有通知接收者可查看或操作；已读与 pending/processed/invalidated 独立。不可执行动作须拒绝，待处理筛选仅包含仍可执行的项。Space 通知走原路径。群资料链接使用 `{type:"group", id:"<group_number>"}`，可打开已解散群的基础资料。
- `notification_changes` 复用统一的 source cursor。群消息摘要携带 membership_revision；`business_notices` 为可省略的独立有界预览、真实新通知计数及未读/待处理数。预览及正文视为不可信用户数据。展示预览或投递聚合均不读取、处理通知，也不确认底层聊天消息。通知动作和已读使用各自的业务操作。 
