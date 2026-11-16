# DEA-483 QA fix round (Sentinel candidate `942dd46a`)

Scope: the three P1 defects Sentinel reproduced on the fixed integration
candidate `942dd46a601d4604cb9273c9830d472cda41378c`. Only the client UI state
was changed; the wire contract, DTOs, `space_service.dart`, local router/ledger,
server code, DEA-480 files and shared CI are untouched.

Base: `4038c1f1f16724dfa810c442f0a5d816dbaa1a64` on
`agent/muse/dea-481-client` (the client tree inside `942dd46a`).

## Defects and fixes

- **T02 stale save response could publish old text.**
  `SpaceComposeController.saveNow` snapshotted nothing: the response of an
  older `update_draft` set `_serverText = text.text` and `phase = saved`, so
  text typed while the request was in flight was labelled saved and
  `publish()` accepted the older server draft. The save now snapshots
  `savedText`/`savedOrder`, sends exactly that payload, and compares the live
  editor state after the receipt. If the user typed or reordered meanwhile it
  keeps `dirty`, merges the confirmed server facts and schedules the next save;
  `saved` is only set when the live state equals what the server accepted.
  `canPublish`/`publish()` additionally require `text == _serverText` and the
  same image order, and save the newer snapshot first otherwise.
- **T02/T17 dirty reopen silently overwrote the other writer.**
  `start()` adopted the newer server version as the save baseline and then
  auto-saved the older local buffer with `expectedVersion = new version`. The
  buffer's base version is now kept (`_baselineVersion`, persisted in
  `SpaceDraftBuffer.version`); when the server moved past it and the content
  differs, the page enters `conflict`, keeps the local text for the user to
  reload explicitly, and sends no automatic write.
- **T07 cached reference snapshot survived deletion.**
  `post.deleted` removed the post and invalidated only its own images; a loaded
  repost card kept the deleted source text. `SpaceController._scrubReferencesTo`
  now reduces every cached reference to that post in the feed, pending page and
  open detail controllers to the contract's deleted placeholder
  (`deleted: true`, no text/author/image), and drops the reference image from
  the shared cache. Local deletion (`_handlePostDeleted`) uses the same path.

## Same-entry audit requested by QA

- Image upload completion (`_upload`, `_refreshDraftImages`) had the same
  stale-response pattern: it reset `phase = saved` and the image order even if
  the user edited or reordered during the upload. It now compares the live
  editor state, merges the new image and keeps `dirty` + schedules a save.
- Discarding a draft could be followed by a debounce/retry that re-created the
  local buffer of the deleted draft. Discard now cancels the timer and ignores
  later persistence for that controller.
- Reference deletion invalidates the deleted source image through the existing
  `SpaceImageLoader` cache entry.

## Commands and results (fixed tree)

Environment: Linux, Flutter 3.47.9 stable / Dart 3.13.7; the installed SDK/pub
cache are read-only in this sandbox, so workspace copies of the same versions
were used. Server via `uv run --project server --locked python -m bb_server`.

| Check | Command | Result | Log/exit |
| --- | --- | --- | --- |
| Analyzer | `flutter analyze` | exit 0, no issues | `analyze.log`, `analyze.exit` |
| Focused Space suite | `flutter test test/space_compose_test.dart test/space_controller_test.dart test/space_feed_test.dart test/space_detail_test.dart test/space_smoke_test.dart test/space_contract_fixtures_test.dart test/space_notifications_test.dart test/space_shell_test.dart test/space_avatar_test.dart` | exit 0, **62 passed** | `space-tests.log`, `space-tests.exit` |
| Full client suite | `flutter test` | exit 0, **686 passed, 12 skipped** | `flutter-test-all.log`, `flutter-test-all.exit` |
| Sentinel probes, real FastAPI → `SpaceService` | `python3 run_real_probes.py` (starts an isolated server, runs `space_defect_probe_test.dart`) | exit 0, **3 passed** | `real-probes.log`, `real-probes.exit`, `server.log` |

