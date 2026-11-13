## Stage B implementation boundary

Implements issue revision 2, execution specification v1 and the B/C recovery addendum. Forge owns all shared state and CI; Muse’s UI is incorporated unchanged from Orion’s `ac2643dd9048466a99291a10b409d8e4bbf55e96`. The management wire contract is `server/contract/admin-openapi.json` (1.1.0); identity/session rules remain in `dea469-admin-v1.md`.

Stage B delivers executable orchestration, fixed Arch/Windows helpers, durable recovery, SSE and product static mounting. It does **not** establish real Cloudflare, privileged Arch installation or Windows service acceptance. No personal credentials, services or production data were used. Independent QA follows Orion’s integration.

## Running the product

Use the locked server environment and ordinary user described in `server/README.md`. Build `admin-ui/` with `npm ci --no-audit --no-fund` and `npm run build`. Start both `bb-server` and `bb-admin` with the same absolute business database path and business port, but a different management database and port. Open `/admin/` on the literal management origin `http://127.0.0.1:<BB_ADMIN_PORT>`.

`BB_ADMIN_UI_DIRECTORY` optionally selects an absolute local build directory at startup. Default is repository `admin-ui/dist`. Static files are limited to `/admin/assets/`; other non-API navigation serves `index.html`. Resolved paths must remain inside the configured directory. `/admin/api/*` never falls back to HTML. No CORS or CSP relaxation, browser interception, or separate static test wrapper is needed.

Only `http://127.0.0.1:<BB_PORT>` is a Tunnel origin. No browser field chooses a target, executable, helper, path or command. The business application adds only `/.well-known/bb-instance/<random UUID>`; all management routes remain absent there. The business database’s sibling `<database>.public-challenges` holds private one-minute proofs shared by the two ordinary-user processes. No proof appears in OpenAPI or contains internal identity data.

## State transitions and recovery

The management database keeps identity schema 1 and adds independently versioned `public_schema=1`. Migration is atomic and never resets identity. A persisted random instance UUID identifies this installation. Draft version starts at 0; saving increments it and invalidates old probes/plans. Active configuration changes only with successful public/current-instance verification. Save during an executing task returns 409.

Probe → immutable plan → explicit confirmed execution is the only external write path. Planning and canceling a dialog have no external effects. Plans bind version, digest, domain, business target, action, observed scope/resources and expiry. Admission checks session/CSRF again in the same transaction as state writes. Invalid/stale/expired confirmation returns 409. Changed external prerequisites discovered later fail the admitted task before new writes.

One database partial unique index admits at most one nonterminal task. Per-plan uniqueness plus durable UUID idempotency keys make both repeated keys and a new key for the same confirmed plan return the existing task. Fingerprints exclude credentials. The worker holds a nonblocking OS file lock for its entire lifetime, uses one execution thread and retains tasks across process restart. No lease expiration can overlap a still-running owner.

For each external write, `public_effects` commits `prepared` intent, then `sent` before sending, then queries the actual resource before committing `done`. The order is Tunnel → remote ingress → DNS → fixed local service → instance proof → active configuration. Local package installation is a separate confirmed plan followed by another probe. Snapshot and monotonically increasing event sequence commit together. Resources identify `created_by_task`, `reused` or unknown ownership; partial outcomes stay visible.

Recovery uses the original plan and task, queries actual resources first, and never infers absence from an unreadable/unauthorized request. Deterministic Tunnel names alone do not prove ownership: the API runtime token must match this task’s private creation secret. DNS must match the dedicated proxied CNAME; a task comment identifies creation ownership. Existing foreign or changed resources stop automatic writes. Already verified own routes can be reused without service re-registration or reinstallation.

If a `sent` creation is still absent or its outcome cannot be established, the task remains `awaiting_authorization`/unknown. Resupply permits another reconciliation query, **not another creation**. This conservative boundary can require an operator to resolve the unknown outcome; v1 has no abandon/reset/cleanup endpoint. It does not promise automatic progress after every ambiguous external failure. Failed terminal tasks can be followed by a new read-only probe, plan and explicit confirmation. No resource deletion or automatic rollback is implemented; keep unknown/reused resources intact and obtain separate operator authorization before any manual cleanup.

