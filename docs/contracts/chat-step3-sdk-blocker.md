DEA-466 SDK delivery gate — 2026-11-11

Status: BLOCKED for freezing the DSH delivery contract. This is a capability
report, not the approved `chat-step3.md` or a completed STEP-3 implementation.
Orion explicitly requested immediate handback if the installed SDK contract
blocks implementation. No server, client, migration, OpenAPI or existing MCP
behavior has changed in this handoff.

Baseline: `0fc58a6ac1e25c4a3c11d8ff781d3b9b3711ea8f`.
Working branch: `agent/forge/dea466-chat-step3`.
Baseline bundle SHA-256:
`dcb17067d65ee12043c6e3f7e3a309171b433b012349e095240b1b66d46e84dc`.

### Verified installed interface

The installed CLI, SDK protocol and SDK JSON-RPC server are `0.2.1-rc.5`.
Paths below are relative to their package directories, not personal deployment
configuration. Only package code/type declarations were used as evidence.

- `dsh-sdk-protocol/lib/types/types.d.ts`, `SessionPromptParams`: exactly
  `sessionId` and ordered `contentBlocks`; the result has server-generated
  `messageId`. No caller-owned event/idempotency field is declared.
- Inline image input is `{type:"image",data,mimeType}`. The server's
  `durablePromptContent` admits images through an attachment store and maps
  references back into their original block positions. Missing attachment
  storage throws before enqueue. Successful image admission and actual visual
  model consumption have NOT RUN.
- `session.event` carries `{sessionId,event}`; `session.status` carries
  `{sessionId,status:"idle"|"running"}`. `turn/end` is a session event.
  An enqueue receipt is not evidence of model presentation or completion.
- The complete declared request map is `initialize`, `session/prompt`,
  `session/resume`, `session/wait`, `session/working-directory/get`,
  `session/working-directory/set`, `shutdown`. There is no declared history
  replay or caller-event reconciliation request in this installed wire API.
- `dsh-sdk-jsonrpc-server/lib/index.js:153` creates a new user message on every
  prompt, calls `agent.followup`, then returns its ID. `resume` restores a
  session and returns an empty result; it does not provide a documented
  event-id lookup. `session/wait` observes quiescence, not settlement of an
  identified application event.

Source SHA-256 for server `lib/index.js`:
`55412923f9f7c279f7e0b2a1e2853eaf238f390b3d84046cb9c94dc5f22a1e4a`.
Protocol declaration SHA-256:
`23eed309626e0c75a6287c36999df6d6002a933204c6dce2641a403966e7967d`.

The [upstream SDK server documentation](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/sdk/server/README.md)
also distinguishes prompt enqueue from subsequent session activity. Upstream
master can differ; the installed, hashed artifacts above control this finding.

### Reproduction and limits

Run from the repository root, supplying your installation path:

```bash
node dsh-plugin/probes/sdk-delivery.mjs "$DSH_PACKAGE_ROOT"
```

Executed with `DSH_PACKAGE_ROOT` set to the installed CLI package directory:
exit **0**. See the attached `DEA-466-sdk-probe.json` for actual output.

The probe imports the actual installed `HarnessSdkJsonRpcServer`, dispatches
two identical `session/prompt` requests, and asserts two distinct message IDs
and two calls to `followup`. It also checks missing attachment storage rejects
before enqueue and reads the declared request map. Context, Agent, transport
and initialized state are synthetic. It does NOT start a product runtime,
write session logs, invoke a model, test real network loss, or prove durability.
The test passing confirms the interface gap, not STEP-3 acceptance.

Failure window inferred from this verified interface: DSH accepts an event,
then the plugin loses the receipt before persisting `messageId`. Retrying the
same input creates another message. Marking the event delivered before sending
instead risks loss. A plugin SQLite outbox alone cannot close this boundary.
Putting an event ID in prompt text does not add runtime idempotency.

### Required coordination

Orion should settle the delivery adapter contract before both ends implement
it. Recommended investigation: a project-owned native Cordis adapter inside
`dsh-plugin/`, installed only in an isolated product profile, which reconciles
stable application event IDs against persisted DSH session facts before
resubmitting. Native `Agent.send/followup` accepts identified messages, but its
deduplication, persistence ordering and restart behavior are NOT yet verified;
this is a candidate, not a promised solution. An SDK update/extension offering
durable caller identity and lookup is another route requiring verification.
Do not weaken the no-loss/no-duplicate acceptance criterion or pretend the
current wire API already supports these operations.

The agreed server endpoints, client ownership, media rules and ordered-content
design remain the Orion attachment's proposals. `chat-step3.md`, machine
schemas, shared fixtures and implementation are NOT delivered by this gate
report. Resume the full Forge implementation after coordination, then hand
the finalized contract to Muse through Orion.

### Commands and acceptance state

- Baseline `sha256sum`, `git bundle verify`, `git bundle list-heads`: exit 0;
  bundle reports complete history. An initial fetch used an incorrect ref and
  returned 128; fetching the listed `agent/muse/profile-step2` ref succeeded (0).
- `git switch -c agent/forge/dea466-chat-step3 <baseline>`: exit 0.
- SDK component probe: exit 0; three asserted checks pass.
- Schema/migrations/API authorization checks: NOT RUN; no product changes.
- Server/plugin pytest regression: NOT RUN; this commit only adds a diagnostic
  probe and report, not product implementation.
- Real MCP → client → server chat, DSH plugin loading/model/round/restart,
  attachment downloads, Flutter three-layer QA, Android/Windows/device tests:
  NOT RUN. Prior STEP-2 evidence does not satisfy STEP-3.
- Security: no personal profile modification, credentials accessed, live
  session replay or product deployment; probe uses synthetic data only.

The issue remains `in_progress` under its existing squad; this report neither
changes status nor constitutes Owner Review readiness.
