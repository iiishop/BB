# DEA-481 Space client surface

Owner: Muse (DEA-483). Scope: the human client path for BB Space — phone, PC and
fold/narrow-window layouts, feed/detail/compose/notifications/visits, client
state preservation and the local unsynced-input buffer.

This document describes the Flutter implementation under
`client/lib/ui/space/`. The wire contract is not defined here; every request and
response is consumed from Forge's generated `SpaceService`/`SpaceApiClient`
(`server/contract` is the only machine authority). The client consumes the
typed client SHA `3887595` (parent `d402ba8`, the server/contract tree used for
this task).

## Files

| File | Responsibility |
| --- | --- |
| `space_gateway.dart` | UI-facing port `SpaceGateway`, production adapter over `SpaceService`, typed error copy, base64 image transfer |
| `space_controller.dart` | Feed pages, unread overview, notification/draft lists, section state, detail stack, visit IDs, single HTTP event replay loop |
| `space_detail_controller.dart` | One active visit: post, root comment page, on-demand replies, focus context, like, comment, delete, visitors/likes |
| `space_compose_controller.dart` | Server draft + local buffer, debounced autosave, conflict/offline states, image add/reorder, publish gating, discard |
| `space_page.dart` | The signed-in Space surface and its three layout modes |
| `space_layout.dart` | Breakpoints, hinge/cutout resolution, pane split, occlusion band |
| `space_widgets.dart` | Post card (four-line fade), ordered nine-image preview, reference card, header, states/banners |
| `space_detail_view.dart` | Full post, ordered images, comment tree (two display levels), composer, visitor/like entry |
| `space_image_viewer.dart` | Full-screen viewer for the current post only; original bytes, prev/next, save, keyboard left/right/escape, account-scoped cache |
| `space_compose_page.dart` | Width-capped editor, drag plus explicit up/down ordering, save/conflict/offline banners |
| `space_lists_view.dart` | Interaction notifications and the draft box |
| `space_people_sheets.dart` | Author visitor details and like list |
| `space_local_store.dart` | Process-local, `server|account`-scoped unsynced text/image-order/composer buffers |

Entry wiring is limited to `main.dart`, `app.dart`, `ui/auth_flow.dart` and
`ui/home_view.dart`. `ui/space/` never imports `ui/chat/` internals except the
existing public `MediaActions` picker and `PlatformGallerySaver`; no chat,
Windows-native, workflow, lockfile or shared-service file was changed.

## Form factors

Breakpoints were chosen after rendering at phone, PC and simulated-fold sizes.
They are UI policy, not device names:

| Mode | Condition | Layout |
| --- | --- | --- |
| Phone | available width < 720 | App bottom bar 聊天 / BB空间; Space top header with publish + notifications; one pane; detail replaces the feed in place |
| Narrow PC | 720 ≤ available width < 900 | Left rail; centered single feed (max 760); detail replaces the feed |
| Wide PC | available width ≥ 900 | Left rail; master-detail: feed pane + independent detail pane; closing detail returns to the centered single feed |
| Vertical fold | platform `DisplayFeature` hinge | Hinge is the pane boundary; panes stop 8 px either side. If either side is < 320, the layout falls back to the larger single side |
| Horizontal fold/cutout | platform `DisplayFeature` | Content is confined to the larger usable band; it never crosses the occlusion |

The rail consumes 92 px; `HomeView` shifts the Space media rectangle and display
feature coordinates by that amount so a hinge remains a real pane boundary.
The signed-in tree keeps the rail slot and `IndexedStack` at stable positions
across breakpoints, so resizing cannot recreate the Space or chat state.

Compose is capped at 980 px. At ≥ 1000 px available width, text and image order
sit side by side; otherwise they stack. Drag reordering always has explicit
up/down buttons that are available without hover.

## State semantics

- **Visit and read are separate.** A `visit_id` is created on an active open and
  reused for retries, comment refreshes and every resize. Closing the detail
  disposes it. `markRead` is sent only for the opened post, once per visit, and
  never for list/preview reads. Images and comments add no visit.
- **Detail history is local.** A reference opens the direct source in the same
  pane (or in place on phone); back returns through C → B → A without losing the
  left-hand feed position or minting a second visit for a post already open.
- **Scroll and input survive.** Feed scroll is stored in `PageStorage`; unsent
  comment text and reply target are stored per post in the scoped local store;
  the image viewer keeps its index across resize.
- **Notifications are explicit.** Loading the list or resizing never
  acknowledges. Tapping an accessible target acknowledges only the observed
  version; "全部标读" is a separate action. A deleted/inaccessible target
  acknowledges without opening a broken detail.
- **Old server.** `overview` returning `unsupported_space` (404) shows a
  capability notice; chat/login/profile stay available. Network failure is shown
  as offline and never as an empty feed or "no notifications".

## Draft lifecycle

1. Entering compose creates a private server draft (or loads an existing one).
2. Text edits are buffered locally immediately, then saved after a 700 ms
   debounce with the current draft version.
3. States are visible: creating, saving, saved, unsaved changes, conflict,
   offline local-only, failed. A conflict never overwrites either side; the
   local text/order stays and an explicit "载入服务器版本" action is offered.
