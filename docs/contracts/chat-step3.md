# Chat step 3 — R3 implementation contract

Status: implementation handoff for Orion review, not independent QA or integrated product acceptance. Supersedes the recovery assumptions in `chat-step3-runtime-patch.md`; historical probes and Sentinel counterexamples remain evidence. Common implementation baseline: `12ce1c054286315f76d7b38143060add6f3c39d2`. No `client/` changes.

## Sources of truth and ownership

- FastAPI/SQLite owns accounts, messages, media metadata, operation results and message events. Account remains the eight-digit login/social identifier; no Actor migration.
- The same-machine client owns credentials, local file/URL access, upload proxies, download tasks, display/consumption receipts, send ordering, and its durable event replay. The DSH plugin calls only `http://127.0.0.1:<port>` client endpoints. No server token is returned to the model.
- Native DSH session JSONL owns event acceptance, claimed content, inference attempts and tool operation plans. Its history never substitutes for platform messages or client download records.
- `server/openapi.json` is generated from the application. `server/contract/chat-local-schema.json` contains POST inputs/outputs, errors, server and local event schemas. `chat-cases.json` supplies synthetic cross-language examples and consumption cases.

## REST API

All endpoints require the existing bearer session; missing/invalid session is 401. The authenticated account always supplies sender/operation ownership. Operations on invisible media/operations return 404.

| Endpoint | Contract |
| --- | --- |
| GET `/users?after_account=&limit=50` | Account ascending keyset pagination, 1–100, self excluded. `items,next_cursor`. All registered users, including no prior contact. Each item: account, username, avatar_url/version, effective presence, nullable last_contact_at/last_message. |
| POST `/messages` | `target_account,client_nonce,content`; content is an ordered nonempty array of text/image(media_id). Returns 200 Message, including on replay. |
| POST `/messages/attachments` | `target_account,client_nonce,media_id`; one non-image attachment, returns 200 Message. |
| GET `/conversations/{account}/messages?after_position=0&limit=50` | Pair-scoped ascending positions, 1–100. `items,next_position,has_more`. Includes both incoming and outgoing messages. |
| GET `/operations/{operation_id}` | Own committed message result only. `operation_id,kind=message,status=succeeded,message`. Absent or another account's operation: 404. |
| POST `/media` | Multipart `target_account,file,cover_media_id?`; returns metadata. 32 MiB file limit, plus bounded multipart overhead. |
| GET `/media/{id}` | Only the bound pair. Authenticated byte ranges, attachment disposition, private/no-store, nosniff. Covers use the same route and authorization. |
| GET `/events?after_event_id=0&limit=100` | Own durable event stream, globally increasing event_id with expected gaps between accounts; 1–500. `items,next_event_id,has_more`. |
| WS `/events` | Authorization header only, query strings rejected. Hints replay durable stored events. Client deduplicates and uses GET replay; socket memory is never authoritative. |

Message fields: id, pair-local position, sender_account, target_account, created_at UTC, kind(body/attachment), nullable content/attachment. Attachment metadata: media_id,media_type,filename,mime_type,byte_size,cover_media_id. Unknown users and self conversations return 404.

Idempotency is **authenticated account + client_nonce**, not target + nonce. Target and complete typed request belong to the canonical JSON digest. Same nonce+parameters returns the original message; changed target/content/kind returns 409. `BEGIN IMMEDIATE` serializes position allocation and duplicate admission. Message, operation result and one event for each participant commit in a single SQLite transaction. Lost HTTP response is resolved by query then identical retry. Uploads are separate immutable resources; retrying upload cannot itself publish another message.

List previews are private to the current account/pair. Concatenate text and `[图片]` in body order; attachments use `[视频]`, `[音频]` or `[文件]` plus filename. Truncate to 20 extended Unicode grapheme clusters then `…`; sender name is a separate field and not counted. Never download attachment originals to construct previews.

Errors use existing `{error:{code,message,fields}}`: 401 unauthenticated; 404 not_found; 409 conflict; 413 payload_too_large; 415 unsupported_media_type; 422 validation_error; 503 storage_unavailable. Local proxies additionally retain 502/504. A transport timeout says **uncertain**, not downstream failure and not logout.

