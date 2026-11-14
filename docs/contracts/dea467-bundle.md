# DEA-467 standalone BB bundle

`dsh-plugin/bundle/` is the product plugin. `dsh-plugin/build_bundle.py` assembles a self-contained directory with the Python MCP source, its unchanged uv lock and the shared contract package. It does not copy or modify DSH. Historical `runtime-patch/` files are not imported or installed.

## Supported environment and installation

Verified target: Linux, Node 26.8.2, installed DSH packages 0.2.1-rc.5, Cordis 4.0.5, Python 3.12+ and uv. The native profile must provide the standard `attachments` service (for example the shipped `dsh-attachment-local` backend). The bridge requires a local filesystem supporting atomic rename, hard-link creation and directory fsync. Windows durability has not been validated. Dependencies remain fixed by the existing uv lock and exact DSH MCP peer version. No SurfCore dependency exists.

From the repository root:

```bash
python3 dsh-plugin/build_bundle.py /absolute/fresh/bb-bundle
```

In the isolated product profile's actual Web UI, open **Plugins → Add plugin**, enter the built directory, choose **Install**, then **Enable now**. Follow any restart requested by the host. Open **Plugins → BB Chat Bridge** to edit its configuration; the same editor contributes to native **Settings**. No developer console or profile-file editing is required. Earlier builds registered only a host Settings namespace, which did not generate a browser form. The bundle now exports its own public Web UI contribution, using the native `plugins.bundle.config` / `settings.section` slots and `configForms` mirror for `bb-bridge`.

Settings:

- `clientUrl`: HTTP `127.0.0.1` origin of the already-running BB local client.
- `targetSession`: ID of an existing/resumed DSH session. Set the model in DSH; this plugin does not select or replace a provider.
- `peerAccount`: optional eight-digit peer filter; empty follows authorized conversations using the shared keyset query.
- `enabled`, `pollMs`: lifecycle switch and bounded background refresh interval. Model polling is not needed.

The five fields above are editable together and saved atomically against the native Settings revision. Valid changes apply live; saving does not restart the host. Reopening and restarting read the host's persisted values. URL validation allows only a `127.0.0.1` HTTP origin with an optional valid port; session IDs allow up to 200 ASCII letters/digits/underscores/hyphens, peers are empty or eight digits starting with 1–9, and refresh is an integer from 250 to 30000 ms. Both the form and host reject invalid values. A stale edit cannot overwrite a newer revision: the draft is retained, save is refused, and **Reload saved values** explicitly accepts the current configuration.

Connection status distinguishes disabled, waiting for login/client/session, bound, and recovery/identity fencing. The optional host-owned GET `/api/bb-bridge/status` uses the public authenticated owner Fetch route service and exposes only state, diagnostic code and required session IDs. It does not expose tokens or consumer capability, and is removed on unload. The browser status timer/requests are disposed on leaving the editor. This is a local DSH plugin interface; the BB HTTP contract is unchanged.

Stopping automatic binding is separate from the reason displayed. A failed initial bind still pauses binding. DEA-474 changes an established connection: transient transport loss preserves the binding and retries connectivity; same-account re-login establishes a fresh generation automatically. Owner/CAS conflicts remain fenced. Its state is now `connection_unavailable`, with allowlisted diagnostics distinguishing TCP refusal, timeout, generic fetch failure and a fetch-restricted port. The page explicitly says rebinding is paused: start the client/check the URL, save a corrected URL or disable/save then enable/save. Restoring a listener alone does not un-fence a failed initial bind; an already bound client resumes without a new CAS. Unknown failures show `stopped` with manual recovery guidance; they are not labelled identity failures or endless connection attempts.

Actual `stale_identity`, `stale_binding`, session-owner mismatch and recovery requirements remain `blocked`; `required_sessions` is retained. Resolve the account/binding/session restriction first, keeping original recovery records, then explicitly rebind. An unknown provider result remains uncertain; changing the diagnostic does not retry models, resend operations, settle messages or delete journals. Only allowlisted diagnostic codes reach the page; arbitrary upstream messages/stacks are not displayed. The local `bb_bridge_status` tool uses the same state mapping.

Advanced installation defaults (`stateDirectory`, `uvCommand`, `pythonProject`) are not editable connection fields: state defaults to the private profile `.bb-bridge`, and MCP uses uv with the bundled locked project.

