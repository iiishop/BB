"""Stable BB conversation addresses. A public group number is a lookup key only."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from .wire import Wire

DIRECT_PATTERN = r"dm:[1-9][0-9]{7}:[1-9][0-9]{7}"
GROUP_PATTERN = r"group:[a-f0-9]{32}"
CONVERSATION_PATTERN = rf"^({DIRECT_PATTERN}|{GROUP_PATTERN})$"
ConversationId = Annotated[str, Field(pattern=CONVERSATION_PATTERN)]
GroupConversationId = Annotated[str, Field(pattern=rf"^{GROUP_PATTERN}$")]
GroupNumber = Annotated[str, Field(pattern=r"^[1-9][0-9]{7}$")]


class ConversationRef(Wire):
    type: Literal["direct", "group"] = "direct"
    id: ConversationId

    @model_validator(mode="after")
    def canonical(self):
        if self.type == "group":
            if not self.id.startswith("group:"):
                raise ValueError("group conversation requires a group ID")
        else:
            if not self.id.startswith("dm:"):
                raise ValueError("direct conversation requires a direct ID")
            _, low, high = self.id.split(":")
            if low >= high:
                raise ValueError(
                    "direct conversation requires two sorted distinct accounts"
                )
        return self


class GroupConversationRef(ConversationRef):
    type: Literal["group"]
    id: GroupConversationId


def direct_id(first: str, second: str) -> str:
    low, high = sorted((first, second))
    return f"dm:{low}:{high}"
