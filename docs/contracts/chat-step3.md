# Chat step 3 — R2 implementation contract

Status: implementation handoff for Orion review, not independent QA or integrated product acceptance. Supersedes the recovery assumptions in `chat-step3-runtime-patch.md`; historical probes and Sentinel counterexamples remain evidence. Baseline: `7c15f172cb8d6ed968629ac5ab41d9c989a8f1ea`. No `client/` changes.

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

## Native recovery R2

Only the version-locked, copied runtime is supported. `runtime-patch/lock.json` pins DSH 0.2.1-rc.5, Cordis 4.0.5, Linux x86_64, full dependency tree and target/helper/patch SHA256. Installer refuses mismatches, symlink destinations and existing targets; never modifies globally installed source. Global source is read-only. Ordinary non-event native tool behavior is unchanged.

Persisted identities are distinct:

- business key `(account, DSH session_id, event_id)` → stable accepted message and logical_turn_id;
- claim → physical turn/step and retained full original content;
- dispatch → unique inference attempt_id, actual projected member_ids and SHA256 of actual input;
- durable model tool plan → fresh operation_id, original arguments digest and event members;
- operation result → reconciled client receipt, independent of tool errors and native completion;
- consumption ACK → separate client fact; runtime status returns consumed_through:null.

Acceptance is native plugin record + retained content, flushed before receipt. Replays reconcile existing acceptance and re-drive the **native driver**, preserving event/logical IDs. Claimed-but-not-dispatched inputs can be reconstructed after restart. Twelve concurrent submissions serialize admission. Completed events do not generate new turns. The pre-step filter may remove claimed messages: only IDs in the built request receive dispatch records, filtered IDs remain deferred and can be retried after filter removal. They are never silently completed or ACKed.

Before provider streaming, flush request member/digest/attempt intent. Stream fragments are provisional diagnostics; no callback publishes them to BB. With no persisted tool plan, a crash before or after provider entry permits another inference attempt under the same logical event. This is deliberately **not exactly once inference**.

Before any event-driven tool execution, persist the returned model tool plan and stable operation_id, flush, then call the local boundary. send_message/send_attachment/start_download are the supported business-effect allowlist. The native local bridge first queries `/operations/get`; only 404 permits the corresponding idempotent submit. Unknown transport state throws and keeps the plan pending. Other non-read effects (including auth/profile mutations or arbitrary shell) are rejected as unsupported in event turns, with explicit failed operation evidence. This restricted profile is essential to the pure-reasoning recovery claim.

On restart, reconcile retained plans **before new inference**. Do not re-emit old native tool/call events in a different physical turn: that violates V4 lifecycle validation. Append only actual operation receipts to the plugin record stream; do not modify old history. A recovered business plan settles that logical event without generating a fresh model continuation/output. Interrupted read-only plans are recorded as interrupted, not business success; an explicit subsequent read is needed. Generic arbitrary-provider/tool transactions are outside this patch.

Compatibility: ordinary sessions without BB records resume unchanged. Prior `bb-recovery-1` acceptance/claim records are readable, but old dispatch records lack actual membership and effect barriers and are conservatively `legacy_uncertain`; they are not promoted to safe R2 proof. New records use bb-recovery-2 in the existing namespace. Unknown versions/owned IDs with missing acceptance fail closed. No rewriting/migrating JSONL history.

## Reproduction and withdrawal

From repository root (source must be the exact pinned package tree):

```sh
uv run --no-project python dsh-plugin/runtime-patch/install.py --source "$DSH_SOURCE" --destination dsh-plugin/.runtime/dsh-r2
uv run --no-project python dsh-plugin/runtime-patch/install.py --verify --destination dsh-plugin/.runtime/dsh-r2
node dsh-plugin/runtime-patch/test.mjs "$DSH_SOURCE" dsh-plugin/.runtime/dsh-r2
node dsh-plugin/runtime-patch/test-boundaries-r2.mjs dsh-plugin/.runtime/dsh-r2
node dsh-plugin/runtime-patch/test-operations-r2.mjs dsh-plugin/.runtime/dsh-r2
uv run --directory server pytest -q
uv run --directory dsh-plugin pytest -q
uv run --directory server python -m bb_server.export_openapi openapi.json
uv run --directory server python contract/export_chat.py
```

The native matrix starts the real Cordis/DSH/JSONL composition in synthetic profiles and terminates all workers before return. `local-bridge.mjs:setupLocalBridge(origin)` is passed as the native agents.create/resume setup callback; runtime resumes after setup. Model is a deterministic double. Operation tests use a durable synthetic local HTTP client; server pytest independently exercises real SQLite transactions. No configured personal runtime is started.

Withdrawal: stop only the isolated worker/process you launched, retain its evidence/session directory, remove that build/profile when no longer needed; use the original installed executable for existing personal deployments. Do not open R2 product sessions with an unpatched runtime and assume delivery guarantees. Rebuild diff via `build-diff.py <pinned-source>` only for review; never regenerate locks against an unreviewed version.

## Remaining integration gates

This code is not final product acceptance. Local client credential/download/display ledgers, durable event feed to native sessions, busy/matching-wait/turn-end scheduling integration, native consumption-evidence plumbing and full chat/MCP/DSH integration still require the shared client build. The event-turn effect allowlist currently refuses ack_messages: it must not advance consumption without that display-evidence plumbing. Python MCP exposes explicit ACK and its 409 contract for client work; no passing double substitutes for actual client behavior. Real models/vision, Flutter three layers, Android, Windows, physical foldables and Owner manual acceptance remain NOT RUN. Orion must review these compatibility/integration limits before treating the contract as frozen for the integrated product.
