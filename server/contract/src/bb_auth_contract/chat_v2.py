"""DEA-467 local-client v2 wire authority; no runtime or authentication implementation.

Export with contract/export_chat_v2.py. Never add these fields to the v1 models.
"""

from typing import Annotated, Generic, Literal, TypeVar

from pydantic import Field, model_validator

from . import chat as v1
from . import chat_query as query

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
    migration: Literal["ready", "migration_required"]


class Protected(v1.Wire):
    expected_identity: ExpectedIdentity


class Users(Protected, v1.Users):
    pass


class Send(Protected, v1.LocalSend):
    pass


class Attachment(Protected, v1.LocalAttachment):
    pass


class Peer(Protected):
    account: v1.Account  # Peer, NOT expected_identity.account.


class Read(Peer, query.HistoryQuery):
    pass


class Conversations(Protected, query.ConversationQuery):
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
    migration: Literal["ready", "migration_required"]


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
    peer_account: v1.Account


class Subscription(v1.Wire):
    peer_account: v1.Account


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
    type: Literal["message.available"]
    peer_account: v1.Account
    position: int = Field(ge=1, le=9007199254740991)


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


LocalEvent = Annotated[
    MessageEvent | DownloadSucceeded | DownloadFailed, Field(discriminator="type")
]


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
    "send_message": ("/v2/chat/send_message", Send, Reply[v1.Message], 200, True),
    "send_attachment": (
        "/v2/chat/send_attachment",
        Attachment,
        Reply[v1.Message],
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
    "migration_required": (
        409,
        "Retain evidence; no copying legacy account-wide cursor.",
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