QA correction after candidate `3d21ce4`: malformed successful replies are also unknown outcomes. Missing/invalid Tunnel or DNS IDs, malformed envelopes and unreadable nested inventory/configuration replies now raise sanitized authorization/reconciliation waits, including through the real HTTP parser. A local parsing exception is not proof that a previously sent operation failed.

`PublicStore._emit` is the common terminal-write barrier: while any effect for the task remains `sent`, an attempted terminal snapshot becomes `unknown/awaiting_authorization` for cloud effects or `unknown/awaiting_local_admin` for package/service effects. It retains the single-target task lock, confirmed plan and event history. `activate` separately rejects unresolved effects in the same transaction before changing active configuration. Thus generic worker exceptions and later conflicts cannot release an uncertain task for a fresh probe/creation. The worker clears credentials based on the committed state under the same mutex as authorization resupply, avoiding automatic retry loops. No DTO, route, schema migration or frontend changes are required.

The original Sentinel regression is retained in `test_public_qa_unknown.py` with identical function AST/assertions (format/import order only). `test_public_effect_recovery.py` covers malformed Tunnel/DNS write responses, ingress response envelopes, every caught unexpected cloud exception family, package/service failures after the effect, malformed reconciliation reads, same-plan concurrent admission, blocked fresh probes/draft changes and cold restart/resupply. Real Cloudflare parsers, SQLite and the executor participate; only external operations are substitutes. All five effect types also exercise the shared store barrier and activation rejection in `test_public_store.py`. These tests do not claim real cloud or elevated OS acceptance.

Management API credentials are memory-only, expire after 900 seconds and disappear on shutdown or an authorization failure. The probe’s authorized token can be used by its immediately confirmed execution within this window. Refresh first reads session and `/tasks/current`. `POST /tasks/{task_id}/authorization` takes required write-only `management_token` (1–4096 characters), returns 202 with the same task, and rejects missing/terminal/not-awaiting/stale-target tasks with 404/409. Concurrent resupply cannot create a second executor. This endpoint does not re-confirm a changed plan.

SSE returns full sanitized task snapshots with `id: seq`, `event: task`. Header `Last-Event-ID` takes precedence over query `after_seq`; invalid/future cursors return 422/409. Events replay in order, without pruning. Session validity is checked before each data event; logout/password rotation closes old streams. Heartbeats do not change sequence. Closing the browser does not cancel an execution.

## Cloud and instance boundaries

Only a user-supplied dedicated Cloudflare API Token is used: Zone Read and DNS Edit for the intended zone, Cloudflare Tunnel Edit for its account. Listing proves read access; Cloudflare still enforces write permissions at execution. DNS resolution and risk confirmation never establish account ownership. The fixed HTTPS API client ignores ambient proxy variables, validates TLS, rejects redirects, bounds replies, paginates inventory and suppresses raw error/body output. No `cert.pem`, other applications’ credentials or personal cloudflared configuration is read.

Probe reports installation, service, authorization, connection, route and instance separately. Missing, stopped, unreadable, unauthorized and unsupported are distinct. Token mode requires no `cert.pem`. Locally managed routes are recognized and left intact; this implementation does not migrate them or treat their mode as proof that their runtime is unavailable. Existing unowned tunnels/DNS are conflicts, not adoption candidates.

Instance verification compares a short-lived random proof from the current local business process and the exact public HTTPS hostname. Every resolved address must be globally routable. The TLS socket connects to a validated numeric IP while retaining the original hostname for TLS/SNI, preventing a second DNS lookup/rebinding. Redirects, private/mixed answers, cacheable replies, wrong proofs, oversize replies, ordinary 200, timeouts and expired challenges fail. Proof files are removed in `finally`; stale files are not served after expiry.

## Fixed local helpers

BB stays unprivileged. The installed helper must byte-match the helper shipped with this candidate and reside in an administrator-controlled path. The only operations are `install` and `connect`, with validated task/instance UUIDs and optional runtime token. There is no frontend command/path/target field. Tokens travel through private request files or stdin, never process arguments. Subprocess errors/output are not returned verbatim.

