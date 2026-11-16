# DEA-481 sixth client repair integration

Approved revision 1; Forge run `01a1e205-1aaf-7344-9820-c1763ed3d6dd`.
Sole branch `agent/forge/dea-481-integration`, draft PR #35.
Tested/build code **`dbabb06217f894656d70c432aeaac51a4af8159d`** merges Muse
`bfb6f32c5f4bb3c60db0dc0e9a6cfe61017ebdfa` onto delivery `d3dbda1`.
Final documentation commits preserve this code tree. `scope.json` verifies UI
equality, unchanged boundaries and all earlier implementation/repair ancestors.

## Fresh evidence

- Required Flutter entry: analyze exit 0; **701 passed / 12 skipped**;
  **14 Linux integration passed**. Stage exits/raw logs are in `flutter/`.
- Twelve unchanged real FastAPI → SpaceService counterexamples: **12/12 passed**
  (original-eight 8, rollback-tombstone 2, comment-deletion 2).
- Sentinel's ordinary and externally conflicting confirmation retries:
  **2/2 passed**. All four real-probe commands exit 0 with zero skipped tests.
- The newest probes verify deletion redacts already-loaded feed previews and
  notification snippets, and prevents a delayed reply page restoring deleted
  text. Authoritative server reads confirm redaction and surviving child/reply
  relationships. These are real controller/service/event paths with response
  gates, not desktop click tests or a substitute service.

`sentinel-before/` preserves the original QA3 attachment obtained through the
authenticated CLI (`01a1e201-051b-7968-a51f-73a7be26ad68`,
`dea481-sentinel-qa3-d3dbda1.zip`): **0/2, exit 1** on `d3dbda1`.
Every original checksum was verified, and the original comment probe matches
Muse's copy byte-for-byte. Previous failed probes/logs remain in earlier evidence
directories. No assertion was weakened, deleted or skipped. Twelve passing
counterexamples are bounded evidence, not whole T01–T17 acceptance.

## Mechanism and entry coverage

| Field | Implementation / evidence |
| --- | --- |
| root_cause_id | `SPACE-DELETION-LATE-WRITE`; prior stale-post and like-rollback failures plus QA3 comment-cache/late-page failures on `d3dbda1` remain versioned. All original probes pass here. |
| writes/invalidations | Feed and pending comment previews; loaded and late notification pages; detail post previews, initial/root pagination, replies, context/merge; local comment deletion and remote comment.deleted; existing post refresh/pagination/pending/detail/like rollback entries. |
| common_fix | Owner/detail comment tombstones feed the same scrub helpers on cached and incoming snapshots. Local delete propagates to the owner. Comment placeholders retain identity, rootId, replyToId and replyToAuthor while clearing text/actions; surviving descendants remain. Existing post/reference admission and live-snapshot like rollback remain intact. |
| contract_gap | none; the existing service placeholder semantics and event contract remain authoritative. |
| owner | Muse owns client-state corrections; Forge owns sole integration and service/contract boundaries. |

Fresh real probes cover consumed comment deletion in feed/notifications and late
reply pagination, alongside previous post/reference/rollback cases. Existing
controller tests run the new comment regressions and late-page descendant checks.
Root pagination/context and late notification admission share the checked scrub
helpers; their separate delayed-response interleavings are not claimed as fresh
real probes. Local comment deletion's owner callback and notification ACK's use
of current snapshots were code-reviewed, not independently asserted as release
clicks. `write-entry-audit.log` records the searched writes; a text scan alone
does not prove complete semantic coverage. Arbitrary identity switches, cache
and native rendering races or all concurrent combinations remain outside these
fourteen checks.

`SPACE-DRAFT-ACK-LOCAL-STATE` is unchanged this round. All previous save/reopen/
upload/version probes and both real retry controls pass; unit tests retain
ordinary reorder/publish/reload/discard coverage. No exhaustive state-machine
claim is made for either mechanism.

Reproduce from repository root after normal locked setup:

```bash
uv run --project server --locked python docs/evidence/dea481-qa-round6/run_probes.py original-eight
uv run --project server --locked python docs/evidence/dea481-qa-round6/run_probes.py rollback-tombstone
uv run --project server --locked python docs/evidence/dea481-qa-round6/run_probes.py controls
uv run --project server --locked python docs/evidence/dea481-qa-round6/run_probes.py comment-deletion
```

The existing Live fixture uses actual isolated server/standalone Dart processes,
synthetic accounts, temporary SQLite/media/session state and owned-child cleanup.
The runner writes only this checkout's ignored `.qa-artifacts/forge-round6/`.
No private model credentials or other developer worktrees are used. Lost-reply
probes deliberately inject gateway response errors after real commits; they do
not claim physical socket-disconnection tests.

## Artifacts, reuse and limits

`artifact-map.json` maps fresh Linux/Android UI and source files to this code SHA;
old ec71e51 UI packages are superseded. Commands/exits, signature verification,
release smoke and package-payload checks accompany the files; all exited 0.
Actual synthetic-avatar upload, unauthenticated GET 401, ETag 304 and 1,248
rendered color pixels passed; the screenshot was visually inspected. Both Linux
packages match all 21 payload files of the smoked build. APK uses the
existing public debug test certificate; ADB has no attached device. Linux is not
Windows/Android runtime evidence, nor does an Arch-built deb prove Debian runtime.

Unchanged standalone Dart/DSH binaries retain 542cfad provenance and verified
bytes. `reuse.json` records equal source/locks and 295 installed host source
hashes matching earlier evidence. Server 459-pass, plugin 114-pass/full Ruff,
gateway and native-host checks are reused only within that scope, not freshly
rerun here. All twelve default skip reasons remain in `skips.json`.

Windows build/runtime/package, Android/real folding runtime, real-model semantics
and adversarial content, native settings rendering, network WS and release
visitor-sheet clicks remain untested. Existing Windows run links are historical,
not current success evidence; CI is not polled, retriggered or awaited.

Parent remains in_progress with Muse. Its enabled once-only wakeup
`01a1e204-f310-7aac-b800-4b53a5354adf` consumes Forge's reply, verifies the new
candidate and owns automated_qa handoff. No extra mention, status change, main
merge, deployment, formal release, Done action or acceptance waiver is made here.
