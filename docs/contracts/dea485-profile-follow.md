# DEA-485 personal timeline and following (revision 1)

Product authority: DEA-485 approved issue specification, acceptance cases 1–13.
Base: `246c690bd4cca4832b3d53c5757eb804e92f3531`. This is an additive
extension of Space v1, not a new account system. Machine authority remains
`server/contract/src/bb_auth_contract/space.py`; regenerate
`server/contract/space-v1.json` with the existing `export_space.py` command.
Existing chat, Profile, Space and MCP operations remain supported. No new MCP
tool or local adapter implementation is part of the server change.

All requests below are JSON POST `/space/<action>` under the existing bearer
session. Unknown fields are rejected. Success is 200. Identity/heading/signature
reuse GET `/users/{account}/profile`; account means the existing eight-digit ID.

| Action | Request | Result |
| --- | --- | --- |
| get_follow | `{target_account}` | `{target_account,following}` |
| set_follow | `{target_account,following}` | `{target_account,following}` |
| list_profile_posts | `{target_account,timezone_offset_minutes,month?,cursor?,limit?}` | existing `Page[Post]`: `{items,next_cursor,has_more}` |
| list_profile_months | `{target_account,timezone_offset_minutes}` | `{items:[{year,month},...]}` descending, only nonempty visible months |
| list_posts | existing fields plus `scope:"all"\|"following"` (default `all`) | existing `Page[Post]` |

`Post.author_following` is an additive boolean, scoped to the authenticated
viewer, in list/detail responses. The publisher is `Post.author.account`;
`Post.created_at` is the timeline instant and `Post.post_id` breaks ties.
A repost is the publisher's own existing post, with its own publication time;
the direct source remains `Post.reference` under the existing live/tombstone
projection. Likes/comments never create timeline entries. Current Space v1
visibility is all authenticated accounts' nondeleted published posts; private
drafts are never included. Follow never changes access permissions.

## Time and pagination

`created_at` remains UTC RFC3339 with microseconds. The client captures its
display offset in minutes east of UTC when opening a profile session (integer
−840…840), sends it on both directory and timeline requests, and renders dates
by adding that same offset to UTC. This is an explicit fixed-offset browsing
policy, including historical dates, not an IANA zone or a server-region guess.
Do not render these dates with an independently changing `toLocal()` offset.
Changing the display offset starts a fresh directory/list query. No regional
timezone is hardcoded. Fixed offset avoids an OS timezone database dependency.

`month` is `YYYY-MM`, years 1000…9998. Null/omitted means latest. A selected
month applies an exclusive upper bound of the next local month's midnight,
converted to UTC. Thus October starts at October's latest visible post and
continues through September/July, with no lower bound and no August placeholder.
For a stale/empty selected month it starts at the latest earlier visible post.
Repeat target, offset and selected month when sending `next_cursor`.

Sort is `(created_at,post_id)` descending. Publication sequence high-water mark
prevents later equal/backdated inserts from entering an existing traversal.
Cursors bind action, viewer, target/author, unread filter, mode, selected month,
display offset, and (for following mode) viewer's follow revision. A cursor from
another query is 422 `validation_error`; following changes invalidate an old
following cursor with the same error. Refresh that view from its first page.
Limit may change between pages. Cursors are opaque continuations, not access
capabilities; all current authorization/filtering is reapplied on every page.
Existing cursors should be discarded when upgrading to this extension.
Directory and each page are separate current DB snapshots: deletion may remove
an entry between requests; no frozen content snapshot is promised.

## Follow state, persistence and invalidation

`set_follow` sets the desired boolean on the authenticated viewer→target row.
It deliberately needs no operation ID or separate receipt: duplicate desired
states are no-ops and the result is authoritative at transaction completion.
For an unknown network outcome, use `get_follow` to reconcile before retrying;
serialize writes per target so an old user intent is not retried over a new one.
`get_follow` for self returns false; `set_follow` for self rejects either boolean.
Unknown target returns 404 even for an unfollow.

Absent→present / present→absent changes the relationship, increments the viewer's
monotonic revision, and appends recipient-only `follow.changed` in one existing
BEGIN IMMEDIATE transaction. Desired state already satisfied performs no write
or event. Commit occurs before HTTP success. A DB failure rolls back relationship,
revision and event together; a lost reply is reconciled from persisted state.
The new event has null post/comment/notification IDs: refetch the viewer's follow
state and invalidate the following feed; it is not a notification to the target.
The response and this existing replay stream are the client's invalidation
inputs. One client state owner updates all corresponding cards/profile displays.

`following` feed filters by the **publisher**, including their own reposts and
their pre-follow history. It never falls back to all. Following yourself is
disallowed, so your own posts do not enter this scope. Other users' relationships
are never exposed through these actions. Client session switch/scroll rules are
owned by the client; the server persists only the relationship and its revision.

## Errors and migration

Use existing `{error:{code,message,fields}}`, with `fields:[]` for domain errors.
401 `unauthenticated`; 404 `not_found` for nonexistent target; 422
`validation_error` for self-follow, invalid offset/month/cursor/unknown fields;
503 existing storage failure codes (`storage_busy`, `storage_io_error`,
`storage_unavailable`). No second error
format or new permission scope is introduced. Existing forbidden operations
remain 403. Never include bearer/body input in errors.

Schema 5 adds `space_follows` (unique viewer/target, FK accounts, self CHECK) and
`space_follow_versions` (one revision per viewer). Existing posts, drafts,
messages, identities, sessions and operation receipts are retained. Existing
author/time indexes serve profile queries. New installs and upgrades use the
same transactional migration entry; failure leaves v4 and its data intact.
No downgrade: older binaries reject schema 5. Rollback requires stopping the
candidate and restoring an owner-approved pre-upgrade backup. Only isolated
synthetic databases are used by this delivery; no production migration runs.
