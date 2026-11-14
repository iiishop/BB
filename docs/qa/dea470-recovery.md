DEA-470 recovery and consumption review
======================================

Scope: issue specification v1 (body's first two layers), baseline
`452e88e2288a909e533e4c993e9806f1e5c83be9`. No client DTO changes, dependency
changes, automatic reconciliation timer or resend. The first commit isolates
404/transport recovery; the second isolates peer guards, their regression entry
and documentation. Review the final branch head as one candidate.

State and write order
--------------------

1. Flush the native tool-call context, then durably reserve logical key,
   operation ID, payload digest, session incarnation and affected peers.
2. Check current client ownership, then call the existing MCP business tool.
3. Reconcile by the original ID. A send 404 is `failed_absent`; network,
   timeout and 5xx preserve unresolved `uncertain`. Authentication/ownership and
   schema failures still reject. Lost replies never authorize another send.
4. Independently retain native presentation/turn proof. Before confirmation or
   ACK, require the peer's operations and input uncertainty to be resolved.
   Client ACK remains contiguous; an out-of-order receipt stays `presented`.
5. After ACK, mark the input `completed`. Cold recovery retains original receipt,
   digest and operation ID; committed inputs are not projected again.

`failed_absent` is plugin metadata, not a new HTTP operation status. It says the
client has no record in this scope; a previously admitted remote side effect may
still exist. Terminal records and IDs are retained. A later authoritative query
can discover a real result; a failed query cannot reopen a terminal record.

Shared entry coverage
---------------------

| Entry | Common rule / regression |
| --- | --- |
| Passive poll and direct claim | Same peer guard; blocked A does not stop B; pending native input is not duplicated. |
| Wait admission/result/cleanup | Peer reservations; same-peer conflicts reject; post-result claim rechecks uncertainty introduced while waiting. |
| Read/get-message/get-context | Existing post-execute hook funnels receipts through claim. Blocked results may remain read-only context, but cannot gain consumption proof. |
| Recover/resumeDelivery | Same guard before delivering a reserved input; session incarnation fence retained. Absent operations do not require an old session, but unsettled native inputs do. |
| Settle, turn observer and tick | Same uncertainty rule before confirm/ACK. Retain successful proof while blocked; real gap tests check no cursor holes. |
| Send/attachment/download wrappers | Persist target and source peers before business dispatch. Downloads have no target peer and use source peers; missing download facts remain uncertain. |
| Old records without peer metadata | Allow new inputs, withhold all confirmation/ACK while scope is unknown. Explicit reconciliation releases the guard; no guessed peer or destructive migration. |
| Close/rebind/account switch | Global lifecycle cancellation and ownership/session fences intentionally remain global. Existing product crash gates cover recovery; no personal profile is touched. |

Reproduction
------------

From the repository root, using existing fixed installations:

```bash
node --test dsh-plugin/probes/product/*.test.mjs
uv run --project dsh-plugin --locked pytest dsh-plugin/tests -q
# Lint from the plugin directory, matching CI's package-root classification:
(cd dsh-plugin && uv run --locked ruff check src tests)

BB_PRODUCT_CASES=peer-isolation uv run --project server --locked python \
  dsh-plugin/probes/journal/live.py --product \
  --runtime "$RUNTIME" --dart "$DART" --crypto "$CRYPTO" --output "$EVIDENCE"
# Repeat with BB_PRODUCT_CASES=gap for out-of-order query receipts + cold recovery.
# Unset BB_PRODUCT_CASES for all existing product crash/install gates.
```

The new JS regressions are invoked by the existing plugin pytest job. They use
only Node built-ins (local measured total about 0.1 seconds), with no dependency
installation, duplicated build or new CI job. Actual host/process tests stay in
the existing opt-in `live.py --product` entry.

Evidence scope
--------------

The new real peer test starts isolated FastAPI/SQLite, the standalone Dart bin,
official MCP stdio and unchanged DSH 0.2.1-rc.5. It discards an actual successful
MCP result before journal settlement, proves B reaches a native turn while A
cannot ACK, injects a lookup network failure, reconciles the original success,
checks an actual client 404, then starts a fresh host process. Both peers finish
at cursor 2, exactly four inputs are completed, exactly one send exists, and the
cold phase makes zero provider calls. This is deterministic-provider transport
and state evidence, not real model comprehension evidence.

The handoff attachment records the final SHA, exact commands/exit codes, source
hashes, host integrity, before/after test output and sanitized real probe results.
Raw synthetic databases, capabilities, session logs and configs are excluded.
Real cloud model, Windows/Android device execution and visual settings regression
are outside this repair's local run; no deployment or merge is performed.