## Media policy and migration

`BB_MEDIA_DIRECTORY` is required by the server launcher; test factory defaults beside its selected DB. Store random opaque IDs, never client-supplied paths. Sanitize only display filenames. Persist file bytes (fsync and directory fsync on POSIX) before SQLite metadata commit; crash or failed commit may leave an inaccessible orphan, never a published partial file. No media deletion/GC is exposed in this step; do not remove referenced bytes. Image input is decoded/verified PNG/JPEG/WebP, at most 16 million pixels. PDF/MP4/WebM signatures are checked; no antivirus or codec-completeness guarantee is claimed. Other allowed types: audio/mpeg,audio/wav,text/plain,application/octet-stream. Arbitrary HTML/SVG is rejected. No server transcoding.

Video upload requires `cover_media_id` of a previously uploaded image bound to the same pair. **Client extracts the actual video frame**; server checks image format and pair ownership, cannot prove it came from that video. Actual extraction/playback remains client/visual acceptance.

Migration 003 adds media/messages/operations/events and indexes transactionally; preserves step 1/2 data. Newer user_version is rejected. Existing SQLite backup command still backs up the DB; for a restorable chat backup stop writes, back up DB, copy its entire avatar/media directories and retain their IDs, then restart. Restore into fresh paths with server stopped and verify all referenced bytes before use. No downgrade of a migrated DB: rollback requires the pre-migration snapshot. A migration failure rolls back schema changes.

## Local client and MCP

All local routes are POST. Strict machine models are in `bb_auth_contract.chat.LOCAL`. The plugin exposes nine additional tools, retaining the eight auth/profile tools:

| Tool | Local path | Result |
| --- | --- | --- |
| list_users | `/chat/list_users` | UserPage |
| send_message | `/chat/send_message` | Message, HTTP 200 |
| send_attachment | `/chat/send_attachment` | Message, HTTP 200 |
| read_messages | `/chat/read_messages` | VisibleMessage items with ordered text/image bytes |
| wait_messages | `/chat/wait_messages` | Read result plus reason messages/timeout/cancelled/logout/disconnected |
| ack_messages | `/chat/ack_messages` | consumed_through |
| start_download | `/downloads/start` | Download, HTTP 202 |
| get_download | `/downloads/get` | Download |
| get_operation | `/operations/get` | Operation |

Local sends use operation_id; client maps it unchanged to server client_nonce after resolving sources. A source has exactly one base64/path/url plus MIME and filename. Client reads files/URLs and uploads; plugin does neither. Client must persist the original source digest and resolved media IDs before retries so reuploading cannot change the same operation's final message parameters. Body first, then each non-image attachment in original order; reuse each successful operation ID on retries, do not resend successes under new IDs.

Read returns metadata and ordered MCP text/image content blocks with actual base64 bytes/MIME. Metadata alone, a URL, or an image description is not an image submission. Incoming message images and video covers can be displayed; attachment originals are downloaded only on explicit request. The Python bridge does not automatically ACK reads or waits.

Wait has account,consumer_session,seen_position,timeout in {30,60,120}. First query backlog after seen_position before subscribing; no arrival gap. Model/tool timeout must exceed requested wait by at least 5 seconds (implemented in Python HTTP client). A read timeout is 504, not an empty successful wait. Logout/disconnect/cancel are distinct from timeout.

ACK uses account,consumer_session,through_position. CLIENT ledger is scoped by authenticated account + consumer_session + peer. Reject 409 consumption_gap if any position between current consumed cursor and through_position lacks verified display evidence. A repeated lower/equal ACK is idempotent; later messages survive. Model request intent, native claim, returned tool result or turn/end alone cannot establish that evidence. No automatic ACK is generated by runtime recovery. Download completion is not message consumption.

