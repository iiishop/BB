# DEA-481 Dart/local/plugin integration

Baseline `d402ba8cecdfdbfb421eef23165483b24f3bd1a3`, approved product revision 1.
Run `01a1e164-cd45-7d81-b0c3-9251ede81d30`, isolated checkout
`dea-484-9251ede81d30/workdir/BB`, branch `agent/forge/dea-481-agent-access`.
Forge owns these services, generated DTOs, local entry, plugin and corresponding
tests. Muse owns UI/navigation. No shared CI or DEA-480 files are changed.

## Dart consumer interface

Import `services/space_service.dart` (exports DTOs and typed method extensions).
Construct `SpaceService(api: SpaceApiClient(baseUri: serverUri), session: auth.session,
chat: chat)` with the **existing** session and ChatService. Import
`services/space_api_client.dart` for the transport constructor. Every action in
`server/contract/space-v1.json` has a camelCase method, camelCase named parameters
and typed `Space*` result. Examples:

```dart
final page = await space.listPosts(limit: 20, unreadOnly: true);
final detail = await space.getPost(postId: id, visitId: stableVisitId);
final receipt = await space.createDraft(operationId: stableOperationId, text: input);
final draft = await space.getDraft(draftId: receipt.resourceId!);
await space.updateDraft(operationId: saveId, draftId: draft.draftId,
  expectedVersion: draft.version, text: input, referenceId: draft.referenceId,
  imageIds: orderedIds);
await space.markRead(operationId: readId, postIds: [id]);
final events = await space.readEvents(afterEventId: appliedCursor);
```

UI omits `expectedIdentity`; local tools must supply the enrolled identity and
owner header. No automatic read/notification acknowledgement or visit generation.
Keep visit ID over resize/retry; issue a new ID for a new active detail visit.
Persist/retain logical mutation IDs with unsynchronized UI input. Retry the same
ID and same payload; the service queries the receipt first. `getOperation` is
scoped to the server/account/consumer that originally accepted the operation.
Errors are `AuthFailure` with status/code, never empty success lists.
Read `overview` to discover capability; 404 means unsupported, preserve chat.

The service deliberately stores no post/image/notification content cache. UI
owns displayed copies and must apply `readEvents` invalidations, refetch affected
facts, clear old identity state on logout/server switch, and advance its cursor
only after applying events. HTTP global replay works with the locked Uvicorn
configuration; no new WebSocket dependency is required for this fallback.

DTOs, validation schemas and typed methods are generated from the single contract:
`uv run --project server --locked python client/tool/generate_space.py`, then
`dart format client/lib/models/space_models.dart client/lib/services/space*.g.dart`.
No hand-maintained caller schema. Pydantic validators for unique image IDs and
nonblank comments are also enforced before local side effects.

## Dispatch order and crash boundaries

Validate -> capture existing auth/binding -> persist intent digest in existing
ChatLedger -> recheck identity -> request with captured token -> persist receipt
(IDs/version only) -> recheck identity -> respond. A lost reply is reconciled
under the original server/account/consumer after explicit rebind. Receipt lookup
never returns a stored body. A switch during IO cannot return old content to the
new session; the receipt remains with the accepted scope. Storage failures before
intent persistence prevent dispatch; failure after server commit remains
queryable under the same ID. The service never creates a replacement ID.

## Existing DSH bundle

The existing Python MCP server now discovers 24 `space_*` tools directly from
`bb_auth_contract.space.REQUESTS`; only internal `read_events` is omitted from
model discovery. The bundle derives mutation wrappers from those tool schemas
and extends its existing `Operations` journal: stable ID/digest is flushed before
calling MCP, recovery queries `/v2/space/get_operation`, and replay never dispatches
again automatically. Host session gating, owner capability and outbound hooks
remain in force. `space_get_image` returns a native MCP ImageContent block plus
non-secret metadata; arbitrary URLs/local paths are not image tool arguments.

The installed-host probe uses public stock DSH plugin-manager/settings/session
services. Disabling bridge polling removes its MCP tools. Uninstall requires the
host's **setBundleEnabled(false) → restart → removeBundle → restart** lifecycle;
bridge `enabled=false` alone is not a host bundle unload. It preserves server
facts and does not regenerate publications. No Space timer/model wakeup or chat
notification subscription was added.

## Repeatable checks

- `flutter test test/space_service_test.dart` from client/ covers pre-dispatch
  flush failure/rollback/cold reopen, lost reply reconciliation, in-flight account
  switch, consumer operation ownership, and strict shared-schema input.
- `uv run --project dsh-plugin --locked pytest dsh-plugin/tests -q` runs MCP
  discovery/transport/schema and existing native-JS operation journal regressions.
- After `flutter pub get --directory client`, run
  `uv run --project dsh-plugin --locked python dsh-plugin/probes/space_live.py` for
  real server + independent Dart/TCP, permissions, CAS, explicit acknowledgements,
  process restart/rebind, durable HTTP replay, deletion and revoked authentication.
- `uv run --project dsh-plugin --locked python dsh-plugin/probes/space_host.py OUTPUT
  --runtime STOCK_DSH_PACKAGE_ROOT` runs installed-bundle lifecycle, 24 tools,
  ten-image publication/order and actual image bytes at the native provider seam.
  The provider is a deterministic test double, **not** semantic model evidence.

All probes own temporary synthetic accounts/profiles and terminate their exact
child PIDs before returning. No global dependency, personal profile or credential
is changed. Build the test bundle using the existing `dsh-plugin/build_bundle.py`.
Real model comprehension/injection resistance, rendered settings UI, and target
Windows/Android/foldable execution are separate unperformed checks for this scope.
Existing bundle settings UI implementation was not changed.
