# DEA-481 eleventh client repair integration

Approved revision 1. Forge run `01a1e24c-e4c5-752b-a1e9-75aed630332e`.
Sole branch `agent/forge/dea-481-integration`, draft PR #35. Tested/build code
**`3b20470da74c661f40e2f934b013f62b8ef765e4`** merges Muse
`5c957a487e09703dc01d06c5c3903520042cc7e0` onto `1668197`. Final evidence/docs
commit preserves runtime/tests. `scope.json` verifies UI equality, prior
ancestors and unchanged service/contract/local API/ledger/dependency/CI scope.

## Evidence classification

Analyze exits 0; default suite **712 passes / 12 skips**; Linux integration
**14 passes**, all stage exits 0. Requested probe set **23/23** passes:

- 20 existing real-service checks of user paths.
- Two actual page/navigation/polling widget probes with **fixture transport**:
  deleted-image removal and the new live-source viewer preservation.
- One real-service exploratory reference-cache probe, **not reachable from the
  current UI and excluded from defect/acceptance conclusions by Sentinel**.

Two retained real confirmation-retry controls also pass. Total **25**, comprising
22 real-service user-path/control checks, two fixture widgets and one excluded
exploratory real check. Zero probe skips/errors; every command exits 0. Modes run
sequentially with Flutter `-j 1`; original real 700ms debounce assertions remain.
`results.json` records parsed native JSON counts, classifications, exits, source
hashes and commands. Passing an excluded exploration does not establish a user
path or retroactively turn its earlier result into a confirmed product defect.

Original Sentinel QA7 attachment `01a1e249-1fb6-71e6-8601-257362abf3cc`,
`dea481-sentinel-qa7-1668197.zip`, is preserved in `sentinel-before/qa7/`.
Its 46-file manifest is verified. Both delivered probe sources match this
archive and Muse byte-for-byte. Before repair, the live-source viewer had a
TestFailure (expected one Image, got zero), exit 1; Flutter wraps that as an
error and Sentinel's checker refused ordinary assertion certification. Keep that
qualification. Earlier failure receipts remain in prior round roots/archive.

## Shared mechanism and entry coverage

| Field | Implementation / coverage |
| --- | --- |
| root_cause_id | `SPACE-DELETION-LATE-WRITE`: earlier deletion-owner failures passed in round10; QA7 at `1668197` exposed invalidation of a still-live source by deleting its repost. |
| writes/invalidations | Own/reference image identity, thumb/original cache and inflight fetch; local/event deletion; feed/page/pending snapshots; detail/reference/back/close; reference scrubbing; viewer listeners and save admission. |
| common_fix | Deleting B invalidates B's `post.images` and recorded owned IDs, never B's borrowed `reference.image`. Only deleting source A scrubs references to A; loaded details now invalidate A's reference image before scrubbing, matching existing feed/pending handling. Existing ownership lifetime and generation fencing remain. |
| contract_gap | none; identities, deletion events and authoritative server media checks are unchanged. |
| owner | Muse owns client state; Forge remains sole integrator/service-contract owner. |

The fresh original fixture-widget probe opens A's viewer through SpacePage,
consumes B's deletion through actual page polling and verifies A remains shown.
The permanent added regression is in `client/test/space_detail_test.dart` (one
new default test); `space_controller_test.dart` is unchanged in this delivery.
The exploratory detail-reference cache probe exercises the added defensive
scrubbing branch but is not current-UI coverage. Previous real local/event,
detail/back/close, cache, draft/comment/notification/rollback probes pass unchanged.
Local and remote deletion share the ownership helper; this round does not claim
a separate release click for local deletion of a repost. Full entry/lifetime
coverage and untested permutations remain in round10's table. No exhaustive
clear/retry, identity-switch or save-interleaving proof is claimed.

Reproduce from repository root after normal locked setup:

```bash
uv run --project server --locked python docs/evidence/dea481-qa-round11/run_probes.py surviving-viewer
uv run --project server --locked python docs/evidence/dea481-qa-round11/run_probes.py exploratory-reference
```

All other modes/commands are in `results.json`. The existing Live fixture owns
isolated FastAPI/standalone Dart processes, synthetic accounts and temporary
storage cleanup. An unused live server opened around a widget mode does not make
the widget use real transport. Earlier lost-response probes inject gateway errors
after real commits, not physical disconnects. No private credentials or other
worktrees, DEA-480 exclusive files or shared CI were modified.

## Artifacts and remaining limits

Fresh source/Linux tar/deb/Android ARM64 APK map to this runtime in
`artifact-map.json`, superseding ae99e76 UI packages. Build/signature/packaging/
Linux release-smoke exits are recorded in `results.json`. The inspected Linux
smoke covers real synthetic-avatar upload, unauthorized 401, ETag 304 and color
rendering; it does not prove release viewer deletion/preservation. Both Linux
packages match the smoked bundle. The APK uses the existing public debug test
certificate; no Android device is attached. Arch-built deb packaging does not
prove Debian runtime. Standalone Dart/DSH files retain 542cfad provenance and
verified unchanged bytes. `reuse.json` records unchanged source/lock boundaries
and 295 matching installed-host hashes; historical server 459, plugin 114/full
Ruff, gateway and native-host evidence is not presented as newly rerun. All 12
default skips retain their reasons and source definitions.

Windows build/runtime/package, Android/real-fold runtime, real-model semantics
and adversarial content, native settings rendering, network WS, release visitor
sheet clicks, native save dialogs and deletion during a save remain untested.
Complete T01–T17 acceptance remains independent QA's responsibility. No CI
polling/retrigger, main merge, deployment, formal release, Done or user acceptance.

Parent stays in_progress with Muse. Enabled once-only wakeup
`01a1e24c-c115-732c-8372-3a42edea048b` consumes Forge's final reply, verifies the
candidate and owns automated_qa handoff; Forge adds no mention/status transition.
