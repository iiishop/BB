"""DEA-467 local-client v2 wire authority; no runtime or authentication implementation.

Export with contract/export_chat_v2.py. This is the sole local business protocol.
"""

from typing import Annotated, Generic, Literal, TypeVar

from pydantic import ConfigDict, Field, model_validator

from . import chat as v1
from . import chat_query as query
from . import cover, group, profile
from .conversation import GroupConversationRef

VERSION = "dea467-local-v2"
Opaque = Annotated[
    str, Field(min_length=1, max_length=200, pattern=r"^[A-Za-z0-9_-]+$")
]
Revision = Annotated[int, Field(ge=1, le=9007199254740991)]
Position = Annotated[int, Field(ge=0, le=9007199254740991)]
OwnerKey = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{43}$")]
OWNER_HEADER = "X-BB-Consumer-Key"


class AuthIdentity(v1.Wire):
    account: v1.Account
    auth_generation: Opaque


class ExpectedIdentity(AuthIdentity):
    consumer_id: Opaque
    binding_revision: Revision


class Empty(v1.Wire):
    pass


class Negotiate(v1.Wire):
    supported_versions: list[int] = Field(min_length=1, max_length=8)


class Negotiated(v1.Wire):
    selected_version: Literal[2]
    contract: Literal[VERSION]
    owner_header: Literal[OWNER_HEADER]


class Status(v1.Wire):
    protocol_version: Literal[2]
    auth: AuthIdentity | None


class CreateConsumer(v1.Wire):
    expected_auth: AuthIdentity
    session_id: Opaque


class GetConsumer(v1.Wire):
    expected_auth: AuthIdentity
    consumer_id: Opaque


class BindConsumer(GetConsumer):
    expected_binding_revision: Revision
    session_id: Opaque


class Binding(v1.Wire):
    identity: ExpectedIdentity
    session_id: Opaque
    active: bool


class Protected(v1.Wire):
    expected_identity: ExpectedIdentity


class ProfileView(Protected):
    account: v1.Account | None = None


class ProfileCover(Protected, cover.CoverUpload):
    pass


class ProfileNickname(Protected, profile.NicknameUpdate):
    @model_validator(mode="after")
    def normalized(self):
        self.value = profile.nickname(self.value)
        return self


class ProfileSignature(Protected, profile.SignatureUpdate):
    @model_validator(mode="after")
    def normalized(self):
        self.value = profile.signature(self.value)
        return self


class ProfileAvatar(Protected, profile.AvatarUpdate):
    model_config = ConfigDict(
        strict=True,
        extra="forbid",
        hide_input_in_errors=True,
        json_schema_extra={
            "minProperties": 2,
            "maxProperties": 2,
            "oneOf": [{"required": [name]} for name in ("path", "url", "base64")],
        },
    )

    @model_validator(mode="after")
    def one_source(self):
        profile.parse_profile_tool(
            "update_avatar",
            {
                key: getattr(self, key)
                for key in self.model_fields_set
                if key != "expected_identity"
            },
        )
        return self


class Users(Protected, v1.Users):
    pass


class Send(Protected, v1.LocalSend):
    pass


class Attachment(Protected, v1.LocalAttachment):
    pass


class Peer(Protected):
    account: v1.Account | None = None  # Legacy peer selector.
    conversation: query.ConversationRef | None = None

    @model_validator(mode="after")
    def one_conversation(self):
        if (self.account is None) == (self.conversation is None):
            raise ValueError("select one peer account or conversation")
        return self


class Read(Peer, query.HistoryQuery):
    unread_only: bool = False


class Conversations(Protected, query.ConsumerConversationQuery):
    pass


class GetMessage(Protected, query.MessageQuery):
    pass


class GetContext(Protected, query.ContextQuery):
    pass


class Wait(Peer):
    seen_position: Position
    timeout: Literal[30, 60, 120] = 60


class Ack(Peer):
    through_position: Position


class Consumption(v1.Wire):
    consumed_through: Position