Register/login remain actual MCP tools before binding. Account passwords and server tokens remain client-owned; the plugin stores only a local consumer capability and dispatch metadata. After switching accounts select a fresh DSH session and explicitly disable/enable to bind. A native session already associated with another account is refused (`session_identity_mismatch`), so its old context is never relabelled. A failed ownership fence stops automatic rebinding: an old process cannot repeatedly steal the new process's revision. `bb_bridge_status` exposes safe binding/recovery diagnostics, never the capability.

Disable closes owned MCP connections/registrations, timers and bridge observers; pending work remains recoverable. The stock Web UI manages its native plugin unload/reload through the Plugins controls. In a headless profile without HMR, removing a running bundle returns `stop-profile`; stop/deselect before removal and follow any restart requested by the host. Durable journals are retained for reinstall/recovery, while live binding files are removed on clean disposal. Removing those durable files is an explicit data-reset decision and forfeits the stable consumer; do not remove them to bypass uncertain work. Rollback means disable this bundle and restore the previous source directory/profile selection; it never means installing the historical runtime patch.

## Product boundaries

The installed official MCP client owns stdio child lifecycle. The Python MCP service forwards to the BB client; it does not authenticate directly to FastAPI. The bundle contributes public Cordis hooks, a cooperative system prompt section and scoped operation wrappers. Register/login, Profile, directory, existing media/download tools and the three new query tools remain. All local business tools, including Profile, require the owner-bound v2 protocol. Unbound standalone MCP exposes the same inventory but only registration/login can execute until the host supplies a binding. No v1 fallback or legacy alias migration exists. Internal confirm/ACK remain hidden from model tools.

Normal send/download operation IDs may be omitted on the bound session's scoped tools. The bridge derives the ID from a durable native session/call identity, persists the intent before dispatch, and returns the generated ID. Existing explicit IDs are accepted for compatibility. Recovery queries the original client operation, never creates a replacement send. The journal stores ID/digest/status metadata, not a duplicate business message table or server result database. A provider or tool outcome without sufficient durable evidence remains `uncertain` and blocks automatic progression; no text-based deduplication or model judgement decides whether to resend.

Download plans are reconciled through `downloads/get`, using a saved task ID or the original operation ID in verified client download events after a lost start response. They are not looked up in the sending-operation API. The fact must match the original operation, account and stable consumer; no new download start is issued during recovery. If neither task nor terminal event is known, uncertainty remains. Legacy metadata can be repaired by a matching verified download event, without manufacturing a business fact.

The bridge periodically discovers/subscribes to authorized peers and reads client facts. Wait, native query presentation and passive input share the journal. Queries themselves never confirm/ACK; only a complete native model presentation and a successful durable turn permit internal settlement. Missing images, failed turns and uncertain requests do not consume. No final model text is forwarded: only explicit send tools own outbound messages.

DEA-474 replaces passive message/history injection with aggregate metadata notifications. The normative contract, write-entry inventory and migration rules are in `dea474-notifications-v1.md`. Notifications are account-configurable, default on, and never confirm read receipts. Models explicitly choose list/read/wait/send tools. No automatic history bootstrap runs for message queries; historical images remain available via explicit queries with their original order. Download callbacks remain automatic for a journaled operation owned by the configured session.

`history.js`, `history.test.mjs` and the old `--context`/`online`/`peer-isolation` probes are historical/component helpers, not DEA-474 product acceptance. The updated installed probe verifies explicit model-driven queries and history; `BB_PRODUCT_CASES=notifications` verifies summary delivery, actual wait A/B, offline re-login and notification crash recovery. The new dependency-free notification tests use the existing plugin pytest/CI entry.

## A/B/C recovery implementation

Every journal write is fsynced, atomically renamed and directory-synced. Owner capability publication uses create-if-absent hard links. Records are separated by binding revision, so stale callbacks cannot overwrite a replacement's revision. The client CAS and strict expected_identity remain the authority for business commits.

