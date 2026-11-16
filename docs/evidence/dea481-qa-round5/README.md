# DEA-481 fifth client repair integration

Approved revision 1; Forge run `01a1e1f4-c931-7de7-a6cd-2e585b3b8169`.
Sole branch `agent/forge/dea-481-integration`, draft PR #35.
Tested/build code **`ec71e5112f76d3f0eab0c3d7dc2c82ea9754b3e6`** merges Muse
`c38a961e20f071c032ec9869433e3a5e946ce342` onto `8a57faa`. Final delivery
documentation commits preserve this code tree. `scope.json` verifies UI equality
and all server, DEA-484/ledger, avatar, plugin lint and previous repair ancestors.

## Fresh regression evidence

- Required Flutter entry: analyze exit 0; **699 passed / 12 skipped**;
  **14 Linux integration passed**. Stage exits and raw logs are in `flutter/`.
- Eight earlier real FastAPI → SpaceService counterexamples: **8/8 passed**.
- The two feed/detail rollback counterexamples: **2/2 passed**. Their source is
  byte-identical to Forge's failing original; Muse's copy also matches.
- Sentinel's normal confirmation retry and retry with an external writer:
  **2/2 passed**, using its original control source. All three real-probe
  commands exit 0 with zero skipped tests. Counts are parsed in `results.json`.

All ten confirmed counterexamples now pass in the tested paths. Original failures
remain in earlier directories, including `../dea481-qa-round4/` (rollback 0/2,
exit 1 on code `7325436`, delivery `8a57faa`) and its `sentinel-before/` archive.
No assertions were relaxed, deleted or skipped. These results are bounded checks,
not whole T01–T17 acceptance or exhaustive concurrency proof.

The rollback probe commits a real like, holds its response, deletes the source
through real FastAPI, consumes the deletion event and verifies both client and
server have scrubbed the reference. It then injects loss of the committed reply.
The current feed/detail snapshot now retains the deleted placeholder after
rollback. This is deliberate gateway response-failure injection; it does not
claim a physical network disconnect. No fake business database is used.

## Same-mechanism closure and entry coverage

| Field | Implementation / evidence |
| --- | --- |
| root_cause_id | `SPACE-DELETION-LATE-WRITE`: stale response failure on `35c9223`, rollback failures on `8a57faa`; preserved before logs, now-passing original probes. |
| writes/invalidations | Feed initial/refresh, loadMore, pending-page creation/application; detail load, summary and post-mutation refresh; both optimistic like applications/rollbacks; local/remote delete, reference/image invalidation; controller/detail and identity lifecycle. |
| common_fix | Incoming snapshots retain the existing tombstone admission guards. Like rollback copies the live snapshot and changes only liked/likeCount; detail rollback additionally rejects deleted/tombstoned targets. Captured whole objects no longer replace current deletion/reference facts. |
| contract_gap | none; service deletion placeholders and events are unchanged. |
| owner | Muse owns client-state fixes; Forge owns sole integration and service/contract boundaries. |

Fresh real probes cover stale first-page refresh, consumed deletion/reference
invalidation, and both like rollback paths. Detail late-reference admission and
ordinary controller operations run in the existing unit suite. loadMore and
pending-page admission share the tested `_admitIncoming` helper; detail read
entries share `_admitPost`. The deleted-target rollback guard is code-reviewed;
there is no separate real delete-target-during-like probe here. Arbitrary identity
switches, image-cache/native rendering races and every concurrent permutation
are not claimed covered by these ten probes.

`SPACE-DRAFT-ACK-LOCAL-STATE` retains strict local-intent reconciliation, upload
receipt version fences and admission-order snapshots across confirmation retry.
Its previous text/save/reopen/image-removal/upload/version probes all pass, as do
the two real normal/conflicting retry controls. Existing unit tests cover ordinary
reorder/publish/reload/discard behavior; broader combinations remain independent
QA scope. No new draft-state changes were made in this round.

Reproduce from repository root after normal locked setup:

```bash
uv run --project server --locked python docs/evidence/dea481-qa-round5/run_probes.py original-eight
uv run --project server --locked python docs/evidence/dea481-qa-round5/run_probes.py controls
uv run --project server --locked python docs/evidence/dea481-qa-round5/run_probes.py rollback-tombstone
```

The existing Live fixture uses synthetic accounts, temporary SQLite/media/session
state, actual server/standalone Dart processes and owned-child cleanup. This run
uses ignored `.qa-artifacts/forge-round5/`; no other developer worktree, personal
profile, private credentials, shared CI or DEA-480 exclusive file is modified.

## Artifacts, reuse and limits

Fresh Linux/Android UI and source artifacts are mapped to this code SHA in
`artifact-map.json`; old ed901e0 UI packages are superseded. Build commands/exits,
signature checks and real release smoke results are recorded separately: all
exit 0. Actual synthetic-avatar upload, unauthenticated GET 401, ETag 304 and
1,248 rendered color pixels passed; the screenshot was visually inspected. Both
Linux packages match all 21 payload files of the smoked build. APK
signing uses the existing public debug test certificate, not production signing.
ADB has no attached device. Linux runtime is not evidence of Windows or Android
runtime, nor is a deb built on Arch evidence of Debian installation compatibility.

Unchanged standalone Dart and DSH bundle bytes retain their original 542cfad
build provenance. `reuse.json` records unchanged code/lock scope and 295 installed
DSH source hashes matching earlier evidence. Server 459-pass, plugin 114-pass/full
Ruff, gateway and native host checks are reused only within that scope; none is
claimed as freshly rerun here. `skips.json` preserves the twelve default skip
reasons; prior opt-in live runs do not change default skips into passes.

Windows build/runtime/package, Android/real folding runtime, real-model semantics
and adversarial content, rendered native settings, network WS and release visitor
sheet clicks remain untested. No new CI status is collected; the old Windows run
link is only a historical reference, not current success evidence.

Parent stays in_progress with Muse. Enabled once-only wakeup
`01a1e1f4-a316-74c4-bee8-11fbf00320c6` consumes Forge's final reply; Muse verifies
the new candidate and owns automated_qa handoff. No extra mention, status change,
main merge, deployment, formal release or Done action is made here.
