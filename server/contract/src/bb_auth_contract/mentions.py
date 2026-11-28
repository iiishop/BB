"""Group mention queries and the explicit client visibility acknowledgement."""

from typing import Annotated

from pydantic import Field

from .chat import Account, Image, Text
from .chat_query import MessageId, Position
from .conversation import GroupConversationId
from .wire import Wire

SUMMARY_PATH = "/chat/mentions/summary"
DETAIL_PATH = "/chat/mentions/list"
SEEN_PATH = "/chat/mentions/mark_seen"
PositivePosition = Annotated[int, Field(ge=1, le=9007199254740991)]


class MentionSummaryQuery(Wire):
    after_conversation_id: GroupConversationId | None = None
    limit: int = Field(default=50, ge=1, le=100)


class MentionSummary(Wire):
    conversation_id: GroupConversationId
    group_name: str
    unread_count: PositivePosition


class MentionSummaryPage(Wire):
    items: list[MentionSummary]
    next_cursor: GroupConversationId | None


class MentionQuery(Wire):
    conversation_id: GroupConversationId
    before_position: PositivePosition | None = None
    limit: int = Field(default=50, ge=1, le=100)


class MentionMessage(Wire):
    message_id: MessageId
    position: PositivePosition
    sender_account: Account
    sender_username: str
    created_at: str
    content: list[Annotated[Text | Image, Field(discriminator="type")]]


class MentionPage(Wire):
    items: list[MentionMessage]
    next_cursor: PositivePosition | None


class MarkMentionsSeen(Wire):
    conversation_id: GroupConversationId
    message_ids: list[MessageId] = Field(min_length=1, max_length=100)


class MentionReadState(Wire):
    unread_count: Position
