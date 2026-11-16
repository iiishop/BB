DEA-481 independent QA 3 — NOT RELEASED

Candidate: d3dbda161e3404128f428decbfd6baa7d50fcb17. PR: https://github.com/iiishop/BB/pull/35. Requirements unchanged. Production source untouched; no competing PR, merge, deployment, release or Done.

## Specified defects

This run executes ten previous real-receiver failure probes plus two normal/conflicting confirmation-retry controls: 12 passed, zero errors/skips, exit 0. All probe sources copied unchanged from earlier artifacts/candidate evidence. Known-report passes repository qa_evidence.py check, exit 0. This closes those particular sequences on this candidate; it is not a whole-mechanism PASS.

## Remaining deletion mechanism failures

root_cause_id: SPACE-DELETION-LATE-WRITE. Entity boundary now verified: comments. Approved T08 and section 6.3 require deleted parent text to disappear while descendants and reply identity survive. Contract gap: none. Owner: Muse, sole integration: Forge.

R3-1 / P1: already-loaded feed previews and notifications retain deleted comment text.

Real account A publishes a post; B comments `deleted comment secret`; A replies `surviving child`. Load feed and notification caches for A. B deletes their own parent comment through actual API; A processes actual comment.deleted replay. Fresh get_post and list_notifications redact parent text and snippet, and the child remains attached. But client caches still contain the secret in both `posts[].previewComments[].root.text` and `notifications[].snippet`. Target assertion compares both fields to null and fails with both original strings.

`space_controller.dart:774–780` forwards comment.deleted only to an existing detail controller. It does not invalidate feed previews, pending posts or notifications. Rendering reads the cached root at `space_widgets.dart:845–866` and notification snippet through `space_lists_view.dart`. This is real service/controller verification plus static render-consumer tracing, not a new desktop or widget screenshot claim. The first probe uses loaded caches; exact foreground notification view interaction was not separately executed.

R3-2 / P1: a late replies page restores text after processed comment deletion.

Create root→reply→child through real API. Open detail and start expandReplies(root), holding the successful page response after server read. Delete reply via real API and consume comment.deleted. Assert the currently cached reply text is null. Fresh server list also has null text and the child still targets the deleted reply. Release the older page: detail.replies now contains `deleted reply secret` again, and target assertion fails.

`space_detail_controller.dart:237–252` admits the page without remembered comment invalidation. `_tombstoneComment` edits currently loaded roots/replies but records no durable per-controller comment tombstone. The post/reference filters added this round do not cover comment entities. The only fault injection is delayed delivery of a valid server response; deletion, event replay and authorization remain real.

Both failures are in code paths not changed between 35c9223 and this candidate (see production-diff.patch). They are residual approved-scope gaps, not attributed to the latest like-rollback fix. The exact introducing commit has not been dynamically bisected; no before/after certification is claimed for these new cases.

Required entry review for repair: feed root/reply previews and pending pages; notification target/snippet admission; detail initial/root pagination/reply pagination/context merges; direct comment deletion and event deletion; references to deleted comment identity must retain valid descendants. Track all associated cache writes and late-response admission. Context banner, delayed root/context pages, image-viewer invalidation, and other notification races remain untested combinations, not extra confirmed defects. Do not present passing original post/reference probes as coverage of these comment boundaries.

## Current-run evidence

- `uv run --project server --locked python ../qa3/run_real.py known`: 12/12, exit 0.
- Same command with `adjacent`: two target assertion failures, zero errors/skips, exit 1.
- Captured `flutter test --no-pub test/space_compose_test.dart test/space_controller_test.dart test/space_detail_test.dart test/space_notifications_test.dart test/space_feed_test.dart --reporter=json`: 55/55, exit 0.
- Repository checker known-report: exit 0; adjacent-report: exit 2, candidate tests failed. Receipts capture clean candidate, source unchanged, command, actual exit and native-event hashes. Artifact SHA256SUMS includes probe source and logs. Checker validates mechanical evidence, not product correctness or platform permissions.
- Real isolated FastAPI, synthetic accounts, existing authorized SpaceService; no personal model credentials/profile. Runner waits synchronously and stops its exact server child after daemon PID check. Databases/session state are excluded and cleaned.
- Source/test/lock equality for server, plugin and service layer against first QA candidate is recorded in unchanged-paths.json. Those suites were not rerun or represented as fresh passes. Developer 699/12 and Linux 14 evidence is not represented as Sentinel current-run evidence; full unchanged test matrices were not repeated.
- Linux is the only detected target; Flutter/Dart and Python versions recorded. One Multica PR snapshot (2026-11-16T01:33:26Z) says six passed, zero failed, two running. No CI polling or all-green assertion.

Reproduction: copy included Dart files to client/.qa-artifacts/probes/ and run run_real.py from repo root, using fresh ../qa3 output directories and existing locked server environment. New failure probes stay outside default test collection while product is unfixed. After repair, integrate equivalent regressions into existing controller/detail/notification tests, retain assertions, remove redundant probes.

## Release conclusion

Return in_progress and assign Muse once. Ten known defects pass their probes, but two confirmed comment-deletion paths still violate approved acceptance; no in_review. Full T01–T17 mechanism review remains incomplete.

Windows build/runtime/package, Android/foldable runtime, actual model/adversarial image behavior, native DSH settings rendering, network WebSocket and release visitor-sheet clicks remain NOT RUN here. Native installed-host lifecycle and standalone Dart executable were not rerun. Device/model/environment limits are separate from these verified code defects and do not waive them.
