# DEA-481 fourth client repair integration — deletion rollback remains

Approved revision 1; Forge run `01a1e1ec-18e4-70c6-8a16-2b452db1ec79`.
Sole integration branch `agent/forge/dea-481-integration`, draft PR #35.
Tested code **`73254369a1b54aa46b86565d430c9f7db6806e91`** merges Muse
`2308ca61fc9b35756a2e2bc6a8295544537c5a9f` onto delivery `35c9223`.
Final delivery commits add evidence/documents only. `scope.json` verifies UI
equality and preservation of service, contract, local API/ledger, avatar,
plugin lint and preceding repair ancestors.

**Keep in_progress with Muse; do not route this candidate to automated_qa.**
All eight previous counterexamples pass, but two adjacent real-service probes
show optimistic like rollback restoring a deleted source's reference body.

## Actual checks

- Existing required Flutter entry: analyze exit 0, **697 passed / 12 skipped**,
  **14 Linux integration passed**. Raw logs and stage exit codes are in `flutter/`.
- Eight original probes: **8/8 passed, exit 0, zero skips**. All original source
  bytes are retained, including Sentinel's two newest probes obtained from its
  authenticated attachment `dea481-sentinel-qa2-35c9223f.zip` (attachment ID
  `01a1e1e8-52e5-7317-a01a-54a4336df884`). `sentinel-before/` preserves its raw
  **0/2, exit 1** failures and original checksum manifest. Every checksum in that
  manifest was verified, and Muse's round4 probe matches the original exactly.
- Sentinel's ordinary confirmation retry and retry with an external writer:
  **2/2 passed, exit 0**, using its unchanged control source.
- New rollback probes: **0/2 passed, exit 1, zero skips**. Both failures reach
  the intended assertion, actual `deleted source secret` instead of null.
  The feed and open detail paths fail independently. See
  `rollback-tombstone.jsonl`, `.exit` and `rollback_tombstone_probe_test.dart`.

## Reproduction and cause

1. Real FastAPI/SpaceService publishes source A and repost B referencing A.
2. Start liking B from either the feed or its open detail. Let the actual
   mutation commit; hold its reply. A separate real read asserts B is liked.
3. Delete A through the real API, then consume its real deletion event.
   Assert the visible reference body is null; a separate server read also
   confirms that the source body is no longer exposed.
4. Release the like wait by injecting an unavailable/lost-response error after
   that genuine commit. This is deliberate response-failure injection at the
   gateway, not a claim that an actual socket disconnect was induced.
5. `SpaceController.togglePostLike` restores its captured `original` object;
   `SpaceDetailController.toggleLike` restores captured `current`. Both replace
   the scrubbed reference with the pre-deletion snapshot. The final assertion
   fails in both cases. Real server data stays correctly deleted.

UI reachability was checked in `space_page.dart` (feed onLike) and
`space_detail_view.dart` (detail toggleLike and reference rendering). These are
controller probes with actual server mutations/events, not release click tests.
They do not claim a new server or contract defect, nor identify the introducing
commit. The new response-admission filters do not guard these rollback writes.

## Same-mechanism rework contract

| Field | Required bounded correction / evidence |
| --- | --- |
| root_cause_id | `SPACE-DELETION-LATE-WRITE`: Sentinel's stale refresh on `35c9223` restored deleted content; Forge's feed/detail rollback on `7325436` does the same after the deletion event. Both failure sources/logs are retained. |
| writes/invalidations | Feed initial/explicit refresh, background pending-page creation/application, loadMore append, optimistic like application and failure rollback; detail load, refresh summary, refresh after mutation, optimistic like application and failure rollback; local delete callback, remote post.deleted, reference scrubbing and image-cache invalidation; controller/detail lifetime and account/server replacement. |
| common_fix | Make confirmed tombstones authoritative at every whole-post write, including optimistic rollback. Revert only the like state against the current admitted snapshot, or pass restored snapshots through the same deletion/reference admission boundary. Never overwrite newer deletion facts with a captured object; preserve deleted target state and scrub source references consistently in feed and detail. Retain current admission guards and their passing tests. |
| contract_gap | none; the service already returns deleted placeholders and sends the real deletion event. |
| owner | Muse is the sole client-state correction owner; Forge remains sole integrator. No independent product patch is made here. |

For `SPACE-DRAFT-ACK-LOCAL-STATE`, the new admission-order snapshot correction
passes all previous draft probes and both confirmation-retry controls. This is
bounded evidence for those paths, not exhaustive concurrency proof. For deletion,
first-page late response is now tested passing; detail late-reference coverage is
in the existing unit suite; loadMore/pending-page use the same admission helper.
The two confirmed rollback paths fail and need regression cases in the existing
controller/detail test entry. No whole-case T01–T17 acceptance is claimed.

Run from the repository root after normal locked setup:

```bash
uv run --project server --locked python docs/evidence/dea481-qa-round4/run_probes.py original-eight
uv run --project server --locked python docs/evidence/dea481-qa-round4/run_probes.py controls
uv run --project server --locked python docs/evidence/dea481-qa-round4/run_probes.py rollback-tombstone
```

The runner uses the existing isolated Live fixture and synthetic accounts,
temporary SQLite/media/session state, owned-child cleanup with daemon protection,
and this checkout's ignored `.qa-artifacts/forge-round4/`. No other developer
directory, personal profile, private model credentials or shared CI is touched.

## Scope and handoff

No new UI binary is built for this known-failing candidate. Existing Linux/APK
packages at ed901e0 do not represent this changed runtime. Source and evidence
archives are supplied for reproduction/rework. The unchanged standalone Dart/DSH
packages and service/plugin/host evidence retain their prior versioned scope;
no native lifecycle, model or whole-server rerun is claimed. `skips.json` retains
all 12 default skip reasons and their unchanged sources.

Windows build/runtime/package, Android/real folding devices, real-model semantics
and adversarial content, native settings rendering, network WS and release
visitor-sheet clicks remain untested. No CI polling/retrigger, main merge,
deployment, formal release, Done action or acceptance waiver.

Muse's enabled once-only wakeup `01a1e1eb-e5d6-7de6-afce-9750068c8446` filters
Forge's reply, expires 2026-11-19, and had no recorded error. Deliver this bounded
rework through that registered handoff; do not create another integration run or
trigger Sentinel while these confirmed failures remain.
