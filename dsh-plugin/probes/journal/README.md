Public journal / attempt recovery probe (DEA-467)
================================================

This is an experimental capability probe, not a production bridge. It uses
stock DSH public interfaces and BB-owned metadata. No imports from runtime-patch,
private scheduler access, monkey-patching, external package changes or upgrades.
Read `docs/contracts/dea467-journal-recovery.md` before interpreting results.

From the repository root, in a Multica task:

```bash
node dsh-plugin/probes/journal/run.mjs "$DSH_PACKAGE_ROOT" ./evidence
node dsh-plugin/probes/journal/alternatives.mjs "$DSH_PACKAGE_ROOT" ./evidence/alternatives
node dsh-plugin/probes/journal/busy.mjs "$DSH_PACKAGE_ROOT" ./evidence/busy
node dsh-plugin/probes/journal/settlement.mjs "$DSH_PACKAGE_ROOT" ./evidence
node dsh-plugin/probes/public-host/run.mjs "$DSH_PACKAGE_ROOT" ./evidence
uv sync --project server --locked
uv run --project server --locked python dsh-plugin/probes/journal/live.py \
  --runtime "$DSH_PACKAGE_ROOT" --dart /path/to/dart-sdk/bin/dart \
  --crypto /path/to/existing/crypto-3.0.7 --output ./evidence
```

`run.mjs` creates a fresh directory, runs 29 workers, collects 14 intentional
SIGKILLs, saves traces and original Session crash prefixes, and rechecks the
fixed host hashes. The model and client in this component matrix are explicit
test doubles. `alternatives.mjs` records three alternative public API outcomes.
`busy.mjs` exercises the real driver and journal with a confirmation double.
The previous public-host suite remains an unchanged negative/control suite;
its BLOCKED label refers to its original admission-only algorithm.

`settlement.mjs` creates a fresh evidence directory and tests confirmation failure
before commit, ACK receipt loss after commit, identity changes during those two
client callbacks, and idle plugin disposal. It runs the actual stock driver and
storage with a deterministic model and an explicit in-memory client double.
Failed settlement remains pending; reconciliation can retry only confirm/ACK
without a new model request. Generation changes prevent local completion and
new-identity watermarks; idle disposal removes native listeners. These assertions
do not prove the real client's atomic checks or cancellation during active work.
The runner records each native event, projection, call count, watermark and
pre/post hashes of the same eight external files. See the integration follow-up
in `docs/contracts/dea467-settlement-probe.md`.

For actual v2 settlement and controlled commit faults, run the live command with
`--faults` (it implies v2). This uses `client_fault_host.dart`: the actual BB
LocalAuthServer, services, on-disk ChatLedger and real FastAPI, with public-DI
decorators that pause before/after delegation. New ledger `beforeCommit` hooks
are forwarded, including the original `stillCurrent`/identity checks. No client
production file, DSH implementation or global runtime is changed. The temporary
control port belongs only to this test host and exposes no credentials.

`real-settlement.mjs` connects the original journal/driver to actual v2
confirmation and ACK APIs; it discards one successful response to simulate local
receipt loss. The provider remains a deterministic double. The suite also tests
admitted-send account switch, outer and lock-internal confirmation/ACK fences,
actual wait/event notification plus contiguous ACK, downloads through rebind and
SIGKILL/restart after receiving real bytes, and migration backup failure/cold
reopen/v1 ACK. Migration uses synthetic legacy disk records and a local synthetic
auth session with no backend request; it is distinct from the live-account cases.

The suite collects each failure and **exits nonzero** if any acceptance assertion
fails. A reproduced defect never counts as PASS. See
`docs/contracts/dea467-real-fault-gate.md` for the current failures and limits.
Deliver only results/sources/host-integrity, redacted request/barrier traces and
synthetic native evidence from `confirm-lost/` and `ack-lost/`; never private/.

`live.py` uses the locked server uv environment and the existing Dart/crypto
installation (no Flutter dependency upgrade). It starts only owned, loopback
test services. It verifies operation recovery across an exact child SIGKILL,
Dart restart and a new host Session. Then it intentionally reproduces two
current-client contract failures: consumer B can ACK without receipts after A
has ACKed, and a stale send can execute under a switched account. Exit 0 means
these negative assertions reproduced, **not six-criterion product acceptance**.
When the client is fixed these negative assertions should fail and be replaced
by the agreed positive contract tests; do not weaken them to maintain green.

Add `--v2` to the same live.py command for the **positive** integration gate from
`docs/contracts/dea467-local-v2.md`. It requires the shared OpenAPI routes and
never falls back to v1. It checks actual consumer cursors, owner proof/CAS, stale
send/ACK/confirmation after account switch and A→B→A. It also kills an actual
stock-host operation worker after a successful send, restarts the Dart client,
checks generation invalidation, explicitly rebinds the original consumer and
queries its persisted operation ID from a new worker/host Session (zero sends).
The plan is synthetic and pre-authorized; no model is used. SQLite read-only
assertions verify that rejected stale requests did not create business messages.
The outer runner owns and collects all processes. This mode must exit nonzero on
the original client (negotiate 404), not report skipped/PASS. Until the client
commit is integrated, downstream v2 assertions remain NOT RUN. An eventual exit
0 covers only these assertions, not in-flight races, migration, media or full QA.

NEVER publish the `private/` directory generated by live.py. It contains fake
account credentials, isolated DB/ledger/session and raw local service logs.
Only deliver `results.json`, `sources.json`, and the synthetic `operation/` or `v2-operation/`
evidence (no client credential files). All owned processes are collected before
the runner exits. The pure host evidence contains only synthetic test records.
No personal profile or production account is used.
v2 additionally stores a private consumer capability in the private directory;
never include that file in evidence, model context or logs.

Do not reuse an existing busy/alternatives directory containing sessions. Use a
fresh directory for each run. Run all workers in the foreground, not as detached
services. No real model/vision, full MCP integration, wait matching, session
rebind, in-flight download, migration, UI or Flutter acceptance is implied.
