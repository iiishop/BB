"""Chat R2: shared strict wire models. Account credentials never cross local replies."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from .conversation import ConversationRef, GroupConversationRef
from .wire import Wire

Account = Annotated[str, Field(pattern=r"^[1-9][0-9]{7}$")]
OperationId = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")]
OpaqueId = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,200}$")]


class SendTarget(Wire):
    target_account: Account | None = None
    conversation: ConversationRef | None = None

    @model_validator(mode="after")
    def one_target(self):
        if (self.target_account is None) == (self.conversation is None):
            raise ValueError("select one target account or conversation")
        return self


class Text(Wire):
    type: Literal["text"]
    text: str = Field(min_length=1, max_length=20000)


class Image(Wire):
    type: Literal["image"]
    media_id: str


class SendMessage(SendTarget):
    client_nonce: OperationId
    reply_to_message_id: OpaqueId | None = Field(
        default=None, exclude_if=lambda value: value is None
    )
    content: list[Annotated[Text | Image, Field(discriminator="type")]] = Field(
        min_length=1, max_length=100
    )
    mentioned_accounts: list[Account] = Field(default_factory=list, max_length=100)

    @model_validator(mode="after")
    def group_mentions(self):
        if self.mentioned_accounts and (
            self.conversation is None or self.conversation.type != "group"
        ):
            raise ValueError("mentions require a group conversation")
        if len(set(self.mentioned_accounts)) != len(self.mentioned_accounts):
            raise ValueError("mention accounts must be unique")
        return self


class SendAttachment(SendTarget):
    client_nonce: OperationId
    media_id: str
    reply_to_message_id: OpaqueId | None = Field(
        default=None, exclude_if=lambda value: value is None
    )


class Media(Wire):
    media_id: str
    media_type: Literal["image", "video", "audio", "document", "other"]
    filename: str
    mime_type: str
    byte_size: int
    cover_media_id: str | None = None


class MessageEntry(Wire):
    id: str
    position: int
    created_at: str


class ReplyQuote(Wire):
    message_id: OpaqueId
    sender_account: Account | None
    sender_username: str | None
    preview: str


class UserMessage(MessageEntry):
    sender_account: Account
    kind: Literal["body", "attachment"]
    content: list[Annotated[Text | Image, Field(discriminator="type")]] | None = None
    attachment: Media | None = None
    reply_to: ReplyQuote | None = Field(
        default=None, exclude_if=lambda value: value is None
    )


class Message(UserMessage):
    target_account: Account


class GroupMessage(UserMessage):
    conversation: GroupConversationRef
    sender_username: str


class MemberJoined(Wire):
    type: Literal["member.joined"]
    account: Account
    username: str


class GroupRenamed(Wire):
    type: Literal["group.renamed"]
    old_name: str
    new_name: str


class SystemMessage(MessageEntry):
    kind: Literal["system"]
    conversation: ConversationRef
    system: Annotated[MemberJoined | GroupRenamed, Field(discriminator="type")]
    text: str


ChatMessage = Message | GroupMessage | SystemMessage


class MessagePage(Wire):
    items: list[ChatMessage]
    next_position: int
    has_more: bool


class Operation(Wire):
    operation_id: OperationId
    kind: Literal["message", "download"]
    status: Literal["pending", "succeeded", "failed"]
    message: ChatMessage | None = None
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


class GroupMessageEvent(Wire):
    version: Literal[1] = 1
    event_id: int
    type: Literal["message.available"] = "message.available"
    occurred_at: str
    message_id: str
    conversation: GroupConversationRef
    position: int
    membership_revision: int


class ConversationAccessEvent(Wire):
    version: Literal[1] = 1
    event_id: int
    type: Literal["conversation.access_changed"] = "conversation.access_changed"
    occurred_at: str
    conversation: GroupConversationRef
    active: bool
    membership_revision: int
    history_through: int


class NotificationEvent(Wire):
    version: Literal[1] = 1
    event_id: int
    type: Literal["notification.available"] = "notification.available"
    occurred_at: str
    notification_id: OpaqueId


class EventPage(Wire):
    items: list[Event | GroupMessageEvent | ConversationAccessEvent | NotificationEvent]
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


class LocalSend(SendTarget):
    operation_id: OperationId
    content: list[Annotated[Text | LocalImage, Field(discriminator="type")]] = Field(
        min_length=1, max_length=100
    )


class LocalAttachment(SendTarget):
    operation_id: OperationId
    source: Source
    cover: Source | None = None


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
    message: ChatMessage
    presentation: Presentation | None = None
    blocks: list[Annotated[Text | VisibleImage, Field(discriminator="type")]]


class ReadResult(Wire):
    items: list[VisibleMessage]
    next_position: int
    has_more: bool


class OperationGet(Wire):
    operation_id: OperationId


class ConfirmedPresentation(Wire):
    confirmed_receipt_ids: list[str]