Regression coverage added to existing entries:
`test/space_compose_test.dart` — in-flight save response keeps newer input
dirty and publishes the latest text; reopened dirty buffer with an older base
version reports conflict and never writes. `test/space_controller_test.dart` —
`post.deleted` scrubs a cached repost reference.

Pre-fix evidence is Sentinel's own run on `942dd46a`: the same three probes
failed (exit 1, no skips) in `qa/sentinel-qa-942dd46a.zip`. This run reuses the
unchanged probe source (`space_defect_probe_test.dart`, copied verbatim) and the
same real-service path; the fixed tree is the only source difference.

## Not run / boundaries

Windows build/run/package, Android and physical fold devices, real model
vision, native settings rendering, network WebSocket push (locked Uvicorn has
no WS support; HTTP replay is tested), release visitor-sheet click. The 12
skips are the same opt-in/environment skips as before; no assertion was
loosened or skipped. This is not overall acceptance, user sign-off or a release.

## Round 2: adjacent ACK/local-state counterexamples

Forge's post-integration adjacent probes on candidate `d463cf7` failed **0/2,
exit 1, zero skips**. Both belong to the same mechanism as round 1:

- `root_cause_id = SPACE-DRAFT-ACK-LOCAL-STATE`
- failing writes/invalidations: image removal during an in-flight save, image
  upload/confirmation, resumed dirty buffer order, explicit server reload,
  publish eligibility, discard-with-pending-ack.
- Round-1 evidence: Sentinel probes on `942dd46a` (stale ack labelled newer
  input saved; dirty reopen overwrote the other writer).
- Round-2 evidence: Forge adjacent probes on `d463cf7` (a removed image
  reappeared when the older receipt landed; a confirmed upload erased text that
  was already dirty at upload admission).
- `contract_gap = none`; owner and sole fix author **Muse**; Forge stays the
  only integrator.

**Common fix (not a per-probe patch).** The previous code compared image orders
with a helper that re-appended server-only members, so a removed image looked
"unchanged"; upload/reload reconciliation also compared only "did the user edit
during this request", ignoring intent that was already dirty when the request
started. Now:

- saved/start/publish comparisons use strict element-wise order equality
  (`listEquals`), so a removed or reordered image is a real local change.
- after any receipt, if local intent changed the controller keeps its local
  text/order/images (an older receipt can never resurrect a removed image) and
  saves the newer snapshot; the server facts are only adopted when nothing
  local differs.
- a resumed dirty buffer reconciles its recorded local order with the server:
  removed members stay removed, only images the buffer never saw are appended.
- upload and confirmation-refresh compare against the confirmed server draft,
  keep text already dirty at admission and any removal/reorder done meanwhile,
  and append only genuinely new server images.

Regressions were added to the existing compose entry (`test/space_compose_test.dart`):
removal during an in-flight save stays removed and is deleted server-side, and
an image upload confirmation keeps already-dirty text. Forge's two adjacent
probes plus Sentinel's three original probes pass on the real
FastAPI→`SpaceService` path.

## Round 2 verification (same fixed tree)

| Check | Command | Result | Log/exit |
| --- | --- | --- | --- |
| Analyzer | `flutter analyze` | exit 0, no issues | `round2/analyze.log`, `round2/analyze.exit` |
| Focused Space suite | same 9 files incl. `space_compose_test.dart` / `space_controller_test.dart` | exit 0, **64 passed** | `round2/space-tests.log`, `round2/space-tests.exit` |
| Full client suite | `flutter test` | exit 0, **688 passed, 12 skipped** | `round2/flutter-test-all.log`, `round2/flutter-test-all.exit` |
| Real probes | `python3 run_real_probes.py` (5 probes: 3 original + 2 adjacent) | exit 0, **5 passed** | `round2/real-probes.log`, `round2/real-probes.exit`, `round2/server.log` |

The 12 skips are unchanged opt-in/environment skips; no assertion was loosened.
Adjacent probe source is copied byte-for-byte from Forge's
`docs/evidence/dea481-qa-integration/adjacent_draft_probe_test.dart`
(`round2/adjacent_draft_probe_test.dart`).

## Round 3: upload receipt fence vs a newer external writer

