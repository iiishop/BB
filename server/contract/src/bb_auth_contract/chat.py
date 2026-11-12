"""Chat R2: shared strict wire models. Account credentials never cross local replies."""

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

Account = Annotated[str, Field(pattern=r"^[1-9][0-9]{7}$")]
OperationId = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")]


class Wire(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)


class Text(Wire):
    type: Literal["text"]
    text: str = Field(min_length=1, max_length=20000)


class Image(Wire):
    type: Literal["image"]
    media_id: str


class SendMessage(Wire):
    target_account: Account
    client_nonce: OperationId
    content: list[Annotated[Text | Image, Field(discriminator="type")]] = Field(
        min_length=1, max_length=100
    )


class SendAttachment(Wire):
    target_account: Account
    client_nonce: OperationId
    media_id: str


class Media(Wire):
    media_id: str
    media_type: Literal["image", "video", "audio", "document", "other"]
    filename: str
    mime_type: str
    byte_size: int
    cover_media_id: str | None = None


class Message(Wire):
    id: str
    position: int
    sender_account: Account
    target_account: Account
    created_at: str
    kind: Literal["body", "attachment"]
    content: list[Annotated[Text | Image, Field(discriminator="type")]] | None = None
    attachment: Media | None = None


class MessagePage(Wire):
    items: list[Message]
    next_position: int
    has_more: bool


class Operation(Wire):
    operation_id: OperationId
    kind: Literal["message", "download"]
    status: Literal["pending", "succeeded", "failed"]
    message: Message | None = None
    task_id: str | None = None
    error_code: str | None = None


class Event(Wire):
    version: Literal[1] = 1
    event_id: int
    type: Literal["message.available"] = "message.available"
    occurred_at: str
    message_id: str
    peer_account: Account
    position: int


class EventPage(Wire):
    items: list[Event]
    next_event_id: int
    has_more: bool


class Preview(Wire):
    id: str
    sender_account: Account
    sender_username: str
    preview_body: str


class User(Wire):
    account: Account
    username: str
    avatar_url: str
    avatar_version: str
    presence: Literal["online", "offline"]
    last_contact_at: str | None
    last_message: Preview | None


class UserPage(Wire):
    items: list[User]
    next_cursor: str | None


class Users(Wire):
    after_account: str = ""
    limit: int = Field(default=50, ge=1, le=100)


class Source(Wire):
    base64: str | None = None
    path: str | None = None
    url: str | None = None
    mime_type: str
    filename: str

    @model_validator(mode="after")
    def one_source(self):
        if sum(x is not None for x in (self.base64, self.path, self.url)) != 1:
            raise ValueError("Exactly one file source is required")
        return self


class LocalImage(Wire):
    type: Literal["image"]
    source: Source


class LocalSend(Wire):
    target_account: Account
    operation_id: OperationId
    content: list[Annotated[Text | LocalImage, Field(discriminator="type")]] = Field(
        min_length=1, max_length=100
    )


class LocalAttachment(Wire):
    target_account: Account
    operation_id: OperationId
    source: Source
    cover: Source | None = None


class Read(Wire):
    account: Account
    consumer_session: str = Field(min_length=1, max_length=200)
    after_position: int = Field(default=0, ge=0)
    limit: int = Field(default=50, ge=1, le=100)


class Wait(Wire):
    account: Account
    consumer_session: str = Field(min_length=1, max_length=200)
    seen_position: int = Field(ge=0)
    timeout: Literal[30, 60, 120] = 60


class Ack(Wire):
    account: Account
    consumer_session: str = Field(min_length=1, max_length=200)
    through_position: int = Field(ge=0)


class AckResult(Wire):
    consumed_through: int


class VisibleImage(Wire):
    type: Literal["image"]
    data: str
    mime_type: Literal["image/png", "image/jpeg", "image/webp"]


class Presentation(Wire):
    receipt_id: str = Field(min_length=1)
    content_digest: str = Field(min_length=1)


class VisibleMessage(Wire):
    message: Message
    presentation: Presentation | None = None
    blocks: list[Annotated[Text | VisibleImage, Field(discriminator="type")]]


