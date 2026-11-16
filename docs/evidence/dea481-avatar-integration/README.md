# DEA-481 avatar integration follow-up

Approved product revision 1. Forge run `01a1e1a7-2789-7c80-9005-25da29e978e0`,
dedicated `dea-481-01655ad7e799/workdir/BB`, unique integration branch
`agent/forge/dea-481-integration`, draft PR #35.

Frozen code candidate: **`b3f391af7d64252b5cc3ced39e9a4ba4f1c94cc9`**.
This merges Muse `4038c1f1f16724dfa810c442f0a5d816dbaa1a64` onto integration
`9f2acffa7d5beadad50800751b719347fe654d3c`. The only product delta is the bounded
UI avatar integration; original client, service, ledger and server evidence
commits remain ancestors. Subsequent delivery commits are documents/evidence.

The initials-only gap reported in the previous integration is fixed. Space now
uses existing `ProfileGateway.loadAvatar(account:)`, including its authorization,
ETag and AvatarCache boundary. A page store shares one request per account and
retains initials during loading/failure. Likes/visitors sheets explicitly reuse
the store outside the page's Navigator subtree. No new transport, credentials,
persistent cache, shared protocol, service/DTO or ledger change was introduced.

## Actual new execution

- Existing required Flutter script: analyze exit 0; **688 passed / 12 skipped**;
  **14 Linux integration tests passed**. Five avatar regressions are included.
  `flutter/results.tsv` records stage exits; raw logs retain test collection and
  counts. This new combined run supersedes the former 683-pass UI result.
- The same real-release probe ran against the previous delivered `542cfad`
  executable and the new `b3f391a` executable. The previous binary was checked
  byte-for-byte against the delivered tar (`before-binary.json`). With an actual
  synthetic PNG uploaded to the real isolated FastAPI `/me/avatar`, the old
  release failed the rendered-avatar assertion: **0 matching pixels**, exit 1.
  The new release passed: **1248 matching pixels**, exit 0. Original failure,
  screenshots and UI logs are preserved. The predicate/threshold was unchanged.
- That probe also checks unauthenticated avatar GET returns **401**, authenticated
  GET succeeds and `If-None-Match` returns **304**. It creates a synthetic account,
  uses standalone Dart to publish a post, launches the actual Linux release with
  an isolated session, opens Space under Xvfb/Openbox and asserts 1440×900 window
  geometry. `avatar-result.json` records normalized server image hash. No tokens,
  session files or service DB are in evidence; owned children are stopped and
  temporary data cleaned by the existing Live context.
- `release-space.png` was visually inspected: the uploaded magenta image appears
  in the feed avatar and sidebar, with no initials and no clipping. This is an
  actual upload/render check using synthetic pixels, not a real person's photo,
  comprehensive visual QA or real device evidence.
- Linux release, portable tar and deb rebuilt from `b3f391a`. Android ARM64 APK
  rebuilt and signature checked; it uses the repository's public debug signing
  key. No device is attached (`devices.log`), so no Android runtime pass is claimed.

`results.json` gives exact commands, exits and parsed counts. `SHA256SUMS` covers
the raw evidence. `artifacts.json` identifies build SHA and reused artifacts;
the attached download README and SHA256SUMS identify the complete test set.

## Reused evidence and packages

`scope.json` mechanically checks identical relevant source/lock paths, expected
ancestors and **295 unchanged stock DSH host files**. Server, plugin, standalone
Dart, DTOs, authorization services, original fixture correction and skipped test
definitions are unchanged. Therefore the following remain evidence for those
boundaries, not new executions or blanket acceptance of the revised UI:

- `../dea481/`: 459 server tests, targeted 57, lint and actual server restart.
- `../dea481-agent/`: 114 plugin tests and local operation ownership regressions.
- `../dea481-integration/`: six real Space/auth/chat/media gateway passes;
  independent Dart TCP restart/rebind/ACL/replay; stock installed DSH lifecycle,
  24 tools, native image bytes, explicit reads, visit dedup and no republish.
- Previous standalone Dart AOT and DSH bundle downloads are reused unchanged,
  retaining their `542cfad` filenames and byte hashes. New Linux/Android UI and
  source downloads carry `b3f391a`; previous UI packages are superseded.

The twelve default skips retain the same unchanged definitions and reasons in
`../dea481-integration/skips.json`: six live tests lack endpoint variables in the
default run (separately passed in the prior real suite); six screenshot tests lack
opt-in output/fonts/assets. They are not relabelled as default-run passes.

## Remaining boundaries and next owner

No known avatar gap remains within this bounded fix. Shared store/widget coverage
includes feed, empty/failure fallback, request dedup, likes sheet and no-profile
fallback. Detail/comment/visitor avatars use the common implementation; the
visitor sheet uses the same explicit scope wrapper as likes, but no separate
real-release visitor click was run. Full independent acceptance is still pending.

Windows build/runtime/package, Android runtime, real foldable hardware, real model
semantics/adversarial content and rendered native settings interaction remain
NOT RUN. Locked Uvicorn still lacks a network WebSocket backend; prior HTTP replay
evidence applies, not network WS delivery. Linux rendering and the earlier
deterministic DSH provider do not prove these other boundaries.

Delivery Squad owns routing this fixed combined candidate through automated_qa.
Parent/child status is not changed by Forge. No main merge, production deploy,
formal release, private credential/profile access, external dependency patch,
shared CI edit, DEA-480 protected-file edit or other developer workspace change.
