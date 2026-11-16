# DEA-481 eighth client repair integration

Approved revision 1; Forge run `01a1e222-20b8-72f3-aff1-ff0340432b0f`.
Sole branch `agent/forge/dea-481-integration`, draft PR #35.
Tested/build code **`6ff6f822b57b53c1fd6e43754fe6ed45d7b3d597`** merges Muse
`d0e6489606b6966b02a20e4214c07d860f478e61` onto `5d84787`. Final documentation
commits preserve this code tree. `scope.json` verifies UI equality, unchanged
service/contract/local API/ledger/lock/CI boundaries and all previous ancestors.

## Fresh checks

- Required Flutter entry: analyze exit 0; **706 passed / 12 skipped**;
  **14 Linux integration passed**. Stage exits/raw logs are in `flutter/`.
- Requested set: **17/17 passed**, consisting of **16 real-service checks and
  one fixture-network viewer widget**. The viewer probe uses the actual page,
  navigation and polling timer but replaces its gateway; it is not real-network UI.
- Two original normal/conflicting confirmation-retry controls also pass:
  **19 total, 18 real-service / 1 widget**, zero probe skips, all exits 0.
  `results.json` records parsed counts, original hashes and commands.
- Every probe mode ran sequentially, with Flutter `-j 1`. The upload-conflict
  probe keeps its original real 700ms debounce/setup assertion; concurrency can
  destabilize that timing assumption. No assertions were changed or skipped.

`sentinel-before/` preserves authenticated attachment
`01a1e21e-ab18-7a80-82a6-33ef5a42aa88` (`dea481-sentinel-qa5-5d84787.zip`).
Its original checksum manifest was verified. The real image probe failed with
one assertion, exit 1, at `5d84787`; the separate viewer widget failed with a
TestFailure wrapped as a Flutter error, exit 1. That widget receipt is not
claimed as checker-certified assertion evidence. Both original sources match
Muse's copies byte-for-byte and now pass unchanged. Earlier failures remain in
prior evidence roots. Imported logs/patches retain their original bytes.

## Mechanism and entry coverage

| Field | Implementation / evidence |
| --- | --- |
| root_cause_id | `SPACE-DELETION-LATE-WRITE`; previous post/comment/notification failures and latest image/viewer failures remain versioned. |
| writes/invalidations | `load`, `_fetch`, cache/inflight, `invalidateImage`, `clear`; thumbnail/original bytes; open-viewer Future/listener; save admission; previous controller deletion boundaries. |
| common_fix | Capture per-image generation and global epoch before the request; reject stale replies before cache admission. Image deletion increments generation; clear increments epoch. Viewers listen for token changes and remove displayed bytes. Unrelated image IDs keep their generation. |
| contract_gap | none; authoritative service deletion response remains 404 and the sole protocol is unchanged. |
| owner | Muse owns client state; Forge remains sole integrator and service/contract owner. |

| Entry | Evidence / limitation |
| --- | --- |
| Late original response after real delete/replay | Original real-service probe passes: deleted cache stays empty, subsequent load is rejected, distinct live image with identical bytes remains authorized/cached. |
| Thumbnail late reply | Existing `space_detail_test.dart` regression exercises default thumb load and per-image invalidation; both variants use the same `_fetch` fence. |
| Already-open viewer | Original page/navigation/polling widget probe and existing detail-suite regression pass; invalidation removes the Image widget and shows retry. Transport is replaced in these widget checks. |
| Global `clear` | Reviewed epoch increment and shared `_fetch`/viewer token test; a separate clear/reconnect-inflight permutation was not freshly exercised. No exhaustive lifecycle claim. |
| Inflight dedup and retry | Real original probe exercises pending deletion then rejection on subsequent load; existing suite covers ordinary fetching. Not all concurrent clear/retry permutations were separately tested. |
| Save | Existing entry obtains bytes through loader; native dialog and deletion during an already-running save remain untested. Do not infer whole-save revocation from cache admission. Previously saved device copies are outside this revocation promise. |
| Previous controller/draft entry points | Original probes and retry controls pass unchanged; their entry maps remain in earlier round evidence. |

Run from repository root after normal locked setup:

```bash
for mode in original-eight rollback-tombstone comment-deletion notification-deletion repost-control controls image-deletion viewer-widget; do
  uv run --project server --locked python docs/evidence/dea481-qa-round8/run_probes.py "$mode" || exit "$?"
done
```

The existing Live fixture runs isolated real server/standalone Dart processes,
synthetic accounts and temporary SQLite/media/session state with owned-child
cleanup. The viewer-widget mode also opens this fixture, but the test itself uses
its own gateway double: the unused live server does not upgrade its evidence.
Only this checkout's `.qa-artifacts/forge-round8/` is used. Prior lost-reply probes
inject gateway errors after genuine commits, not physical disconnections.
No private credentials, other developers' worktrees, DEA-480 exclusive files or
shared CI were touched. These counts do not constitute whole T01–T17 acceptance.

## Delivery and remaining limits

`artifact-map.json` maps fresh Linux/Android UI/source files to this code SHA;
old a65af80 UI packages are superseded. Build/signature/smoke/payload results are
recorded separately. Linux release smoke verifies a real synthetic-avatar
upload, unauthenticated GET 401, ETag 304 and uploaded-color rendering. It does
not exercise image deletion in a release viewer. The screenshot and pixel count
are in `release-space.png` / `avatar-result.json`. Package payload equality is
recorded in `package-payload-verification.json`.

APK uses the existing public debug test certificate. ADB has no device. Linux
does not prove Windows/Android runtime or Debian compatibility for the Arch-built
deb. Unchanged standalone Dart/DSH bytes retain 542cfad provenance. `reuse.json`
verifies unchanged code/locks and 295 installed host source hashes. Server
459-pass, plugin 114-pass/full Ruff, gateway and native-host evidence is reused
only within that scope, not freshly rerun. All 12 default skip reasons remain
explicit; separate historical runs do not turn current skips into passes.

Windows build/runtime/package, Android/real folding runtime, real-model semantics
and adversarial content, native settings rendering, network WS, release visitor
sheet clicks, native save dialogs and deletion during an ongoing save remain
untested. Historical CI links are not current PASS evidence; CI is not polled,
awaited or retriggered.

Parent stays in_progress with Muse. Enabled once-only wakeup
`01a1e222-0000-78df-997d-6899c5d585e0` consumes Forge's reply, verifies this
candidate and owns automated_qa handoff. No extra mention, status change, main
merge, deployment, formal release, Done action or acceptance waiver is made here.
