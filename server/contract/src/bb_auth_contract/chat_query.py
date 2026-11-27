"""Query revision 1: shared server/local semantics; no new business fact store."""

from typing import Annotated, Literal

from pydantic import Field, model_serializer, model_validator

from . import chat as v1
from .conversation import (
    ConversationId,
    ConversationRef,
    GroupConversationRef,
)

Position = Annotated[int, Field(ge=0, le=9007199254740991)]
MessageId = Annotated[
    str, Field(min_length=1, max_length=200, pattern=r"^[A-Za-z0-9_-]+$")
]


class ConversationQuery(v1.Wire):
    after_account: str = Field(default="", pattern=r"^([1-9][0-9]{7})?$")
    limit: int = Field(default=50, ge=1, le=100)


class ConsumerConversationQuery(ConversationQuery):
    order: Literal["account", "recent"] = "account"
    unread_only: bool = False
    cursor: str | None = Field(
        default=None, min_length=1, max_length=200, pattern=r"^[A-Za-z0-9_-]+$"
    )

    @model_validator(mode="after")
    def pagination(self):
        if self.after_account and (
            self.order != "account" or self.unread_only or self.cursor
        ):
            raise ValueError(
                "after_account cannot be combined with snapshot pagination"
            )
        return self


class MessagePreview(v1.Wire):
    message_id: MessageId
    sender_account: v1.Account
    position: Position
    created_at: str
    text: str = Field(max_length=160)
    truncated: bool


class MessageQuery(v1.Wire):
    message_id: MessageId


class ContextQuery(MessageQuery):
    before_limit: int = Field(default=10, ge=0, le=49)
    after_limit: int = Field(default=10, ge=0, le=49)


class HistoryQuery(v1.Wire):
    after_position: Position | None = None
    before_position: Annotated[int, Field(ge=1, le=9007199254740991)] | None = None
    limit: int = Field(default=50, ge=1, le=100)

    @model_validator(mode="after")
    def direction(self):
        if self.after_position is not None and self.before_position is not None:
            raise ValueError(
                "before_position and after_position are mutually exclusive"
            )
        return self


class Conversation(v1.Wire):
    peer_account: v1.Account
    display_name: str | None = None
    last_message: v1.Message
    last_activity_at: str
    latest_position: Position


class ConversationPage(v1.Wire):
    items: list[Conversation]
    next_cursor: str | None


class MemberHistory(v1.Wire):
    history_through: Position
    membership_revision: Annotated[int, Field(ge=1, le=9007199254740991)]


class ConversationDisplay(v1.Wire):
    conversation: ConversationRef
    display_name: str
    last_message: v1.ChatMessage | None
    last_activity_at: str
    latest_position: Position


class GroupConversation(ConversationDisplay, MemberHistory):
    conversation: GroupConversationRef
    avatar_url: str
    avatar_version: str


class DirectConversation(Conversation):
    conversation: ConversationRef


class SharedConversationPage(v1.Wire):
    items: list[DirectConversation | GroupConversation]
    next_cursor: ConversationId | None


class ConsumerState(v1.Wire):
    latest_position: Position
    incoming_unread: Position
    latest_unread: MessagePreview | None

    # Positions in the complete bidirectional stream, NOT incoming unread count.
    consumed_through: Position
    unconsumed_positions: Position

    @model_validator(mode="after")
    def watermark(self):
        if self.unconsumed_positions != max(
            0, self.latest_position - self.consumed_through
        ):
            raise ValueError(
                "unconsumed_positions must agree with the consumer watermark"
            )
        if (self.incoming_unread > 0) != (self.latest_unread is not None):
            raise ValueError("unread count and preview must agree")
        return self


class ConsumerConversation(Conversation, ConsumerState):
    conversation: ConversationRef
    display_name: str


class ConsumerGroupConversation(GroupConversation, ConsumerState):
    pass


class ConsumerConversationPage(v1.Wire):
    items: list[ConsumerConversation | ConsumerGroupConversation]
    next_cursor: str | None


class PositionRange(v1.Wire):
    start_position: Position
    end_position: Position


class ContextMetadata(v1.Wire):
    peer_account: v1.Account | None = None
    conversation: GroupConversationRef | None = None
    anchor_message_id: MessageId
    range: PositionRange
    before_has_more: bool
    after_has_more: bool
    missing_positions: list[Position] = Field(max_length=100)
    missing_truncated: bool
    reply_relations: Literal["unsupported"] = "unsupported"

    @model_serializer(mode="wrap")
    def omit_unused_target(self, handler):
        value = handler(self)
        for key in ("peer_account", "conversation"):
            if value[key] is None:
                value.pop(key)
        return value


class MessageContext(ContextMetadata):
    items: list[v1.ChatMessage] = Field(min_length=1, max_length=99)


class VisibleQueryMessage(v1.Wire):
    item: v1.VisibleMessage
    missing_media_ids: list[str] = Field(max_length=100)


class VisibleContext(ContextMetadata):
    items: list[v1.VisibleMessage] = Field(min_length=1, max_length=99)
    missing_media_ids: list[str] = Field(max_length=9900)
