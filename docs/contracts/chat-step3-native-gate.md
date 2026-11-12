DEA-466 native Cordis recovery gate — 2026-11-11

**Decision: BLOCKED / do not freeze the delivery contract.** Native session
facts solve admission reconciliation in this limited prototype, but the tested
public API path does not recover already accepted input into model execution
without another insertion. This is a reproducible negative result for the
installed version, not a claim that every possible plugin design is impossible.
Per Orion's instruction, stop at this gate and return the missing primitives;
do not implement a replacement scheduler or weaken the acceptance criteria.

Based on `81715beb937303ec814d5229f43e833ddf5d6be4`, continuing
`agent/forge/dea466-chat-step3`. No server/client code, business migrations,
OpenAPI, personal profile, installed package or credential was changed.

### Runtime and isolation

The reproducible composition is `dsh-plugin/probes/native/profile.mjs`:
real Cordis **4.0.5**, DSH **0.2.1-rc.5** AgentRegistry, AgentLoop, Session,
SessionProjection, SystemPrompt, Tools, LLM runtime and JSONL persistence.
It mounts the installed packages through `Context.plugin`, using an isolated
product-probe profile and synthetic sessions. It does not launch the ordinary
DSH CLI profile, merge home/profile overlays, or register itself in a personal
deployment. The evidence's `profile.json` describes this programmatic profile;
it is not claimed to be a DSH CLI configuration file.

Only the model provider is a deterministic, explicitly named test double
(`bb-probe/deterministic`). Agent, inbox, event projection, persistence, resume
and turn execution are real. The worker environment excludes model/account
credentials and personal profile variables. There is no network or model API
call. The profile exposes no shell, filesystem, MCP or management tools.
Node **v26.8.2** was used. Raw sessions are written by the real JSONL backend
in its current `session.v4.jsonl` format, not fabricated by the probe.

### What the admission prototype verifies

`adapter.mjs` is an **admission-only experimental helper**, not a finished
Cordis scheduler or an integration-ready product plugin. Its API is
`AdmissionProbe(ctx, agent, account).accept(event, {wake})` and `inspect(event)`.
The event key is `(account, session_id, event_id)`; the entire tuple hashes to a
stable message identity. The helper binds the account/session, rejects changed
payload under an existing key, and reconciles the full native session history.
It never assumes that choosing a message ID itself supplies idempotency.

The acceptance record is the **same native `agent/inbox/spliced` insertion that
places the message in the inbox**. There is no separate deduplication table:

1. Inspect native insertion facts and check identical message content.
2. If absent, call native `Agent.send` (no await between inspection/insertion).
3. Await `ctx.sessions.flush(agent.session)` and require its positive result.
4. Return an acceptance receipt derived from the session fact.

Twelve concurrent replays use twelve newly constructed helpers against the
same live Session, including after a whole-process restart. They produce one
insertion. The check/insert is synchronous inside the one native Session
writer; this does not prove arbitrary multi-host concurrency. The backend's
write lease is used normally, but separate-process writer contention was not
tested. Account/session mismatch and same-key/different-payload rejection were
also exercised.

The receipt witness used in the third crash scenario is fsynced to a separate
caller file only to establish that checkpoint. Recovery never consults it.
This avoids moving the admission uncertainty into another table.

### Actual crash matrix

Command from the repository root (substitute the installed CLI package root):

```bash
node dsh-plugin/probes/native/run.mjs "$DSH_PACKAGE_ROOT" ./native-evidence
```

Actual final run used the installed package and `../handoff` as evidence
parent: **exit 0**, 9 workers, 4 deliberate **SIGKILL** process crashes.
The control and four resumed workers exited **0**. A zero runner exit means
the negative-result assertions reproduced, **not** that the product gate passed.
Every forced kill targeted the exact child PID after comparing it with the
Multica daemon PID. All children were collected in the foreground.

| Crash point | Cold recovery + 12 concurrent replays | Insertions | New model requests | Verdict |
| --- | --- | --- | --- | --- |
| Before native acceptance | Absent event is accepted, projected and driven | 1 | 1 | PASS for this case |
| After durable acceptance, before caller receipt | Existing pending input identified, no reinsertion; remains idle | 1 | 0 | Admission PASS; delivery FAIL |
| After fsynced caller receipt, before turn starts | Same pending state after restart; remains idle | 1 | 0 | Admission PASS; delivery FAIL |
| After inbox claim, before model request | Accepted event is neither pending nor history-projected | 1 | 0 | Delivery FAIL |

The two pre-turn cases request a real wake inside documented
`Agent.runMaintenance`; maintenance holds turn execution until the checkpoint,
so they do not merely test deliberately non-waking input. After restart,
native resume does not restore that wake request. Calling `followup` again
with the pending identity throws **already pending**; this is asserted.

For the claimed-input case, an `agent/request` middleware pauses before model
admission, flushes the actual Session, and reports the checkpoint. The parent
then kills the whole host process, including adapter and DSH runtime. A fresh
worker resumes the same persisted session through `ctx.agents.resume`:

```text
seq 0  agent/inbox/spliced   insert original identified input
seq 1  turn/start           turn 1
seq 2  agent/inbox/spliced   remove one item for claim, no cancellation outcome
seq 3  step/start           turn 1, step 1
       SIGKILL
seq 4  step/end             appended by native resume repair
seq 5  turn/end             reason=interrupted, appended by native resume repair
seq 6  session/end-seed     native restored-session marker
```

