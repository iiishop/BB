DEA-481 independent QA 4 — NOT RELEASED

Candidate 00ab236dc96ff056398974d0584a75215b1036a4; https://github.com/iiishop/BB/pull/35. Requirements unchanged. Scope in scope.md. No production code/default tests edited; no competing PR, merge/deploy/release/Done.

## Specified defects

Twelve prior failure probes and two confirmation-retry controls passed this run (14 tests, no failures/errors/skips). Source reused unchanged. These particular sequences are closed on this candidate. Repository evidence checker accepts known-report, exit 0. No claim that this proves the complete invalidation mechanism or all T01–T17.

## Remaining notification invalidation defects

root_cause_id=SPACE-DELETION-LATE-WRITE; requirements T07/T08, section 6.3. Owner Muse; Forge sole integrator. Contract gap none: server returns explicit snippet/accessibility/deletion state.

R4-1 / P2: comment notification remains accessible after target deletion. Real A publishes; B comments; A replies. Load notification caches, start a notification reload and delay its already-read server response. B deletes parent comment; process real deletion event. Release old notification page. Fresh server result is `{snippet:null, accessible:false, deleted:true}`, but cached result is `{snippet:null, accessible:true, deleted:false}`. Target assertion fails. `space_controller.dart:451–473` clears snippet but retains availability flags; it also returns immediately when snippet is already null. `space_lists_view.dart` uses these flags for the deleted-content label and `SpaceController.openNotification` for navigation decisions. Thus redaction alone leaves wrong UI state and a stale target route. This is controller/real-service evidence plus static UI consumer tracing, not a new screenshot claim.

Positive control in the same probe: B's notification to A's surviving child remains accessible, keeps its snippet, opens successfully and resolves the correct child context despite the parent deletion. Do not indiscriminately disable all notifications in the discussion.

R4-2 / P1: whole-post deletion retains notification content and target availability, both in current cache and after a late page. Real A publishes; B comments `comment secret`. Load notifications and delay the next valid notification page. Delete post through real A API; consume post.deleted. Capture notification state, then release old page. Both snapshots remain `{snippet:'comment secret', accessible:true, deleted:false}`. Fresh server query is `{snippet:null, accessible:false, deleted:true}`. Target assertion fails for both admission paths. `_applyEvent` post.deleted (lines 820–824) scrubs posts/references but not notifications; `_scrubNotification` checks only individually deleted comment IDs, not deleted target posts. Cascading server deletion does not emit one comment.deleted per removed row.

Additional normal control PASS: A deletes source A after B reposts it. Notification.postId points to deleted source but targetPostId points to the valid repost. It remains accessible, its snippet agrees with server, navigation succeeds and repost reference is deleted. Repair must use effective target semantics, not reject every notification whose source post is tombstoned.

These are residual gaps in the previously reviewed deletion mechanism. Both forms were already possible before the latest snippet-only correction; exact introducing commit was not dynamically bisected. production-diff.patch records the actual latest changes. No new repaired version exists, so no red→green claim for R4-1/R4-2.

Repair inventory: loaded notification mutation, initial/reset/page admission, local/remote comment and post deletion, effective target for comment/reply/repost/like, accessible/deleted/snippet consistency, openNotification behavior, version/unread preservation, surviving descendants and reposts. Additional late root/context combinations remain independent boundaries and were not newly executed here.

## Actual evidence

- `uv run --project server --locked python ../qa4/run_real.py known`: 14 passed, exit 0.
- Same command with `adjacent`: 2 target assertion failures, zero errors/skips, exit 1.
- Same command with `controls`: 1 passing real repost-navigation control, zero skips, exit 0.
- Captured `flutter test --no-pub test/space_controller_test.dart test/space_detail_test.dart test/space_notifications_test.dart test/space_feed_test.dart --reporter=json`: 43 passed, zero skips, exit 0.
- Repository qa_evidence.py check: known and controls exit 0; adjacent exit 2, candidate tests failed. Receipts record actual SHA, clean source, source unchanged, commands, exit codes and hashes. Checker is mechanical evidence validation, not a platform permission gate or semantic PASS.
- Real isolated FastAPI and synthetic accounts through existing authorized SpaceService. Only delivery of actual successful list responses is delayed. All server comparisons use actual receiver rules; no fake successful mutation. Foreground completion; own child stopped after daemon PID comparison. Server databases/session state cleaned and excluded.
- Current environment/version/device probes attached: Linux only, Flutter 3.47.9/Dart 3.13.7, Python 3.13.15. No model credentials or personal DSH profile used.
- Developer 701/12 and Linux 14 results remain developer evidence, not this reviewer's runs. Full server/plugin/native suites not rerun or claimed as fresh PASS. No redundant full matrix after independent product failures.
- One PR snapshot: 2026-11-16T01:53:03Z, seven passed, zero failed, one running. No wait/poll or all-green claim.

Reproduce: copy supplied Dart files under client/.qa-artifacts/probes/; run supplied run_real.py from repository root with existing locked server environment and fresh ../qa4 output directories. Probe imports reuse the original real login/publish helpers. Keep new failing probes outside default CI until fixed, then integrate equivalent assertions into existing notification/controller tests and remove duplicates. SHA256SUMS covers supplied artifacts.

## Decision and limits

Return in_progress and assign Muse once; do not advance to in_review. Twelve earlier failure probes pass, but notification state still violates approved deletion semantics. Full T01–T17 remains incomplete.

Windows build/runtime/package, Android/foldable runtime, real model/adversarial content, native settings rendering, network WS and release visitor-sheet clicks remain NOT RUN. Standalone Dart/native installed-host lifecycle not rerun. Environment gaps do not explain or waive the confirmed code failures.
