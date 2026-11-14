# DEA-471 media contract v1

Based on specification v1 and baseline `452e88e2288a909e533e4c993e9806f1e5c83be9`.
Forge owns `server/` and this document; Muse owns the client; Orion integrates.

## Metadata without downloading bytes

`GET /media/{media_id}/metadata` requires the same Bearer session and media
owner/recipient access as the original download. It returns the existing shared
`bb_auth_contract.chat.Media` DTO (called `MediaView` by the client):

```json
{"media_id":"opaque-id","media_type":"image","filename":"photo.png","mime_type":"image/png","byte_size":3145728,"cover_media_id":null}
```

`byte_size` is the original uploaded byte count from SQLite, never a thumbnail
size or a client claim. Upload replies and attachment messages already contain
this DTO. Historical body image blocks only contain `type` and `media_id`, so
resolve their IDs through this endpoint before deciding which bytes to request.
This additive endpoint preserves existing strict message DTOs, message digests,
operation replay and all historical stored payloads; no database migration or
duplicated size field is needed. Metadata reads do not open original files or
generate thumbnails. Responses are `private, no-store`. Unauthenticated requests
return 401; missing or other-pair media return 404 with the existing error envelope.

## Binary retrieval

`GET /media/{media_id}` and `?variant=original` retain the original file, MIME,
filename, `private, no-store`, and Starlette FileResponse Range behavior:
200 full bytes, 206 byte ranges, 416 unsatisfiable range; malformed ranges are
400. Authentication/owner-or-recipient checks happen before file access.

`GET /media/{media_id}?variant=thumb` accepts image media IDs only (including a
video's `cover_media_id`, not the video's own ID). It returns `image/jpeg`, with
both dimensions at most 512 pixels and at most 65536 bytes, without upscaling.
It applies EXIF orientation, composites transparency on white, uses the first
frame for animated WebP, and removes EXIF and other source metadata. The original
file is never changed. Parameters and limits live in
`server/contract/src/bb_auth_contract/media.py`; arbitrary size/quality inputs
are not supported. Unknown variants return 422.

Thumbnail responses use a content-derived ETag, `Cache-Control: private,
no-cache`, and `X-Content-Type-Options: nosniff`. An authenticated
`If-None-Match` match returns 304 without a body; Range applies to thumbnail
bytes if requested. Client cache keys must include server/account/media/variant
and must remain separate from originals and avatars. A cache hit or conditional
request still performs the normal authentication and media ACL checks.

Non-image thumbnail requests return 415 `unsupported_media_type`. Missing or
undecodable source images, generation or derivative-storage failures return
503 `thumbnail_unavailable` in the existing `{error:{code,message,fields}}`
envelope. Retrying the same GET is safe. No error returns original file bytes
as a thumbnail, and callers must not silently fetch a remote original on failure.

## Storage and failure order

Original uploads and SQLite records remain authoritative and immutable. Generated
files live at `BB_MEDIA_DIRECTORY/derivatives/thumb-v1/{media_id}.jpg`, separate
from original IDs and avatar storage. The version in the directory invalidates
the derivative cache when its encoding policy changes.

The sequence is: authenticate → authorize the media row → check derivative →
decode/resize in a bounded worker section → create a unique private temporary
file in that derivative directory → write/flush/fsync → atomic replace → serve.
Generation concurrency is bounded per process; multiple processes may generate
the same immutable image, but publish only complete files. Failures clean their
own temporary file. A hard crash can leave an unreferenced `.tmp` file, which is
never served; the next request independently regenerates. No DB update, message
event, receipt or consumption advance occurs. Derivatives may be discarded while
the service is stopped and are rebuilt on demand after restart.

## Client decisions and limits

The configured client boundary is 100 * 1024 bytes inclusive. Small images may
fetch originals; larger images use thumbnails in both the list and first viewer
screen. The original button and save action explicitly fetch original bytes.
Video display uses its image cover; only a play or save action fetches video
bytes. A sender can retain an already-held local original preview while the
derivative is unavailable. Metadata failure is retryable and is not permission
to assume a small image. Existing paginated history defines viewer ordering;
this change adds no parallel media index.

Server tests cover HTTP metadata, isolation, compression bounds, original ranges,
conditional access, concurrent generation, write failure/retry and restart.
Real device saves and player behavior remain client/integration acceptance.