| Boundary | Replacement behavior |
| --- | --- |
| A: old message claim durable, no model dispatch intent | Preserve as `awaiting_read`, remove only its owned pending entry; no unsolicited body replay. An explicit query can claim it with a fresh receipt. Download callbacks retain their prior recovery. |
| B: dispatch intent durable, model outcome unknown | Preserve queryable uncertain. No model replay, send, confirm or ACK. A fully durable successful native turn may resolve a lost observer update. |
| C: completed native turn, confirm/ACK response lost | Reuse the same attempt/digest/receipt; idempotently confirm and query/advance the client's cursor, without another provider request. |
| Explicit send succeeded, result not journaled | Query original operation ID, retain the original success, never resend; an unfinished native turn stays uncertain. |
| Download succeeded, start response not journaled | Find its terminal event by the original operation ID, verify the task via `downloads/get`, never restart the download; an unfinished native turn stays uncertain. |

The metadata journal is not an alternate scheduler. The stock host owns inboxes, turns, tool calls, cancellation, Session projection and Session persistence. The bridge uses `followup`, `runMaintenance`, `inbox.remove`, `sessions.flush`, scoped tool registration and documented event hooks only.

Message bodies are no longer scheduled by polling. Old unexposed body reservations await explicit queries; successful or uncertain presentations retain their original evidence. Notification reservations have a separate durable window/cursor and native-ID reconciliation; see the DEA-474 contract. Download callback reservations retain their existing advancement rules.

Operation uncertainty is different from a pre-dispatch reservation. Ordinary ticks
skip only the affected peers while a send/download result is unknown; they do not retry the tool.
The existing explicit recovery path is disable/save, then enable/save with the same
account and original native session. Binding invokes `Bridge.recover`, which queries
the original operation ID (or the matching download event/task). A send lookup's
404 becomes durable `failed_absent`: absent in the current client scope, not proof
that the remote send never happened. Its operation ID, logical key and digest stay
reserved; no automatic resend or new-ID retry is authorized. Transport errors,
timeouts and 5xx leave unresolved plans `uncertain`; identity/schema errors still
reject recovery. A failed lookup does not reopen a previously terminal record.
Missing download events/tasks remain uncertain. A terminal operation resolves only
that operation: an unfinished native turn still remains uncertain and cannot confirm/ACK.

Before dispatch, new plans persist the target peer plus peers whose inputs belong
to the current native turn. Explicit query `claim`, wait admission and
replacement delivery use the same peer uncertainty guard. Uncertain input journals
also block only their peer. Other peers can deliver and settle independently.
Settlement checks the guard before confirmation/ACK and retains the original
successful turn proof until it can commit; the client still enforces contiguous ACK.
Wait reservations are scoped by peer and release through the existing tool hooks.

Pre-DEA-470 journals have no peer metadata. Such unresolved plans allow new input,
but conservatively withhold confirmation/ACK until explicit reconciliation resolves
them. They are not deleted or assigned a guessed peer. Failed/unknown native turns
remain protected even after an operation becomes absent. Automatic periodic
reconciliation is outside DEA-470; disable/save then enable/save remains the
supported explicit recovery path.

F2/F5 targeted checks: `BB_PRODUCT_CASES=online` with the real `live.py --product`
entry tests one-shot HTTP history failure, pre-followup failure and post-enqueue
failure. `node dsh-plugin/probes/product/operation-contract.mjs "$RUNTIME" "$EVIDENCE"`
checks the explicit operation recovery contract with stock DSH and labelled
client/model doubles; the existing `operation-result`/`download-result` product
cases exercise actual client facts across process restart.

DEA-470 regression: `BB_PRODUCT_CASES=peer-isolation` with the same `live.py --product`
command starts the real standalone Dart entry, FastAPI, official MCP and stock DSH.
It drops a successful MCP result before journal settlement, delivers peer B while
A is blocked, injects a lookup transport failure, reconciles the original ID,
checks real 404 and then cold-reopens without another send or model call.
`BB_PRODUCT_CASES=gap` checks real out-of-order query receipts and contiguous ACK.
The dependency-free `probes/product/*.test.mjs` cases run through the existing
plugin pytest/CI entry (`tests/test_bundle_regressions.py`); no new CI job or package
installation is added. All providers in these probes are deterministic doubles.

## Reproduction and evidence scope

