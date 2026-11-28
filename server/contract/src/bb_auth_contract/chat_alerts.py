"""Shared unread mention/reply protocol for direct and group chats."""

from typing import Annotated

from pydantic import Field

from .chat_query import MessageId, Position
from .conversation import ConversationId
from .wire import Wire

SUMMARY_PATH = "/chat/alerts/summary"
LIST_PATH = "/chat/alerts/list"
SEEN_PATH = "/chat/alerts/mark_seen"
PositivePosition = Annotated[int, Field(ge=1, le=9007199254740991)]


class AlertSummaryQuery(Wire):
    after_conversation_id: ConversationId | None = None
    limit: int = Field(default=50, ge=1, le=100)


class AlertCounts(Wire):
    unread_mention_count: Position
    unread_reply_count: Position


class AlertSummary(AlertCounts):
    conversation_id: ConversationId
    display_name: str


class AlertSummaryPage(Wire):
    items: list[AlertSummary]
    next_cursor: ConversationId | None


class AlertQuery(Wire):
    conversation_id: ConversationId
    before_position: PositivePosition | None = None
    limit: int = Field(default=50, ge=1, le=100)


class UnreadAlert(Wire):
    message_id: MessageId
    position: PositivePosition
    mention: bool
    reply: bool


class AlertPage(Wire):
    items: list[UnreadAlert]
    next_cursor: PositivePosition | None


class ClientAlertSummary(AlertSummary):
    latest_alert: UnreadAlert


class ClientAlertSummaryPage(AlertSummaryPage):
    items: list[ClientAlertSummary]


class MarkAlertsSeen(Wire):
    conversation_id: ConversationId
    message_ids: list[MessageId] = Field(min_length=1, max_length=100)
