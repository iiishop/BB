# DEA-492 profile cover contract

The server is the authority for the displayed cover. These routes are additive.
Both require a current `Authorization: Bearer <session token>`.

| Method | Request | Success |
| --- | --- | --- |
| `POST /me/cover` | Exactly one multipart part named `file`, raw PNG/JPEG/WebP up to 8 MiB | 200 JSON `{cover_url, cover_version}`, after commit |
| `GET /covers/{account}` | An eight-digit account starting with 1–9, optional `If-None-Match` | 200 display image or 304 on match |

Uploads infer the owner from the Bearer token and reject query parameters and
additional multipart parts. A failed upload preserves the previous cover. Reads
permit any existing account and use the same default sea-wave asset when the
account has no custom cover. Clients may use the identical packaged crop as a
local default while loading. Successful reads return `image/png`, `image/jpeg`
or `image/webp` up to 512 KiB, with `X-BB-Cover-Default: true|false` (also on
304), `Cache-Control: private, no-cache`, and `Vary: Authorization`. Cache by
server and account, revalidate on reopen, and retain a previously displayed
cover when replacement fails. The `cover_url` is `/covers/{account}`.
`cover_version` is the unquoted ETag `sha256-<hex SHA-256 of display bytes>`.
The original/source is internal.

Errors use the BB envelope. 401 means unauthenticated, 404 unknown account,
413 oversize, 415 unsupported/invalid image, 422 invalid request shape, and
503 unavailable storage.

## Guarded local client and DSH

See `chat-v2-openapi.json` and `chat-v2-cases.json`. Both local routes use the
existing v2 owner header, `expected_identity` and `{identity,result}`.

| Local route | DSH tool input (public fields) | Local result |
| --- | --- | --- |
| `POST /v2/profile/view_cover` | `view_cover({account?})`, missing/null means self | `{account,cover_url,cover_version,mime_type,data,is_default}` |
| `POST /v2/profile/update_cover` | `update_cover({base64})`, raw padded standard base64, 8 MiB decoded | `{cover_url,cover_version}` |

The client adds the current session Bearer to both server requests and uses a
bounded JSON body budget of 12 MiB for the local upload. It rejects extra
fields including upload `account`, and uses the existing v2 identity and owner
checks. An invalid base64 string is a 422. The MCP read projects the returned
display image as ImageContent and omits `data` from structured/text metadata.
