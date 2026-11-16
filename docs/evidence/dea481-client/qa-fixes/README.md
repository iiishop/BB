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