There is **no `user/message`** for the input, no pending input, and no model
request in the restarted worker. The helper preserves `accepted_unpresented`
and refuses to treat it as absent or consumed. Repeating a stable ID after a
completed turn is separately tested in the control: raw `followup` accepts it
again, creating **two insertions and two completed model calls**. Native
pending-ID uniqueness is not lifetime delivery deduplication.

Evidence `native-gate-zNTPfI` contains per-worker IPC traces, exit codes/signals,
`SessionPersistence.open(...,'read').read()` results, the caller receipt,
raw runtime session files, and exact pre-resume copies in `crash-prefixes/`.
Copies preserve the files as generated; the harness never writes session
events or repairs history itself. Normal resumed-worker teardown can append
native inbox cancellation after the recorded result; the result and crash
prefixes deliberately show the state **before** that cleanup.

An earlier harness attempt exited 1 because an unreferenced IPC channel let
the checkpoint worker exit 13 before SIGKILL. Referencing IPC fixed the harness;
that failed attempt is not acceptance evidence. Intermediate passes preceded
the final wake-request/receipt and scope-rejection assertions; the final
evidence directory above is authoritative.

### State meanings and contract boundary

| State | Evidence | What it does not prove |
| --- | --- | --- |
| Arrived | Synthetic event supplied to the helper | Native acceptance |
| Accepted | Native insertion plus successful Session flush, or cold persisted insertion | Model presentation |
| Pending | Native pending-inbox projection contains ID | A driver will restart |
| Claimed, unpresented | Insertion exists, pending false, user/message absent | Safe completion or consumption |
| History projected | Native user/message exists | Provider actually received/understood input |
| Provider handed input | Deterministic model callback observes ID in this test | Real-model/visual acceptance or durable consumption |
| Consumed | No implementation/ack protocol in this gate | Never inferred from enqueue/turn-end |

Every recovery result leaves `consumed_through: null`. This helper deliberately
does not export a working wait, download scheduler or consumption-ack API.

### Missing primitives and minimum extension candidates

These are **proposed upstream/runtime changes**, not names of existing APIs:

1. **Wake an already accepted identity without enqueueing another message.**
   A public, idempotent `wakeAccepted(messageId)`-like operation should serialize
   with current driver state, survive/reconcile restart, and never create an
   additional turn for the same accepted item. The installed public Agent
   contract offers `send/followup/steer/inject`; waking calls insert first.
   Calling private `wakeDriver`, inserting a dummy prompt or changing the
   installed package would not be a supported solution to this task.
2. **Recover a claim until model admission commits.** The core driver needs a
   durable in-flight identity/claim state that resume can retry without a
   second business admission/inbox insertion, or an atomic claim-to-admission
   transition with equivalent semantics. The current removal precedes async
   prompt assembly and request preparation. Resume closes interrupted turns
   but does not restore this input. A new plugin table cannot repair that
   native state transition by itself.

These changes affect Agent/Inbox/resume lifecycle and persistent replay
semantics, so they need native tests at the same SIGKILL checkpoints plus
schema compatibility checks. Their exact API/schema is **not frozen here**.
An application-level policy allowing requeue of a recognized unpresented
claim would change the strict no-reinsertion requirement and still needs
race proofs; it is not silently adopted. This report does not assert no other
documented composition is possible; none has passed this gate.

Installed-source evidence:

- `dsh-agent-loop/lib/index.js:189` checks duplicate IDs only across pending
  lists; `:800` inserts before waking; `:906` claims before async assembly;
  `:1969` resumes via persisted log plus interrupted-turn closers.
- `dsh-agent/lib/types/runtime-types.d.ts:175` defines public delivery methods.
- `dsh-session/lib/index.js:907` delegates interrupted repair to boundary/tool
  closers, not inbox-claim restoration.
- `dsh-session-persistence/lib/types/handle.d.ts` defines flush as the durability
  barrier; `ctx.sessions.flush` is the live Session entry point.
- Exact SHA-256 values and Node version are in evidence `sources.json`.
  [Official AgentLoop documentation](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/agent-loop/README.md)
  provides context on native inbox facts; installed hashes control this result,
  since upstream master differs from this release.

### Remaining validation and handoff

PASS applies only to the scoped admission/concurrency checks, one recovered
previously unaccepted event, the control turns, and reproduced crash evidence.
Overall recovery gate: **FAIL/BLOCKED**.

NOT RUN: busy-session event bursts, matching wait, turn/end scheduling races,
download success/failure session routing, independent writer contention,
power-loss/storage-error injection, real DSH model/image input, actual MCP /
client chat, server/plugin pytest regressions, Flutter three layers and
Android/Windows hardware. The common native recovery prerequisite failed;
the downstream scheduler matrix was intentionally not implemented or claimed.
No real-model evidence is replaced by the deterministic provider.

`node --check` on all four new modules and `git diff --check`: exit 0.
Only `dsh-plugin/probes/native/` and this evidence/contract report are changed.
Keep existing issue status and assignee. Return to Orion for the native
primitive/contract decision before resuming the original backend/plugin task;
do not start Muse, Sentinel, QA or Owner Review from this result.
