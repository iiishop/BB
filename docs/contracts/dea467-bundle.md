# DEA-467 standalone BB bundle

`dsh-plugin/bundle/` is the product plugin. `dsh-plugin/build_bundle.py` assembles a self-contained directory with the Python MCP source, its unchanged uv lock and the shared contract package. It does not copy or modify DSH. Historical `runtime-patch/` files are not imported or installed.

## Supported environment and installation

Verified target: Linux, Node 26.8.2, installed DSH packages 0.2.1-rc.5, Cordis 4.0.5, Python 3.12+ and uv. The native profile must provide the standard `attachments` service (for example the shipped `dsh-attachment-local` backend). The bridge requires a local filesystem supporting atomic rename, hard-link creation and directory fsync. Windows durability and rendered Settings UI have not been validated; do not infer them from Linux service tests. Dependencies remain fixed by the existing uv lock and exact DSH MCP peer version. No SurfCore dependency exists.

From the repository root:

```bash
python3 dsh-plugin/build_bundle.py /absolute/fresh/bb-bundle
```

Use the isolated product profile's native Plugin Manager to install that directory (`pluginManager.installBundle`), then restart the profile when the host requests it. Do not edit the profile's package.json/patch by hand. The host applies the bundle's `cordis.patch.yml` and exposes the **BB Chat Bridge** Settings form (`bb-bridge`).

Settings:

- `clientUrl`: HTTP `127.0.0.1` origin of the already-running BB local client.
- `targetSession`: ID of an existing/resumed DSH session. Set the model in DSH; this plugin does not select or replace a provider.
- `peerAccount`: optional eight-digit peer filter; empty follows authorized conversations using the shared keyset query.
- `enabled`, `pollMs`: lifecycle switch and bounded background refresh interval. Model polling is not needed.
- `stateDirectory`: optional private local recovery directory; defaults to the profile's `.bb-bridge`.
- `uvCommand`, `pythonProject`: executable/path overrides; by default use uv and the bundled locked Python project.

Register/login remain actual MCP tools before binding. Account passwords and server tokens remain client-owned; the plugin stores only a local consumer capability and dispatch metadata. After switching accounts select a fresh DSH session and explicitly disable/enable to bind. A native session already associated with another account is refused (`session_identity_mismatch`), so its old context is never relabelled. A failed ownership fence stops automatic rebinding: an old process cannot repeatedly steal the new process's revision. `bb_bridge_status` exposes safe binding/recovery diagnostics, never the capability.

Disable closes owned MCP connections/registrations, timers and bridge observers; pending work remains recoverable. Native Plugin Manager enable/disable and removal require the restarts specified by the installed host. Removal of a running bundle returns `stop-profile`; stop/deselect before removal. Durable journals are retained for reinstall/recovery, while live binding files are removed on clean disposal. Removing those durable files is an explicit data-reset decision and forfeits the stable consumer; do not remove them to bypass uncertain work. Rollback means disable this bundle and restore the previous source directory/profile selection; it never means installing the historical runtime patch.

## Product boundaries

The installed official MCP client owns stdio child lifecycle. The Python MCP service forwards to the BB client; it does not authenticate directly to FastAPI. The bundle contributes public Cordis hooks, a cooperative system prompt section and scoped operation wrappers. Register/login, Profile, directory, existing media/download tools and the three new query tools remain. v1 standalone MCP compatibility remains unchanged; the bundle uses strict negotiated v2 and hides internal confirm/ACK from model tools.

Normal send/download operation IDs may be omitted on the bound session's scoped tools. The bridge derives the ID from a durable native session/call identity, persists the intent before dispatch, and returns the generated ID. Existing explicit IDs are accepted for compatibility. Recovery queries the original client operation, never creates a replacement send. The journal stores ID/digest/status metadata, not a duplicate business message table or server result database. A provider or tool outcome without sufficient durable evidence remains `uncertain` and blocks automatic progression; no text-based deduplication or model judgement decides whether to resend.

Download plans are reconciled through `downloads/get`, using a saved task ID or the original operation ID in verified client download events after a lost start response. They are not looked up in the sending-operation API. The fact must match the original operation, account and stable consumer; no new download start is issued during recovery. If neither task nor terminal event is known, uncertainty remains. Legacy metadata can be repaired by a matching verified download event, without manufacturing a business fact.

The bridge periodically discovers/subscribes to authorized peers and reads client facts. Wait, native query presentation and passive input share the journal. Queries themselves never confirm/ACK; only a complete native model presentation and a successful durable turn permit internal settlement. Missing images, failed turns and uncertain requests do not consume. No final model text is forwarded: only explicit send tools own outbound messages.

Inputs contain BB/source account, consumer/session and original message metadata plus ordered text/image blocks. Actual images are saved through the public attachment service; image-capable model metadata and actual projected image blocks are checked. A fresh consumer catches up incrementally; an existing consumer starts after its own committed position. New/rebuilt sessions receive bounded history automatically as described below. Exact context and older history remain available through `get_context`, `get_message` and bidirectional `read_messages`; the bridge does not synthesize summaries. Download completion/failure is delivered only for a journaled operation initiated by the configured session, after querying the client's current task fact.

