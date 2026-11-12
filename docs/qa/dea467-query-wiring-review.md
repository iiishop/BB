DEA-467 query wiring integration review — Orion, 2026-11-12

Tested product commit: `bec7d843e975aa11c5401b76774db73d2a29a84e`.
Client tree: `26832065e55e08f66ad2080c2c2888009a1b450e`.
This report does not mark the product ready for independent QA.

## Completed checks

`flutter test test/chat_query_service_test.dart test/chat_v2_query_routes_test.dart test/chat_v2_shared_contract_test.dart --reporter expanded`, from `client/`: **16 passed, exit 0**. These are client fixture-based tests, not a live FastAPI claim.

A separate foreground orchestration launched real isolated FastAPI/SQLite and the standalone Dart `client/bin/bb_client_api.dart`, then used MCP `ClientSession` over stdio to the production Python `bb_dsh_plugin` process with its guarded transport. There was no transport double in this check. Synthetic account credentials, consumer capability, database, session files and raw service logs remained private. All owned processes were stopped before completion; DSH was not launched or modified.

The live runner exited 0 with eight assertions:

1. MCP tools/list includes register/login and all three new queries plus read_messages, and hides internal ack_messages in guarded mode. Registration/login themselves were performed through HTTP fixture setup, not asserted as MCP calls here.
2. Three explicit text sends through MCP create one actual conversation with consumer watermark 0 and unconsumed_positions 3.
3. get_message returns the same stored message and a presentation receipt.
4. get_context returns positions 1–3 around position 2, range 1–3 and unsupported reply relations.
5. before_position=3/limit=1 and after_position=1/limit=1 both return position 2, next_position 2 and the correct directional has_more.
6. After queries, consumer watermark remains 0.
7. An absent message produces a guarded MCP error with status 404.
8. A real server-created third-party message produces exactly the same safe error as the absent ID.

## Reproduced defect: binding revision changes during query

One controlled Flutter/local HTTP test failed, exit 1: expected 409, actual 200. It used the existing fake backend only to pause the query, with the real ChatService, ledger, v2 HTTP handlers and binding implementation. It is distinct from the eight live assertions above.

Minimal reproduction, based on `chat_v2_query_routes_test.dart` setup:

1. Subclass ChatApiClient.messageById to await the original implementation, signal an entered Completer, and await a release Completer before returning that original message.
2. Start POST `/v2/chat/get_message` with the enrolled owner's key and expected_identity revision R; pause at the above barrier.
3. POST `/v2/consumers/bind` with the same owner, current expected_auth, same consumer_id, expected_binding_revision R and session_id `replacement`. Assert bind succeeds.
4. Release the old query; assert HTTP 409 / stale_binding. Current code instead returns HTTP 200 carrying the old revision R.

The new query cases call requireIdentity at entry, then `_ensureCurrent(context.identity)` before returning. `_ensureCurrent` checks the auth generation only, so a same-account binding revision change is invisible to this last check. `_reply` merely serializes the old expected_identity. This is a query completion fence defect, not evidence that the previously verified atomic confirm/ACK fix regressed.

Client owner should validate the full expected identity/binding after asynchronous query/media work before exposing results, and verify stale queries do not leave a usable complete presentation under the replacement binding. Cover the common query return/projection path and keep the established stale_identity vs stale_binding distinction. Do not change shared schema or relax the test to accept 200.

## Limits

The live check used text; two-image ordering, missing media in the real chain, real model/vision, bundle installation/settings/lifecycle, product recovery A/B/C, final integrated CI and Sentinel independent QA remain outside this check. Muse's reported full Flutter 331 passed / 8 skipped and Linux integration 13 passed were not rerun here. The initial reproduction command was launched once from the repo root and exited because there was no pubspec; the defect result above is from the corrected `client/` invocation.

The temporary failing review test was removed from the repository test tree after execution. No client production code or external runtime was edited by this review. Existing query and recovery passes remain valid within their recorded scopes; this defect must be fixed before final product acceptance, and does not prevent parallel bundle work.
