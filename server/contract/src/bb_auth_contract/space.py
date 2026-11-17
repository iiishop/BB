"""DEA-481 Space v1: sole DTO authority for server, local client and MCP.

Server POST /space/<action> uses the request directly and the existing bearer.
Local POST /v2/space/<action> uses LOCAL_REQUESTS and {identity, result}, behind
the existing owner capability/CAS fence. This module defines no new identity.
"""

from typing import Annotated, Literal, TypeVar

from pydantic import Field, create_model, model_validator

from .chat import Account, Wire
from .chat_v2 import ExpectedIdentity, Opaque, Position, Protected, Revision
from .media import MediaVariant

VERSION = "dea481-space-v1"
MAX_IMAGE_BYTES = 32 * 1024 * 1024
MAX_TEXT = 20000
Id = Opaque
Cursor = Annotated[str, Field(min_length=1, max_length=2048)]
Text = Annotated[str, Field(max_length=MAX_TEXT)]


class Empty(Wire):
    pass


class PageQuery(Wire):
    cursor: Cursor | None = None
    limit: int = Field(default=20, ge=1, le=100)


class Mutation(Wire):
    operation_id: Id


class PostKey(Wire):
    post_id: Id


class DraftKey(Wire):
    draft_id: Id


class CommentKey(Wire):
    comment_id: Id


class PostList(PageQuery):
    author: Account | None = None
    unread_only: bool = False
    scope: Literal["all", "following"] = "all"


class FollowTarget(Wire):
    target_account: Account


class SetFollow(FollowTarget):
    following: bool


class FollowState(FollowTarget):
    following: bool


class ProfileMonths(FollowTarget):
    # One fixed display offset per browsing session; no server regional default.
    timezone_offset_minutes: int = Field(ge=-840, le=840)


class ProfileTimeline(ProfileMonths, PageQuery):
    # Upper time bound, never an equality filter. Repeat on subsequent pages.
    month: (
        Annotated[str, Field(pattern=r"^(?:[1-9][0-9]{3})-(?:0[1-9]|1[0-2])$")] | None
    ) = None

    @model_validator(mode="after")
    def supported_year(self):
        if self.month is not None and self.month.startswith("9999-"):
            raise ValueError("month year must be at most 9998")
        return self


class ProfileMonth(Wire):
    year: int = Field(ge=1, le=9999)
    month: int = Field(ge=1, le=12)


class ProfileMonthDirectory(Wire):
    items: list[ProfileMonth]


class GetPost(PostKey):
    # Null is an explicit preview/prefetch. Active detail reads must supply an ID.
    visit_id: Id | None = None


class CreateDraft(Mutation):
    text: Text = ""
    reference_id: Id | None = None


class UpdateDraft(Mutation, DraftKey):
    expected_version: Revision
    text: Text
    reference_id: Id | None = None
    # Full ordered replacement. No nine-image product cap.
    image_ids: list[Id]

    @model_validator(mode="after")
    def unique_images(self):
        if len(set(self.image_ids)) != len(self.image_ids):
            raise ValueError("duplicate image IDs")
        return self


class DraftMutation(Mutation, DraftKey):
    expected_version: Revision