class ReadResult(Wire):
    items: list[VisibleMessage]
    next_position: int
    has_more: bool


class WaitResult(ReadResult):
    reason: Literal["messages", "timeout", "cancelled", "logout", "disconnected"]


class DownloadStart(Wire):
    operation_id: OperationId
    consumer_session: str = Field(min_length=1, max_length=200)
    media_id: str
    directory: str | None = None


class DownloadGet(Wire):
    task_id: str
    consumer_session: str = Field(min_length=1, max_length=200)


class OperationGet(Wire):
    operation_id: OperationId


class Download(Wire):
    task_id: str
    operation_id: OperationId
    consumer_session: str
    status: Literal["pending", "running", "succeeded", "failed"]
    planned_path: str
    actual_path: str | None = None
    error_code: str | None = None

    @model_validator(mode="after")
    def paths(self):
        if (self.actual_path is not None) != (self.status == "succeeded"):
            raise ValueError("actual_path only on success")
        return self


LOCAL = {
    "list_users": ("/chat/list_users", Users, UserPage, 200),
    "send_message": ("/chat/send_message", LocalSend, Message, 200),
    "send_attachment": ("/chat/send_attachment", LocalAttachment, Message, 200),
    "read_messages": ("/chat/read_messages", Read, ReadResult, 200),
    "wait_messages": ("/chat/wait_messages", Wait, WaitResult, 200),
    "ack_messages": ("/chat/ack_messages", Ack, AckResult, 200),
    "start_download": ("/downloads/start", DownloadStart, Download, 202),
    "get_download": ("/downloads/get", DownloadGet, Download, 200),
    "get_operation": ("/operations/get", OperationGet, Operation, 200),
}


class LocalEventBase(Wire):
    version: Literal[1] = 1
    event_id: str = Field(min_length=1, max_length=200)
    account: Account
    consumer_session: str = Field(min_length=1, max_length=200)


class LocalMessageEvent(LocalEventBase):
    type: Literal["message.available"]
    peer_account: Account
    position: int = Field(ge=1)


class LocalDownloadSucceeded(LocalEventBase):
    type: Literal["download.succeeded"]
    task_id: str
    operation_id: OperationId
    actual_path: str = Field(min_length=1)


class LocalDownloadFailed(LocalEventBase):
    type: Literal["download.failed"]
    task_id: str
    operation_id: OperationId
    error_code: str = Field(min_length=1)


LocalEvent = Annotated[
    LocalMessageEvent | LocalDownloadSucceeded | LocalDownloadFailed,
    Field(discriminator="type"),
]


class ConfirmPresentation(Wire):
    consumer_session: str = Field(min_length=1, max_length=200)
    attempt_id: str = Field(min_length=1)
    request_digest: str = Field(min_length=1)
    receipt_ids: list[str] = Field(min_length=1, max_length=100)


class ConfirmedPresentation(Wire):
    confirmed_receipt_ids: list[str]


class Subscribe(Wire):
    consumer_session: str = Field(min_length=1, max_length=200)
    peer_account: Account


class EventsRead(Wire):
    consumer_session: str = Field(min_length=1, max_length=200)
    after_cursor: int = Field(default=0, ge=0)
    limit: int = Field(default=50, ge=1, le=100)


class EventsWait(EventsRead):
    timeout: Literal[30, 60, 120] = 60


class LocalEventEntry(Wire):
    cursor: int = Field(ge=1)
    event: LocalEvent


class LocalEventPage(Wire):
    items: list[LocalEventEntry]
    next_cursor: int = Field(ge=0)
    has_more: bool


class LocalEventWait(LocalEventPage):
    reason: Literal["events", "timeout", "cancelled", "logout", "disconnected"]


INTERNAL = {
    "confirm_presentation": (
        "/chat/confirm_presentation",
        ConfirmPresentation,
        ConfirmedPresentation,
        200,
    ),
    "events_subscribe": ("/events/subscribe", Subscribe, Subscribe, 200),
    "events_read": ("/events/read", EventsRead, LocalEventPage, 200),
    "events_wait": ("/events/wait", EventsWait, LocalEventWait, 200),
}
