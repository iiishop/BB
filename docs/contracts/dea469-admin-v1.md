## Scope and version

DEA-469 execution specification v1, stage A, based on `58c748a8254d4f1c7ed5cd5d0cce5962b1696db9`. Forge owns management identity and all configuration/task persistence. Orion owns integration; Muse consumes this contract. No business, client or DSH identity changes.

The machine-readable contract is `server/contract/admin-openapi.json`, generated from the pure DTOs in `server/contract/src/bb_auth_contract/admin.py` and the management routes in `server/src/bb_server/admin.py`. Do not hand-edit the JSON or create separate frontend wire definitions with different semantics. The snapshot test detects drift. Export with:

```bash
uv run --project server --locked python -m bb_server.export_admin_openapi server/contract/admin-openapi.json
```

Each operation has `x-implementation-stage`. **A is implemented. B is reserved and returns `501 stage_b_not_implemented` after authentication/initialization checks.** B response schemas describe the next phase, not evidence of implemented orchestration. The business OpenAPI remains unchanged.

## Listener and identity boundary (A)

`bb-server` remains the business API. `bb-admin` is a separate executable/ASGI app and database, bound exclusively to literal `127.0.0.1` at `BB_ADMIN_PORT`. The required `BB_DATABASE_PATH` and `BB_PORT` are checked against the management path/port, including existing hardlinks. The management app is never mounted on the business app; business requests for `/admin` or `/admin/api/*` return 404 even with loopback/forwarding headers. No management UI is shipped in A. Muse must serve the Vue build on this management origin, without mounting it on the business origin. The browser API base is relative `/admin/api`; development cross-origin CORS is deliberately not enabled.

Only the business listener is an eligible Tunnel target in B. The browser cannot submit a listener/command/target URL. Local source address alone is not authorization. The management boundary also requires exact Host `127.0.0.1:<BB_ADMIN_PORT>`, rejects Forwarded, all X-Forwarded-* and CF-* headers, and rejects remote socket peers. Proxy header processing is disabled in the management CLI. A local reverse proxy, `localhost` alias, remote SSH/browser origin, or externally published management port is not a supported management deployment. An OS user/process able to impersonate direct local HTTP clients or read the private database is outside this HTTP boundary; this is not OS account authentication.

New management database initialization is transactional. It creates exactly one `admin` identity with an Argon2id hash of the initial password `admin`; it does not create a BB account. `must_change_password=true` allows only session inspection, logout and password change. All other management API routes refuse with 403 before parsing their bodies. Password change requires the old password and a new password of 12–1024 characters, preserves whitespace, forbids the same password, commits the hash/initialization flag/epoch and revocation of **all** sessions in one transaction. No replacement session is issued: Vue must return to login. Cold startup never resets the password or resurrects sessions. There is no reset-password/multi-admin facility.

Session cookie: `bb_admin_session`, host-only, `Path=/admin`, `HttpOnly`, `SameSite=Strict`, maximum age 8 hours. Server storage contains only SHA-256 of the random 256-bit bearer; a separate random CSRF value is returned by login/session and stored in the session row. The bearer is never in a response body. `Secure` is not set because the supported listener is strictly local HTTP; this cookie configuration must never be reused for an external HTTP listener. Use `credentials: 'same-origin'`; do not persist bearer/CSRF values in localStorage. On refresh call `GET /admin/api/session` to obtain current state and CSRF. Closing a browser is not a server-side revocation guarantee; logout and expiry are.

Every mutation (including login) requires JSON, exact `Origin: http://127.0.0.1:<port>` and `X-BB-Admin: 1`; authenticated mutations also require `X-CSRF-Token` from session. Missing/mismatched origin, cross-origin/same-site-but-other-origin Fetch Metadata, foreign Host and forwarding headers fail closed. No CORS headers are emitted. Session reads/event streams may omit Origin, but a supplied Origin must match; cookie and host/peer rules still apply. Responses use no-store, nosniff, frame denial and a self-only CSP. The future Vue build must not require inline scripts/styles or external CDN resources. API request bodies are bounded to 16 KiB before JSON decoding; validation never echoes input values or unknown field names.

