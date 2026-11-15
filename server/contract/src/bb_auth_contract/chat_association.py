"""Opt-in account-private message association. Legacy wire types stay strict."""

from pydantic import model_serializer

from . import chat, chat_query

HEADER = "X-BB-Message-Association"
VERSION = "1"


class AssociatedMessage(chat.Message):
    operation_id: chat.OperationId | None = None

    @model_serializer(mode="wrap")
    def omit_private_absence(self, handler):
        value = handler(self)
        if self.operation_id is None:
            value.pop("operation_id", None)
        return value


class AssociatedMessagePage(chat.MessagePage):
    items: list[AssociatedMessage]


class AssociatedOperation(chat.Operation):
    message: AssociatedMessage | None = None


class AssociatedConversation(chat_query.Conversation):
    last_message: AssociatedMessage


class AssociatedConversationPage(chat_query.ConversationPage):
    items: list[AssociatedConversation]


class AssociatedMessageContext(chat_query.MessageContext):
    items: list[AssociatedMessage]
