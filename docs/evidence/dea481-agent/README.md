# DEA-484 agent access evidence

Implementation candidate: `87c3807caa70b58914caf28c21b18d47386dfd15`.
Baseline: `d402ba8cecdfdbfb421eef23165483b24f3bd1a3`; approved product revision 1.
Branch: `agent/forge/dea-481-agent-access`. Run: `01a1e164-cd45-7d81-b0c3-9251ede81d30`.

`checks.json` records actual commands, durations, exit codes and hashes.
Every final command exited zero. JUnit/JSON reporters were parsed mechanically:
114 Python/plugin tests passed, zero skipped; 46 targeted Dart tests passed,
zero skipped. The plugin suite includes existing dependency-free JS regressions.
Dart analyze and changed-scope Python ruff passed. No CI/job/dependency changed.
The server tree is byte-for-byte unchanged from the baseline; previous server
459-test evidence applies to that tree, not to this complete client/plugin path.

## Executed boundaries

- Real FastAPI TCP + independently launched `client/bin/bb_client_api.dart`:
  private drafts, publication and receipt lookup/replay, owner key rejection,
  original account/consumer isolation, author visitor permissions, version
  conflict, explicit mark-read/notification ack, cold server/client restart,
  stale generation rejection and rebind, global HTTP event replay/dedup,
  deletion/snippet invalidation, and revoked session clearing.
- Stock installed DSH `0.2.1-rc.5`, Node `v26.8.2`: public plugin-manager install,
  settings save, reload/restart, 24 discovered Space tools, generated durable
  mutation IDs, ten images and reversed stable-ID ordering, native image bytes
  read back from the provider attachment seam, explicit read, visit dedup,
  self-notification absence, comment/context, likes, author visitor query,
  preserved draft/receipt after host restart, no republish/no autonomous wakeup,
  deleted-image refusal, disabled MCP tool removal, host bundle deselection and
  removal/restart. `host-result.json` proves installed host source hashes did not
  change. The provider was a deterministic double, not a real model.
- Dart fault tests: intent-write failure prevents dispatch, atomic rollback and
  cold reopen, lost server reply reconciles without a second mutation, account
  switch while IO is pending saves only the original receipt and refuses the
  outward result, and consumer operation-ID ownership.
- Both real local requests/responses and Python transport doubles use the single
  Pydantic schema. Generated Dart schema equality is a permanent plugin test.

## Confirmed regression

`client-before.log` records the consumer ID reuse counterexample against the
initial `3887595` implementation: another consumer of the same account could
plan the first consumer's ID. The assertion failed (4 other tests passed).
`9dbc1b9` fixed the common existing-ledger plan boundary: same server/account ID
may belong to only one consumer; another server remains isolated. The same test
passes in the final 46-test run and the actual TCP probe. Receipt lookup was
already scoped; planning, query, retry and cold reopen now have regression checks.
Intent and receipt writes share existing ChatLedger atomic flush/rollback; no
content snapshot, additional credentials or Space business database was added.

## Probe corrections / limitations

`native-probe-correction.log` preserves the initial probe's wrong assumption that
bridge enabled=false meant a host bundle was unloaded. Stock host correctly
requires deselect bundle → restart → remove → restart; the corrected probe tests
that public lifecycle. Two initial MCP discovery tests expected the pre-Space
exact tool set and were extended to the schema-derived Space set (no assertion
removed). TCP probe setup also required distinct session IDs for distinct owners;
comment context asserts target/root rather than assuming a sole root has nearby
siblings. These were probe corrections, not product/host modifications.

Uvicorn's locked environment still lacks a network WebSocket backend. No repeated
upgrade probe, patch or dependency change was made. Actual HTTP global replay
and recovery passed. This does not claim network WebSocket delivery.

Not run: semantic real-model image understanding or prompt-injection resistance,
Windows/Android/foldable devices, UI screenshots/layout/navigation, rendered
settings form interaction. No model credential was read. UI invalidation and
unsynchronized input belong to Muse; the shared service keeps no content cache.
The setting editor source was unchanged. Prior UI/device evidence is not claimed
as part of this run. Full combined candidate/QA remains with parent DEA-481.

Delivery package is built by the existing `dsh-plugin/build_bundle.py`; its own
Python source, unchanged uv lock and shared contract are bundled. Evidence and
bundle zip are attached to the issue. No production deploy, main merge, release,
private profile edit, shared CI edit or issue Done action occurred.
