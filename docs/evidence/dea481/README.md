# DEA-481 server milestone evidence

Run `01a1e14c-2b6a-77aa-bae3-01655ad7e799`, Forge, Linux.
Dedicated checkout `dea-481-01655ad7e799/workdir/BB`, branch
`agent/forge/dea-481-integration`, fixed base
`573f3877cb8497d9df4720be3c13eee089ff9642`.
Product specification: Orion's revision 1; full approved body captured at issue
record revision 3 in `docs/design/dea481-approved-space.md`.

The initial contract commit is `2af41742d9cb096304cf8c4ee25c4296e0c17001`.
The complete frozen server/local wire contract and implemented server candidate
is **`d402ba8cecdfdbfb421eef23165483b24f3bd1a3`**. It additionally includes explicit
`get_image`, so a local/MCP adapter can obtain actual bytes without arbitrary URL
fetching. Use this candidate's `server/contract/space-v1.json` for integration.
Documentation/evidence-only descendants reuse the identical server tree.

## Actual execution and limits

`results.json` records source/tree/lock hashes, exact commands, exit codes, JUnit
counts and log hashes. `server.log`/`server.xml` are the existing full server
pytest entry on the fixed candidate; `ruff.log` is the existing lint entry plus
the new contract module/exporter. `targeted.log`/`targeted.xml` are the focused
57-test check immediately before the candidate commit; source bytes are the
same. No skip is silently treated as a pass.

`test_space_live.py` starts the actual `python -m bb_server` entry on a private
ephemeral TCP listener with a temporary SQLite DB, synthetic accounts and media.
It stops/restarts the process and verifies operation reconciliation, durable
events, visits, byte-identical image access, thumbnails, logical deletion and
logout. Both live tests use the shared request and response DTOs. The remaining
state tests use real SQLite/files via FastAPI TestClient; their controlled SQL
failure triggers and thread barriers are fault injection, not a second business
implementation. They do not certify any client/native/plugin host behavior.

`environment.json` records the actual interpreter/OS/lock and network probe.
Installed commands: uv 0.12.10, Python 3.13.15, Dart 3.13.7, DSH 0.2.1-rc.5,
adb 37.0.0; Flutter command is present. No dependency/lock was changed. The locked
server has neither websockets nor wsproto; an actual WebSocket upgrade returned
404. ASGI WebSocket replay was tested separately. Authoritative HTTP event replay
is operational, matching the existing client's account-wide poll + optional
socket-hint pattern. Network push is not claimed as tested or available.

NOT RUN: standalone Dart space adapters, rendered Flutter UI, existing DSH plugin
space tools/install/settings/lifecycle, real visual model, Windows, Android and
foldable device/simulator checks, screenshots and test packages. These belong to
the next allocated integration work. No model credentials or private profile
were read. No production DB, main merge, deployment or release was performed.

## Confirmed counterexamples retained

`regression-before.log` and `.xml` are real failures against implementation
`ebfeb86b5bb41a890b2fca87e874d07be767349e` (exit 1, two failures).
The fixture's representation deliberately omits synthetic bearer credentials;
logs, not private service DB/config/session files, are delivered.

| Root cause | Failing assertion | Common correction and regression |
| --- | --- | --- |
| SPACE-PAGING-SAME-TIME | A newly published same-timestamp row below the saved anchor entered the old page | All list_posts queries retain the first page's publication sequence ceiling in the opaque cursor; `test_t03_equal_timestamp_new_post_is_excluded_until_refresh` |
| SPACE-LIKE-DELETED-TARGET | Deleting a post removed active likes, so its old aggregate disappeared instead of rendering deleted | Notification list and overview share the same visibility predicate, retaining tombstoned targets without actors/body; `test_t06_t07_reposts_delete_scrub_media_and_shared_blob` |

Both failures are fixed without weakening their assertions in the candidate.
No product-semantic exception or dependency change was used.

## Write and invalidation coverage

| Entry | Evidence |
| --- | --- |
| draft create/read/list/update/reorder/remove/add/publish | T01 ten-image test; T02 CAS and eight concurrent publish retries; edit/publish competition |
| draft deletion and upload crash gap | `test_draft_delete_and_uncommitted_upload_recovery`: operation-trigger rollback leaves no visible image; restart collects orphan; same logical ID can then commit |
| post deletion, source invalidation, protected media/thumbnail | T06/T07 both direct and repost targets; shared space blob retained by a separate draft; TCP image test after restart |
| comment create/reply/delete, parent placeholders and context | T04/T05/T08 plus actual concurrent delete/write cases |
| likes and notification create/ack | T11 desired-state no-op, active membership, first-like version, old acknowledgement versus new liker, no self notifications |
| reads and visits | T09/T10 sparse marks, dedup visits, author-only visitor page, new-comment independence |
| reliable events + operation receipt | SQL event failure rolls post/notification/receipt back; TCP cold restart resolves original receipt; HTTP/ASGI replay agrees |
| garbage collection on delete, startup, maintenance | deletion cleanup failure retains queue, startup retries; periodic maintenance calls the identical tested collect implementation, without a separate cleanup algorithm |
| authorization at transaction admission | session rechecked inside DB transaction; unauthenticated HTTP actions, cross-author draft/delete/visitor restrictions and real logout rejection |

Remaining acceptance ownership and full T01–T17 sources are in
`docs/design/dea481-acceptance.md`. T01–T12 here are server portions only; a pass
does not imply the corresponding three-client/DSH case is complete. Orion owns
next allocation and the later fixed full-candidate QA handoff; Forge remains the
sole integrator of this branch. DEA-480/client/plugin/shared-CI files are untouched.
