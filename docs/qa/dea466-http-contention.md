# DEA-466 HTTP/SQLite contention investigation

**Investigation complete; first-attempt availability remains FAIL; bounded recovery and idempotency PASS.** This is Forge's scoped investigation, not independent product QA. The issue remains in_progress with its existing assignee. No client files or DSH runtime were changed.

## Baseline and scope

Started from requested `a54b6cb5ada91b7853cbb1d24d1130cdd892a5ae`, then fast-forwarded the working branch to the newly reviewed `a727385fa9dbbb29c2f18f185e0297890a66088f`. `git diff a54b6cb5 a727385 -- server dsh-plugin` is empty. This preserves the entire latest client/history; branch `agent/forge/dea466-http-contention`. Final commit/bundle hashes are in the handoff comment and evidence manifest.

Read both Sentinel evidence packages and original three failure logs. Their hashes are `f1e6289f1e012e78edaf1a387236b0aad19517cecee7a5f69d61431b8f3c5f64` (R3) and `870a18dcd37e35a61ba5263503d2fea60380661d1e14ef3bd5455ecc4839b324` (R4). The two `qa-r3-extra.py` copies match. A byte-identical copy is retained at `server/probes/fixtures/sentinel_qa_r3_extra.py`, SHA256 `df730d267e8d1c1c58c071656af03f8ba66465d7243dcc470f0854e7c4b4d1e5`.

Load stays 120 sends with 8 workers, then subscription concurrent with the last 2 sends. Messages use the original body and `qa-backfill-N` nonce. HTTP timeout stays 15 seconds; SQLite timeout stays 1 second. Every run uses fresh synthetic accounts, an isolated database and the actual Dart client. No models, MCP or DSH inference are exercised by this pressure script, despite its inherited generic summary labels/unused runtime parameter.

## Evidence and diagnosis

| Stage | Repetitions | Exit / result |
| --- | --- | --- |
| Unmodified original on a54b6cb5 | 3 | 1 / 1 / 1; all stop during initial sends with 503 |
| Original on a727385, opt-in SQLite observation | 3 | 1 / 1 / 1; SQLITE_BUSY at BEGIN IMMEDIATE |
| Minimal auth fix, original assertions/no retries, same observation | 3 | 1 / 1 / 1; remaining SQLITE_BUSY at message submit |
| Minimal auth fix, bounded reconciliation/retry | 3 | 0 / 0 / 0; original 5 assertions + added recovery/integrity check PASS |
| Targeted contention + original presence tests | 8 tests | exit 0 |
| Full server pytest | 105 tests | exit 0; one existing Starlette/httpx warning |

Original scripts abort before the second phase when the first non-200 is encountered. Their `finally` summary can misleadingly say `failures:0` with no completed checks; those runs are **FAIL**, and subsequent registration/replay assertions **NOT RUN**. All failures remain in the evidence package.

Diagnostic `server/probes/sql_trace/sitecustomize.py` is activated only by this test's PYTHONPATH/BB_SQL_TRACE. It records connection/SQL operation/transaction-exit elapsed times, SQLite error name and whether a transaction began. It does not change SQL, connection timeout, journal/synchronous modes or retry, and does not log parameters, tokens or response bodies. Normal production startup does not load it.

On the latest unmodified baseline, three runs had respectively 2/2/2 `SQLITE_BUSY` failures: five in `find_session` and one in `submit`, all at `BEGIN IMMEDIATE`, with 1001–1003 ms waits and `in_transaction=false`. No observed error was a constraint, malformed input, read-to-write upgrade, or commit failure. Transaction exit durations reached 18–26 ms in those runs. Authentication unnecessarily competed for the single writer lock on every authenticated request, including read/event polling, even with all sessions fresh. The native SQLite busy budget then expired under repeated writer competition; the numeric one-second timeout alone was not taken as a root-cause diagnosis.

## Minimal change and limits

`server/src/bb_server/storage.py::find_session` first checks whether offline transition/expiry work is actually due. With no due work it reads the identity without acquiring the writer lock. With due work it still acquires `BEGIN IMMEDIATE`, rechecks through the existing maintenance UPDATE/DELETE predicates, and reads the session in that transaction. No read transaction is retained during lock acquisition. Heartbeat, maintenance, expiry boundaries, logout and invalid-session behavior are unchanged; the original presence suite is retained and passes.

The new lock regression proves an active-session read succeeds while a different connection holds a reserved writer lock, whereas a message write returns the existing bounded 503. A second test verifies due maintenance still fails safely under the same lock and subsequently performs offline transition/24h expiry without resurrection.

This removes unnecessary authentication write contention. It does **not** guarantee no 503: all three no-retry reruns still failed at `submit` (3/1/3 observed SQLITE_BUSY errors). Some commit/transaction-exit waits reached 103–118 ms. We did not increase timeouts, reduce concurrency, add an unbounded queue, change durability modes or promise SQLite writer fairness. No evidence in this investigation requires a new wire API, schema or migration.

