"""Group management and general BB notifications shared by HTTP and local tools."""

from typing import Annotated, Literal

from pydantic import Field, StringConstraints, model_validator

from .chat import Account, OpaqueId, OperationId, Source, Wire
from .conversation import GroupConversationRef, GroupNumber

Name = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)
]
Description = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)]
PROFILE_REVISION_HEADER = "X-BB-Group-Profile-Revision"
PROFILE_REVISION_PATTERN = r"^[0-9]+\.[1-9][0-9]*\.[0-9]+$"


class GroupNumberRequest(Wire):
    group_number: GroupNumber


class GroupTarget(Wire):
    conversation: GroupConversationRef


class GroupCreate(Wire):
    operation_id: OperationId
    name: Name
    description: Description = ""
    invitees: list[Account] = Field(default_factory=list, max_length=100)
    avatar: Source | None = None


class GroupUpdate(GroupTarget):
    name: Name | None = None
    description: Description | None = None
    allow_member_invites: bool | None = None
    avatar: Source | None = None
    reset_avatar: bool = False

    @model_validator(mode="after")
    def one_avatar_action(self):
        if self.avatar is not None and self.reset_avatar:
            raise ValueError("select one avatar action")
        return self


class GroupProfile(GroupTarget, GroupNumberRequest):
    name: Name
    description: Description
    avatar_url: str
    avatar_version: str
    status: Literal["active", "dissolved"]
    # Viewer-relative only. Public lookup does not disclose the owner account.
    role: Literal["owner", "member"] | None = None
    can_invite: bool = False
    allow_member_invites: bool | None = None


class DirectoryQuery(Wire):
    after_account: str = Field(default="", pattern=r"^([1-9][0-9]{7})?$")
    limit: int = Field(default=50, ge=1, le=100)


class DirectoryUser(Wire):
    account: Account
    username: str
    avatar_url: str
    avatar_version: str
    presence: Literal["online", "offline"]


class DirectoryPage(Wire):
    items: list[DirectoryUser]
    next_cursor: Account | None


class GroupMember(DirectoryUser):
    role: Literal["owner", "member"]


class GroupMemberPage(Wire):
    items: list[GroupMember]
    next_cursor: Account | None


class GroupMembers(GroupTarget, DirectoryQuery):
    pass


class GroupInvite(GroupTarget):
    accounts: list[Account] = Field(min_length=1, max_length=100)


class GroupRemove(GroupTarget):
    account: Account


class NoticeAction(Wire):
    id: OpaqueId
    label: str
    available: bool


class NoticeLink(Wire):
    type: OpaqueId
    id: OpaqueId


class Notice(Wire):
    id: OpaqueId
    type: OpaqueId
    title: str
    text: str
    created_at: str
    read: bool
    state: Literal["informational", "pending", "processed", "invalidated"]
    actions: list[NoticeAction]
    link: NoticeLink | None = None


class Notices(Wire):
    filter: Literal["all", "pending"] = "all"
    cursor: OpaqueId | None = None
    limit: int = Field(default=50, ge=1, le=100)


class NoticePage(Wire):
    items: list[Notice]
    next_cursor: OpaqueId | None
    unread_count: int = Field(ge=0)
    pending_count: int = Field(ge=0)


class NoticeId(Wire):
    notification_id: OpaqueId


class NoticeActionRequest(NoticeId):
    action_id: OpaqueId


class GroupRequests(Wire):
    request_ids: list[OpaqueId]


class AvatarBytes(Wire):
    base64: str = Field(min_length=1, max_length=10_000_000)
    mime_type: Literal["image/png", "image/jpeg", "image/webp"]


class RemoteGroupCreate(GroupCreate):
    avatar: AvatarBytes | None = None


class RemoteGroupUpdate(GroupUpdate):
    avatar: AvatarBytes | None = None


class RemoteGroupMembers(GroupMembers):
    include_counts: bool = Field(
        default=False, description="Include counts for the entire active group."
    )


class GroupMemberCounts(Wire):
    online: int = Field(ge=0, description="Active members with an online session.")
    total: int = Field(ge=0, description="Number of active members in the group.")


class RemoteGroupMemberPage(GroupMemberPage):
    counts: GroupMemberCounts | None = Field(
        default=None,
        description="Whole-group counts from the same snapshot as the page, omitted unless requested.",
    )


# operation -> (JSON POST path, strict request, response). Authentication is the BB server session.
REMOTE = {
    "create_group": ("/chat/groups/create", RemoteGroupCreate, GroupProfile),
    "find_group": ("/chat/groups/find", GroupNumberRequest, GroupProfile),
    "update_group": ("/chat/groups/update", RemoteGroupUpdate, GroupProfile),
    "list_directory": ("/chat/directory/list", DirectoryQuery, DirectoryPage),
    "list_group_members": (
        "/chat/groups/members",
        RemoteGroupMembers,
        RemoteGroupMemberPage,
    ),
    "invite_to_group": ("/chat/groups/invite", GroupInvite, GroupRequests),
    "apply_to_group": ("/chat/groups/apply", GroupTarget, GroupRequests),
    "leave_group": ("/chat/groups/leave", GroupTarget, GroupProfile),
    "remove_group_member": ("/chat/groups/remove_member", GroupRemove, GroupProfile),
    "dissolve_group": ("/chat/groups/dissolve", GroupTarget, GroupProfile),
    "list_notices": ("/chat/notices/list", Notices, NoticePage),
    "mark_notice_read": ("/chat/notices/mark_read", NoticeId, Notice),
    "execute_notice_action": (
        "/chat/notices/execute_action",
        NoticeActionRequest,
        Notice,
    ),
}
