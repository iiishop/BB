DEA-466 project-local runtime patch gate — 2026-11-11

**Narrow recovery increment: PASS in the deterministic-provider tests. Overall
delivery gate: FAIL.** The patch fixes durable re-drive and pre-dispatch claim
recovery. It deliberately holds uncertain external dispatches; it cannot
automatically complete those deliveries without risking repeat execution.
Do not freeze the product contract, resume client/backend feature work, or
interpret the test runner's exit 0 as full product acceptance.

This continues `0a3d01cd5a81a17b58a882f179b209ef702f3ae6` on
`agent/forge/dea466-chat-step3`. Changes stay in `dsh-plugin/` and this report.
No personal profile, global package, server/client code or business database
was modified. The original installed AgentLoop hash was rechecked unchanged.

### Patch and compatibility boundary

`dsh-plugin/runtime-patch/agent-loop.patch` adds hooks to the **existing**
AgentLoop: admission/status/recovery methods, claim tracking, model-call
barrier, terminal flush, and recovery after native resume. The accompanying
`recovery.mjs` folds append-only native session facts. It does not implement a
second turn driver, tool executor or model scheduler.

The installer copies all 61,818 files from the pinned installation into a new
project-owned directory before applying the patch. File symlinks are
dereferenced, directory symlinks are refused, and every copied file is checked
for distinct inode identity. Neither hard links nor links into shared
dependencies remain. Generated dependencies and evidence are gitignored.

The checked-in `lock.json` pins Linux x86_64, DSH **0.2.1-rc.5**, Cordis
**4.0.5**, the complete source dependency-tree hash, patch hash, helper hash and
before/after AgentLoop hashes. It refuses different source content even under
the same version, refuses overwrites, and verifies the copied/patched tree.

- Original full tree SHA-256: `6b975d17d879820246c72ef72fa84ab0206f23dc47f63b8ff8e244f0e9352556`.
- Original AgentLoop: `cf57e3ecd487ac5c2553455aaa5cef2c6fb41e6bd61be5aa455675d1d7193033`.
- Patched AgentLoop: `30eb7348269a9c4a55a2d2046c673e6196af99f9441b6c9ca52051a7b093e0b0`.
- Patch/helper hashes and the remaining exact pinning are in `lock.json`.

Only current **V4** session logs from this version are covered, including an
old unpatched V4 session with completed turns. Its existing facts remain a
prefix after patched resume and a new delivery. Older storage-format migration,
other DSH releases, other operating systems and mixed-version writers are
unsupported by this experiment.

### Persistent state and ordering

There is no SQL migration and no independent dedup table. Experimental
`plugin:bb/delivery-v1` records are appended through DSH's real
`appendPluginRecord` API, with `version: bb-recovery-1`:

- `accepted`: full immutable content, `(account, session_id, event_id)`, stable
  message ID and logical-turn ID.
- `claimed`: that same identity plus native physical turn/step.
- `recovered`: same identity, referencing previous claims; no renamed event.
- `dispatch`: that identity plus physical turn/step, written **before** calling
  the provider stream entry point.

DSH marks experimental records ignorable to unknown readers. They survive the
tested same-version resume, but their upstream contract is not a durable
cross-version schema guarantee. Therefore the patched store must not be
opened by an unpatched runtime or upgraded/migrated with this protocol active.
Unknown BB record versions, altered content under one key, or owned message
identities missing their state records are rejected. This is a pinned
experiment, not a released session-format migration.

Ordering for owned events:

1. Append acceptance with retained content, then native inbox insertion.
2. Await `ctx.sessions.flush(session)` before returning the receipt or waking
   the native driver. A durable acceptance without insertion can be requeued
   from its retained content. No external receipt table decides acceptance.
3. Native claim removes pending input; append its turn/step association and
   flush before asynchronous prompt/request preparation.
4. Append and flush dispatch intent **before** `preparedCall.stream(request)`.
   Even synchronous provider-side effects occur after this barrier. If no
   durable intent exists for this guarded protocol, pre-dispatch recovery can
   retry; absence of `user/message` is never the deciding evidence.
5. Native completion remains `turn/end` with `reason.kind=completed`; the patch
   flushes the terminal before retirement. Completed replays do not enqueue or
   start another physical turn. An incomplete dispatch is held as uncertain.

Native resume still appends its normal interrupted-turn closers. A safe claim
retry may append a second inbox insertion and start a second **physical
attempt**, both linked to the original business event and logical turn. The
test asserts one acceptance, one logical ID, one provider execution, and one
user-message projection. It reports physical attempts and insertions openly;
it does not relabel a second model execution as recovery.

### Experimental local API

These methods exist only on this patched AgentLoop; they are not official SDK
APIs or the frozen product MCP contract:

```text
agent.bbDeliver({account, session_id, event_id}, orderedContentBlocks)
  -> Promise<{state, logical_turn_id?, accepted_seq?, claims?, dispatches?,
              disposition?, blocked?, consumed_through: null}>
agent.bbDeliveryStatus({account, session_id, event_id}) -> same state view
agent.bbRecoverDeliveries() -> Promise<{blocked: logicalTurnIds[]}>
```

The native resume path calls recovery automatically. Twelve concurrent calls
serialize only admission/reconciliation on the exact Agent; the original
driver retains turn ownership. Session/account bindings and conflicting
content are checked. Public code must use this entry for the tested behavior;
ordinary raw `followup` is not converted into a universally idempotent API.