class Confirm(Protected):
    attempt_id: Opaque
    request_digest: str = Field(pattern=r"^[a-f0-9]{64}$")
    receipt_ids: list[Opaque] = Field(min_length=1, max_length=100)


class OperationGet(Protected, v1.OperationGet):
    pass


class Operation(v1.Operation):
    status: Literal["pending", "uncertain", "succeeded", "failed"]

    @model_validator(mode="after")
    def outcome(self):
        if self.status in ("pending", "uncertain") and (
            self.message is not None or self.error_code is not None
        ):
            raise ValueError("unknown outcome cannot claim success or terminal failure")
        if (
            self.status == "succeeded"
            and self.kind == "message"
            and self.message is None
        ):
            raise ValueError("successful message needs durable result")
        if (
            self.status == "succeeded"
            and self.kind == "download"
            and self.task_id is None
        ):
            raise ValueError("successful download plan needs task ID")
        if self.status == "failed" and not self.error_code:
            raise ValueError("terminal failure needs a code")
        return self


class DownloadStart(Protected):
    operation_id: v1.OperationId
    media_id: str = Field(min_length=1, max_length=200)
    directory: str | None = None


class DownloadGet(Protected):
    task_id: Opaque


class Download(v1.Wire):
    task_id: Opaque
    operation_id: v1.OperationId
    origin_identity: ExpectedIdentity
    status: Literal["pending", "running", "uncertain", "succeeded", "failed"]
    planned_path: str
    actual_path: str | None = None
    error_code: str | None = None

    @model_validator(mode="after")
    def paths(self):
        if (self.actual_path is not None) != (self.status == "succeeded"):
            raise ValueError("actual_path only on success")
        return self


class Subscribe(Protected):
    peer_account: v1.Account | None = None
    conversation: query.ConversationRef | None = None
    discover: bool = False

    @model_validator(mode="after")
    def selection(self):
        if (
            sum(
                (
                    self.peer_account is not None,
                    self.conversation is not None,
                    self.discover,
                )
            )
            != 1
        ):
            raise ValueError("select one peer, conversation or discovery")
        if self.peer_account == self.expected_identity.account:
            raise ValueError("self conversation is unsupported")
        if (
            self.conversation
            and self.conversation.type == "direct"
            and self.expected_identity.account
            not in self.conversation.id.split(":")[1:]
        ):
            raise ValueError("conversation does not belong to the current account")
        return self


class Subscription(v1.Wire):
    peer_account: v1.Account | None
    conversation: query.ConversationRef | None
    discover: bool


class NotificationSettings(v1.Wire):
    enabled: bool
    revision: Revision
    skip_source_through: Position


class SetNotifications(Protected):
    enabled: bool


class NotificationChanges(Protected):
    retry_cursors: list[Annotated[int, Field(ge=1, le=9007199254740991)]] = Field(
        default_factory=list, max_length=100
    )
    after_cursor: Position = 0
    through_cursor: Position | None = None
    limit: int = Field(default=100, ge=1, le=100)


class NotificationSummary(v1.Wire):
    conversation: query.ConversationRef
    peer_account: v1.Account
    display_name: str
    new_count: int = Field(ge=1)
    incoming_unread: Position
    last_message: query.MessagePreview


class DeferredNotification(v1.Wire):
    cursor: int = Field(ge=1, le=9007199254740991)
    peer_account: v1.Account
    error_code: Literal[
        "not_found", "upstream_unavailable", "upstream_timeout", "network_error"
    ]


class GroupNotificationSummary(v1.Wire):
    conversation: GroupConversationRef
    display_name: str
    membership_revision: Revision
    new_count: int = Field(ge=1)
    incoming_unread: Position
    last_message: query.MessagePreview


class DeferredGroupNotification(v1.Wire):
    cursor: int = Field(ge=1, le=9007199254740991)
    conversation: GroupConversationRef
    membership_revision: Revision
    error_code: Literal[
        "not_found", "upstream_unavailable", "upstream_timeout", "network_error"
    ]


