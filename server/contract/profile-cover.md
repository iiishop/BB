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

## Source and display policy

- SHA-256 of the original bytes is the first lookup. Successful aliases point
  to one source, while account-to-cover assignments remain independent.
- A cross-file match requires oriented aspect ratios within 0.5%, a short side
  of at least 96 px, spatial detail, and agreement of registered 128×128 color
  and alpha samples. Across the image we allow mean absolute channel error up
  to 2.5/255 and up to 3.5% of channels differing by more than 10/255. Each
  16×16 block must also stay within 5/255 and 16% respectively. Both the first
  comparison signature and the current source have to agree. Flat, ambiguous
  and multiple-candidate matches are stored separately.
- Confirmed variants retain the source with the largest oriented pixel area.
  Equal-area uploads keep the existing source. When a source is upgraded, all
  accounts already referencing that same image see the upgraded derivative on
  revalidation. Only the authenticated account's assignment changes.
- The display preserves aspect ratio, never upscales and caps the longest edge
  at 1,600 px and the payload at 512 KiB. A clean static image within both caps
  is served byte-for-byte. A derivative normalizes orientation and color and
  removes private metadata. For a small image that requires normalization, the
  encoder first tries lossless WebP at the original dimensions. Otherwise it
  tries WebP qualities 88, 82 and 74
  before reducing the output size. Every attempt uses the current source.
- Sources are capped at 24 megapixels and 8 MiB. The first frame of an animated
  upload is used. The original, the display (if different), aliases and account
  assignments commit atomically in SQLite. Only an unreferenced replaced
  source and its aliases are collected.

The cover matrix is exercised by `server/tests/test_profile_cover.py`. On an
integrated tree, run the installed DSH probe with
`BB_PRODUCT_CASES=profile-cover` and
`BB_PROFILE_COVER_CLIENT_ASSET=client/assets/profile/default-cover.png` using
`dsh-plugin/probes/journal/live.py --product`. The probe checks two isolated
accounts against real DSH tools, the standalone Dart client and FastAPI.

The shipped default is the same PNG as `client/assets/profile/default-cover.png`
from `eeddc0b0f3258a366b05f9c5691fa70c89ffae73`. It is served byte-for-byte
at 604×326 px (422,141 B), with ETag
`"sha256-85e4f78178c812b90f453be0c9033ea49b4fd1223a84c91f70719d673edc6ba9"`.

The real FastAPI process was exercised with Pillow 12.3.0. Sample dimensions
and byte counts came from the uploaded and retrieved files.

| Sample | Upload | Retrieved |
| --- | --- | --- |
| Sea crop, resized and encoded as WebP | 480×240, 50,756 B | 480×240 before upgrade, then the 1,200×600 JPEG below |
| Same sea picture, highest resolution | JPEG 1,200×600, 221,259 B | Same bytes, including after a later low-resolution upload |
| Same picture and resolution, different codec | WebP 1,200×600, 202,820 B | Existing JPEG, equal pixel area |
| Same-size mirror and local edit | JPEG 1,200×600, 221,364 B / 220,622 B | Separate covers, each byte-identical to its upload |
| Small clean PNG | 220×160, 510 B | Same bytes |
| High-frequency size stress | JPEG 2,400×1,200, 3,672,141 B | WebP 1,280×640, 473,726 B |

The 1,600 px attempt for the size-stress sample exceeded the byte budget, so
the derivative used a smaller proportional frame. Its original remains at
2,400×1,200. The two covers still read back after restarting the server on the
same SQLite database.
