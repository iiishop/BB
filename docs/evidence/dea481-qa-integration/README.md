# DEA-481 integration of first QA fixes — additional draft failures

Forge run `01a1e1c2-6d2a-79a6-a94e-f20ab2844cc5`, approved revision 1.
Only integration branch: `agent/forge/dea-481-integration`, draft PR #35.
Merged Muse `2e5f758a8c13a84ff4e5de95e7c460849aa786cb` onto the previous fixed
candidate `942dd46a601d4604cb9273c9830d472cda41378c` without rewriting history.
**Integrated code: `8b2f787a0d60b4f09686ed7a1dcbde7576831a02`.** Later delivery
commits contain evidence/documents only. The UI tree matches Muse's delivered
tree; existing service, ledger, avatar and full plugin-lint fixes remain ancestors.

**Do not advance this candidate to automated_qa: two real draft failures remain.**
The three originally reported P1 probes pass, but that does not close the shared
draft state mechanism or constitute overall acceptance. No new UI binary package
is issued for this failing candidate; source and evidence are provided for repair.
Previous UI packages do not represent this new runtime. Unchanged server/local
API/plugin evidence remains valid only within its original scope.

## Actual checks

The existing required Flutter script passed analyze, **691 client tests / 12
skips**, and **14 Linux integration tests** (`flutter/`, exit 0). The additional
real probes below are outside that default suite and must not be hidden by its
green summary. `results.json` mechanically parses both sets of results.

The three original Sentinel probes ran unchanged against isolated real FastAPI
and the actual SpaceService: **3 passed / 0 skipped, exit 0** (`original.jsonl`).
Their source SHA-256 is
`28f70598526dda61cb2a026bdccac7f8268976b981676cbf54af9c0c97df8ca7`.
It matches `sentinel_real_space_test.dart` byte-for-byte in the authenticated
attachment `dea481-sentinel-qa-942dd46a.zip` (attachment ID
`01a1e1bb-40e2-7990-ac56-36db94739541`). The original report/logs are retained
under `sentinel-before/`: **0 passed / 3 failed / 0 skipped** on `942dd46a`.

Two adjacent real-service probes on the new integrated candidate both fail:

1. **Image removal while a save receipt is delayed is undone.** Create a real
   draft with an uploaded image; accept a text save at the server but hold its
   reply; remove the image locally; release the old reply. Removal is visible
   before release. Afterwards `c.images` contains the image again rather than
   remaining empty. `_sameOrder([], [image])` merges the missing server image
   back before comparison, incorrectly treating the changed membership as
   unchanged. Save confirmation then restores the older server image list.
2. **Uploading an image erases text already dirty at upload admission.** Type
   `unsaved before image selection`, call the actual image picker/upload path
   before the 700ms save debounce, and await upload confirmation. The image is
   successfully uploaded, but `c.text.text` is now `''`. `_upload` compares the
   live editor only with its entry snapshot; because no further typing occurred
   during the upload, it overwrites the already-dirty input with `draft.text`.
   `_refreshDraftImages` uses the same admission-versus-completion comparison.

`adjacent.jsonl` records **0 passed / 2 failed / 0 skipped**, exit **1**. Neither
failure is a compile/fixture failure: the real upload succeeds, the delayed save
is accepted, and the explicit data-preservation assertions fail. The delayed
gateway only gates an actual response after actual commit; it does not replace
the native/API boundary or business implementation.

## Same-mechanism rework contract (before further product changes)

| Field | Handoff |
| --- | --- |
| root_cause_id | `SPACE-DRAFT-ACK-LOCAL-STATE`: confirmed first by Sentinel's old-save/new-text failure on `942dd46a`, and again by the two adjacent failures on `8b2f787` after the first repair |
| writes/invalidations | `start`/dirty-buffer reopen; `onTextChanged`; `saveNow` receipt and confirmation read; `removeImage`/`moveImage`; picker admission, `_upload`, `_refreshDraftImages` and retry; explicit server-version reload; `_persist`; publish readiness; discard/timer/pending-response cleanup |
| common_fix | Reconcile confirmed server facts against the exact accepted payload and all outstanding local intent. Exact order/membership comparison must not merge missing image IDs before deciding equality. Preserve edits already dirty at upload admission as well as edits made while IO is pending. Merging a newly uploaded image must not resurrect an intentional local removal. Keep baseline/conflict and publish readiness consistent across those paths. No new generic framework or wire contract is required. |
| contract_gap | none; real server CAS and image operations behave correctly in these probes |
| owner | Muse for this bounded client UI-state correction; Forge remains sole final integrator |

Coverage: original text race, dirty reopen and deletion-reference probes pass.
Image removal during save and already-dirty text during upload fail as above.
Image reorder/confirmation retry share the changed comparison/merge paths but
have no new independent real probe in this run; discard and explicit reload use
existing tests. This is not a claim that the adjacent-entry audit is complete.
Carry both failures into the existing compose regression entry when fixing them,
then rerun the unchanged real probes and integrate a new fixed SHA.

## Reproduction and safety

From repository root, after normal locked project setup:

```bash
uv run --project server --locked python docs/evidence/dea481-qa-integration/run_probes.py original
uv run --project server --locked python docs/evidence/dea481-qa-integration/run_probes.py adjacent
```

The runner uses the repository's existing `Live` fixture: private temporary DB,
synthetic accounts, actual server and standalone Dart processes, daemon-PID check
before terminating owned children, and cleanup on failure. Probe copies live in
this checkout's ignored `.qa-artifacts/forge-qa-integration/`. Muse's historical
hardcoded-workspace runner was not executed; no other developer directory was
modified. No private model credentials or personal profile were read.

The unchanged skip definitions and earlier service/DSH evidence keep their prior
boundaries. Windows build/runtime/package, Android/real foldable devices, real
model semantics/adversarial content, native settings rendering, network WS and
actual release visitor-sheet clicks remain untested. No CI job is dispatched or
waited for manually. No shared CI/DEA-480/server/contract/ledger file is changed.

Muse's existing once-only wakeup `01a1e1c2-4142-7829-9810-d7868f2cae6c` consumes
Forge's final reply. Keep `in_progress` assigned to Muse, repair the concrete
failures, then return a fixed source candidate to Forge. Do not trigger Sentinel
for this candidate. No main merge, deployment, formal release or Done action.