class BusinessNoticePreview(v1.Wire):
    notification_id: group.OpaqueId
    type: group.OpaqueId
    text: str = Field(max_length=160)
    truncated: bool


class BusinessNoticeSummary(v1.Wire):
    new_count: int = Field(ge=1)
    unread_count: Position
    pending_count: Position
    last_notice: BusinessNoticePreview


class NotificationPage(v1.Wire):
    deferred: list[DeferredNotification | DeferredGroupNotification]
    settings: NotificationSettings
    items: list[NotificationSummary | GroupNotificationSummary]
    business_notices: BusinessNoticeSummary | None = None
    next_cursor: Position
    through_cursor: Position
    has_more: bool


class EventsRead(Protected):
    after_cursor: Position = 0
    limit: int = Field(default=50, ge=1, le=100)


class EventsWait(EventsRead):
    timeout: Literal[30, 60, 120] = 60


class EventBase(v1.Wire):
    version: Literal[2]
    event_id: Opaque
    origin_identity: ExpectedIdentity


class MessageEvent(EventBase):
    conversation: query.ConversationRef
    type: Literal["message.available"]
    peer_account: v1.Account
    position: int = Field(ge=1, le=9007199254740991)


class GroupMessageEvent(EventBase):
    conversation: GroupConversationRef
    type: Literal["message.available"]
    membership_revision: Revision
    position: int = Field(ge=1, le=9007199254740991)


class AccessChangedEvent(EventBase):
    conversation: GroupConversationRef
    type: Literal["conversation.access_changed"]
    active: bool
    membership_revision: Revision
    history_through: Position


class BusinessNoticeEvent(EventBase):
    type: Literal["notification.available"]
    notification_id: group.OpaqueId


class DownloadSucceeded(EventBase):
    type: Literal["download.succeeded"]
    task_id: Opaque
    operation_id: v1.OperationId
    actual_path: str = Field(min_length=1)


class DownloadFailed(EventBase):
    type: Literal["download.failed"]
    task_id: Opaque
    operation_id: v1.OperationId
    error_code: Opaque


LocalEvent = (
    MessageEvent
    | GroupMessageEvent
    | AccessChangedEvent
    | BusinessNoticeEvent
    | DownloadSucceeded
    | DownloadFailed
)


class EventEntry(v1.Wire):
    cursor: int = Field(ge=1, le=9007199254740991)
    event: LocalEvent


class EventPage(v1.Wire):
    items: list[EventEntry]
    next_cursor: Position
    has_more: bool


class EventWait(EventPage):
    reason: Literal["events", "timeout", "cancelled", "disconnected"]


class WaitResult(v1.ReadResult):
    reason: Literal["messages", "timeout", "cancelled", "disconnected"]


T = TypeVar("T")


class Reply(v1.Wire, Generic[T]):
    identity: ExpectedIdentity
    result: T


class Error(v1.Wire):
    code: str = Field(pattern=r"^[a-z_]+$", max_length=80)
    message: str = Field(max_length=200)
    fields: list[str] = Field(max_length=20)


class ErrorEnvelope(v1.Wire):
    error: Error