Login and password verification share a persistent, single-account budget: at most five admitted attempts per 60-second fixed window, including successful attempts. Reservations commit before expensive verification; invalid credentials and crashes still consume an attempt. All usernames share this budget. It is intentionally conservative for one local administrator; 429 carries `Retry-After: 60`. Logout/session reads do not spend attempts. Hash verification happens outside the writer lock; login/password updates recheck identity epoch/session inside their final transaction so a concurrent password change cannot create a session with the old password.

The database has its own application id and schema version 1, distinct from business schema version 3. An existing business/unknown/newer database is rejected, not migrated. On POSIX new management directories/files use 0700/0600; existing files with group/other permission are rejected. Existing parent directories and Windows user-directory ACLs must be protected by the operator. No external credential is persisted in A. Back up this management database separately while stopped; treat it as sensitive, and remember restoring an old backup restores that backup's password/session state. Do not use the business backup/restore as a password reset mechanism.

Implementation references: [Uvicorn proxy settings](https://uvicorn.dev/settings/), [Starlette cookie response options](https://starlette.dev/responses/). The disabled proxy trust and cookie flags are explicit choices above, verified against the locked local packages.

## Endpoints and errors

All paths below are under `/admin/api`; exact field types are in the snapshot.

| Stage | Method/path | Behavior |
| --- | --- | --- |
| A | POST `/login` | `{username,password}` → session/CSRF and cookie; no previous session required |
| A | GET `/session` | session/CSRF, `must_change_password`, absolute Unix `expires_at` |
| A | POST `/password` | `{old_password,new_password}` → 204; revoke all sessions and clear cookie |
| A | POST `/logout` | JSON `{}` → 204; revoke current session and clear cookie |
| B | GET / PUT `/public-config` | read/save domain draft with `expected_version`; response keeps `active` separate |
| B | POST `/probes` | read-only probe, `expected_version`, UUID `idempotency_key`, optional write-only management token → 202 task |
| B | POST `/plans` | version, completed `probe_task_id`, allowed action → 201 immutable confirmation plan |
| B | POST `/executions` | exact plan id/digest/version, UUID idempotency key, `confirmed=true`, optional write-only management token → 202 task |
| B | GET `/tasks/current` | `{task: AdminTask or null}` for current/latest task, including terminal result |
| B | GET `/tasks/{task_id}` | durable task snapshot |
| B | GET `/tasks/{task_id}/events?after_seq=N` | same-origin cookie-authenticated SSE, specified below |

Common error envelope remains `{error:{code,message,fields:[]}}`. Unauthenticated/expired/revoked or ordinary BB bearer/cookie: 401. Initial password restriction, old password failure, CSRF/source/cross-origin: 403 with distinct codes. Draft/plan/idempotency conflicts: 409 (B). Missing task: 404 (B). Invalid fields/domain: 422. Oversized body: 413. Non-JSON mutation: 415. Budget: 429. Storage: 503 (`storage_busy`, `storage_io_error`, `storage_unavailable`) with `Retry-After: 1`. B reserved operations: 501. Browser navigation/unknown non-API paths can be 404 in A. Login is the sole unauthenticated API exception; it never accepts a BB identity.

## State and recovery contract for B

This section is a required implementation contract for Forge's next phase. **None of these external operations or recovery behaviors are implemented/claimed PASS by A.** Muse may build against these shapes after Orion accepts the phase contract.

The singleton configuration starts at version 0 with null draft and null active configuration. `PUT public-config` compares `expected_version` inside a write transaction, updates the normalized dedicated ASCII subdomain, increments version and invalidates outstanding plans. Domain field validation rejects URL syntax, IP literals, ports, wildcards and malformed labels. This syntax validator is not SSRF protection: B additionally resolves/rechecks addresses, rejects non-public ranges/redirects/rebinding and verifies the current instance using a random short-lived non-cacheable challenge. Saving a draft does not change `active`. Only successful instance verification can commit active domain/tunnel/instance/verified timestamp. Saving while an external execute task owns the singleton target returns 409; a superseded read-only probe cannot publish a valid plan.

`POST probes` may read fixed executable/version/service status and explicitly authorized cloud resources. No installation, service registration/start, DNS/Tunnel creation/deletion or personal credential discovery is permitted. Installation, service, connection, authorization, route and instance checks are separate typed results. Classification is `passed`, `failed`, `unknown`, `not_applicable` or pending/running. Unreadable/unauthorized is `unknown`, not missing. Token runtime mode does not require cert.pem. DNS resolution alone cannot grant account authority. `allowed_actions` determines the single capsule's action, not a frontend inference from HTTP 200.

One current nonterminal task per target, enforced transactionally in the management database; this includes probes. Duplicate identical UUID idempotency keys return the same task, even after completion. Reusing a key for different kind/target/version/plan returns 409. Execution uniqueness also attaches to the confirmed plan: repeated execution of the same plan with a new key returns its existing task rather than creating another resource set. A running task for a different request returns 409 and a stable error code so the caller fetches `/tasks/current`. Request fingerprints exclude the secret itself; refreshed authorization may resume the same task's recovery without changing the confirmed plan. Idempotency history must survive restart and not be pruned while a client can replay the associated plan/task.

An immutable plan binds `plan_id`, digest, config version, normalized domain, server-selected business target, allowed action, expiry, concrete resource create/reuse intents, public scope and risks. The confirmation dialog renders these fields. Canceling it sends no execution request and has no external effect. Changed domain/version, changed observed prerequisites or expired plan invalidates execution with 409; re-probe/re-plan/re-confirm is required. No arbitrary frontend command/path/service origin is accepted. `confirmed=true` confirms only this exact plan, not account ownership, token scope, sudo/UAC or future modifications.

Management API token input is write-only, submitted only to the local management origin, never returned, included in plan digests, persisted in the task/event body, argv, logs or raw command output. It is distinct from a Tunnel runtime token. B must restrict runtime-secret storage to private files/ACLs and keep only references in task state. In-memory management authorization is lost on restart: expose `awaiting_authorization` and resume the same task after explicit resupply. Do not read another application's credentials or infer cloud permission from a risk confirmation. Authorization and system elevation remain independently necessary.

Every external side-effect step uses this write order: (1) transactionally record owned task, expected config/plan, resource intent and durable event; (2) perform one fixed external operation outside the SQLite transaction; (3) reconcile the actual resource identity and transactionally record outcome/ownership + next event. A crash/timeout after intent and before a known result becomes `reconciling`/`unknown`; do not blindly replay creation. On restart claim/lease the existing task, query resources first (or await authorization), then resume or explain uncertainty. Record `created_by_task`, `reused` or `unknown` for each resource. Conflict with existing third-party Tunnel/DNS stops without overwrite. Cleanup is allowed only for resources proven created by this task and not subsequently used elsewhere; response loss is not proof of ownership. Resource ids/names in public state must be sanitized and contain no tokens.

`AdminTask` is the complete sanitized UI snapshot: `task_id`, monotonically increasing durable `seq`, config version, kind, stage, classification, issue code, allowed actions, confirmation need, typed check results, resource ownership and message. Stage and classification are independent (e.g. `awaiting_authorization/unknown`, `finished/failed` with partial resources). Process exit, connected service, HTTP 200 or canceled browser wait is not successful instance validation. Failure remains visible with partial success and a repair/reconciliation action. The UI owns no task truth and never recreates a task solely because its request/stream disconnected.

SSE events use `id: <seq>`, `event: task`, `data: <AdminTask JSON>`; data is the same full snapshot as GET. Allocate sequence and event in the same transaction as state. Reconnect uses the last applied sequence (`Last-Event-ID` on automatic reconnect; explicit `after_seq` on new EventSource). If both exist, the header takes precedence; invalid/negative/future cursors are 422/409. Replay events strictly after the cursor, in order; clients ignore duplicated/older sequence. No event pruning in v1. Heartbeats are SSE comments and never advance sequence. Stream start requires the same cookie/initialization guard; ongoing streams must recheck session expiry/revocation before each data delivery and close on revocation. Terminal snapshot is delivered before close. Refresh starts with session and `/tasks/current`, then subscribes using its sequence. Closing the stream or confirmation window never rolls back an executing task. No cancel-execution endpoint is promised.

## Complete management write inventory and ownership

All entries are Forge-owned. Vue only calls the contract; no browser persistence is authoritative. All A writes use the existing bounded `connection(..., write=True)` transaction helper. The business migration and users/sessions remain unchanged.

| Entry | Writes / shared commit point | A verification or B obligation |
| --- | --- | --- |
| `bb-admin` lifespan / `AdminStore.migrate` | new schema, singleton initial hash, epoch, attempts; no reinitialization on restart | new/failed/retried/newer/business-db rejection, private file, real restart |
| login + password / `_reserve_attempt` | shared persistent attempt budget; commit even when verification fails | restart, shared budget, 8 concurrent attempts capped to 5 |
| login / final transaction | recheck epoch; delete expired sessions; insert hashed token + CSRF + expiry | stale-login race, failed insert, no cookie before commit |
| password / final transaction | recheck live session/epoch; hash + flag + epoch + delete ALL sessions atomically | two concurrent rotations, delete failure rollback, retry, cold startup |
| logout / final transaction | recheck live session + CSRF; delete current token digest | revoked token cannot be reused; real CLI logout |
| session/guards | **read only**, expiry predicate; no heartbeat or separate session writer | expiry boundary and every API rejects BB identity |
| B draft save | singleton config compare-and-swap, plan invalidation | pending; no writes in A placeholders |
| B probe admission/result | task/idempotency admission; snapshot + event sequence | pending; probe results can only plan for same version |
| B plan create/expire | immutable plan/version/digest/expiry | pending; shared config/task transaction boundary |
| B execute admission/retry | consume exact confirmation, one task per plan/target, key replay mapping | pending; concurrent double-click and reconnect |
| B worker install/service/Tunnel/DNS/verification | durable intent → external effect → reconciled resource + event; active config only on verified match | pending; every crash/response-loss cut must be covered |
| B startup recovery / authorization resume | lease existing task, unknown result reconciliation, no fresh duplicate task | pending; failure→restart→resupply→retry regression |
| B authorized cleanup | verify task ownership and current lack of other uses, record removal outcome | pending; never delete reused/unknown resource |

A has no scheduler, cloud worker, configuration import, admin CLI reset command or hidden second identity writer. B must extend this table whenever it adds another ingress (including service/helper callbacks), use the same shared commit points and test each ingress or explicitly identify its shared tested implementation.

## Validation and remaining environments

`server/tests/test_admin_http.py` starts the installed `bb-server` and `bb-admin` CLI entrypoints on two temporary loopback ports with isolated DB/avatar/media paths. It verifies initial password restriction, forwarding rejection, business-port management isolation, password/session revocation, process restart, logout and an unchanged business register/login/session path. This is actual HTTP/process evidence, not a Cloudflare Tunnel test.

`server/tests/test_admin.py` verifies the matrix, CSRF/source/Host/JSON boundaries, hash/cookie confidentiality, rate limiting, expiry, deterministic concurrency interleavings, failed transaction recovery, schema/contract drift and domain syntax. Concurrency hooks pause real Argon2 computations; no production dependency is patched. Existing CI already runs all server tests and `ruff check src tests`; no extra runner is needed for A.

Current environment: Arch x86_64, uv-managed locked Python environment. Windows real device, Windows UAC/service lifecycle, actual Arch installation/elevation, Cloudflare account/DNS/Tunnel effects and Vue browser flows are NOT RUN in A. No dedicated cloud credentials/resource scope or system-install permission is available. Stage B/C and independent QA remain necessary. No main merge, production deployment, system package install or issue Done is authorized by this phase.