Download start adds operation_id and consumer_session. Same authenticated account+ID+arguments returns the same task_id; changed arguments 409. Persist reservation/task before 202. Operation query returns kind=download,pending/succeeded/failed,task_id; missing/other account 404. A task binds to its originating session. Task status pending/running/succeeded/failed; actual_path exists only on success. Use absolute same-machine directory or configured cache subdirectory (images/videos/audio/documents/other); reserve names exclusively, suffix collisions, reject traversal, never overwrite. Failure returns a safe error code. Task results and completion events survive client restart. These are client obligations and currently verified with labeled doubles, **not an implemented Dart download subsystem**.

Client local events use the exported schema: version,event_id,account,consumer_session,type with peer/position for messages, task_id/operation_id/actual_path or error_code for downloads. Replay and session binding must precede adapter ingestion; event text IDs alone are never deduplication evidence.

## Internal R3 client interfaces (not MCP tools)

`VisibleMessage.presentation` is optional `{receipt_id,content_digest}`. New clients prepare and persist it for each returned message, bound to login account, consumer session, peer, message ID/position and the ordered blocks. It is a preparation receipt, not display or consumption. Old replies remain readable but cannot be confirmed. Client digest is opaque to the adapter; the adapter does not recanonicalize client JSON to reproduce it.

| Internal POST | Input | HTTP 200 output |
| --- | --- | --- |
| `/chat/confirm_presentation` | consumer_session,attempt_id,request_digest,receipt_ids | confirmed_receipt_ids |
| `/events/subscribe` | consumer_session,peer_account | consumer_session,peer_account |
| `/events/read` | consumer_session,after_cursor>=0,limit 1–100 (50) | items[{cursor,event}],next_cursor,has_more |
| `/events/wait` | events/read input + timeout 30/60/120 | page + reason(events/timeout/cancelled/logout/disconnected) |

These four interfaces are exported under `internal_operations` in the machine schema, never listed as model-callable MCP tools. Client account/consumer/peer subscription, event stream, prepared receipts, confirmations and ACK cursors must persist. Client source events are deduplicated; message events appear only when the corresponding message is readable. Download events bind to the creating consumer session, with no peer inference. Event cursor is per account+consumer, distinct from each conversation's message position and consumption watermark.

Confirm retries with the original attempt/receipts are idempotent; changed identity/content 409, other account/unknown receipt 404, logged out 401. Confirm never advances the ACK cursor. ACK stays `/chat/ack_messages {account,consumer_session,through_position}`: require confirmed receipts across the entire gap, return 409 consumption_gap otherwise; a lower/equal ACK is idempotent and later messages survive. UI rendering, a tool return, request intent or turn/end alone cannot confirm DSH display. Account switching and 401 must isolate the client ledgers; network failure must not silently log out or clear them.

## Native recovery R3

Only the version-locked copied runtime is supported. `runtime-patch/lock.json` pins DSH 0.2.1-rc.5, Cordis 4.0.5, Linux x86_64, full dependency tree and target/helper/patch SHA256. Installer refuses mismatches, symlink destinations and existing targets; source remains read-only. No personal profile discovery or shared dependency mutation.

The two native primitives remain: durable acceptance retaining full content, and recoverable claim/redrive through the existing DSH driver. Business identity is `(account,session_id,event_id)`; repeated/concurrent admission reuses its native acceptance and logical ID. A plugin cursor is flushed only after acceptance. A crash between acceptance and cursor update replays the event key without refetching/changing its already accepted body. Deferred inputs are retried on explicit/native recovery or the next adapter pump; completed events never wake another turn.

Each actual model request records its attempt ID, actual member IDs and input digest. Claims removed by pre-step filtering remain deferred, never completed or ACKed. Provider request/stream fragments are provisional and never directly publish BB messages. A successful native model response is separately persisted; no terminal success is inferred from turn/end. Requests ending in max-tokens/error/abort do not create display confirmation. A pure inference attempt without a durable effect plan can retry under the original logical event.