Forge's post-integration probe on candidate `4790ae4` failed **0/1, exit 1,
zero skips**: the image upload was committed and its receipt held; another
client then saved a newer version (`other client committed`); when the upload
receipt was released, the confirmation read saw that newer version and
`_reconcileAfterUpload` adopted it as the baseline for the pending local text,
so the next autosave overwrote the other writer.

Same mechanism, same `root_cause_id = SPACE-DRAFT-ACK-LOCAL-STATE`; no contract
gap (the receipt already carries `resourceVersion`). Owner and sole fix author
**Muse**; Forge remains the only integrator.

**Common fix (extends the round-2 reconciliation).** The receipt version is the
accepted boundary for the local mutation. A confirmation read with a newer
version means another writer committed afterwards:

- If local intent (text plus the local order, where the upload's own new image
  counts as local) differs from the confirmed draft, the controller enters
  `conflict`, keeps the local text/order and never auto-saves against the newer
  version.
- `PendingDraftImage.confirmedVersion` carries that boundary through
  `_refreshDraftImages`, so a confirmation retry keeps the original fence
  instead of adopting yet another version.
- Only when the confirmed draft equals local intent (e.g. the external write
  was content-identical) is the newer version adopted as saved.

Regression added to the existing compose entry: upload receipt held, an
external update commits a newer version, and after release the server keeps
`other client committed`, local text stays `pending local text` and the phase
is `conflict`.

## Round 3 verification (same fixed tree)

| Check | Command | Result | Log/exit |
| --- | --- | --- | --- |
| Analyzer | `flutter analyze` | exit 0, no issues | `round3/analyze.log`, `round3/analyze.exit` |
| Focused Space suite | same 9 files | exit 0, **65 passed** | `round3/space-tests.log`, `round3/space-tests.exit` |
| Full client suite | `flutter test` | exit 0, **689 passed, 12 skipped** | `round3/flutter-test-all.log`, `round3/flutter-test-all.exit` |
| Real probes | `python3 run_real_probes.py` (6 probes: 3 original + 2 adjacent + 1 upload-conflict) | exit 0, **6 passed** | `round3/real-probes.log`, `round3/real-probes.exit`, `round3/server.log` |

The upload-conflict probe source is copied byte-for-byte from Forge's
`docs/evidence/dea481-qa-round2/upload_conflict_probe_test.dart`
(`round3/upload_conflict_probe_test.dart`). The 12 skips are unchanged; no
assertion was loosened.

## Round 4: Sentinel rejection on candidate `35c9223`

Sentinel re-verified the six existing real-service probes as **6/6 passed**, then
found two new P1 failures (**0/2, exit 1, both target assertions**):

1. **T02/T17 upload-retry restored a removed image.** Draft had image A; upload
   B committed but its receipt was delayed; A was removed during the upload and
   a real old-version save returned `version_conflict`; the confirmation read
   then failed once, and the retry restored A. `_refreshDraftImages` re-read the
   local order at retry time, so `_reconcileAfterUpload` saw "no local change".
   This is the fourth instance of `root_cause_id=SPACE-DRAFT-ACK-LOCAL-STATE`.