This version uses one configured native session per bundle instance. While claimed work exists, resume its recorded session before selecting a different session; the bridge fails closed rather than abandoning an old pending input. Different consumers use different private state directories. It does not implement shared-JSON cross-machine HA.

## Automatic bounded history

Before the first incremental input for each native session incarnation and peer, the bridge queries the existing client `get_context` fact, anchored at that input. It prefixes the same native message/tool result with a `history_context` envelope and nearby already-consumed messages. This applies to passive delivery and model wait/query presentation. The journal records session ID, public session-header creation time, peer, anchor, consumed position, selected IDs/ranges, omissions and projection digest. It stores no historical message bodies. The host's ordinary Session persistence owns the rendered context.

The envelope has hard limits: eight neighboring historical messages, 12 KiB of total historical text including metadata, two images and 2 MiB of decoded image bytes. Selection prefers nearby messages and restores chronological order; each retained message preserves text/image order. Source/target identities and original message IDs distinguish history from the current increment. Text overflow, image overflow/unavailability, missing positions/media, unsupported reply relations and an older-page indicator are explicit. The envelope includes bounded `get_context`, backward `read_messages`, and exact `get_message` continuation arguments. `reserved_usage` describes conservative reservations before omissions, not model token usage.

Only positions at or below the captured committed cursor are historical context. Unconsumed neighboring positions are labelled `unconsumed_not_history`, never silently treated as processed. Historical queries may prepare receipts, but the bridge does not claim those messages, confirm their receipts, send anything, or ACK them. The first increment alone is the new task, and its own complete presentation plus successful turn remain necessary for settlement. A historical image may be explicitly omitted; missing incremental media still fails the ordinary strict presentation gate.

The durable initializer is part of the first incremental journal record and native projection. Later inputs and a restored original session do not repeat it. Rebuilding a settled session, including reusing its ID with a different public header creation time, initializes it again. If unsettled work belongs to a different or lost original session incarnation, binding reports `recovery_session_required` and `required_sessions`; it preserves uncertainty and performs no model replay or early consumption. This is an explicit recovery restriction, not a claim that the lost native session was recovered. Restore the original session evidence before retrying; deleting uncertain rows is not a supported repair.

## A/B/C recovery implementation

Every journal write is fsynced, atomically renamed and directory-synced. Owner capability publication uses create-if-absent hard links. Records are separated by binding revision, so stale callbacks cannot overwrite a replacement's revision. The client CAS and strict expected_identity remain the authority for business commits.

| Boundary | Replacement behavior |
| --- | --- |
| A: claim durable, not delivered; or owned native pending persisted | Rebind explicitly; resume the native session; remove the old owned pending entry under public maintenance; fetch the original fact and create one new attempt. |
| B: dispatch intent durable, model outcome unknown | Preserve queryable uncertain. No model replay, send, confirm or ACK. A fully durable successful native turn may resolve a lost observer update. |
| C: completed native turn, confirm/ACK response lost | Reuse the same attempt/digest/receipt; idempotently confirm and query/advance the client's cursor, without another provider request. |
| Explicit send succeeded, result not journaled | Query original operation ID, retain the original success, never resend; an unfinished native turn stays uncertain. |
| Download succeeded, start response not journaled | Find its terminal event by the original operation ID, verify the task via `downloads/get`, never restart the download; an unfinished native turn stays uncertain. |

The metadata journal is not an alternate scheduler. The stock host owns inboxes, turns, tool calls, cancellation, Session projection and Session persistence. The bridge uses `followup`, `runMaintenance`, `inbox.remove`, `sessions.flush`, scoped tool registration and documented event hooks only.

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

`--context` uses six separate plugin processes: seed/settle, new native session, restore that session, rebuild the same ID, unknown model outcome, and lost original session rejection. It checks cursor/request/receipt facts and actual red/blue native image bytes. The installed product test also switches a fully settled session via the real Settings service and proves automatic historical context plus one new task. `history.test.mjs` separately uses a query double for budgets, omissions and peer/session scoping. Neither test's deterministic provider is evidence of real model visual understanding.

Only sanitized `results.json`, `sources.json`, `host-integrity.json`, lifecycle/installed summaries are distributable. Private service logs, native sessions, owner files, databases and raw configs may contain synthetic credentials/capabilities and must not be attached. The runner hashes the fixed eight host files before/after and records product source hashes. Real model/visual understanding, browser Settings screenshots, Windows/Android, final same-SHA Flutter/CI and Sentinel independent QA remain separate acceptance work; deterministic media projection is not visual-understanding evidence.

## Remaining raw-client contract discrepancy

On client tree `dea50f14f0d3c8470ed87573370887f6580d424a`, a direct `/v2/chat/send_attachment` request omitting optional `cover` returns 422; the identical request with `cover: null` returns 200. The machine contract accepts omission. The MCP transport now emits the canonical explicit null, so the installed bundle's attachment/download test passes; that does not fix the raw Dart HTTP parser. Reproduce independently with `BB_PRODUCT_CASES=cover` before the `--product` command above. Its result is `REPRODUCED_GAP`, not a passing contract test. Client ownership remains with Muse/Orion; no Flutter production source was edited in the bundle work.
