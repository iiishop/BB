# DEA-481 Space v1

Product authority: `docs/design/dea481-approved-space.md` (Orion's revision-1
product specification, captured from issue record revision 3). Sole machine
authority: `server/contract/src/bb_auth_contract/space.py`, exported with
`uv run --project server --locked python server/contract/export_space.py`.
`server/contract/space-v1.json` contains all request/response and local-envelope
schemas. Do not copy a second hand-maintained protocol into callers.

## Authorization and transport

All actions are JSON POST `/space/<action>` using the existing server bearer
session. Actor is always the authenticated account. Unknown fields are rejected.
No new Account/Actor identity, consumer enrollment or password mechanism exists.
Local client adapters will expose POST `/v2/space/<action>` with the same fields
plus mandatory `expected_identity`; the existing `X-BB-Consumer-Key`, generation,
owner/CAS and in-flight identity fences apply. Responses are `{identity,result}`.
These local schemas describe the next integration phase, not implemented local
routes in this server-only milestone. MCP must call that adapter, never SQLite or
the server with credentials borrowed from another account.

`overview` discovers `contract=dea481-space-v1`. An older server's 404 means
unsupported; do not disable chat, silently pretend space is empty, or downgrade
the existing v2 identity protocol. Old chat/Profile routes and events stay intact.

## Actions and result flow

| Action | Behavior |
| --- | --- |
| overview | Counts unread posts/interactions and current visible event cursor; no read/visit mutation |
| list_posts | Descending creation time + ID; optional author and sparse unread filter |
| get_post | Complete body, ordered images, one direct reference, 5 root/3 reply previews; explicit nullable visit_id |
| create_draft, get_draft, list_drafts | Private author scope; create may be empty or reference an existing post |
| update_draft | Compare expected_version; replace text/reference/full ordered image_ids; removing/reordering images uses stable IDs |
| add_image | Compare expected_version; validated base64 PNG/JPEG/WebP, atomically append completed image, increment version |
| publish_draft | Compare expected_version; commit one immutable post from that version; original needs nonblank text or ready image, reference-only repost allowed |
| delete_draft, delete_post | Distinct actions; author only; draft deletion compares version |
| set_like | Set desired boolean state; one active row per account/post |
| create_comment, delete_comment | Nonblank text, immutable; optional live reply target in same post; author only deletion |
| list_comments | root_id null: roots ascending; root_id set: all descendants ascending, no recursive expansion |
| get_comment_context | Direct indexed target/root/parent lookup plus bounded neighbors, even if target is on an unloaded page |
| list_likes | Bounded active liker page |
| mark_read | Explicit 1..100 IDs, idempotent; no timeline-wide watermark |
| list_notifications, ack_notifications | Bounded interaction records; acknowledgement includes each observed version |
| get_view_summary, list_visitors | Public authenticated total; details strictly author-only |
| get_operation | Account-scoped operation reconciliation; stable IDs, never content snapshots |
| read_events | Persisted invalidations after event ID, bounded; no auto-consumption or acknowledgement |

Mutations require an operation_id and return `Operation`: resource_id is a draft
ID for draft create/update/delete, image ID for add_image, post ID for publish/
delete/like, comment ID for create/delete. resource_version is the resulting draft
version for draft actions including image append and publish. Fetch facts using
the returned ID. Mark-read/notification acknowledgement have no resource ID.
`get_operation` uses the same result. Replaying a committed operation returns its
original ID/version even after later edits/deletion; it never restores content.
The caller must query the current resource. Same ID with another action/payload
is 409 idempotency_conflict. IDs are account-scoped; callers must use globally
unique logical operation IDs across consumers. Local operations remain scoped
by the existing consumer journal; space does not bypass its uncertainty rules.
Network loss/503: query the same operation before retrying, never invent a new ID.
A 404 lookup is not proof that a concurrently in-flight request cannot commit.

`get_post` with visit_id records one account/post visit, retries share that ID.
Changing post for the same account/visit ID is a conflict. Null explicitly means
preview/prefetch, not an active detail visit. Visits and mark_read are independent.
Images/comments/visitor pages/reference previews never increment visits. Author
visits count. UI rebuilds and window changes must keep the active visit ID.

## State transitions, deletion and durable events

