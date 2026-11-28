"""DEA-519 reply queries and the owner-scoped operation arguments."""

from typing import Annotated

from pydantic import Field

from .chat import ChatMessage, LocalImage, OperationId, Text, UserMessage
from .chat_query import MessageId
from .conversation import ConversationId, ConversationRef
from .wire import Wire

UNREAD_PATH = "/chat/replies/unread"
DIRECT_PATH = "/chat/replies/direct"
UnreadPosition = Annotated[int, Field(ge=1, le=9007199254740991)]


class ReplyPageQuery(Wire):
    before_position: UnreadPosition | None = None
    limit: int = Field(default=50, ge=1, le=100)


class UnreadRepliesQuery(ReplyPageQuery):
    conversation_id: ConversationId


class DirectRepliesQuery(ReplyPageQuery):
    original_message_id: MessageId


class ReplyMessage(UserMessage):
    sender_username: str


class UnreadReply(Wire):
    reply: ReplyMessage
    original: ChatMessage


class UnreadReplyPage(Wire):
    items: list[UnreadReply]
    next_cursor: UnreadPosition | None


class DirectReplyPage(Wire):
    items: list[ReplyMessage]
    next_cursor: UnreadPosition | None


class SendReply(Wire):
    conversation: ConversationRef
    reply_to_message_id: MessageId
    operation_id: OperationId
    content: list[Annotated[Text | LocalImage, Field(discriminator="type")]] = Field(
        min_length=1, max_length=100
    )