# (route, request, response, success status, requires owner capability)
BOOTSTRAP = {
    "negotiate": ("/v2/protocol/negotiate", Negotiate, Negotiated, 200, False),
    "status": ("/v2/status", Empty, Status, 200, False),
    "consumer_create": ("/v2/consumers/create", CreateConsumer, Binding, 200, True),
    "consumer_get": ("/v2/consumers/get", GetConsumer, Binding, 200, True),
    "consumer_bind": ("/v2/consumers/bind", BindConsumer, Binding, 200, True),
}
BUSINESS = {
    "view_cover": (
        "/v2/profile/view_cover",
        ProfileView,
        Reply[cover.CoverImageResponse],
        200,
        True,
    ),
    "update_cover": (
        "/v2/profile/update_cover",
        ProfileCover,
        Reply[cover.CoverResponse],
        200,
        True,
    ),
    "view_avatar": (
        "/v2/profile/view_avatar",
        ProfileView,
        Reply[profile.AvatarImageResponse],
        200,
        True,
    ),
    "update_avatar": (
        "/v2/profile/update_avatar",
        ProfileAvatar,
        Reply[profile.AvatarResponse],
        200,
        True,
    ),
    "view_nickname": (
        "/v2/profile/view_nickname",
        ProfileView,
        Reply[profile.AccountResponse],
        200,
        True,
    ),
    "update_nickname": (
        "/v2/profile/update_nickname",
        ProfileNickname,
        Reply[profile.AccountResponse],
        200,
        True,
    ),
    "view_signature": (
        "/v2/profile/view_signature",
        ProfileView,
        Reply[profile.SignatureResponse],
        200,
        True,
    ),
    "update_signature": (
        "/v2/profile/update_signature",
        ProfileSignature,
        Reply[profile.SignatureResponse],
        200,
        True,
    ),
    "get_notifications": (
        "/v2/notifications/get",
        Protected,
        Reply[NotificationSettings],
        200,
        True,
    ),
    "set_notifications": (
        "/v2/notifications/set",
        SetNotifications,
        Reply[NotificationSettings],
        200,
        True,
    ),
    "notification_changes": (
        "/v2/notifications/changes",
        NotificationChanges,
        Reply[NotificationPage],
        200,
        True,
    ),
    "list_conversations": (
        "/v2/chat/list_conversations",
        Conversations,
        Reply[query.ConsumerConversationPage],
        200,
        True,
    ),
    "get_message": (
        "/v2/chat/get_message",
        GetMessage,
        Reply[query.VisibleQueryMessage],
        200,
        True,
    ),
    "get_context": (
        "/v2/chat/get_context",
        GetContext,
        Reply[query.VisibleContext],
        200,
        True,
    ),
    "list_users": ("/v2/chat/list_users", Users, Reply[v1.UserPage], 200, True),
    "send_message": ("/v2/chat/send_message", Send, Reply[v1.ChatMessage], 200, True),
    "send_attachment": (
        "/v2/chat/send_attachment",
        Attachment,
        Reply[v1.ChatMessage],
        200,
        True,
    ),
    "read_messages": ("/v2/chat/read_messages", Read, Reply[v1.ReadResult], 200, True),
    "wait_messages": ("/v2/chat/wait_messages", Wait, Reply[WaitResult], 200, True),
    "ack_messages": ("/v2/chat/ack_messages", Ack, Reply[v1.AckResult], 200, True),
    "get_consumption": ("/v2/chat/consumption", Peer, Reply[Consumption], 200, True),
    "confirm_presentation": (
        "/v2/chat/confirm_presentation",
        Confirm,
        Reply[v1.ConfirmedPresentation],
        200,
        True,
    ),
    "start_download": (
        "/v2/downloads/start",
        DownloadStart,
        Reply[Download],
        202,
        True,
    ),
    "get_download": ("/v2/downloads/get", DownloadGet, Reply[Download], 200, True),
    "get_operation": ("/v2/operations/get", OperationGet, Reply[Operation], 200, True),
    "events_subscribe": (
        "/v2/events/subscribe",
        Subscribe,
        Reply[Subscription],
        200,
        True,
    ),
    "events_read": ("/v2/events/read", EventsRead, Reply[EventPage], 200, True),
    "events_wait": ("/v2/events/wait", EventsWait, Reply[EventWait], 200, True),
}


# Release with the corresponding Dart handlers and MCP registration in DEA-503.
class CreateGroup(Protected, group.GroupCreate):
    pass


class FindGroup(Protected, group.GroupNumberRequest):
    pass


class UpdateGroup(Protected, group.GroupUpdate):
    pass


class Directory(Protected, group.DirectoryQuery):
    pass


class ListMembers(Protected, group.GroupMembers):
    pass