Draft: private draft(v) -> draft(v+1) / published(v+1, post_id) / deleted(v+1).
Publish clears the draft's body/image references; the immutable post owns them.
Post: live -> tombstone (ID/author/time/direct reference only, blank body).
Comment: live -> relation tombstone (ID/root/parent/author/time, null body).
Deleted parents retain live descendants; new replies to a tombstone are refused.
Post deletion removes all its comment/like/read/visit rows and image references.
Independent reposts survive and resolve their direct source to deleted status.

Each writer uses the existing SQLite BEGIN IMMEDIATE boundary: check identity
scope/resource/version -> write business rows -> write notification/invalidation
rows -> write operation receipt -> COMMIT -> return. A failure in any DB write
rolls all of these back. A post deletion serializes against comment/repost writes.
File upload writes complete validated bytes durably before making the DB image
reference visible. Deletion removes visibility/references and queues cleanup in
the transaction; cleanup is repeatable after commit and at restart. Live shared
space blobs are reference-counted by query, never deleted because one post died.
Private chat media are not made public or collected by space cleanup.

GET `/space/images/{image_id}?variant=original|thumb` uses existing bearer auth,
original bytes and shared thumbnail generator. Authorization is checked against
current live post or owned draft references before every response (including
conditional requests). No direct public file mount exists. Responses are private
no-store. Maximum decoded file size is the existing 32 MiB media limit; text is
20,000 code points, request envelope 48 MiB, response pages at most 100. Nine is
only a UI preview count, never an attachment limit. Content formats outside
PNG/JPEG/WebP are rejected; image validation does not trust the filename.

Events use the existing durable replay + WebSocket transport pattern, isolated
from the chat event stream: POST read_events and WebSocket `/space/events` with
bearer auth and `after_event_id` query. Global post/comment invalidations are
visible to every account; notification/read/draft invalidations are recipient
scoped. IDs are monotonically increasing, possibly sparse per account. Store the
last processed cursor only after applying invalidations; deduplicate by ID and
refetch current facts. No event contains body text, images, or notification
snippets. Reconnect reads all pages before treating local cached content as fresh.
The server retains events in this version; no arbitrary retention gap is implied.

## Notifications and pagination

Only direct post author (comment/like), immediate parent author (reply), or direct
source author (repost) receives a notification; self actions do not notify.
Likes aggregate by post, with a monotonic event version and active-account count.
A given liker raises its notification version only on its first like for that
post; unlike/re-like updates membership without generating unlimited reminders.
New people increment version; ack of v cannot acknowledge v+1. Acknowledgement
never accepts a future version and never lowers the stored ack watermark.
Empty like aggregates are hidden. Explicit repeated set_like with a new operation
ID is still a no-op when the desired membership already holds.

Notifications store IDs, not snippets. Snippets and accessibility resolve live
targets at read time. A deleted comment shows no old text; a live child remains
locatable. A repost notification targets the new post, so deleting its source
does not remove the repost's own text or make that target inaccessible.

Cursors are opaque, versioned and query/account-scoped keysets, not offsets.
Rows sort by created_at plus stable ID (ascending comments, descending posts,
drafts and notifications); likes/visitors use account order. New posts do not
move older pages. Unread filtering is evaluated against current explicit reads.
Context before_cursor is the predecessor anchor before the returned window;
after_cursor continues after it, with the same root query scope. Deletion may
remove rows between pages; no promise of a frozen database snapshot is made.

Errors use existing `{error:{code,message,fields}}`: 401 unauthenticated;
403 forbidden (only author visitor details/deletion); 404 not_found (missing,
deleted, private draft/image); 409 version_conflict, invalid_state,
idempotency_conflict, source_deleted; 422 validation_error, attachments_not_ready;
413 payload_too_large; 415 unsupported_media_type; 503 existing storage failures.
Never echo credential/body/base64 input in errors. UI can_delete is a hint only.

## Migration and rollback

Schema 4 adds only `space_*` tables/indexes within the existing migration
transaction. Users, sessions, private messages/media/events are unchanged.
Synthetic v3 upgrade and injected rollback are required regression cases.
Old binaries reject schema 4 rather than dropping unknown data. Rollback needs
stopping the candidate and restoring a pre-upgrade backup under owner approval;
there is no automatic downgrade/destructive migration. No production migration
has been authorized or executed.