Model tool plans are flushed before effects: stable operation_id, complete arguments/digest, owning event members, native turn/step. send_message/send_attachment/start_download query the local operation result before submitting. Receipt status preserves pending/succeeded/failed; accepted download pending never becomes completed download. Unknown transport results stay uncertain and reconcile before continuation. Unsupported effects are rejected before execution in event/product sessions. Ordinary sessions without BB bindings/records retain their native behavior.

**Continuation:** after resolving retained plans, append an explicitly marked `source.kind=runtime-context` recovery message, never a platform message or fabricated old tool/result. Its stable continuation_id points to original logical event/input and records plan IDs, actual receipts, phase and content revision. The original ordered text/image input remains in native history. Repeated restart reuses the same pending continuation/revision. The model actually runs again; only a successful terminal response completes the event. An interrupted read plan is reported as interrupted in recovery facts, so the model can explicitly read again rather than inventing a result.

Cross-restart attempts to resend the same retained write intent (tool + canonical parameters, excluding caller operation_id) map to its existing persisted operation and receipt, even with a fresh provider call ID. This policy is scoped to old physical turns of the same logical event; multiple new calls in the original live plan are not collapsed. Changed intentional parameters create and flush a new plan. During recovery, an intentional exact repeat of an already executed write requires a new business event; a renamed operation_id alone cannot authorize duplicate output. Native plan aliases record this correlation. No provider transaction or semantic equivalence guessing is introduced.

**Presentation mapping:** Python MCP results include reserved start/end markers and internal `bb_presentations` metadata (receipt, client digest, source message/position, sender/target, consumer, peer, expected image count). Native hooks compare the final canonical projection against the original MCP wire text/image structure, then bind its actual native message ID and segment digest. At request time only complete unchanged segments in the actual input are eligible; removed/truncated content, image admission fallback and binding conflicts cannot confirm. Passive inputs use the same markers, with actual image references saved by the isolated native attachment store after positive model image-capability admission. Actual model vision quality remains a separate acceptance gate.

After a valid successful model response, persist response success and request/receipt evidence, then call confirm_presentation. On response/confirmation interruption, replay that same stored attempt+receipt set. A terminal response already persisted does not need another provider call merely to finish confirmation. Explicit ack_messages first drains pending confirmations and then calls the client's independent gap-checked ACK. Session binding is checked; native status does not invent a client consumption watermark.

**Scheduling:** `RuntimeBridge` registers one configured peer per DSH session and reads/waits on the client event feed. It validates account, session, peer and monotonic cursor before admission. Idle input wakes the native driver; ordinary busy input and download events use next-turn. A message matching an active wait tool uses next-step in the current turn. Active waits are tracked by native call identity and cleared on tool/turn exit. A late event for a message already present in a successful read/wait request is explicitly linked to that request as satisfied, so it does not restart processing. Receipt confirmation is still retried independently and never implies ACK. Other sessions do not share delivery IDs, cursors or receipts.

`setupRuntimeBridge` installs callbacks before publication; binding/subscription initialization occurs after the real session becomes live and before automatic resume. `setupProductBridge` additionally mounts the real Agent-scoped DSH MCP client with namespace `bb` (or configured unnormalized ASCII namespace <=30 chars) and `toolCallTimeoutMs=130000`; the DSH default 60000 is insufficient for 120-second waits. The internal HTTP wait allows requested time +5 seconds. Cordis owns/disposes the MCP subprocess with the Agent. The host must await `bridge.run(signal)` or explicitly call pumpOnce; no detached poller or second Agent scheduler is created. Cancellation stops the awaited loop; transport failures retain durable state for retry.

Compatibility: ordinary old sessions resume unchanged. R2 acceptance/claim/effect records remain readable. R1 dispatches lacking actual membership/effect barriers remain legacy_uncertain. R2 sessions already terminal under their old semantics are not rewritten or silently rerun. Unknown versions and owned IDs with missing acceptance fail closed. No V4 history is rewritten.

## Reproduction and withdrawal

From repository root (source must be the exact pinned package tree):

