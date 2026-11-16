# Sentinel QA7

Candidate 16681978cebc45eb25fe8cc765ac0716e524d2b4, PR #35. Issue requirements unchanged. No production code modified. Scope and its correction are in scope.md.

## Specified defects

Six prior probes pass unchanged, zero skips/errors, exit 0: late real image reply, actual page viewer deletion, local deletion, detail outside first feed page, reference navigation/back, closed details. Five use real isolated FastAPI/SpaceService and one uses actual widget navigation/polling with substituted transport. Checker known-report passes exit 0. This is fresh independent evidence, distinct from developer 711/12 and Linux14 reports.

## Confirmed P2: deleting repost blanks a live source viewer

Root family SPACE-DELETION-LATE-WRITE; owner Muse, sole integrator Forge. Create loaded source A with image img-1 and independent repost B referencing A. Through actual SpacePage, tap A's image and observe one Image in SpaceImageViewer. Deliver contract-valid post.deleted(B) through actual page polling. B is removed; A remains available in the gateway. Viewer now has zero Image widgets and takes the original-image failure branch. The test expects one live source Image and fails at that assertion, exit 1. The precondition that polling consumed the event passes. This is a user-visible reachable navigation path; transport is substituted, not an actual-network or release-device demonstration. It measures widget/byte state, not screenshot pixels.

Cause: SpaceController._invalidateImagesForPostId invalidates both post.images and post.reference.image. The latter belongs to surviving A, not deleted B. Loader generation changes notify A's active _ViewerImage, which immediately sets _invalidated=true. Thus fixing revocation has exposed overly broad owner selection. The old ec65ac4 event path also invalidated referenceImage, so this is not attributed solely to the latest ownership-map commits. Source comparison is static; no dynamic old-candidate run claimed.

Fix owner selection across local and event deletion, current snapshots and remembered ownership; preserve an unrelated source's image/viewer and continue to revoke actual deleted owners. Add this normal-survivor regression to an existing widget entry after repair. Do not weaken the six prior assertions. Native saving and in-progress save cancellation are outside this measured result.

## Rejected experiment (not a product defect)

adjacent/ and sentinel_round7_test.dart record an exploratory real-service reference-preview cache assertion that failed. Reachability review showed SpaceReferenceCard only renders an icon, never loads those bytes. The probe's direct loader call invented that current UI path. It is REJECTED as a release blocker and must not be dispatched as a second bug. Its checker exit 2 proves its assertion failed, not that its scenario is a product defect. This distinction is why checker output alone is insufficient.

## Execution and checker

From repo root with normal locked server and Flutter environments:

```
uv run --project server --locked python ../qa7/run_real.py known
uv run --project server --locked python ../qa7/run_real.py adjacent
python scripts/ci/qa_evidence.py run --cwd client --out ../qa7/viewer --flutter-json -- flutter test --no-pub .qa-artifacts/probes/sentinel_round7_viewer_test.dart --reporter=json
```

Copy archived Dart sources into client/.qa-artifacts/probes; use fresh output paths. collect.py captures counts/checker results, preserves server logs and removes owned synthetic state. Known six tests pass, checker exit 0. Rejected adjacent test has one assertion failure, exit 1/checker2 but is not a product finding. Confirmed viewer has one TestFailure, exit1, no skip; Flutter wraps widget assertions as isFailure=false. Repository checker exits2 with 'environment/runner error is not an assertion counterexample'. Manually inspected raw TestFailure shows expected one Image, found zero, at the target line. Do not claim checker-certified widget assertion classification. Raw SHA/commands/exit/hashes remain available in run.json.

Server child PIDs stopped after comparing against daemon identity; no personal data/credentials/profiles used. Source unchanged and clean in receipts. Production diff and source boundary hashes recorded. Prior unrelated tests remain historical, not rerun or counted as fresh passes. Single PR snapshot only, no CI polling. Current Flutter and device discovery included.

## Conclusion

Return in_progress, single assignment Muse. Previously requested deletion leaks are repaired, but live-source viewer regression remains. Full T01–T17 is not complete. Windows, Android/real folding, real-model/adversarial inputs, native settings UI, network WS, release visitor dialog, native image saving, and this round's standalone Dart/native DSH lifecycle are NOT RUN. No claim of platform readiness, merge/deployment/release or Done.