## Bounded recovery and facts

The diagnostic driver `server/probes/chat_http_contention.py --recover` retains the original fixture and its five assertions, relocates only HERE, observes every send, and enables a test-caller recovery policy. It adds no production retry behavior and does not claim the Dart UI automatically executes this policy.

Policy: at most three reconciliation rounds with 50/100/200 ms backoff. For a transient 502/503/504 or transport-unknown result, query `/operations/{same_nonce}` under the same account first. If 200, reuse that committed message; if 404, retry the original body and nonce; an unknown/503 query does not authorize a send in that round. Other errors stop. Budget exhaustion propagates failure. Requests still have their original 15-second HTTP timeout; this is bounded, not a 350-ms total latency guarantee.

Three real HTTP runs completed the original 122-event workload and the five Dart checks. Natural initial 503 counts were **2 / 2 / 0**. Each actual failed initial send resolved after one query-404 and one same-key retry; no second resend was needed. The first 122 operations yielded exactly **122 messages, 122 operations, 244 events** (one event per participating account/message), contiguous positions 1–122 and no duplicate event/account pairs. Registration during arrival, 50-entry pagination, repeated subscription/Dart restart, illegal-receipt atomic rejection, 12 concurrent confirmations and restart/ACK all passed in these recovery runs.

Each run also performed:

- Query a committed original nonce, replay it concurrently 8 times, and require the exact same message result and unchanged database counts.
- Hold a real SQLite `BEGIN IMMEDIATE` lock, receive HTTP503, query404, release the lock, then reconcile/retry once. Exactly one new message/two events.
- Actually commit another HTTP send, discard its successful receipt at the caller, query before any resend, and recover the exact same message. Exactly one new message/two events; no resend needed.

Final counts in each run were **124 messages / 124 operations / 248 events**. These observations support retryable competition with transaction atomicity/idempotency, not data loss or a broken nonce protocol. The fixture's fail-fast expectation explains why it could not reach later checks; it did not fabricate the genuine 503. No blanket claim is made for every possible storage error, crash, filesystem or sustained load.

## Reproduction

Install server's locked uv environment. `$CLIENT_SHA` is the reviewed full HEAD whose client tree is clean; use this branch's final SHA after checkout. Dart executable and cached crypto 3.0.8 are explicit local inputs, not personal deployment configuration. From repository root:

```sh
uv run --project server --locked python server/probes/chat_http_contention.py \
  --evidence ./server/.evidence/observe-1 -- \
  --client ./client --expected-client-sha "$CLIENT_SHA" \
  --runtime ./dsh-plugin/.runtime/dsh-rc5-r3-handoff \
  --dart "$DART_SDK/bin/dart" --crypto "$PUB_CACHE/hosted/pub.dev/crypto-3.0.8"

uv run --project server --locked python server/probes/chat_http_contention.py \
  --recover --evidence ./server/.evidence/recovery-1 -- \
  --client ./client --expected-client-sha "$CLIENT_SHA" \
  --runtime ./dsh-plugin/.runtime/dsh-rc5-r3-handoff \
  --dart "$DART_SDK/bin/dart" --crypto "$PUB_CACHE/hosted/pub.dev/crypto-3.0.8"

uv run --project server --locked pytest server/tests -q --tb=short
uv run --directory server --locked ruff check src tests probes/chat_http_contention.py probes/sql_trace/sitecustomize.py
```

Use a fresh evidence directory for each run; repeat recovery at least three times and retain any failures. `observe` may fail before the post-load checks; `recover` is a separately reported recovery result, never a relabeling of the original raw-load result. Exact invocations, exits, elapsed times, HTTP outcomes, lock traces and counts are attached. Original fixture style is preserved verbatim rather than reformatted to satisfy lint. Services/child processes are collected in the foreground with the fixture's owned-process/daemon guard.

The report and driver do not modify the machine contract/OpenAPI. Existing 503 `storage_unavailable`, stable account+client_nonce/operation_id, lookup, conflict409 and transactional message/event semantics remain in force. Unknown results should be reconciled; neither a 503 nor a missing HTTP receipt justifies choosing a new business nonce.

## NOT RUN / handoff

Plugin pytest and native recovery matrices were not rerun: this increment changes server authentication storage only; full server regressions ran. New Sentinel media identity and download-write failures are client-owned and remain outside this fix. Flutter/builds/devices, actual media interactions, true models/vision, full integrated fault matrix and independent QA of this new SHA are NOT RUN here. Windows is not a blocking target per issue scope. No Owner Review, main merge, release or Done action.

Evidence packaging excludes private directories, credentials and raw databases. Only synthetic diagnostic logs/HTTP status and readonly aggregate counts are delivered. The existing client source tree is preserved exactly from a727385. Orion should integrate this limited server increment and decide whether the remaining first-attempt 503 rate requires a separate availability target; bounded recovery evidence must not be reported as zero-contention throughput.