| State | Evidence/action |
| --- | --- |
| absent | No guarded acceptance; a new delivery may be admitted |
| accepted_pending | Acceptance exists and native inbox contains the identity; wake existing work |
| accepted_recoverable | Retained acceptance/claim with no dispatch intent; safely retry under the same logical identity |
| dispatch_uncertain | Intent exists without completed native outcome; do not replay or advance consumption |
| completed | Guarded dispatch has a completed native turn; replay returns existing outcome |

`user/message` alone proves history projection, not external presentation.
Even `completed` is **not** a client consumption acknowledgement. All states
retain `consumed_through: null`; this increment adds no read-position ACK API.

### Actual verification

Node **v26.8.2**, real Cordis/DSH AgentLoop/Session/JSONL. Only the provider is
the explicitly named deterministic test double; no real model API or image
understanding was tested. Child processes receive no credential/profile env
variables. Each forced kill checks the exact child PID against the daemon PID.

The original failure runner and assertions are retained. The shared test
profile only gains an optional awaited provider checkpoint. The final matrix
first reruns the unpatched baseline, with separate synthetic storage, and
reproduces its negative result (9 workers / 4 SIGKILLs). It then runs the patch
against its private copied dependencies (25 workers / 8 SIGKILLs).

| Case | Patched result |
| --- | --- |
| Before acceptance; accept → lost receipt; receipt → before turn; claimed → before model | All four recover: 12 concurrent replays, one logical event and one provider call |
| Crash again during recovery before wake | Same logical identity recovers, no duplicate provider execution |
| Live and cold replay after completion | No new log mutation/physical turn/provider call |
| Same event ID, different account/session | Independent IDs and correct session binding; mismatches rejected |
| Same key, different content | Rejected |
| Old unpatched V4 session | Prior facts retained; new delivery completes |
| Intent persisted, before provider entry | Recovery holds `dispatch_uncertain`, provider calls before/after crash = 0/0 |
| Provider entered, before result | Independent fsynced provider witness; recovery holds `dispatch_uncertain`, calls before/after crash = 1/0 |

The last two cases have indistinguishable **delivery status** in native storage,
but different observed provider execution. The test witness is diagnostic
evidence only; the runtime does not consult it. Auto-retrying the latter may
duplicate execution; refusing to retry the former leaves delivery incomplete.
The patch chooses explicit unresolved state and preserves evidence. This is
why the overall delivery gate remains **FAIL**, rather than asserting
cross-provider exactly-once or silently weakening the requirement.

Resolving that boundary needs a verified external idempotency/receipt lookup
contract, or an explicitly defined resolution policy for uncertain outcomes.
Neither is implemented or assumed here. Expanding into provider protocols or
uncertain replay strategies is outside this increment; return to Orion.

Final evidence is `recovery-Am6N18`: summary, per-worker IPC traces, exit
codes/signals, native cold reads, raw JSONL, pre-resume crash copies, caller
receipt, provider witness, baseline logs, lock and integrity checks. Normal
worker disposal may append native cleanup after the recorded result; the
crash-prefix copies capture the exact pre-resume state. No test writes or
rewrites runtime history directly.

Commands/results:

- Installer: exit **0**; copied tree verified with no shared links/inodes.
- `node dsh-plugin/runtime-patch/test.mjs <original-package> <copied-package>`:
  exit **0**; scoped tests PASS, overall gate explicitly FAIL.
- Installed-copy hash tampering: verifier exits **1**, expected rejection;
  restoring exact bytes verifies with **0**. Wrong source version and wrong
  source tree each exit **1** before a destination is created.
- `node --check` for new JS modules and `git diff --check`: exit **0**.
- Original global AgentLoop SHA still matches its pinned original hash.

### Install, start, and withdraw locally

Run from the repository root. `DSH_PACKAGE_ROOT` is the original package
directory selected by the operator; there is no hardcoded personal path.

```bash
uv run --no-project python dsh-plugin/runtime-patch/install.py \
  --source "$DSH_PACKAGE_ROOT" --destination dsh-plugin/.runtime/dsh-rc5-bb1
uv run --no-project python dsh-plugin/runtime-patch/install.py \
  --verify --destination dsh-plugin/.runtime/dsh-rc5-bb1
node dsh-plugin/runtime-patch/test.mjs \
  "$DSH_PACKAGE_ROOT" dsh-plugin/.runtime/dsh-rc5-bb1
```

The last command is the supported startup entry for this validation increment:
it verifies hashes, starts isolated programmatic profiles, collects all
foreground children and exits. It is not a production DSH launch configuration.
Do not call internal workers as an unchecked product launch path. Partial
installs are refused; choose a new destination after diagnosing an interrupted
build instead of overwriting it.

Withdrawal requires no global uninstall or profile edit: finish/stop the
owned test run, archive its evidence, and cease using the private runtime.
The exact generated `.runtime/dsh-rc5-bb1` copy can then be removed by the
operator. Keep patched session logs archived with the matching lock/patch;
**do not feed them to the unpatched runtime** as a rollback mechanism.
Existing personal deployments and original session stores remain unchanged.

### Remaining limits

NOT RUN: real model/vision, multi-step tool actions/provider retries, busy/wait
and download event scheduling, cross-process writer contention, power-loss or
disk-error faults, older-format migration, MCP/client/server integration,
server/plugin pytest regressions, Flutter three layers, Android/Windows.
Only the two native recovery primitives and their tested boundaries are claimed.
No product release, main merge, status/assignee change, full QA or Owner Review
is authorized by this result.
