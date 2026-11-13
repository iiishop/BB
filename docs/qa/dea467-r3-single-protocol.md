DEA-467 — R3 and single protected local protocol
================================================

2026-11-12, Forge. Base `71b3a0c8292712f65abb66da5c2e777ed4fba542`.
Independent branch `agent/forge/dea467-r3-gap-recovery`; only Orion writes PR #12.
No client, external runtime, personal profile or credential edits.

R3: CONFIRMED, then fixed
------------------------

Regression-only commit `b0d9d41e751e07827de1d1fefe717761ab58b6e4` retains
the baseline production code. Both real MCP `get_message` and `get_context`
(before_limit=0, after_limit=0) query position 3 while cursor=0. A native
successful turn explicitly sends exactly one reply (position 4). Actual
Dart/FastAPI confirms the position-3 receipt but rejects ACK 3 with HTTP 409
consumption_gap. The disk journal is presented, not completed.

The test kills that native process only after session/journal flush and the
successful operation fact, then kills/restarts the actual Dart process.
A replacement host resumes the persisted native session and explicitly binds.
Baseline recovery rejects consumption_gap, cursor stays 0, no model call:
both reproduction paths fail their recovery assertion; command exit 1.
No journal, receipt or consumption state is synthesized for this reproduction.

Fix `45f4f48e1e9569e79eb2074591eb43651ba279d2` handles only an ACK response
with status=409 and code=consumption_gap inside the common settlement method.
It retains the presented row and its successful turn/receipt/attempt/request
proof; it does not mark completed or advance the cursor. Recovery can finish
and normal polling can present missing positions. Observer, startup and tick
now share this behavior. Confirmation errors, other ACK errors and non-409
responses still propagate. No automatic retry of sends was added.

Both paths now pass seed/recover/replay (6 PASS, exit 0). Before missing inputs
run, cursor is still 0. Native inputs 1, 2 and 4 execute once each; position 3
keeps the exact original nativeId, turn, receiptId, attempt and requestDigest.
Cursor reaches 4 only after contiguous confirmations. The business stream
still has three incoming messages and one original outgoing reply. The stable
operation_id is queried; the successful query/send turn is never re-executed.
A second host restart has zero model calls and unchanged completed rows.

Actual HTTP recovery also rejects wrong owner, old auth_generation and old
binding_revision with stale_binding/stale_identity. Old-binding ACK is rejected.
Seven component fault tests separately verify narrow error handling, including
confirmation failure, 401, unrelated 409 and an HTTP 500 named consumption_gap.
Those component tests use doubles and are not the real recovery proof.

The same six real R3 phases passed again at
`a708c83466966fa9757a52cea3c2790a8c0e0a8f` after MCP protocol convergence.
All runs used client tree `c4d96de34d6dc790d471b86f08504e5886b876ff`;
they do not claim to validate Muse's later client changes.

Owner's single-protocol revision
-------------------------------

The updated issue explicitly says there are no deployed old callers. Shared
contract commit **`4fd57d679891428884a812b7e46f31392470d981`** is ready for Muse.
The authority is `server/contract/src/bb_auth_contract/chat_v2.py`, with
`chat-v2-openapi.json`, `chat-v2-cases.json` and `docs/contracts/dea467-local-v2.md`.

- Six protected POST routes `/v2/profile/{view_avatar,update_avatar,view_nickname,
  update_nickname,view_signature,update_signature}` use the existing owner header,
  four-field expected_identity and `{identity,result}` response. Business payloads,
  media output and product validation rules are preserved. Async completion must
  revalidate full identity/binding before returning media or profile facts.
- Binding response is now `{identity,session_id,active}`; consumption response
  is `{consumed_through}`. Legacy migration fields/error/semantic requirement are
  removed. Existing owner, stable consumer, CAS, operations and receipts remain.
- Fixtures list 20 retired identity-less business paths, all requiring HTTP 404.
  Auth bootstrap `/auth/register` and `/auth/login` remains; server bearer-auth
  APIs and SQLite business ownership are unchanged.
- Deleted obsolete chat/profile local schema exports, old LOCAL/INTERNAL route
  tables and session-only local DTOs. Shared chat message/media/server event
  payload models remain in chat.py; this is not a second local protocol.
