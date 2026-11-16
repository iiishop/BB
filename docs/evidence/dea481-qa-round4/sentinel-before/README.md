DEA-481 Sentinel second QA — NOT RELEASED

Candidate `35c9223f45613e916c9d6d5f90d510feba3f713d`; PR https://github.com/iiishop/BB/pull/35. Requirements unchanged. No production edits, merge, deployment or Done.

## Specified defects

This run: six original real FastAPI→SpaceService probes PASS, zero errors/skips. Original three probe bytes match prior Sentinel source exactly (filename differs); the three additional developer probes were copied unchanged. Repository checker accepts current-run known-report, exit 0. Prior red results remain prior-version evidence; this is not a newly rerun automated before/after certificate.

## Two remaining P1 defects

R2-1 / T02,T17 / root_cause_id=SPACE-DRAFT-ACK-LOCAL-STATE:

Real draft contains image A. Start upload B; server accepts, delay its successful receipt. Remove A locally; real save rejects the pre-upload version and controller enters conflict, but local A stays removed. Deliver upload receipt and fail its confirmation GET once with a 503 AuthFailure. Retry confirmation. Expected: local deletion intent survives or explicit conflict remains. Actual: A reappears in c.images; target assertion fails.

`space_compose_controller.dart:_refreshDraftImages` snapshots localOrder at retry time, after removal. `_reconcileAfterUpload:602` compares current order to this retry-time snapshot, concludes no change, and replaces it with server order at 604–605. confirmedVersion protects newer external writes but does not preserve image intent across failed reads. The failure path also changes conflict to offline. `space_compose_page.dart:380–390` leaves image removal enabled while uploading. This is a real-controller reproduction plus static widget reachability, not a new desktop-click claim.

Neighboring controls PASS: same-version confirmation retry without edits retains image and successfully publishes; retry with newer external writer preserves both local and remote text and enters conflict. Rejecting all retries is not a valid repair.

R2-2 / T07 / root_cause_id=SPACE-DELETION-STALE-SNAPSHOT:

Load source A and repost B. Start explicit refresh and delay the already-read valid list response. Delete A through real server and consume actual post.deleted replay. Assert A absent and B.reference.text null (original fix works). Release old list response. Expected deletion remains effective; actual A is restored by `_loadFeedFirst:133–140`; final absence assertion fails.

Event scrub protects only snapshots already present. Response writers include first-page replacement, pagination append, pending insertion and detail load/reload. This probe confirms explicit refresh plus replay only; other writers are required review inventory, not extra confirmed defects. Timer polling is reachable while refresh waits on list HTTP; refresh does not hold _polling across that wait. Only response delivery is delayed, not server/event semantics.

These are remaining failures in the previously identified mechanisms, not evidence the latest version comparison introduced them. Static comparison with 942dd46a shows unchanged unguarded feed replacement; older upload code also lacked persistent image intent. The new sequences were not run on the older candidate, so exact introducing commit is NOT DETERMINED. No fixed version exists for these new cases; no red→green claim.

## Current-run evidence

- `uv run --project server --locked python ../qa2/run_real.py known`: 6 passed, exit 0.
- Same command with `adjacent`: 2 target assertion failures, zero errors/skips, exit 1.
- Same command with `controls`: 2 passed, zero skips, exit 0.
- Repository capture of `flutter test --no-pub test/space_compose_test.dart test/space_controller_test.dart test/space_detail_test.dart test/space_notifications_test.dart --reporter=json`: 42 passed, zero skips, exit 0; clean candidate/source-unchanged receipts.
- `qa_evidence.py check` known-report exit 0; adjacent-report exit 2, candidate tests failed. Native logs, receipts, counts and checker outputs attached. Checker validates mechanical evidence, not semantic completeness or platform permissions.
- Wrappers use isolated synthetic-account FastAPI, collect tests synchronously and stop exact child after daemon PID comparison. No personal profile/model credentials; wrappers only delay successful responses or fail a confirmation read.
- Current device probe: Linux only. Flutter 3.47.9/Dart 3.13.7, Python 3.13.15. `reuse.json` verifies unchanged server/plugin source/tests/locks and prior Sentinel logs/XML hashes: server 52 and plugin 114 passes are reused mechanical evidence, not new executions. Prior XML-path collection limitation remains recorded.
- Prior full Flutter and Linux integration are not reused as current full-scope PASS because UI changed. Developer 694-pass/12-skip and Linux 14-pass results remain developer evidence. No redundant full-suite run after confirmed product blockers.
- One PR snapshot at 2026-11-16T01:07:51Z: seven passed, zero failed, one running. No polling or all-green claim.

Reproduce by copying included Dart files into `client/.qa-artifacts/probes/`, then running supplied run_real.py from repo root with fresh ../qa2 output directories. It assumes locked server environment exists. Keep review probes outside default CI and failing until repaired; then integrate equivalent assertions into existing tests and remove duplicates. Archive excludes server databases/session state; SHA256SUMS covers artifacts.

## Scope and conclusion

Six prior counterexamples closed; affected mechanisms still FAIL. Muse owns UI corrections; Forge remains sole PR integrator. Return in_progress and assign Muse once. Repair should preserve input across upload admission/receipt/failed read/retry/persist and deletion across feed/pending/pagination/detail response application. Preserve normal same-version retry and valid conflict decisions. This is targeted correctness work, not authorization to rewrite architecture or change contracts.

Full T01–T17 remains incomplete. Windows build/runtime/package, Android/foldable runtime, real model/adversarial images, native settings rendering, network WS and release visitor-sheet clicks remain NOT RUN. Standalone Dart/native installed-host lifecycle not rerun. Other combinations in scope.md remain unverified; no broad mechanism PASS is inferred from six green probes.