2. **T07 a stale refresh response resurrected deleted content.** A refresh page
   was read from the server but delayed; another operation deleted A, the client
   applied the real deletion event (A gone, B's reference text cleared); the old
   page then reinserted A through `_loadFeedFirst`. Deletion invalidation only
   covered the then-current cache, not late-arriving writes.

**Fixes (common boundary, not per-probe):**

- `PendingDraftImage` now records `localOrderAtAdmission` /
  `serverOrderAtAdmission`. `_refreshDraftImages` reconciles with that snapshot,
  so an image removed during the upload stays removed across a failed
  confirmation read and retry; a retry that sees a genuinely newer external
  version still conflicts.
- `SpaceController` keeps a deletion tombstone set fed by both remote
  `post.deleted` events and local deletion. Every incoming feed write is
  admitted through one filter: initial/refresh replacement, `loadMore` append,
  and pending-page application drop tombstoned posts and scrub references to a
  tombstoned post. `SpaceDetailController` receives the same lookup, rejects a
  late detail response whose post is tombstoned, and scrubs a moved reference
  before rendering it. A response captured before deletion cannot restore the
  deleted post or its text.
- `contract_gap=none`; owner and sole fix author Muse; Forge remains the only
  integrator.

Regressions were added to the existing entries `test/space_compose_test.dart`
(failed confirmation retry keeps a removed image removed) and
`test/space_controller_test.dart` (stale refresh cannot resurrect a deleted
post/reference; stale detail keeps a deleted reference invalidated).

## Round 4 verification (same fixed tree)

| Check | Command | Result | Log/exit |
| --- | --- | --- | --- |
| Analyzer | `flutter analyze` | exit 0, no issues | `round4/analyze.log`, `round4/analyze.exit` |
| Focused Space suite | same 9 files | exit 0, **68 passed** | `round4/space-tests.log`, `round4/space-tests.exit` |
| Full client suite | `flutter test` | exit 0, **692 passed, 12 skipped** | `round4/flutter-test-all.log`, `round4/flutter-test-all.exit` |
| Real probes | `python3 run_real_probes.py` (8 probes: the prior six + Sentinel round-2's two) | exit 0, **8 passed** | `round4/real-probes.log`, `round4/real-probes.exit`, `round4/server.log` |

The round-2 probe source is copied byte-for-byte from Sentinel's
`dea481-sentinel-qa2-35c9223f.zip` (`round4/sentinel_round2_test.dart`); that
bundle keeps the pre-fix 0/2 evidence. The 12 skips are unchanged; no assertion
was loosened.

## Round 5: optimistic like rollback vs a processed deletion

Forge's adjacent probes on candidate `8a57faa` failed **0/2, exit 1, zero
skips**. A like on B was really committed at the server, its reply was held,
the real API deleted A (B's reference source), the client consumed the real
deletion event and cleared B's reference text, then the model failed the held
like reply. The feed `togglePostLike` wrote back its whole captured `original`
object and the detail `toggleLike` wrote back `current`, both restoring
`deleted source secret` (and the old reference author/image).

`root_cause_id = SPACE-DELETION-LATE-WRITE` (same mechanism as Sentinel's stale
refresh write-back in `35c9223`): confirmed deletion must constrain every
whole-object write, including optimistic rollbacks. `contract_gap = none`;
owner and sole fix author Muse; Forge remains the only integrator.

**Common fix.** Both rollbacks now run through one rule: copy the *live*
post (which already carries the scrubbed reference) and override only the
`liked`/`likeCount` fields. A whole pre-deletion object is never written back;
if the post was deleted/tombstoned during the request, the rollback restores
nothing. The existing tombstone admission filters (initial/refresh feed
replacement, `loadMore`, pending-page apply, detail load/reload) stay in place.

Regressions were added to the existing `test/space_controller_test.dart` entry:
feed like rollback after a real deletion event keeps the reference scrubbed,
and detail like rollback after `onReferenceDeletedEvent` keeps it scrubbed.

## Round 5 verification (same fixed tree)

| Check | Command | Result | Log/exit |
| --- | --- | --- | --- |
| Analyzer | `flutter analyze` | exit 0, no issues | `round5/analyze.log`, `round5/analyze.exit` |
| Focused Space suite | same 9 files | exit 0, **70 passed** | `round5/space-tests.log`, `round5/space-tests.exit` |
| Full client suite | `flutter test` | exit 0, **694 passed, 12 skipped** | `round5/flutter-test-all.log`, `round5/flutter-test-all.exit` |
| Real probes | `python3 run_real_probes.py` (10 probes: prior eight + Forge's two rollback probes) | exit 0, **10 passed** | `round5/real-probes.log`, `round5/real-probes.exit`, `round5/server.log` |

The rollback probe source is copied byte-for-byte from Forge's
`docs/evidence/dea481-qa-round4/rollback_tombstone_probe_test.dart`
(`round5/rollback_tombstone_probe_test.dart`); Forge's bundle keeps the
pre-fix 0/2 evidence. The 12 skips are unchanged; no assertion was loosened.