```bash
uv run --project dsh-plugin --locked pytest dsh-plugin/tests -q
node --test dsh-plugin/probes/product/history.test.mjs
uv run --project server --locked python dsh-plugin/probes/journal/live.py --context \
  --runtime /absolute/fixed/dsh/package \
  --dart /absolute/existing/dart-sdk/bin/dart \
  --crypto /absolute/existing/crypto-3.0.7 \
  --output /absolute/new/context-evidence
uv run --project server --locked python dsh-plugin/probes/journal/live.py --product \
  --runtime /absolute/fixed/dsh/package \
  --dart /absolute/existing/dart-sdk/bin/dart \
  --crypto /absolute/existing/crypto-3.0.7 \
  --output /absolute/new/evidence

python3 dsh-plugin/build_bundle.py /absolute/new/bundle
DSH_HOME=/absolute/new/lifecycle/home node dsh-plugin/probes/product/lifecycle.mjs \
  /absolute/fixed/dsh/package /absolute/new/lifecycle /absolute/new/bundle
```

`--product` uses actual isolated FastAPI/SQLite, actual Dart client, actual MCP stdio and unchanged DSH. Only the model is deterministic. Its crash cuts kill the actual plugin process, then start a fresh process and CAS rebind; the install test uses native Plugin Manager and Settings. `BB_PRODUCT_CASES=installed` selects only the install/media test for debugging and is not a full gate result.

The old `--context` probe documents the former automatic-history behavior and is not the DEA-474 acceptance entry. Updated `--product`, `BB_PRODUCT_CASES=gap` and `BB_PRODUCT_CASES=notifications` exercise explicit reads, sparse display, send/download recovery and aggregate reminders. Deterministic providers prove transport/projection ordering, not real model comprehension.

Only sanitized `results.json`, `sources.json`, `host-integrity.json`, lifecycle/installed summaries and inspected UI screenshots are distributable. Private service logs, browser storage, native sessions, owner files, databases and raw configs may contain synthetic credentials/capabilities and must not be attached. The runner hashes the fixed eight host files before/after and records product source hashes. Real model/visual understanding, Windows/Android, final same-SHA Flutter/CI and Sentinel independent QA remain separate acceptance work; deterministic media projection is not visual-understanding evidence.

## Rendered settings reproduction

Use the already installed Playwright and Chromium; this test does not install or upgrade external dependencies:

```bash
BB_PROBE_PLAYWRIGHT=/absolute/existing/playwright/package.json \
BB_PROBE_CHROMIUM=/absolute/existing/chromium \
uv run --project server --locked python dsh-plugin/probes/journal/live.py --settings \
  --runtime /absolute/fixed/dsh/package \
  --dart /absolute/existing/dart-sdk/bin/dart \
  --crypto /absolute/existing/crypto-3.0.7 \
  --output /absolute/new/settings-evidence
```

This launches a clean stock Web profile, installs through actual Plugins controls, edits/saves the native form, exercises two browser edit revisions, tests invalid writes, binds a real isolated Dart/FastAPI client, disables/re-enables, restarts and uninstalls. A test-only public plugin creates a deterministic native session and observes tools/owned subprocesses; it does not modify the host or replace Settings. Native runtime-context messages and automatic title requests are counted separately from BB inputs/turns. The model is a double; no real provider credentials are used.

For the limited stopped-state regression, prefix the same command with `BB_SETTINGS_CASES=status`. It closes a real high-port TCP forwarder to the actual Dart client before binding and after connection, restores its listener, and verifies the displayed explicit recovery action. It separately covers fetch-restricted port 1, actual account switching/owner CAS, and a real native failed turn followed by a replacement-session recovery refusal. The deterministic provider deliberately fails in the last case; uncertain journal hashes, model-call count and absence of send/confirm/ACK requests are asserted. `node --test dsh-plugin/probes/product/status.test.mjs` checks raw fetch diagnostics and safe fallback classification. This is a status-only change; the original retry/dispatch/settlement code and prior gate evidence remain intact.

## Closed raw-client cover discrepancy

The former omitted-cover 422 counterexample belongs to client tree `dea50f14f0d3c8470ed87573370887f6580d424a`. Muse's fix is integrated at `5a0739f` (client tree `c4d96de34d6dc790d471b86f08504e5886b876ff`). `BB_PRODUCT_CASES=cover` now asserts omitted and explicit-null cover both return 200 and reconcile the same operation. The historical negative evidence is retained; this gate no longer expects the old defect. No client production source was edited in the Settings work.
