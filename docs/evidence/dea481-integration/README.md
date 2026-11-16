# DEA-481 combined candidate evidence

Specification: approved product revision 1, captured verbatim in
`docs/design/dea481-approved-space.md`. Forge is the sole integrator on
`agent/forge/dea-481-integration`, draft PR #35. Run:
`01a1e18e-7f37-7935-b50d-53ed329e6126`; dedicated checkout:
`dea-481-01655ad7e799/workdir/BB`. Initial main baseline:
`573f3877cb8497d9df4720be3c13eee089ff9642`.

**Frozen combined code: `542cfadcb38e6b60856c2e371d921443cba53a4c`.**
Later delivery commits contain evidence/documents only. `scope.json` records
Git tree IDs, checked ancestry and the precise unchanged paths that permit
reuse. Both complete development branches are merged without rewriting them:

- DEA-484 `593e48f4aa69c109a11c7b3c4dac045126a225ec`, including the consumer
  operation-ownership ledger fix, typed adapters and existing DSH extension.
- DEA-483 `63b16f608a35fbc56ddca3638d0ecc829b4a9f8c`, including original
  implementation `de0da8b`, evidence `05e675d`, and operation-ID retention and
  failure feedback revision `d3856e3`. The tested UI tree and delivered UI tree
  match. No implementation was lost through an exclusive cherry-pick range.
- Server evidence commit `3a2b67b` is preserved. Shared authority remains
  `server/contract/`; the integration introduces no new protocol or identity.

## Actual checks

`results.json` indexes commands, source versions, exits and counts. All raw
logs are retained, including failures. No check is labelled complete acceptance.

| Check | Version | Result and boundary |
| --- | --- | --- |
| Existing required Flutter entry | `542cfad` | analyze PASS; 683 tests PASS / 12 SKIP; 14 Linux integration tests PASS |
| Real Space/auth/chat/media gateway suite | `542cfad` | 6 PASS / 0 SKIP, real isolated FastAPI TCP; JSON reporter in `real-gateway-final.jsonl` |
| Independent Dart/local contract and recovery | `d2211e2` | PASS, actual server + standalone Dart; account/consumer fencing, restart/rebind, HTTP replay, delete invalidation, explicit ACK |
| Stock installed DSH lifecycle | `d2211e2` | PASS for native install/settings save/restart/disable/uninstall, 24 Space tools, ten ordered images, native attachment bytes, explicit read, dedup visits, no republish; deterministic provider only |
| Full server regression | reused `d402ba8` | 459 PASS / 0 SKIP, targeted 57 PASS and lint; identical entire server tree |
| Plugin regression | reused `87c3807` | 114 PASS / 0 SKIP plus lint; identical plugin and relevant service/DTO/lock trees |
| Linux release + packages | `542cfad` | release build, deb and portable tar PASS; actual release screenshot against synthetic real service at 1440×900 |
| Independent Dart AOT package | `542cfad` | `dart build cli` PASS; executable register/login/consumer/create/read against real TCP PASS |
| Android ARM64 test APK | `542cfad` | release build and APK v2 signature verification PASS; public checked-in debug signer, not a production signature; no device run |
| DSH bundle/source archive | `542cfad` | existing builder and Git archive succeeded; checksums in `artifacts.json` |

The default Flutter entry uses Xvfb, required widget/integration flags and the
existing repository script. Linux integration includes native ffmpeg/FVP but
uses the existing test HTTP backend; it is separate from the actual FastAPI
gateway suite and actual release smoke. `release-space.png` was visually checked:
Space navigation and the synthetic post render without clipping at 1440×900.
It is a smoke screenshot, not comprehensive visual QA.

Earlier in this run, `d2211e2` passed analyze, 681 tests / 12 skips and 14 Linux
integration tests (`flutter/`). The compose revision invalidated that UI result;
`flutter-final/` is the superseding combined run. Native/TCP paths are unchanged
and their earlier execution is deliberately reused, rather than relabelled as
a run on `542cfad`. Original Muse viewport screenshots and 54 Space checks are
in `docs/evidence/dea481-client/`; they remain separate developer evidence.

## Failures and corrections

The first optional real gateway run on `d2211e2` had 5 passes and 1 failure:
`live_auth_test.dart` wrote a fake invalid token at generation 0 after login had
advanced the stored credential. SessionStore correctly rejected the stale
fixture, so restore still saw the valid token. Commit `51f90c1` sets
`assignGeneration: true` and asserts the invalid token was actually persisted.
Original 401/cleared-session/file-deletion assertions remain intact. Before and
after JSON logs and exit codes are retained. This fixes a test precondition,
not production authentication semantics. Final real run: 6 passes.

First Android `--no-pub` build failed because the generated Java registrant still
referenced the dev-only integration-test plugin. The normal Flutter build with
dependency/plugin metadata regeneration succeeded with unchanged lock files;
no generated Java, Gradle, SDK, dependency or CI patch was made. Both build logs
and exits are retained. `dart compile exe` refused an existing build-hook package;
the SDK-supported `dart build cli` succeeded without a dependency change.

Two exploratory smoke-probe assumptions were corrected before the delivered
probe: a guessed contract version was replaced by shared `space.VERSION`, and
an unmanaged Xvfb window produced a cropped 640×480 image. The final probe starts
its own Openbox, asserts actual 1440×900 geometry, and stops only its own children.
Neither correction changes product code or asserts a product defect.

## Skips, remaining issues and untested boundaries

`skips.json` derives all twelve names from the test runner's JSON metadata, not
from interleaved progress lines. Six live tests skip because their endpoint env
variables are absent in the default suite; those same tests separately pass in
the real gateway suite. Six opt-in screenshot tests skip because output/font/
asset inputs are absent. Existing Muse Space screenshots are independently
versioned evidence, not a conversion of these default skips to PASS.

Known UI gap for Muse: `SpaceAvatar` (`client/lib/ui/space/space_widgets.dart:14`)
always renders initials and does not consume `SpaceAuthor.avatarUrl`. Feed,
detail, comments and people reuse it. The approved §3.1 requires card avatars,
and real Profile avatars exist; the delivered UI explicitly documents this
placeholder limitation. Reuse the existing authorized avatar/cache boundary;
do not invent an unauthenticated fetch or new protocol. This remains open for
UI correction and independent QA, not waived by integration tests.

NOT RUN: Windows build/runtime and Windows test package; Android installation/
runtime; real foldable device; real model image comprehension and adversarial
content behavior; rendered native DSH settings interaction in this run. Linux
viewport resizing and deterministic provider attachment bytes do not prove any
of those. Android SDK/toolchain is present, but no Android device is attached.
No private model credentials/profile was inspected. Source archive is available
for Windows reproduction; it is not a Windows binary.

Network WebSocket delivery remains unavailable in the locked Uvicorn environment
(neither websockets nor wsproto; prior real upgrade 404). HTTP global replay and
recovery passed; ASGI socket evidence remains server-only. No dependency patch
or unapproved upgrade was used to turn this into a claimed network pass.

No shared CI, Windows/clipboard/DEA-480 protected files, production data, external
DSH installation, other developer workspace, main branch or issue status was
changed. Parent remains in_progress for Delivery Squad; this is a reviewable
combined candidate, not whole-product acceptance or a release.

See `docs/design/dea481-integration-acceptance.md` for all T01–T17 evidence and
remaining ownership. Downloadable test packages, source, evidence, README and
SHA256SUMS are attached to the parent issue's integration reply.