- MCP LocalClient can call only register/login. Every business tool, including
  Profile, uses GuardedTransport. Missing binding returns stale_binding, without
  HTTP fallback or implicit enrollment. Internal consumption tools stay hidden.
  The BB_GUARDED switch is removed: protection is unconditional.
- Existing profile/chat tests were ported to the protected wire, preserving
  content order, media, errors, timeouts, no retry and account rules. New tests
  cover every unbound business tool and stale responses for all six Profile tools.
- The default live probe now selects v2 instead of obsolete v1 counterexamples.
  Old-deployment migration cases were removed from active faults/remaining
  suites under the new Owner scope, not marked PASS or silently skipped.
  Historical probe sources/reports remain evidence of the earlier specification.

First-party call audit: bundle/client.js uses protected routes plus negotiation/
status/enrollment; bundle index owns binding and MCP lifecycle; guarded.py owns
all business forwarding; plugin.py owns only auth bootstrap; smoke.py tests auth
bootstrap and current tool inventory. FastAPI uses its existing bearer account
authorization and does not implement the local consumer API. Client route removal,
first-party Dart/UI calls and profile completion fences are Muse's work.

Executed checks
---------------

| Check | Exact applicable revision | Result |
| --- | --- | --- |
| Real R3 seed/recover/replay, both query tools | b0d9d41 baseline production | exit 1, two recovery failures reproduced |
| Same real R3 matrix | 45f4f48 and a708c83 | each exit 0, 6 PASS |
| Existing product recovery suite and installed bundle | 45f4f48 | exit 0, 11 recovery cuts + 1 installation PASS |
| Shared wire tests | 4fd57d6 contract | exit 0, 81 PASS |
| `uv run --project server --locked pytest server/tests -q` | 4fd57d6 server/contract tree | exit 0, 200 PASS, one existing dependency warning |
| `uv run --locked pytest -q` in dsh-plugin | a708c83 | exit 0, 106 PASS; HTTP/stdio doubles explicitly labeled |
| `node --test dsh-plugin/probes/product/*.test.mjs` | a708c83 | exit 0, 12 PASS |
| Ruff src/tests/probes/build_bundle + format | delivery tree | exit 0 |
| `build_bundle.py` | a708c83 product tree | exit 0; build is not new Profile installation proof |

An initial overly broad `ruff check .` included historical runtime-patch scripts
and reported 10 pre-existing lint errors (exit 1). Those files were not changed;
the actual product/test/probe scope passes. Two initial reproduction fixture
setup mistakes (registration payload/status) were corrected before b0d9d41's
recorded two-query baseline run; they are not product failures.

Reproduce R3 from repository root, with the existing fixed installations:

```bash
BB_PRODUCT_CASES=gap uv run --project server --locked python dsh-plugin/probes/journal/live.py \
  --product --runtime "$DSH_PACKAGE" --dart "$DART_EXECUTABLE" \
  --crypto "$CRYPTO_PACKAGE" --output "$ISOLATED_EVIDENCE"
```

The harness owns/stops its child processes and checks eight external file
hashes before/after. All recorded runs kept those hashes unchanged. Stock DSH
0.2.1-rc.5 / Cordis 4.0.5 / Node 26.8.2; the model is a deterministic test double.
Evidence attachment includes sanitized results/source hashes and test logs, never
binding files, owner keys, account credentials, databases or raw native content.

Handoff / not claimed
---------------------

Muse should wire the exact shared Profile contract from client `79b0a57`, remove
old `/profile/*`, and align removed migration fields and deleted schema snapshots.
Orion then integrates both independent branches and reruns R3 plus real six-tool
Profile/media, rejected old routes, wrong owner and in-flight identity/binding
changes. The new Profile routes do not yet exist in this branch's baseline client;
no real protected Profile PASS, integrated Flutter result, final CI or Sentinel
PASS is claimed here. The earlier 45f4f48 installation result is not extrapolated
to the new Profile protocol. The old 18/6 matrix totals are historical, not the
post-removal acceptance count.

Earlier real two-image/provider evidence at 19:23 is retained for unchanged
ordered chat media, not relabeled as a new run. Windows/Android runtime and the
two golden checks remain their previously recorded limitations. Status remains
in_progress; no main merge, release, deployment or personal data cleanup.
