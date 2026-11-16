# DEA-481 seventh client repair integration

Approved revision 1; Forge run `01a1e212-cc13-7842-9e94-ee44b3eaf212`.
Sole branch `agent/forge/dea-481-integration`, draft PR #35.
Tested/build code **`a65af8052fffff281bc78bac5718ec2e5a130b0c`** merges Muse
`2cf262626defdbae1842a9b31d74cfd6dafad871` onto `00ab236`. Final documentation
commits preserve this code tree. `scope.json` verifies UI equality, unchanged
service/contract/local API/ledger/lock/CI boundaries and all previous ancestors.

## Fresh checks

- Required Flutter entry: analyze exit 0; **704 passed / 12 skipped**;
  **14 Linux integration passed**. Stage exits/raw logs are in `flutter/`.
- Requested real-service set: **15/15 passed** = twelve prior counterexamples,
  two notification counterexamples and one surviving-repost control.
- Two original normal/conflicting confirmation-retry controls also pass:
  **17 checks total**, all commands exit 0, zero probe skips. `results.json`
  records parsed counts, original source hashes and reproduction commands.
- New notification probes compare actual authorized FastAPI projection with
  cached/late client notification state after real delete events. Deleted targets
  become snippet=null/accessibility=false/deleted=true. A surviving child comment
  and a surviving repost remain navigable, including controller navigation/context
  assertions. These are real controller/service/event checks, not release clicks.

`sentinel-before/` preserves authenticated attachment
`01a1e210-9864-739c-8526-592ffeab773e` (`dea481-sentinel-qa4-00ab236.zip`),
including original **0/2, exit 1** evidence on `00ab236`. Its original checksum
manifest was verified and both new probe/control sources match Muse's copies
byte-for-byte. All earlier failures remain in prior evidence roots. Assertions
were not relaxed or skipped. Raw evidence, including any patch whitespace, is
preserved as received rather than reformatted.

## Mechanism and coverage

| Field | Implementation / evidence |
| --- | --- |
| root_cause_id | `SPACE-DELETION-LATE-WRITE`; earlier stale-post, rollback, comment and latest notification failures remain versioned, with original passing probes here. |
| writes/invalidations | Loaded/late notification pages, snippet, accessible/deleted flags and navigation target; local/remote post deletion and comment deletion; existing feed/pending/detail/comment/context/rollback entry boundaries. |
| common_fix | Mirror `space_queries.notification`: invalidate based on the navigation targetPostId or referenced commentId. Post deletion now scrubs loaded notifications; incoming pages share the same filter. Do not invalidate a surviving repost just because source postId was deleted. Preserve surviving child-comment navigation. |
| contract_gap | none; existing DTO and server projection are authoritative and unchanged. |
| owner | Muse owns client state; Forge remains sole integrator and service/contract owner. |

Fresh real checks cover loaded and late notification projections, actual navigation
to surviving reposts/children, plus the prior draft/post/comment/rollback paths.
New cases also run in the existing controller suite. The local post-delete
callback shares notification scrubbing with remote deletion and was code-reviewed;
it is not separately claimed as a fresh release click. Earlier root/context and
identity/cache/native race permutations are not exhaustively proved. Code review
compared the filter with `server/src/bb_server/space_queries.py:251`; unchanged
authorization/operation semantics are not replaced by a client protocol copy.
`SPACE-DRAFT-ACK-LOCAL-STATE` remains unchanged and its prior probes/controls pass.

Run from repository root after normal locked setup:

```bash
for mode in original-eight rollback-tombstone comment-deletion notification-deletion repost-control controls; do
  uv run --project server --locked python docs/evidence/dea481-qa-round7/run_probes.py "$mode" || exit "$?"
done
```

The existing Live fixture runs isolated real server/standalone Dart processes,
synthetic accounts and temporary SQLite/media/session state with owned-child
cleanup. Only this checkout's `.qa-artifacts/forge-round7/` is used. Prior lost-reply
probes inject gateway errors after genuine commits, not physical disconnects.
No private credentials, other developers' worktrees, DEA-480 exclusive files or
shared CI were touched. Counts here do not constitute whole T01–T17 acceptance.

## Delivery and remaining limits

`artifact-map.json` maps fresh Linux/Android UI/source files to this code SHA;
old dbabb06 UI packages are superseded. Build/signature/smoke/payload results are
recorded separately: all exit 0. Real synthetic-avatar upload, unauthenticated
GET 401, ETag 304 and 1,248 rendered color pixels passed; the screenshot was
visually inspected. Both Linux packages match all 21 files of the smoked bundle.
APK uses the existing public debug test certificate, and
ADB has no device. Linux evidence does not prove Windows/Android runtime or Debian
compatibility for the Arch-built deb.

Unchanged standalone Dart/DSH bytes retain 542cfad provenance. `reuse.json`
verifies unchanged code/locks and 295 installed host source hashes. Server
459-pass, plugin 114-pass/full Ruff, gateway and native-host evidence is reused
only within that scope, not freshly rerun. All 12 default skip reasons remain
explicit. Windows build/runtime/package, Android/real folding runtime, real-model
semantics/adversarial content, native settings rendering, network WS and release
visitor-sheet clicks remain untested. Historical CI links are not current PASS
evidence; CI is not polled, awaited or retriggered.

Parent stays in_progress with Muse. Enabled once-only wakeup
`01a1e212-ab4a-79d5-9861-51d1aa52c28e` consumes Forge's reply, verifies this
candidate and owns automated_qa handoff. No extra mention, status change, main
merge, deployment, formal release, Done action or acceptance waiver is made here.