```sh
uv run --no-project python dsh-plugin/runtime-patch/install.py --source "$DSH_SOURCE" --destination dsh-plugin/.runtime/dsh-r3
uv run --no-project python dsh-plugin/runtime-patch/install.py --verify --destination dsh-plugin/.runtime/dsh-r3
node dsh-plugin/runtime-patch/test.mjs "$DSH_SOURCE" dsh-plugin/.runtime/dsh-r3
node dsh-plugin/runtime-patch/test-boundaries-r2.mjs dsh-plugin/.runtime/dsh-r3
node dsh-plugin/runtime-patch/test-continuation-r3.mjs dsh-plugin/.runtime/dsh-r3
node dsh-plugin/runtime-patch/test-presentations-r3.mjs dsh-plugin/.runtime/dsh-r3
node dsh-plugin/runtime-patch/test-mcp-r3.mjs dsh-plugin/.runtime/dsh-r3
uv run --directory server pytest -q
uv run --directory dsh-plugin pytest -q
uv run --directory server python -m bb_server.export_openapi openapi.json
uv run --directory server python contract/export_chat.py
```

The native matrix starts the real Cordis/DSH/JSONL composition in synthetic profiles and terminates all workers before return. `native-setup.mjs:setupProductBridge({mcpModule,pluginDirectory,origin,account,peer_account}, onReady)` is passed as the native agents.create/resume setup callback. Load mcpModule from the verified private runtime; pluginDirectory is an absolute project path. The callback supplies the RuntimeBridge to the host, which awaits its run(signal) lifetime; native recovery starts only after binding/subscription initialization. `setupLocalBridge` is retained only for the narrower operation fault tests. Model is a deterministic double. Operation tests use a durable synthetic local HTTP client; server pytest independently exercises real SQLite transactions. No configured personal runtime is started.

Withdrawal: stop only the isolated worker/process you launched, retain its evidence/session directory, remove that build/profile when no longer needed; use the original installed executable for existing personal deployments. Do not open R2/R3 product sessions with an unpatched runtime and assume delivery guarantees. Rebuild diff via `build-diff.py <pinned-source>` only for review; never regenerate locks against an unreviewed version.

## Remaining integration gates

Forge's native/bridge R3 fault matrix uses real Cordis/DSH/JSONL, the local native image store, real Python MCP stdio and actual native MCP projection. Its provider and synthetic client are explicitly labeled doubles. A separate `test-live-r3.py` runs the unmodified Dart client at `c684e29371b0236dadecb05f8ff18802175502ef`, real FastAPI/SQLite, Python MCP and the patched native runtime; only its provider is a double. It verifies actual receipt→confirmation→explicit ACK, the unpresented gap, durable events across Dart restart, and business-commit SIGKILL→continuation→two replays with one output. It does not verify visual understanding or Flutter rendering.

**Integration remains FAIL:** that Dart revision rejects the R3 `events/wait.limit` field (422), overwrites a changed attempt/digest/receipt set (200 instead of 409, allowing the otherwise missing position to be ACKed), and gives a newly subscribed consumer no incoming backlog after another consumer advanced the account source cursor. The live runner deliberately exits 1 on these failures. Same-account receipt/session identity conflict returning 409 is valid; it is not confused with another account's 404. Shared R3 fixtures retain the required behavior. Coordinate fixes in client/ through Orion; do not work around these gaps by weakening the adapter or machine contract. Rerun on a reviewed combined SHA before independent QA.

Real models/vision, complete client/server/runtime recovery and download/ACK flow, actual account-switch timing, Flutter three layers, Android, Windows, physical foldables and Owner manual acceptance remain separate NOT RUN gates in this Forge handoff. No main merge, release, personal deployment or workflow reassignment is authorized here.

The frozen negative V4 reproducer is `runtime-patch/regressions/v4-failure/` (old helper, exact patch and lock, isolated installer). Build it into a separate `.runtime/v4-negative` and run `node dsh-plugin/runtime-patch/test-v4-negative.mjs <negative-copy>`. Wrapper exit 0 means it reproduced the expected second-restart corruption; it is not a product PASS. R2 original tests and Sentinel originals remain in the repository; R3 continuation expectations live in separate scripts.
