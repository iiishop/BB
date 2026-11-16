DEA-481 independent QA 5 — NOT RELEASED

Candidate 5d84787a2c50413d20d54fd698ac9546c4de96ac; https://github.com/iiishop/BB/pull/35. Approved requirements unchanged. Scope in scope.md; no production/default-test edits or competing PR.

## Specified defects

Fourteen prior failure probes plus three normal controls passed this run: 17 tests, zero errors/skips, exit 0. Original probe assertions preserved. Known-report passes repository evidence checker, exit 0. This includes loaded/late notification tombstones and surviving descendant/repost navigation. It does not certify every media or device path.

## Remaining P1 media invalidation gap (T07, section 6.3)

root_cause_id=SPACE-DELETION-LATE-WRITE; owner Muse, sole integrator Forge. No contract gap.

R5-A: late original-image response refills cache after consumed deletion. Real account publishes two posts with separate image IDs using identical PNG bytes. Cache the live post image. Start reading the first original image and hold its actual successful server response. Delete its post through real API and process actual post.deleted replay. Assert post removed, deleted image absent from cache, other image still cached. Real server original-image read now rejects with 404; the other image remains authorized. Release old response: SpaceImageLoader.cached(deletedId, original) returns PNG bytes again, target assertion fails.

Root: space_image_viewer.dart:_fetch unconditionally writes bytes into _cache after awaiting gateway.image. invalidateImage removes current cache entries only; it does not fence the outstanding fetch. _inflight still refers to the pre-deletion request. This is actual FastAPI→SpaceService→controller/loader behavior; only delivery of the successful response is delayed. The final subsequent-load rejection assertion was not reached because cache assertion failed; the load cache-hit bypass is additionally visible in source, not claimed as a second executed failure.

R5-B: already-open image viewer retains deleted image state. Widget test uses the actual SpacePage, taps the feed image to navigate into SpaceImageViewer, and enables the actual page polling timer. Contract-valid gateway fixture supplies valid image bytes and then post.deleted; post is removed and subsequent image request is configured to reject. After timer consumes the event, the viewer still contains Image.memory for the deleted image; target assertion fails. _ViewerImageState keeps its original resolved Future and receives no invalidation notification from SpaceImageLoader. This is actual widget/navigation/polling evidence with transport replaced; not real-device pixels, native-save dialogue or a second actual-network UI run. It proves retained image-widget/byte state, not a captured screen image.

Both are facets of the same media invalidation gap: removing entries does not invalidate pending results or already-held view state. Review load/_fetch/_inflight/invalidateImage/clear together with _ViewerImage Future lifecycle and save admission. A post deletion must constrain both thumb/original, inflight and cached/visible states; unrelated live image IDs must keep working. Native save/file dialog and a save already in progress were NOT RUN and should not be represented as tested. Existing-device saved copies are outside the approved revocation promise.

Baseline: image-baseline.json shows the entire space_image_viewer.dart blob is identical at 942dd46a, 00ab236 and this candidate. These are residual first-version defects, not attributed to latest notification changes. Older full candidate was not dynamically rerun with new probes; no repaired candidate/red→green claim yet.

## Actual evidence

- `uv run --project server --locked python ../qa5/run_real.py known`: 17 passed, exit 0.
- Same command with `adjacent`: one target assertion failure, zero errors/skips, exit 1. Positive live-image authorization/cache controls passed before failing assertion.
- Captured `flutter test --no-pub .qa-artifacts/probes/sentinel_round5_widget_test.dart --reporter=json`: exit 1; one TestFailure, expected no Image descendant but found one. Flutter wraps widget TestFailure as error/isFailure=false; raw exception identifies the assertion. Do not claim checker-certified assertion-counterexample for this widget receipt; inspect original print/error events. Real loader probe has native isFailure=true and is mechanically classified as assertion failure.
- Captured existing controller/detail/notifications/feed tests: 46 passed, zero skips, exit 0.
- qa_evidence.py check known-report exit 0, adjacent-report exit 2 (candidate tests failed). Checker verifies receipts/hashes/collection, not semantic completion or platform permissions.
- Clean candidate/source unchanged captured in runner receipts; SHA256SUMS includes source and logs. Isolated synthetic-account server, locked project Python, exact-child cleanup after daemon PID comparison. Databases/session state excluded and cleaned. No model credentials or personal profile access.
- Environment and Linux-only device discovery recorded. Developer 704/12, Linux 14 and historical native-host evidence are not Sentinel current-run passes. Unrelated full suites not repeated after independent blockers. PR snapshot is a single read; no CI polling or all-green claim.

Reproduction: copy included Dart files into client/.qa-artifacts/probes/; execute supplied run_real.py from repository root with existing locked server environment and fresh ../qa5 output directories. Run widget probe from client with the command above. Keep unfixed probes outside default collection; after repair integrate equivalent tests into existing entries and remove duplicate probes.

## Decision and limits

Return in_progress; assign Muse once. Known notification defects pass, but approved online media removal remains broken. No in_review/merge/deploy/release/Done. Full T01–T17 review remains incomplete.

Windows package/runtime, Android/foldable runtime, real model/adversarial images, native settings rendering, network WS, release visitor sheet, actual native save interaction and installed-host lifecycle were not tested here. Flutter and loader evidence does not replace those boundaries or standalone Dart executable validation.
