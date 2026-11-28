"""Authorized group mentions, by recipient account."""

from typing import Annotated

from pydantic import Field, model_validator

from .chat import Account, Image, LocalImage, OperationId, Text
from .chat_alerts import PositivePosition
from .chat_query import MessageId
from .conversation import GroupConversationId, GroupConversationRef
from .wire import Wire

DETAIL_PATH = "/chat/mentions/list"


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


class GroupMentionSend(Wire):
    conversation: GroupConversationRef
    operation_id: OperationId
    mentioned_accounts: list[Account] = Field(
        min_length=1, max_length=100, json_schema_extra={"uniqueItems": True}
    )
    content: list[Annotated[Text | LocalImage, Field(discriminator="type")]] = Field(
        min_length=1, max_length=100
    )

    @model_validator(mode="after")
    def unique_recipients(self):
        if len(set(self.mentioned_accounts)) != len(self.mentioned_accounts):
            raise ValueError("mention accounts must be unique")
        return self
