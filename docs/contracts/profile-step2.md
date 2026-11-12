# STEP-2 Profile contract

Authority: DEA-465 and Orion's `DEA-465-spec.md` attachment (2026-11-11).
Base: `325f530f57f0b5e5b35a7cef2376d4919c874c4b`. STEP-1 registration,
login, session DTOs and Argon2id/token hashing remain compatible. No Chat,
Space, Actor redesign, events, WebSocket, or Bot inference is introduced here.
`server/openapi.json` is generated from the implementation;
`server/contract/profile-local-schema.json` describes the local client routes;
`server/contract/profile-cases.json` supplies cross-language validation examples.

## Server HTTP

All routes below require `Authorization: Bearer <current session token>`.
Authenticated accounts may read another account's Profile/avatar. Every write
derives its owner from that session. `/me/*` mutations reject query parameters;
PATCH rejects unknown JSON fields, including `account`/`nickname`. Upload
accepts exactly one multipart part named `file`, no other fields.

| Method/path | Input | Success |
| --- | --- | --- |
| `GET /users/{account}/profile` | account path | 200 Profile |
| `PATCH /me/profile` | `{username?,signature?}` | 200 Profile |
| `POST /me/avatar` | multipart `file` | 200 Avatar |
| `DELETE /me/avatar` | no body | 200 Avatar; returns to identicon |
| `GET /avatars/{account}.png` | optional `If-None-Match` header | 200 PNG / 304 empty |
| `POST /auth/heartbeat` | no body | 200 `{status:"online",last_seen_at:"...Z"}` |
| `POST /auth/logout` | no body | 204 empty |

Profile example (synthetic account; version shown symbolically):

```json
{
  "account": "12345678",
  "username": "Alice",
  "signature": null,
  "avatar_url": "/avatars/12345678.png",
  "avatar_version": "identicon-v1-<sha256(account)>"
}
```

Avatar is `{avatar_url,avatar_version}`. URLs are same-origin relative paths;
versions are opaque strings. `nickname` is UI terminology for `username`, never
a second stored field. Username is trimmed, 3–24 Unicode code points, non-null
when supplied. Signature is trimmed, 0–49 code points; null or trimmed empty
clears it. PATCH omission preserves the field; `{}` is a valid no-op. Count
Unicode code points (Dart `runes.length`), not UTF-16 units or grapheme clusters.

Errors keep `{error:{code,message,fields:[{field,code,message}]}}`:

| HTTP | code | Meaning |
| --- | --- | --- |
| 401 | `unauthenticated` | missing, revoked, or cleaned session; clear client credentials |
| 404 | `not_found` | account does not exist |
| 422 | `validation_error` | invalid shape/type/length or forbidden fields; no mutation |
| 413 | `payload_too_large` | avatar exceeds 5 MiB or multipart exceeds bounded overhead |
| 415 | `unsupported_media_type` | invalid magic/decode/type, or decompression-bomb rejection |
| 503 | `storage_unavailable` | DB/file unavailable; paths and credentials omitted |

STEP-1 login still uses 401 `invalid_credentials`. Client network failures use
502 `upstream_unavailable` / 504 `upstream_timeout`; they do not invalidate a
session. Validators do not echo input values or unknown field names.

## Avatar bytes and caching

- Defaults: SHA-256(account UTF-8), first 15 bits, MSB-first, row-major over left
  3 columns × 5 rows; mirror columns 0/1 into 4/3. Hue = `digest[2]/255` turns,
  HLS lightness = 0.50, saturation = 0.65. RGB channels round to 0–255. Solid
  foreground, transparent `(0,0,0,0)` background. Resize 5×5 to 250×250 by nearest
  neighbor. No default file or per-account default migration.
- Uploads: raw bytes ≤ `5*1024*1024`; extension/MIME ignored. PNG/JPEG/WebP magic
  and actual decoding must both succeed. Output is RGBA PNG, dimensions retained,
  metadata removed; animated sources use first frame. Pillow's built-in
  decompression-bomb warnings/errors are rejected. Multipart has an additional
  64 KiB overhead budget, checked before parsing even without Content-Length.
- Default version = `identicon-v1-` + SHA-256(account); upload version = `sha256-`
  + SHA-256(normalized PNG). Identical normalized content retains its version.
  Nickname/signature edits do not change avatar version.
- GET sends strong `ETag: "<avatar_version>"`, `Cache-Control: private, no-cache`,
  `Vary: Authorization`, `X-Content-Type-Options: nosniff`. If-None-Match supports
  lists, weak comparisons for GET, and `*`. Authentication precedes 304.
- Opening another user's Profile and every MCP `view_avatar` must check the
  server now: reuse cached bytes only on 304, replace on 200. Own successful
  upload/delete invalidates its cache. Local API always returns current base64
  bytes to MCP, including when it revalidated cached bytes with a 304.

Uploads use random server-generated storage keys. A SQLite write transaction
coordinates immutable file creation and pointer changes. Files are synced before
commit (directory sync on POSIX). SQL/file failure rolls back the pointer and
removes the new file; old file removal follows commit. Crash windows or failed
post-commit unlink can leave unreferenced files; the latter logs
`avatar_orphan_cleanup_failed`. Stop writers before offline orphan removal.
Missing referenced files return 503, never a silent identicon fallback. This is
not a claim of atomic commit across the filesystem and SQLite.

## Migration and session lifecycle

