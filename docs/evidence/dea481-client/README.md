# DEA-483 Space client evidence

Owner: Muse. Task: DEA-483, client part of the approved DEA-481 Space revision 1.

- Baseline: `d402ba8cecdfdbfb421eef23165483b24f3bd1a3`.
- Consumed Forge typed-client SHA: `3887595` (`agent/forge/dea-481-agent-access`,
  parent `d402ba8`; only `client/lib/models/space_models.dart`,
  `client/lib/services/space*`, ledger/local-router and its docs). The client
  branch is based on that commit; Forge remains the sole integrator of PR #35.
- Candidate branch: `agent/muse/dea-481-client` (pushed from the run worktree).
- Verification SHA: `de0da8b` (the code/test tree all commands above ran on).
  The branch head appends this manifest/SHA note only; code and tests are
  unchanged by that documentation commit.
- Run directory: `dea-483-17449a6f2dc1/workdir/BB-client`; scope: `ui/space/`,
  `main.dart`, `app.dart`, `ui/auth_flow.dart`, `ui/home_view.dart`,
  `test/space_*`, `test/support/space_*`, `client/docs/dea481-*`,
  `docs/evidence/dea481-client/`. No chat/windows/workflow/lockfile file changed.

## Environment

See `logs/environment.log`: Flutter 3.47.9 stable, Dart 3.13.7, Linux
`7.2.4-arch1-2` x86_64, only the Linux desktop device is available. No Android
device/emulator and no physical fold device. The isolated server used the repo's
`server/pyproject.toml` via `uv run --project server --locked`; its database,
avatars, media and session files were under this run directory, not a personal
or production profile.

## Executed checks

| Check | Command | Result | Raw log |
| --- | --- | --- | --- |
| Analyzer | `flutter analyze` | exit 0, no issues | `logs/analyze.log`, `logs/analyze.exit` |
| Full client suite | `flutter test` | exit 0, **676 passed, 12 skipped**, 25 s | `logs/flutter-test-all.log`, `logs/flutter-test-all.exit` |
| Focused Space tests | `flutter test test/space_smoke_test.dart test/space_contract_fixtures_test.dart test/space_controller_test.dart test/space_feed_test.dart test/space_detail_test.dart test/space_compose_test.dart test/space_notifications_test.dart test/space_shell_test.dart` | exit 0, **52 passed**, 4 s | `logs/space-widget-tests.log`, `logs/space-widget.exit` |
| Real HTTP path | `BB_SPACE_API_BASE=http://127.0.0.1:8765 flutter test test/space_real_api_test.dart` | exit 0, **1 passed** | `logs/space-real-api.log`, `logs/space-real-api.exit` |
| Rendered screenshots | opt-in screenshot test with Noto CJK + MaterialIcons fonts | exit 0, **2 passed**, 10 files | `logs/space-screenshots.log`, `.exit` |
| Linux release build | `flutter build linux --release` | succeeded (`build/linux/x64/release/bundle/bb_mobile`) | `logs/build-linux.log` |
| Real Linux client | Xvfb + built binary + isolated server + synthetic session | window ran; screenshots captured | `logs/app*.log`, `logs/xvfb*.log`, `run_real_client*.sh` |

Twelve skipped tests are pre-existing opt-in suites and the two opt-in Space
evidence tests (`QA_SPACE_SCREENSHOT_DIR`/`BB_SPACE_API_BASE` absent in the plain
`flutter test` run). They are not counted as passes.

## What the real HTTP test exercises

`client/test/space_real_api_test.dart` uses the exact `SpaceServiceGateway` the
UI consumes, over real TCP against the isolated server, with two synthetic
accounts:

1. overview contract `dea481-space-v1`;
2. create draft → upload two real PNG bytes → reorder via update → publish;
3. get the published post with a visit ID and read the ordered original image
   bytes (PNG magic verified);
4. second account sees the post, lists comments, replies, likes;
5. author receives interaction notifications and acknowledges one observed
   version;
6. author sees visitor details; the non-author is rejected with 403;
7. explicit `markRead` removes only that post from the unread filter;
8. `readEvents` returns persisted invalidations;
9. delete removes the post and its detail read is 404.

## Real Linux client run

The isolated server was seeded with two synthetic accounts and a photo post with
comments/likes. A `session.json`/`server.json` pair for account `A` was written
under `real-client-data/run/` (0600), and the release binary was started under
Xvfb (`1600x1000`). The real window was resized with `xdotool` and captured with
ImageMagick `import`; the scripts are included for reproduction.

Observed in the real client:

- wide feed and detail with live server data, real image bytes and counts;
- phone layout with the bottom 聊天 / BB空间 bar;
- 390×844 detail with typed comment text, then 1024×768 (simulated fold width)
  with the same detail, same typed text and the same visit count;
- image viewer open at 2/2, still 2/2 after the resize;
- compose with typed text showing “已保存到服务器”.

The 1024×768 run is a resized Linux window plus a simulated width; it is **not**
a physical fold device. Android/Windows runtime and a real hinge remain NOT RUN.

