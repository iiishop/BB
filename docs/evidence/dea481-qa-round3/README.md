# DEA-481 third QA-fix integration

Approved specification revision 1. Forge run
`01a1e1d7-2176-75cb-bcfb-aecccdb9725c`, sole integration branch
`agent/forge/dea-481-integration`, draft PR #35.
Tested/build code: **`ed901e02e9626cd91e193439aed205b9fb79423d`**.
Muse `e009647bd93fb1f4142f5b1d1e4827db95076c41` is merged in full. Final
delivery documentation commits preserve this code tree. `scope.json` verifies
the UI matches Muse and earlier server, local API/ledger, avatar, plugin lint
and previous QA repairs remain ancestors.

## Fresh checks

- Existing required Flutter entry: analyze exit 0; **694 client passes / 12
  skips**, **14 Linux integration passes**, exit 0. Raw logs and stage exits are
  in `flutter/`; `results.json` records commands and parsed counts.
- Six original real FastAPI → SpaceService probes, unchanged source bytes:
  **6 passed, 0 failed, 0 skipped**. The five prior probes are in
  `original-five.jsonl`; the newest upload race is in `upload-conflict.jsonl`.
  Both commands exit 0. These delay actual committed responses; they do not
  replace server persistence or its version checks with mocks.
- The newest probe preserves `other client committed` on the server, retains
  `pending local text` locally and asserts conflict after the upload response
  arrives. Its prior **0/1, exit 1** on code `6a4f0e0` (delivery `4790ae4`)
  remains in `../dea481-qa-round2/`. Earlier 0/3 and 0/2 evidence remains in
  `../dea481-qa-integration/`; no failed assertion was weakened or skipped.

Reproduce from the repository root:

```bash
uv run --project server --locked python docs/evidence/dea481-qa-round3/run_probes.py original-five
uv run --project server --locked python docs/evidence/dea481-qa-round3/run_probes.py upload-conflict
```

The runner uses the existing isolated Live fixture, temporary synthetic accounts,
owned-child cleanup and ignored `.qa-artifacts/forge-round3/`. No other developer
directory, personal profile or model credentials are used.

## Shared mechanism and coverage

| Field | Current implementation / evidence |
| --- | --- |
| root_cause_id | `SPACE-DRAFT-ACK-LOCAL-STATE`; prior failures on `942dd46a`, `d463cf7`, `4790ae4` remain versioned. All six original probes now pass. |
| writes/invalidations | start/buffer restore; text/remove/reorder; save receipt; upload and confirmation retry; persist/baseline; publish; explicit server reload; discard and pending callbacks. |
| common_fix | Reconcile accepted server payload with unacknowledged local intent using exact image member/order equality. Preserve the upload receipt's accepted version separately from later reads; a newer differing server draft produces conflict instead of an automatic rebase. `PendingDraftImage.confirmedVersion` carries that fence to confirmation retry. |
| contract_gap | none; existing resourceVersion and server CAS remain authoritative. |
| owner | Muse owns client draft state; Forge owns sole integration and service/contract boundaries. |

Fresh real probes exercise start/dirty restore, delayed text-save acknowledgement,
image deletion during save, already-dirty text during upload, external writes
during upload confirmation, and deletion invalidation. Publish/current-content
guards and ordinary reorder/retry/reload/discard behavior also run through the
existing compose unit suite. `_refreshDraftImages` shares the tested
`_reconcileAfterUpload` implementation and passes the retained receipt version;
there is no separate real failed-confirmation/retry interleaving probe here.
Pre-existing dirty image-order admission, discard with an already committed
upload, and combinations of these races are not independently proved by the six
probes. This bounded coverage is not an exhaustive state-machine acceptance.

## Reuse and delivery

Server/contract, plugin, standalone API, services/models/config, locks, Windows
sources and shared CI match the prior candidate (`scope.json`). Prior server
459-pass, plugin 114-pass/full Ruff, six real API and installed stock DSH evidence
is reused only within these unchanged boundaries; it is not a new host/model run.
The standalone Dart and DSH bundle retain their original build SHA and verified
bytes. Linux/Android UI packages must use this new runtime, not old `b3f391a`
UI binaries. Fresh Linux release and Android ARM64 builds, Linux tar/deb packaging, APK
signature verification and real Linux release smoke all exited 0. The APK uses
the public debug test certificate. Actual synthetic-avatar HTTP upload, 401
without auth, ETag 304 and 1,248 rendered color pixels passed; the screenshot
was visually inspected. No Android device was attached. Build logs, signature
checks and `artifact-map.json` identify fresh files and reused artifacts. `SHA256SUMS` covers this evidence directory.

`skips.json` preserves all twelve default skip reasons: six opt-in live API
cases and six opt-in screenshot cases. Their test sources are unchanged; prior
separate runs do not turn these default skips into passes.

Windows build/runtime/package, Android/real foldable runtime, real-model semantics
and adversarial content, rendered native settings, network WS and actual release
visitor-sheet clicks remain untested. APK build/signature is not device runtime;
Linux is not Windows; deterministic DSH provider evidence is not model validation.
No complete T01–T17 acceptance or release authorization is asserted.

Parent stays in_progress assigned to Muse. Its enabled once-only wakeup
`01a1e1d6-fc8f-76e9-ab1f-6a8777a6f264` filters Forge's final comment (expires
2026-11-19, no recorded error); Muse verifies the candidate and owns automated_qa
handoff. No extra mention, status change, main merge, deployment, formal release,
manual CI trigger/wait or Done action is made by this run.