class AddImage(DraftMutation):
    filename: str = Field(min_length=1, max_length=255)
    # Complete upload appended atomically, retaining a stable ID for reorder/remove.
    base64: str = Field(min_length=1, max_length=4 * ((MAX_IMAGE_BYTES + 2) // 3))


class DeletePost(Mutation, PostKey):
    pass


class SetLike(DeletePost):
    liked: bool


class CreateComment(Mutation, PostKey):
    text: Text = Field(min_length=1)
    reply_to_id: Id | None = None

    @model_validator(mode="after")
    def nonblank(self):
        if not self.text.strip():
            raise ValueError("comment must not be blank")
        return self


class DeleteComment(Mutation, CommentKey):
    pass


class Comments(PostKey, PageQuery):
    # Null lists roots; otherwise lists all descendants, one level of indentation.
    root_id: Id | None = None


class Context(CommentKey):
    radius: int = Field(default=3, ge=0, le=20)


class PostPageQuery(PostKey, PageQuery):
    pass


class MarkRead(Mutation):
    post_ids: list[Id] = Field(min_length=1, max_length=100)


class AckVersion(Wire):
    notification_id: Id
    version: Revision


class AckNotifications(Mutation):
    items: list[AckVersion] = Field(min_length=1, max_length=100)


class Notifications(PageQuery):
    unread_only: bool = False


class Events(Wire):
    after_event_id: Position = 0
    limit: int = Field(default=100, ge=1, le=100)


class OperationGet(Wire):
    operation_id: Id


class GetImage(Wire):
    image_id: Id
    variant: MediaVariant = "original"


class ImageContent(Wire):
    image_id: Id
    mime_type: Literal["image/png", "image/jpeg", "image/webp"]
    base64: str


class Author(Wire):
    account: Account
    username: str
    avatar_url: str


class Image(Wire):
    image_id: Id
    filename: str
    mime_type: Literal["image/png", "image/jpeg", "image/webp"]
    byte_size: int
    original_url: str
    thumbnail_url: str


class Reference(Wire):
    post_id: Id
    deleted: bool
    author: Author | None = None
    text: str | None = None
    image: Image | None = None


class Comment(Wire):
    comment_id: Id
    post_id: Id
    root_id: Id
    reply_to_id: Id | None
    reply_to_author: Author | None
    author: Author
    created_at: str
    text: str | None
    deleted: bool
    can_delete: bool


T = TypeVar("T")


class Page[T](Wire):
    items: list[T]
    next_cursor: str | None
    has_more: bool


class Branch(Wire):
    root: Comment
    replies: list[Comment]
    remaining_replies: int


class Post(Wire):
    post_id: Id
    author: Author
    author_following: bool = False
    created_at: str
    text: str
    images: list[Image]
    reference: Reference | None
    liked: bool
    read: bool
    like_count: int
    comment_count: int
    root_count: int
    repost_count: int
    view_count: int
    can_delete: bool
    can_list_visitors: bool
    preview_comments: list[Branch]
    remaining_roots: int


class Draft(Wire):
    draft_id: Id
    version: Revision
    state: Literal["draft", "published", "deleted"]
    text: str
    reference_id: Id | None
    images: list[Image]
    post_id: Id | None
    created_at: str


class Operation(Wire):
    operation_id: Id
    status: Literal["succeeded"] = "succeeded"
    action: str
    resource_id: Id | None = None
    resource_version: Revision | None = None
    # Never store/return deleted text as an operation-result snapshot.


class CommentContext(Wire):
    post_id: Id
    root: Comment
    target: Comment
    parent: Comment | None
    nearby: list[Comment]
    before_cursor: str | None
    after_cursor: str | None


class Visitor(Wire):
    author: Author
    count: int
    last_visited_at: str


class ViewSummary(Wire):
    post_id: Id
    view_count: int


class Notification(Wire):
    notification_id: Id
    kind: Literal["like", "comment", "reply", "repost"]
    post_id: Id
    comment_id: Id | None
    target_post_id: Id
    version: Revision
    ack_version: Position
    unread: bool
    accessible: bool
    deleted: bool
    actors: list[Author]
    actor_count: int
    snippet: str | None
    created_at: str


class Overview(Wire):
    contract: Literal[VERSION] = VERSION
    unread_posts: int
    unread_notifications: int
    latest_event_id: Position


class Event(Wire):
    version: Literal[1] = 1
    event_id: Position
    type: Literal[
        "post.changed",
        "post.deleted",
        "comment.deleted",
        "notification.changed",
        "read.changed",
        "draft.changed",
        "follow.changed",
    ]
    post_id: Id | None
    comment_id: Id | None
    notification_id: Id | None
    occurred_at: str


class EventPage(Wire):
    items: list[Event]
    next_event_id: Position
    has_more: bool


# Real routes, generated schemas and test requests consume this same registry.
REQUESTS = {
    "get_follow": FollowTarget,
    "set_follow": SetFollow,
    "list_profile_posts": ProfileTimeline,
    "list_profile_months": ProfileMonths,
    "get_image": GetImage,
    "overview": Empty,
    "list_posts": PostList,
    "get_post": GetPost,
    "create_draft": CreateDraft,
    "get_draft": DraftKey,
    "list_drafts": PageQuery,
    "update_draft": UpdateDraft,
    "add_image": AddImage,
    "publish_draft": DraftMutation,
    "delete_draft": DraftMutation,
    "delete_post": DeletePost,
    "set_like": SetLike,
    "create_comment": CreateComment,
    "delete_comment": DeleteComment,
    "list_comments": Comments,
    "get_comment_context": Context,
    "list_likes": PostPageQuery,
    "mark_read": MarkRead,
    "list_notifications": Notifications,
    "ack_notifications": AckNotifications,
    "get_view_summary": PostKey,
    "list_visitors": PostPageQuery,
    "get_operation": OperationGet,
    "read_events": Events,
}
RESPONSES = {
    "get_follow": FollowState,
    "set_follow": FollowState,
    "list_profile_posts": Page[Post],
    "list_profile_months": ProfileMonthDirectory,
    "get_image": ImageContent,
    "overview": Overview,
    "list_posts": Page[Post],
    "get_post": Post,
    "get_draft": Draft,
    "list_drafts": Page[Draft],
    "list_comments": Page[Comment],
    "get_comment_context": CommentContext,
    "list_likes": Page[Author],
    "list_notifications": Page[Notification],
    "get_view_summary": ViewSummary,
    "list_visitors": Page[Visitor],
    "read_events": EventPage,
}
for _action in REQUESTS:
    RESPONSES.setdefault(_action, Operation)

LOCAL_REQUESTS = {
    name: create_model("LocalSpace" + model.__name__, __base__=(Protected, model))
    for name, model in REQUESTS.items()
}


class LocalResult[T](Wire):
    identity: ExpectedIdentity
    result: T


LOCAL_RESPONSES = {name: LocalResult[model] for name, model in RESPONSES.items()}
