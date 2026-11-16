# DEA-481 second QA-fix integration — upload version conflict remains

Forge run `01a1e1cd-3125-739b-a8b7-1309ce0e2ff5`; approved revision 1;
sole integration branch `agent/forge/dea-481-integration`, draft PR #35.
Integrated Muse `9415fb8a04126bcf7c336030a81383f9d6a8581a` onto `d463cf7`.
**Tested code: `6a4f0e096ace18da9eeea0e06f74a513b634e065`.** Subsequent delivery
commits add evidence/documents only. The delivered UI tree matches Muse; server,
DEA-484/local API, avatar and plugin-lint corrections remain ancestors.

**Keep in_progress; do not hand this candidate to automated_qa.** All five prior
counterexamples are fixed in the tested paths, but another actual multi-writer
upload confirmation case still silently overwrites committed remote input.

## Results

- Existing required Flutter entry: analyze PASS; **693 client passes / 12 skips**;
  **14 Linux integration passes**, exit 0. Logs are in `flutter/`.
- The original Sentinel three plus Forge adjacent two real-service probes:
  **5 passed, 0 failed/skipped, exit 0** (`original-five.jsonl`). Their source
  bytes match the original files and Muse's copies exactly; no assertions were
  changed. Previous 0/3 and 0/2 failure evidence remains in earlier directories.
- The new upload/version probe: **0 passed, 1 failed, 0 skipped, exit 1**
  (`upload-conflict.jsonl`). This is outside the default test suite; its failure
  is not overridden by the green existing suites.

Reproduction uses real FastAPI, SpaceService and actual versioned requests:

1. Start a real draft and type `pending local text` before the save debounce.
2. Upload a real PNG. The server commits it and returns an operation version;
   hold that actual response before delivery to the compose controller.
3. A second authorized writer reads the committed draft, then saves
   `other client committed` against that real version. This advances the server
   version while preserving its image IDs.
4. Release the upload response. The controller reads the newer draft, then its
   new common reconciliation method schedules an automatic save of the pending
   local input against the **newer reader version**.
5. After the debounce, the authoritative server text is `pending local text`,
   not the other writer's committed text. The assertion fails. Expected behavior
   is preserving the remote commit and local input while surfacing conflict.

The setup verifies the upload receipt version equals the server version before
the other write, and that the controller remains dirty before the upload reply
is released. It only delays a genuine response after commit; no fake server or
alternative business implementation is used. Synthetic credentials stay in
temporary state and are not printed or delivered.

## Same-mechanism rework contract

| Field | Evidence / required next correction |
| --- | --- |
| root_cause_id | `SPACE-DRAFT-ACK-LOCAL-STATE`. Earlier evidence: Sentinel's stale-response/reopen failures on `942dd46a`; Forge's remove-image/dirty-upload failures on `d463cf7`. Those five now pass. New evidence: upload confirmation adopts a newer writer's version on `6a4f0e0`, then overwrites its text. |
| writes/invalidations | start/buffer restore; text/remove/reorder; save receipt and confirmation read; `_upload` and `_refreshDraftImages` → `_reconcileAfterUpload`; `_persist`/baseline version; scheduled save and publish; explicit server reload; discard/pending-response handling. |
| common_fix | Keep the version acknowledged by the mutation distinct from a later read's version. When a later writer advanced the draft and local intent differs, preserve that intent and enter conflict instead of rebasing it automatically. Carry the acknowledged upload version through confirmation-read retry as well. Retain strict member/order comparison and previously fixed local deletions; audit pre-existing dirty image membership/order as well as text. |
| contract_gap | none: operation receipts already carry resourceVersion and server CAS works in the original real conflict probe. The controller must not treat a newer read as permission to overwrite it. |
| owner | Muse for bounded UI draft-state correction; Forge remains sole integrator. No independent product patch made by Forge. |

Five prior paths have fresh passes. The new external-writer upload path fails.
The confirmation-refresh path shares `_reconcileAfterUpload` and also adopts the
read version; it has no separate real retry probe in this run and is not claimed
covered by the direct-upload failure. The pre-existing dirty-image-order variant
needs audit; it is not presented as a separately confirmed failure. Preserve this
counterexample in the existing compose regression entry with the correction.

## Reproduction

After the repository's normal locked setup, run from its root:

```bash
uv run --project server --locked python docs/evidence/dea481-qa-round2/run_probes.py original-five
uv run --project server --locked python docs/evidence/dea481-qa-round2/run_probes.py upload-conflict
```

The runner uses the existing isolated `Live` fixture, owned-child cleanup with
daemon-PID protection, and this checkout's ignored `.qa-artifacts/forge-round2/`.
No other developer directory or private profile is touched. `results.json`,
`scope.json` and SHA256SUMS give source equivalence, counts, exits and hashes.

No new Linux/Android UI package is built/issued for this failing candidate;
old UI binaries do not represent it. The new source/evidence archive is for
reproduction and repair. Unchanged standalone Dart/DSH binaries may only be
reused within their original versioned scope and byte mapping.

Windows build/runtime/package, Android/real foldable devices, real-model semantics
and adversarial content, native settings rendering, network WS and actual release
visitor-sheet clicks remain untested. No new server/native acceptance is claimed,
and the twelve default skips retain their earlier explicit reasons. This is not
full T01–T17 acceptance. No manual CI dispatch/wait, main merge, deployment,
formal release, shared CI/DEA-480 edit or Done transition.

Muse's registered once-only wakeup `01a1e1cd-02c5-72d7-b065-85b28e09ef0e` consumes
Forge's final reply. Keep in_progress assigned to Muse and repair the version
boundary before returning a new candidate; do not trigger QA for this version.
