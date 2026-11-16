# DEA-481 tenth client repair integration

Approved revision 1. Forge run `01a1e23d-b68a-74d4-ba1e-403fffe53157`, sole
branch `agent/forge/dea-481-integration`, draft PR #35. Tested/build runtime
**`ae99e76280eb0edc68e7388d29dd6f1c5a618cae`** merges Muse
`5fdf1d123d884091406d76157e2a26158e9eb159` onto `f3e1496`. Final documentation
commits preserve runtime/test trees. `scope.json` verifies UI equality,
unchanged service/contract/local API/ledger/lock/CI boundaries and ancestors.

## Fresh checks

- Required entry: analyze exit 0; **711 client passes / 12 skips**;
  **14 Linux integration passes**, all stage exits 0.
- Requested set: **21/21 passes**, comprising **20 real-service checks and one
  actual page/navigation/polling widget with fixture transport**.
- Two original normal/conflicting confirmation-retry controls also pass:
  **23 total, 22 real-service / 1 widget**, all exits 0, zero probe skips/errors.
- Every mode ran sequentially with Flutter `-j 1`, retaining the original real
  700ms debounce/setup assertion. No assertions were weakened or skipped.

`results.json` records native Flutter JSON counts, assertion/error classification,
source hashes and commands. Original counterexamples remain byte-identical.
The last two Forge failures are in `docs/evidence/dea481-qa-round9/` at runtime
`3866b26` / delivery `f3e1496`: 0/2 target assertion failures, zero runtime
errors/skips, exit 1 each. Both now pass unchanged, and equivalent permanent
regressions are in the existing `client/test/space_controller_test.dart` entry.
Earlier Sentinel/Forge failures remain in their original evidence roots and the
combined evidence archive. The previous viewer TestFailure remains identified
as a widget error, not a checker-certified ordinary assertion failure.

## Shared mechanism and entry coverage

| Field | Implementation / evidence |
| --- | --- |
| root_cause_id | `SPACE-DELETION-LATE-WRITE`; Sentinel deletion-entry and Forge returned-reference/closed-owner failures remain versioned and pass here. |
| writes/invalidations | Post/image ownership observation, both media variants and inflight fetch; feed replace/page/pending admission; detail load/reference/refresh/back/close/dispose; local/remote deletion; reference scrubbing; viewer/identity/save boundaries. |
| common_fix | Controller-owned postId -> own-image IDs outlives visible snapshots. Feed and detail admission register ownership. Local/remote deletion uses the shared invalidation helper, then removes the ownership record. Existing per-image generation fences cache/inflight and notifies open viewers. This is in-memory controller state, not a new disk store or wire protocol. |
| contract_gap | none; existing post/image identities, event and server 404 behavior are authoritative. |
| owner | Muse owns client state; Forge remains sole integrator and service/contract owner. |

| Entry | Coverage |
| --- | --- |
| Returned reference detail | Original real probe follows source detail, loads thumb/original, backs out, then deletes/replays. Both caches are absent; remaining reference is a tombstone; direct server fetch is 404; unrelated image stays cached. |
| All details closed | Original real probe loads source media, closes the real stack, then deletes/replays. Both variants are absent without a visible owner; unrelated image remains cached. |
| Feed/local and direct-detail deletion | Prior real deletion-entry probes pass; existing controller regressions include detail-local delete and both-variant/live-image preservation. |
| Feed replacement, pagination, pending creation/application | All admit through `_admitIncoming` / `_scrubIncoming`, which records ownership after tombstone filtering. Existing controller suite runs; each eviction/delete combination was not separately reenacted in a fresh real probe. |
| Detail load/reference/refresh/after-change reload | All admitted post reads call `_admitPost` and the same observer. Back/close disposes detail snapshots without dropping main-controller ownership. Known reference/back/close paths have real probes; every refresh interleaving is not exhaustively tested. |
| Inflight/visible image invalidation | Earlier real late-image probe and fixture-network viewer probe pass unchanged. Ownership invalidation reuses that generation boundary; a new combined close-while-fetching permutation was not separately executed. |
| Identity reset/global clear/native save | Existing lifecycle behavior and source boundaries retained; no new exhaustive identity/clear race or native-save interaction claim. Native dialog and deletion during save remain untested. |

Run from repository root after normal locked setup:

```bash
for mode in original-eight rollback-tombstone comment-deletion notification-deletion repost-control controls image-deletion viewer-widget deletion-entry detail-reference closed-detail; do
  uv run --project server --locked python docs/evidence/dea481-qa-round10/run_probes.py "$mode" || exit "$?"
done
```

The existing Live fixture runs isolated FastAPI and standalone Dart processes,
synthetic accounts and temporary SQLite/media/session state with owned cleanup.
The viewer-widget test itself uses fixture transport even though the runner opens
an unused live server for that mode. Previous lost-response probes inject gateway
errors after genuine commits, not physical disconnects. No private credentials,
other developers' worktrees, DEA-480 exclusive files or shared CI were changed.

## Delivery and limits

Fresh source/Linux tar/deb/Android ARM64 test APK map to this runtime in
`artifact-map.json`; they supersede old 6ff6f82 UI packages. Build/signature/
packaging/release-smoke exits and reproduction commands are in `results.json`.
Linux release smoke exercises actual synthetic-avatar upload, unauthenticated
401, ETag 304 and rendered avatar color; it does not prove release image deletion.
The inspected screenshot and pixel count are separate artifacts. Linux package
payload hashes match the smoked bundle. APK uses the repository's public debug
test certificate; no Android device is attached. Arch-built deb packaging does
not prove Debian installation/runtime.

Standalone Dart/DSH files retain 542cfad provenance and verified unchanged bytes.
`reuse.json` verifies source/lock scope and 295 installed host source hashes.
Server 459-pass, plugin 114-pass/full Ruff, real gateway and native-host evidence
is reused only within that scope, not freshly rerun. All 12 default skip reasons
remain explicit; historical separate runs do not convert them into passes.

Windows build/runtime/package, Android/real-fold runtime, real-model semantics
and adversarial content, native settings rendering, network WS, release visitor
sheet clicks, native save dialogs and deletion during a save remain untested.
Full T01–T17 remains for independent QA. No CI polling/retrigger, main merge,
deployment, formal release, Done or user-acceptance claim.

Parent remains in_progress with Muse. Enabled one-shot wakeup
`01a1e23d-8889-7287-9b4b-37f3f3936d59` consumes Forge's final comment, verifies
the candidate and owns automated_qa handoff. Forge does not add another mention
or change workflow status.