Arch x64 uses `/usr/bin/pacman -S --needed --noconfirm extra/cloudflared` only when `/usr/bin/cloudflared` is absent; it does not refresh repositories, upgrade or reinstall an existing binary. The root-owned standalone helper belongs at `/usr/local/libexec/bb-public-helper` (0755; parents root-owned and not group/world writable). A local administrator may install the reviewed candidate with:

```bash
sudo install -o root -g root -m 0755 server/src/bb_server/helpers/arch.py /usr/local/libexec/bb-public-helper
```

This command is an operator instruction, not an action performed in development evidence. Desktop execution uses `pkexec /usr/bin/python3 -I` with JSON stdin after plan confirmation. Headless/unavailable elevation returns `awaiting_local_admin`. The saved request is `<BB_ADMIN_DATABASE_PATH>.private/<task_id>.request` (0600 inside 0700). After checking it belongs to the current task, the local administrator can execute that exact request through the installed helper; do not print or paste its token:

```bash
sudo /usr/bin/python3 -I /usr/local/libexec/bb-public-helper < /absolute/private/task-uuid.request
```

The helper locks its own `/var/lib/bb-public`, verifies immutable ownership/content and registers only `bb-cloudflared-<instance UUID>.service`. Systemd `DynamicUser`, `LoadCredential`, private filesystem restrictions and a token-file argument keep BB unelevated and secrets out of argv. Existing conflicting units/tokens are refused. The worker does not repeatedly prompt; it polls the fixed service and resumes the original task after an administrator completes the saved operation.

Windows x64 uses the reviewed helper at `C:\Program Files\BB\bb-public-helper.ps1`, installed by a local administrator with protected ACLs. It must match `server/src/bb_server/helpers/windows.ps1`; the ordinary-user process verifies hash, reparse-point restrictions and write ACLs of helper and parent paths before UAC. Headless sessions explicitly await a local administrator. Run the installed helper with `-RequestFile` pointing to the private saved request; the token itself is never an argument. User private directory ACLs are constrained to the current SID, Administrators and SYSTEM, including rejecting unrelated explicit allow entries.

The helper downloads only official `cloudflare/cloudflared` release **2026.11.0**, `cloudflared-windows-amd64.exe`, SHA-256 `d5c1d82031da6253dcdcff64c944cd0fe063016edeb2e4fd088075fc9bd52d0a`. Hash checking precedes installation. Existing mismatched binaries are refused, not upgraded. Runtime secrets are in protected `C:\ProgramData\BB-Public\<instance UUID>` with LocalService read access. A nonsecret ownership receipt precedes any reading of the owned service command line; third-party service arguments/credentials are not inspected. The fixed `Cloudflared` service uses `NT AUTHORITY\LocalService`, the owned binary and token file; an existing foreign service is refused. Windows UAC, installation and service lifecycle still require real Windows validation.

Back up the stopped management database **and** its private runtime-secret directory together with their permissions. Do not restore an old ownership database onto independently changed cloud/service resources. Credentials, private requests, databases and raw process logs are excluded from CI artifact upload.

## Complete B write-entry inventory

Identity writes and their existing tests remain in `dea469-admin-v1.md`. No import, scheduler, hidden CLI writer, browser-owned truth or helper callback mutates the shared database.

