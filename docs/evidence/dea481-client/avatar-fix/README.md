# DEA-483 avatar fix evidence

Scope: bounded UI fix requested by Forge after integration — `SpaceAvatar` must
use the server avatar from `SpaceAuthor.avatarUrl` instead of always rendering
initials.

- Branch: `agent/muse/dea-481-client`, based on delivered `63b16f6`.
- Code: `client/lib/ui/space/space_avatars.dart` (new store/scope),
  `space_widgets.dart` (`SpaceAvatar`), `space_page.dart` (optional
  `ProfileGateway` + scope), `ui/home_view.dart` (pass the existing profile
  gateway), `test/space_avatar_test.dart` (new regression).
- Reused entry: `ProfileGateway.loadAvatar(account:)` — existing token, ETag
  revalidation and shared `AvatarCache`; no new wire contract, no change to
  Forge's `space_service.dart`/DTOs, no DEA-480 or shared-CI files.

## Environment

- Linux, Flutter 3.47.9 (stable, engine `89c39edfdf`, Dart 3.13.7).
- The installed SDK and pub cache are read-only inside this run's sandbox, so
  the commands below ran against workspace copies of the same versions
  (`flutter-sdk/`, `.pub-cache/`). `PUB_CACHE` and `TMPDIR` point inside the
  workspace; no project or dependency versions changed.

## Commands and results

| Check | Command | Result | Log/exit |
| --- | --- | --- | --- |
| Analyzer | `flutter analyze` | exit 0, no issues | `analyze.log`, `analyze.exit` |
| Avatar regression | `flutter test test/space_avatar_test.dart` (included in focused run) | 5 passed | `space-tests.log`, `space-tests.exit` |
| Focused Space suite | `flutter test test/space_avatar_test.dart test/space_smoke_test.dart test/space_contract_fixtures_test.dart test/space_controller_test.dart test/space_feed_test.dart test/space_detail_test.dart test/space_compose_test.dart test/space_notifications_test.dart test/space_shell_test.dart` | exit 0, **59 passed** | `space-tests.log`, `space-tests.exit` |
| Full client suite | `flutter test` | exit 0, **683 passed, 12 skipped** (25-30 s) | `flutter-test-all.log`, `flutter-test-all.exit` |

The 12 skips are the same opt-in/environment skips recorded for `63b16f6`; this
run did not remove, loosen or skip any assertion.

## Not run

Real user-uploaded avatar photo on a live profile (fixture PNG bytes are used),
Android/Windows runtime, physical fold device, real model vision, network
WebSocket push. Forge's server tests remain the owner of the avatar endpoint
behavior.