Transactional `002_profile.sql` advances user_version to 2. Added user fields:
nullable signature/avatar_path/avatar_version (path/version nullness constrained
together). Added session fields: last_seen_at (UTC epoch seconds), status
(online/offline), offline_since (UTC epoch seconds or null). STEP-1 sessions get
migration time as last_seen_at because STEP-1 never recorded heartbeats. Existing
accounts/password hashes/token hashes stay intact. Repeated migration is a no-op;
failure rolls back; newer schemas refuse startup.

Login starts online. Client sends heartbeat every 30s while signed in. At
`now >= last_seen_at+90`, mark offline with offline_since set to that exact
boundary. Offline is not logout: token remains valid; ordinary API reads do not
refresh last_seen_at. Heartbeat clears offline_since and restores online. Delete
only when `now > offline_since+86400`; exactly 24h offline is still recoverable.
Logout deletes only the calling session, even if that account has others.

Maintenance runs on startup and every `BB_SESSION_MAINTENANCE_SECONDS` (default
5s), without incoming traffic. Rows change on the first tick at/after the 90s
boundary, subject to scheduler/storage availability. Authentication and heartbeat
also apply the same rules transactionally; cleanup/heartbeat cannot revive an
expired token. Startup catches up after downtime. Periodic DB errors log a safe
diagnostic and retry at the next tick. No token refresh or fixed expiry added.

Client: retain credentials after network failure, accumulate missed beats; after
three show reconnect banner and keep retrying. Success clears banner/counter;
401 clears credentials and returns to login. Android timer suspension alone
must not log users out. These client behaviors belong to Muse's `client/` work.

## Six local routes and MCP tools

All local routes: `POST /profile/<tool-name>`, JSON, 200 success. Listener binds
only 127.0.0.1, port configurable. Client owns the session and calls the server;
no token/cookie reaches the plugin. Retain register_account/login_account: eight
MCP tools total.

| Tool | Input | Local response |
| --- | --- | --- |
| `view_avatar` | `{account?}` | `{account,mime_type:"image/png",data:<raw base64>,avatar_version}` |
| `update_avatar` | exactly one of `{path}`, `{url}`, `{base64}` | `{avatar_url,avatar_version}` |
| `view_nickname` | `{account?}` | `{account,username}` |
| `update_nickname` | `{value:<string>}` | `{account,username}` |
| `view_signature` | `{account?}` | `{account,signature}` |
| `update_signature` | `{value?:<string or null>}` | `{account,signature}` |

Missing/null account means self; specified account is eight ASCII digits.
Unknown keys are rejected; update schemas have no account. Signature missing,
null or trimmed empty clears. Length errors reference username/signature;
structural errors can reference value. MCP errors: `isError:true`,
structuredContent `{status,error}` plus matching JSON text. Success uses a
field whitelist. view_avatar returns genuine MCP ImageContent with raw base64
and `mimeType:"image/png"`, plus text/structured metadata
`{account,mime_type,avatar_version}`; no duplicate base64 in text metadata.

Avatar sources are resolved by the local client:

- path: absolute local POSIX or Windows path; bounded read.
- url: http/https; timeout, bounded download, follow redirects, validate each
  redirect scheme and image bytes; never forward session/server authorization.
- base64: raw or `data:image/...;base64,` prefix; validated decoding; apply 5 MiB
  after decoding and reject invalid/unsupported image data.

Zero/multiple supplied source keys: 422 `one_source`, even if one is null.
Selected empty/null source: 422 `required`. Client update_avatar needs bounded
JSON sufficient for base64: recommend 8 MiB here, retaining 16 KiB on small routes.
Plugin forwards the selected string; no path read, URL download, upload decoding,
cache, retry, or login state. Plugin-to-client redirects never followed;
environment proxies ignored. Client validation remains mandatory independently.

Examples (synthetic placeholders):

```json
{"path":"C:\\synthetic\\avatar.png"}
{"url":"https://example.invalid/avatar.png"}
{"base64":"data:image/png;base64,<encoded bytes>"}
{"value":"  Alice  "}
{"value":null}
```

## Configuration and verification

CLI requires BB_DATABASE_PATH, BB_AVATAR_DIRECTORY, BB_HOST, BB_PORT.
Python create_app(database_path, avatar_directory=None) derives an isolated
`<db filename>.avatars` sibling if omitted, preserving STEP-1 test callers.
CLI requires explicit storage configuration. Plugin requires BB_CLIENT_BASE_URL;
BB_CLIENT_TIMEOUT_SECONDS defaults to 10. No production paths/hosts/credentials.
Back up SQLite and avatar directory together with writes stopped (see server
README); DB-only backup cannot recover uploaded avatars.

```bash
uv run --project server --locked python -m bb_server.export_openapi server/openapi.json --local-profile-output server/contract/profile-local-schema.json
uv run --project server --locked pytest server/tests -q
uv run --project dsh-plugin --locked pytest dsh-plugin/tests -q
```

Tests cover real FastAPI/SQLite/files with synthetic accounts, controlled clocks,
faults, concurrency, migration and restore. MCP stdio→loopback HTTP uses a client
test double. Real MCP→Dart→FastAPI, Flutter UI, Android, Windows and product DSH
Runtime need separate integration evidence. Public deployment hardening, global
request/rate limits, automatic orphan collection and power-loss guarantees are
outside this delivery. No message/event contract or Outbox is needed in this step.