class GroupInvite(Protected, group.GroupInvite):
    pass


class GroupTarget(Protected, group.GroupTarget):
    pass


class GroupRemove(Protected, group.GroupRemove):
    pass


class ListNotices(Protected, group.Notices):
    pass


class NoticeId(Protected, group.NoticeId):
    pass


class ExecuteNoticeAction(Protected, group.NoticeActionRequest):
    pass


GROUP_BUSINESS = {
    "create_group": (
        "/v2/groups/create",
        CreateGroup,
        Reply[group.GroupProfile],
        200,
        True,
    ),
    "find_group": ("/v2/groups/find", FindGroup, Reply[group.GroupProfile], 200, True),
    "update_group": (
        "/v2/groups/update",
        UpdateGroup,
        Reply[group.GroupProfile],
        200,
        True,
    ),
    "list_directory": (
        "/v2/directory/list",
        Directory,
        Reply[group.DirectoryPage],
        200,
        True,
    ),
    "list_group_members": (
        "/v2/groups/members",
        ListMembers,
        Reply[group.GroupMemberPage],
        200,
        True,
    ),
    "invite_to_group": (
        "/v2/groups/invite",
        GroupInvite,
        Reply[group.GroupRequests],
        200,
        True,
    ),
    "apply_to_group": (
        "/v2/groups/apply",
        GroupTarget,
        Reply[group.GroupRequests],
        200,
        True,
    ),
    "leave_group": (
        "/v2/groups/leave",
        GroupTarget,
        Reply[group.GroupProfile],
        200,
        True,
    ),
    "remove_group_member": (
        "/v2/groups/remove_member",
        GroupRemove,
        Reply[group.GroupProfile],
        200,
        True,
    ),
    "dissolve_group": (
        "/v2/groups/dissolve",
        GroupTarget,
        Reply[group.GroupProfile],
        200,
        True,
    ),
    "list_notices": (
        "/v2/notices/list",
        ListNotices,
        Reply[group.NoticePage],
        200,
        True,
    ),
    "mark_notice_read": (
        "/v2/notices/mark_read",
        NoticeId,
        Reply[group.Notice],
        200,
        True,
    ),
    "execute_notice_action": (
        "/v2/notices/execute_action",
        ExecuteNoticeAction,
        Reply[group.Notice],
        200,
        True,
    ),
}
OPERATIONS = BOOTSTRAP | BUSINESS
ERRORS = {
    "validation_error": (
        422,
        "Fix the request; never echo input values or unknown field names.",
    ),
    "unsupported_version": (426, "No shared version; never fall back to unguarded v1."),
    "unauthenticated": (401, "Use existing login MCP; no token in this protocol."),
    "stale_identity": (
        409,
        "Refresh auth state; reconcile old operations under original account.",
    ),
    "stale_binding": (
        409,
        "Missing/wrong owner capability or CAS conflict; explicit rebind, no replay.",
    ),
    "consumption_gap": (
        409,
        "Read and confirm this consumer's missing contiguous receipts.",
    ),
    "idempotency_conflict": (
        409,
        "Same operation/attempt ID with different intent; do not send.",
    ),
    "not_found": (
        404,
        "Absent or outside caller scope; not proof an uncertain operation never ran.",
    ),
    "storage_unavailable": (
        503,
        "No success/ACK unless durable; reconcile after recovery.",
    ),
    "upstream_unavailable": (
        502,
        "Outcome may be uncertain; query original operation ID.",
    ),
    "upstream_timeout": (504, "Outcome may be uncertain; query original operation ID."),
    "payload_too_large": (413, "Reduce input; never echo input."),
    "unsupported_media_type": (415, "Use a supported media type."),
}

GROUP_ERRORS = {
    "forbidden": (403, "Role lacks permission; refresh the resource."),
    "action_unavailable": (
        409,
        "Resolve current notification state before taking another action.",
    ),
    "group_unavailable": (
        409,
        "Group is dissolved; its basic profile is still readable.",
    ),
}
