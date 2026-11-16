# DEA-481 ninth client repair integration — remaining P1

Approved revision 1. Forge run `01a1e233-65b5-7777-9a20-4fd48e3db107`, sole
branch `agent/forge/dea-481-integration`, draft PR #35. Tested runtime
**`3866b265c094f63cfbc59fc4071db80635a6b090`** merges Muse
`f3987ae9da234b8b23cf2b5e3e69017ff268aa6b` onto `ec65ac4`. Final evidence
commit does not change runtime/tests. UI matches Muse; prior service, DEA-484,
avatar, lint and repair ancestors remain. See `scope.json`.

## Results

- Required entry: analyze exit 0; **709 client passes / 12 skips**;
  **14 Linux integration passes**, all stage exits 0.
- Requested set: **19 passes** (18 real-service checks plus one actual
  page/navigation/polling widget with fixture transport). The two original real
  confirmation-retry controls also pass: **21 total, zero skips**.
- New adjacent cases: **0/2, two target assertion failures, zero runtime errors
  or skips, each exit 1**. Both variants remain cached: expected `[false,false]`,
  observed `[true,true]`. Real service returns 404 and unrelated live image
  remains cached before each failing assertion.

`results.json` parses native Flutter JSON events, collection/counts, assertion
classification and exits. All modes ran sequentially with `-j 1`; original
700ms debounce/setup assertions remain unchanged. No pass was obtained by
retries, weakened assertions or enlarged skips. Earlier known probes remain
byte-identical. The new probes are outside default collection pending Muse's
repair and must become permanent regressions in existing entries with that fix.

## Confirmed adjacent failures

Both tests use actual HTTP -> SpaceService -> controller -> image loader,
synthetic accounts and ordinary navigation, with no fabricated feed list or
database edits. An image source and its repost are published before 21 newer
posts, so neither appears in the actual first page. Open the repost, follow its
source reference, and load thumbnail/original through the shared loader.

1. **Return to detail-only repost.** `backDetail()` disposes the source detail,
   leaving only the repost detail in history. Delete the source through real API
   and consume real replay. The remaining reference correctly becomes a deleted
   placeholder, and direct original fetch returns 404; both cached variants
   survive. `_invalidateImagesForPostId` only checks the matching post's detail;
   `_scrubReferencesTo` tells other details to scrub their references without
   notifying the shared image loader first.
2. **Close all details.** After loading, `closeDetail()` disposes both detail
   snapshots. Delete the source and replay. Neither current feed nor pending
   page/details contains its owner, so the helper cannot discover the cached
   images. Both cached variants survive despite real server 404.

The tested cache entry already holds bytes; the existing `load` cache-hit path
can return them without fetching. That is source inspection, not a separate
executed native-save or target-device display claim. Details render reference
image indicators rather than fetched thumbnail pixels; the test deliberately
loads bytes by navigating into the real source detail before returning/closing.

## Shared mechanism rework record

| Field | Evidence / requested correction |
| --- | --- |
| root_cause_id | `SPACE-DELETION-LATE-WRITE`. Sentinel QA6 at `ec65ac4`: local-delete and detail-only invalidation 0/2, exit 1. Those now pass; Forge at `3866b26`: returned-reference and closed-owner paths 0/2, exit 1. Earlier stale-write failures remain versioned. |
| writes/invalidations | Image load/cache/inflight ownership, both variants; local/remote post deletion; feed replacement/pagination/pending-page application; detail open/reference/back/close/dispose; reference scrubbing; account/server reset and clear; viewer-held Futures and save admission. |
| common_fix | Deletion authority must survive removal/disposal of the view snapshot. Before scrubbing a detail reference, invalidate its source bytes. Also retain enough post-to-image ownership while cache/inflight bytes live, or invalidate them before the last owner snapshot is dropped. Reuse the existing generation/epoch and shared loader boundary; do not limit the correction to whichever current lists happen to contain the post. Preserve unrelated live-image access. This is a repair requirement, not a Forge production implementation. |
| contract_gap | none; existing post identity, image identity and server deletion/404 semantics suffice. |
| owner | Muse is the sole client-state repair owner. Forge remains sole integrator/service-contract owner. |

Known cases cover local feed deletion, current direct detail deletion, existing
draft/post/comment/notification/rollback and image-generation/viewer behavior.
New cases cover removal of the original detail owner with/without a remaining
reference. Pending-page ownership, feed replacement, multiple simultaneous
views, clear/retry and native-save interleavings are not exhaustively tested;
they must be reviewed against the common lifetime rule, not claimed as proven.

## Reproduction and provenance

From repository root after normal locked setup:

```bash
uv run --project server --locked python docs/evidence/dea481-qa-round9/run_probes.py deletion-entry
uv run --project server --locked python docs/evidence/dea481-qa-round9/run_probes.py detail-reference
uv run --project server --locked python docs/evidence/dea481-qa-round9/run_probes.py closed-detail
```

The final two commands are expected to fail on this runtime. All other modes and
commands are recorded in `results.json`. The existing Live fixture owns and
cleans isolated FastAPI/standalone Dart processes, temporary accounts and storage.
No personal DSH/model credentials or other worktrees were used. Original Sentinel
attachment `01a1e230-94c6-7cd7-ba8c-7d4da0fc9a0c`,
`dea481-sentinel-qa6-ec65ac4.zip`, is preserved under `sentinel-before/qa6/`;
its manifest was verified and the new specified source matches Muse byte-for-byte.
One initial extraction verification assumed a flat ZIP; it was corrected to the
archive's `qa6/` directory before tests. This was a preparation error, not a
product test failure and is not counted.

## Delivery decision and limits

**Remain in_progress for Muse rework; do not hand this candidate to QA as fixed.**
Only source/evidence/checksums are delivered for this incomplete runtime. No new
UI package is built; old ec65ac4/6ff6f82 packages do not represent this version.
Unchanged server/plugin/gateway/native-host evidence remains historical within
the source/lock scope in `reuse.json`; 295 installed host source hashes match.
Those suites and installed-host lifecycle were not rerun here. Existing default
skip reasons remain explicit and separate historical runs do not convert skips.

Windows build/runtime/package, Android/real-fold runtime, real-model semantics
and adversarial content, native settings rendering, network WS, release visitor
sheet clicks, native save dialogs and deletion during a save remain untested.
No new release smoke/build/device validation is claimed. Full T01–T17 remains
incomplete. No CI polling/retrigger, shared CI/DEA-480 edits, merge/deployment,
formal release, Done or acceptance waiver.

Muse's enabled one-shot wakeup `01a1e233-4316-7dc9-9fb4-0932ba190351` consumes
Forge's final comment. Its concrete-gap branch applies: keep in_progress and
repair the above common mechanism before producing the next candidate. No
additional agent mention or workflow transition is issued by Forge.