## Screenshots

Widget renders (Noto CJK, phone 390×844, PC 1440×900, simulated fold
1024×768; these are widget-test renders, not device screenshots):

- `screenshots/widget-shell-phone.png` — app bottom bar + Space
- `screenshots/widget-shell-wide.png` — narrow rail + centered feed
- `screenshots/widget-shell-folded.png` — rail + master-detail at a simulated hinge
- `screenshots/widget-feed-phone.png`, `widget-feed-wide.png`
- `screenshots/widget-detail-phone.png`, `widget-detail-wide.png`, `widget-detail-folded.png`
- `screenshots/widget-notifications-phone.png`
- `screenshots/widget-compose-wide.png`

Real Linux desktop window against the isolated server:

- `screenshots/real-feed-wide.png`, `real-detail-wide.png`
- `screenshots/real-detail-phone.png`, `real-detail-phone-typed.png`
- `screenshots/real-detail-fold-typed.png` (same detail + typed text after resize)
- `screenshots/real-viewer-phone.png`, `real-viewer-fold.png` (same viewer index)
- `screenshots/real-compose-phone.png` (autosaved typed text)

## T01–T17 client mapping

Only the client-owned rows are claimed here. Server, local-adapter, DSH/plugin,
Windows/Android/fold-device and model-vision evidence belong to other owners.

| Case | Client evidence |
| --- | --- |
| T01 | Ten images render nine tiles with `+1`; viewer holds all ten and only that post; long text clamps at four lines with 查看全文; publish/edit-immutability behavior is server-verified and the UI has no post-edit path (`space_feed_test`, `space_detail_test`, screenshots) |
| T02 | Conflict keeps local text/order and offers explicit reload; offline keeps local-only input and blocks publish; publish gating requires a saved attachment-ready version (`space_compose_test`; multi-device concurrency is NOT RUN) |
| T03 | Cursor feed, dedupe on append, refresh inserts new posts, background comparison yields an explicit “有新说说” banner rather than moving the list; scroll restored after detail (`space_controller_test`, `space_feed_test`) |
| T04 | Five-root/three-reply preview with separate remaining counts; two display indent levels; arbitrary reply target text; on-demand root/reply pagination (`space_detail_test`) |
| T05 | Notification tap opens target and focuses an unloaded comment via `get_comment_context`; acknowledgement uses the observed version (`space_controller_test`, `space_notifications_test`) |
| T06 | Direct reference card only; local back history C→B→A; independent per-post images/counts (`space_detail_test`) |
| T07 | Delete confirmation, feed removal, detail/history handling and local event invalidation; deleted reference/target copy (`space_detail_test`, `space_controller_test`) |
| T08 | Deleted root/reply placeholders keep live children and “回复谁” (`space_detail_test`) |
| T09 | Visit ID reused across retries/resize; list load does not count or mark read; images/comments add no visit; markRead only the opened post (`space_detail_test`, `space_controller_test`) |
| T10 | Public view count; author visitor sheet shows count/last visit; non-author 403 is shown as a denial, not an empty list (`space_detail_test`) |
| T11 | Like notification rendering, per-version acknowledgement and new-version-unread retained (`space_controller_test`, `space_notifications_test`) |
| T12 | Only client-visible parts: failure keeps composer text and drafts; repeated events dedupe (`space_controller_test`); transaction ordering is server evidence |
| T13 | Wide master-detail independent scroll panes, close returns to centered feed, keyboard arrows in the viewer, focusable non-hover-only actions (`space_shell_test`, `space_detail_test`, real wide screenshots). Windows runtime NOT RUN |
| T14 | Same post/reply target/text/image viewer index and unchanged visit count across 390→1440→390 and 390→1024 simulated fold (`space_detail_test`, `space_shell_test`, real phone→fold screenshots). Physical fold NOT RUN |
| T15/T16 | DSH/plugin owner (Forge); the client consumes the same contract and does not add an alternate agent path |
| T17 | Offline banner distinct from empty; reconnect replay clears deleted cached post/images and keeps unsynced draft; account/server scoping of local buffers; old server capability notice keeps chat usable (`space_controller_test`, `space_feed_test`, `space_compose_test`) |

## Unmeasured / blocked

- Android runtime, Windows runtime and a physical fold device: no such device is
  attached to this machine (only Linux desktop); no build was claimed as runtime.
- Network WebSocket push: the locked server has no Uvicorn WebSocket backend
  (known 404); the client uses the single authenticated HTTP event replay loop.
- DSH plugin install/tool/image behavior and real model vision: sibling DEA-484
  and parent scope.
- Multi-device simultaneous draft editing and lost-response replay: server and
  service tests exist; this client run verified single-process conflict/offline
  states only.
- Screen readers, IME composition and real hover-capable input hardware: not
  executed; the code exposes semantics labels and keyboard focus but no audit is
  claimed.
- Real avatar images: Space cards use deterministic initial-letter avatars; no
  second avatar transport was introduced.
