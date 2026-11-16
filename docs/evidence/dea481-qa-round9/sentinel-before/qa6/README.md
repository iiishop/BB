# Sentinel QA6

Fixed candidate ec65ac4cf46186623ee7d69d4f5ec53193519f10, PR #35. Requirements unchanged. Independent scope in scope.md. Production code untouched.

## Specified defects

Unmodified prior real-service late-image probe and page/navigation/polling widget probe pass: 2 tests, 0 failures/errors/skips, exit 0. Widget uses replaced transport, real probe uses isolated FastAPI and SpaceService. This fixes the two previously demonstrated paths; it does not prove all deletion callers send invalidation.

## Confirmed remaining mechanism defects

Root cause family SPACE-DELETION-LATE-WRITE, P1, UI owner Muse, integrator Forge. No contract gap; real server returns 404 after both deletions.

1. Publish an image post, start controller and cache original. Call actual SpaceController.deletePost(post), then poll actual deletion events. Feed removes post, server denies original with 404, a separate live post's cached image remains valid. Deleted original cache still contains PNG bytes (target assertion fails). _handlePostDeleted removes post without invalidating its images; replay later only searches the now-missing feed entry. Therefore the loader's new generation fence never receives the invalidation.
2. Publish an older image post then 21 newer posts. Start controller (real first-page limit 20); older post is absent. Open its actual detail (the same openPost entry used by references/notifications), cache original, delete through API from another caller and poll events. Server now denies original with 404; cached original remains (target assertion fails). _applyEvent searches only posts to discover images; detail.onDeletedEvent drops its post snapshot without notifying the shared image loader. This is an ordinary reachable detail path, no fabricated list mutation or database access.

Tests exercise actual HTTP -> SpaceService -> controller -> loader; unlike the previously failing widget test, both assertions are ordinary Dart tests classified as assertion failures. The tests prove retained bytes, not native device pixels or an additional executed save operation. Existing loader.load cache-hit path can return them without new authorization; this is source inspection, not a separate measured save claim.

Required review: invalidate images before dropping owners in local deletion, remote replay, detail-only/reference navigation and pending pages. Both variants and pending requests must receive the existing generation/epoch signal, while unrelated surviving sources remain usable. Do not solve only the two concrete IDs; integrate regressions into existing test entries after repair. No production fix made by QA.

## Versioned execution

From repo root, with existing locked server environment and Flutter:

```
uv run --project server --locked python ../qa6/run_real.py known
uv run --project server --locked python ../qa6/run_real.py adjacent
python ../qa6/collect.py
```

Restore included probes under client/.qa-artifacts/probes before replay; output directories must be fresh. Known: 2/2 pass, exit 0; adjacent: 2/2 target assertion failures, zero skips/errors, exit 1. Checker run for each report: known exit 0, adjacent exit 2 (candidate tests failed). Raw receipts carry clean SHA, source unchanged, command and hashes. Checker validates facts, not product semantics or platform authorization.

Initial preparation command used an incorrect relative script path and failed before tests; corrected to ../qa5 before capture. It did not produce a product result and is not counted. Tests did not change assertions, retry after failure, or skip anything. Isolated servers stopped by owned PID after checking daemon identity; synthetic databases/media removed, server logs retained. No secrets or personal profiles used.

reuse-boundaries.json confirms controller/detail/compose, lock, server and plugin trees equal to QA5. Prior 17 known real probes and 46 targeted cases remain historical evidence from 5d84787, not new current-candidate execution. New image file is the only production change, recorded in production-diff.patch. Do not reuse old whole-UI pass as current whole-UI proof. Developer full-suite and integration counts remain developer evidence. PR snapshot taken once, no CI polling.

## Decision and limits

Do not release to in_review: approved T07/6.3 online cache removal still broken. Return in_progress and single-assign Muse. Forge remains sole PR integrator. No merge/deployment/release/Done.

Full T01–T17 remains incomplete. Windows/Android/real-fold runtime, model behavior/adversarial inputs, native settings rendering, network WS, release visitor sheet, native save dialog/in-progress saving, standalone Dart executable and native DSH lifecycle not executed this round. Environment/device snapshot included; Linux widget evidence cannot replace these. Do not infer all environment gaps are code defects.