4. Images upload before publish; failures stay as retryable pending tiles and
   block publish. Removing/reordering uses stable image IDs.
5. Publish is enabled only for a saved version with no pending/failed uploads
   and nonblank text, one image, or a valid reference. The result is a stable
   post ID; the draft is removed locally immediately.
6. "关闭" keeps the draft; "丢弃草稿" is a distinct confirmed delete. The draft
   box lists existing drafts and can discard them.

The local buffer is process-local. It survives navigation, tab switches,
account isolation via `server|account` scope, resize and reconnects in one
process; it is not a second durable fact and does not pretend the server saved.

## Tests

Commands and results are in `docs/evidence/dea481-client/`:

- `flutter analyze` — clean.
- `flutter test` — 676 passed, 12 skipped.
- Focused Space widget/state tests — 52 passed.
- Real HTTP round trip through `SpaceServiceGateway` against an isolated server
  — 1 passed.
- Opt-in rendered screenshots — 2 passed, 10 widget renders.
- Linux release client run against the isolated server — screenshots in the
  same evidence directory (real window, not a widget render).

NOT RUN / retained gaps: Android and Windows runtime, a physical fold device,
real DSH plugin lifecycle and model vision (Forge/sibling scope), network
WebSocket push (locked server lacks a Uvicorn WebSocket backend; HTTP replay is
the authoritative path), multi-device concurrent editing, real screen readers
and IMEs, a real user-uploaded avatar photo (the avatar path is covered with
fixture PNG bytes; the server's identicon/upload endpoint is Forge's test
scope).

## Avatar fix after integration (follow-up to `63b16f6`)

Forge found that `SpaceAvatar` always rendered initials and ignored
`SpaceAuthor.avatarUrl`. The follow-up keeps the existing authorized Profile
entry: every card/comment/people row asks `ProfileGateway.loadAvatar(account:)`
once per page visit, which owns the token, ETag revalidation and shared avatar
cache. `SpaceAvatar` shows `Image.memory` from those bytes and keeps the
deterministic initials only while loading or after a failed fetch. No new wire
contract, avatar transport or persistent cache was added; Forge's
`space_service.dart`/DTOs are untouched.

- `flutter analyze` — clean.
- `flutter test` — 683 passed, 12 skipped (previous 678 + 5 avatar regressions).
- Focused Space widget/state tests — 59 passed.
- New `test/space_avatar_test.dart`: real bytes replace initials and are
  requested once per account; empty `avatarUrl` and a failed fetch keep
  initials without a retry loop; the likes sheet reuses the page's store; a
  `SpacePage` without a profile gateway keeps initials.
- Raw logs: `docs/evidence/dea481-client/avatar-fix/`.

## QA fix round after Sentinel candidate `942dd46a`

Sentinel found three client state defects on the combined candidate; all are
fixed on this branch without touching the wire contract or server code.

- An in-flight `update_draft` response no longer marks text typed meanwhile as
  saved. The save snapshots its payload, compares the live editor state after
  the receipt, keeps `dirty` and saves the newer snapshot; `publish` refuses a
  draft whose live text/order differ from the accepted server copy.
- A dirty buffer reopened against a newer server version now reports
  `conflict` instead of replaying the old input with the newer version (which
  silently overwrote the other writer). The buffer keeps its base version.
- A `post.deleted` event now scrubs cached references to the deleted post in
  the feed, pending page and open detail views and invalidates the reference
  image; the same path runs for local deletion.
- The upload-completion and discard paths were audited for the same class:
  uploads keep newer edits dirty instead of resetting `saved`, and a discard
  cancels pending saves so the local buffer cannot reappear.

New regressions live in `test/space_compose_test.dart` and
`test/space_controller_test.dart`; Sentinel's three real-service probes pass
against the isolated FastAPI server (`docs/evidence/dea481-client/qa-fixes/`).

- `flutter analyze` — clean.
- `flutter test` — 686 passed, 12 skipped.
- Focused Space suite — 62 passed.
- Real FastAPI probes — 3 passed (pre-fix run on `942dd46a` failed all three).

### Adjacent ACK/local-state round (`SPACE-DRAFT-ACK-LOCAL-STATE`)

Forge's post-integration probes found two more instances of the same mechanism:
removing an image while a save is in flight was undone by the older receipt,
and an image upload confirmation erased text that was already dirty when the
upload started.

The fix is shared, not per-case: save/start/publish compare image order with
strict element equality (a removed or reordered image is a real local change);
a receipt only adopts server facts when no local intent changed, otherwise the
local text/order/images stay and the newer snapshot is saved; a resumed dirty
buffer keeps removed images removed and appends only images it never saw;
upload/refresh confirmation compares against the confirmed server draft and
preserves text dirty at admission plus any membership/order change made while
the upload ran.

Regressions live in `test/space_compose_test.dart`; Sentinel's three probes and
Forge's two adjacent probes pass on the real FastAPI path
(`docs/evidence/dea481-client/qa-fixes/round2/`). Current suite: 688 passed /
12 skipped, Space 64 passed.