| Entry / shared implementation | Writes | Verification |
| --- | --- | --- |
| lifespan → `PublicStore.migrate` | tables + instance identity in one transaction | migration/restart and schema rejection; no business DB changes |
| PUT config → `save` | version/domain; old probe terminal event | store CAS/concurrency; API live-session guard |
| POST probes/executions → `admit` | task/context, key fingerprint, initial event, per-plan mapping | repeated/concurrent keys, changed payload, one target, stale/expired plan |
| POST plans → `plan` | immutable plan/context, digest, expiry | cancel/no effects, old version refusal; actual browser dialog |
| POST authorization → `authorize` | existing task event + memory token | concurrent resupply, 404/409, revoked session, changed business target |
| worker → `publish` / `_emit` | snapshot/context/terminal + ordered event together | failure/cold restart/event sequence; HTTP SSE replay |
| worker → `effect` / `mark_effect` | prepared/sent/done + sanitized intent/outcome | lost responses at Tunnel, ingress, DNS, service; query before retry |
| worker → `activate` | active config + verified terminal event | wrong-proof failure never activates; successful current proof required |
| runtime `credential`, `start`, `close` | memory TTL/clear; OS lock | lost credentials and duplicate executor tests; no token in DB/events |
| `SecretFiles.secret/request` | exclusive private secret/request files | ownership/modes/path validation, changed request conflict; Windows ACL subprocess failure simulations |
| Cloudflare adapter | only confirmed Tunnel POST, own ingress PUT, DNS POST | fixed API/pagination/sanitized failures plus effect substitutes; real cloud NOT RUN |
| Arch/Windows helper | package, owned receipt/token, own service | strict input/private files/fixed command assertions; Windows executable CI tests pending; real privileged lifecycle NOT RUN |
| `InstanceVerifier.verify` | temporary proof create/finally delete | actual business proof route; timeout/cache/redirect/SSRF/wrongproof tests |

The worker and helper each own a separate lock because they protect different resources: one management database versus machine service files. Helpers never receive a management API token or edit the management database. Worker reconciliation is the sole bridge back to shared state.

## Acceptance evidence and limits

| Issue acceptance | Stage B check | Scope limit |
| --- | --- | --- |
| 3 | actual Arch CLI read-only probe and six-result SSE; missing/denied/local/token modes in tests | no authorized real cloud inventory |
| 4 | actual Vue/product-server confirmation cancel; version/expiry regressions | external side effects counted with substitutes |
| 5 | DNS/route/ownership conflicts before and after plan | synthetic cloud inventory |
| 6 | real SQLite concurrency/idempotency, native EventSource replay/refresh | external effects counted with substitutes |
| 7 | each cloud/service response-loss boundary, cold executor recreation/resupply, no duplicate effects | no process-kill against real cloud/OS; unknown absent outcome remains pending |
| 8 | real business challenge route; numeric-IP TLS implementation and rejection regressions | public HTTPS transport cases controlled; real public domain NOT RUN |
| 9 | Arch unprivileged helper validation; official Windows EXE download/hash checked; Windows CI executable tests wired | actual Arch elevation and all Windows UAC/install/service acceptance NOT RUN |
| 10 overlap | production Vue served by product app: native local probe plus full backend with external substitutes | no browser route stubs; substitute scenario is not real cloud acceptance |
| 11 | existing business/server suite, Vue build/type/test, product browser probe and Windows helper job | CI run results belong to Orion’s PR; local checks are development evidence |

Reproduce from repository root:

```bash
uv run --project server --locked ruff check server/src server/tests server/contract/src/bb_auth_contract/admin.py server/probes/public_browser_fixture.py server/platform-tests/windows_helper.py
uv run --project server --locked pytest server/tests -q --junitxml=server/.evidence/dea469-b-server.xml
npm --prefix admin-ui run typecheck
npm --prefix admin-ui test -- --reporter=default --reporter=junit --outputFile=.evidence/dea469-b-unit.xml
npm --prefix admin-ui run build
node server/probes/public_browser.mjs
```

The browser probe requires Playwright Chromium installed by the UI tooling. `native-cli` starts real `bb-admin`, isolated DBs and local read-only inspection. `external-fixtures` starts the product app/runtime with only cloud, installer and public-instance verifier replaced; routes, auth, SQLite, SSE, static mount and Vue remain real. The probe verifies exact one-each external effect counts and shuts down its own processes. Screenshots/results are safe artifacts; runtime DB/private files are not deliverables. CI installs uv and the locked Python environment before the UI DTO regression, preserving assertions that the old non-UUID key fails and the corrected key passes.

Windows-only validation command: `uv run --project server --locked pytest server/platform-tests/windows_helper.py -q`. It actually executes PowerShell helper parsing with `-ValidateOnly` and never installs/registers a service. It is intentionally outside the Linux pytest collection, not silently skipped or reported as locally passed.
