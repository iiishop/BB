import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/fake_space_profile_gateway.dart';
import 'support/profile_test_harness.dart';
import 'support/space_fixtures.dart';

void main() {
  testWidgets('follow persists only the authoritative result', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    final ProfileRig rig = await pumpProfilePage(
      tester,
      profile: _profile(),
      space: space,
    );

    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();

    expect(space.followWrites, <({String account, bool following})>[
      (account: spacePeerAccount, following: true),
    ]);
    expect(rig.store.stateFor(spacePeerAccount), isTrue);
    expect(find.text('已关注'), findsOneWidget);
  });

  testWidgets('cancelling the unfollow dialog keeps the relationship', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    space.followStates[spacePeerAccount] = true;
    await pumpProfilePage(tester, profile: _profile(), space: space);

    expect(find.text('已关注'), findsOneWidget);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();

    // The confirmation names the target and can be dismissed without writing.
    expect(find.byKey(SpaceProfilePage.unfollowDialogKey), findsOneWidget);
    expect(find.textContaining('bob'), findsWidgets);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    expect(space.followWrites, isEmpty);
    expect(find.text('已关注'), findsOneWidget);
  });

  testWidgets('confirming the unfollow dialog writes the desired state', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    space.followStates[spacePeerAccount] = true;
    await pumpProfilePage(tester, profile: _profile(), space: space);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SpaceProfilePage.unfollowConfirmKey));
    await tester.pumpAndSettle();

    expect(space.followWrites, <({String account, bool following})>[
      (account: spacePeerAccount, following: false),
    ]);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);
  });

  testWidgets('a failed follow never renders a fake success', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    space.failNext(
      'set_follow',
      const AuthFailure(status: 500, code: 'error', message: 'boom'),
    );
    await pumpProfilePage(tester, profile: _profile(), space: space);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();

    expect(space.calls, contains('set_follow'));
    // The store reconciles with get_follow; the fake still reports not-following.
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);
    expect(find.text('操作失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('a failed unfollow keeps the real following state', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    space.followStates[spacePeerAccount] = true;
    space.failNext(
      'set_follow',
      const AuthFailure(
        status: 503,
        code: 'upstream_unavailable',
        message: 'offline',
      ),
    );
    await pumpProfilePage(tester, profile: _profile(), space: space);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SpaceProfilePage.unfollowConfirmKey));
    await tester.pumpAndSettle();

    expect(find.text('已关注'), findsOneWidget);
    expect(find.text('暂时无法连接服务器，请稍后重试'), findsOneWidget);
  });

  testWidgets('your own home page never shows or writes a follow', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway profile = FakeSpaceProfileGateway(
      account: spaceSelfAccount,
      viewer: spaceSelfAccount,
    );
    profile.putPage(
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'post-1', timelineAt: '2026-11-10T12:00:00Z'),
      ],
    );
    final FakeSpaceGateway space = FakeSpaceGateway();
    await pumpProfilePage(tester, profile: profile, space: space);

    expect(find.byKey(SpaceProfilePage.followKey), findsNothing);
    expect(space.followWrites, isEmpty);
    expect(find.text('bob'), findsOneWidget);
  });

  testWidgets('a persisted follow.changed event refreshes the shared store', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    space.followStates[spacePeerAccount] = true;
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: space,
      viewerAccount: space.account,
    );
    await pumpProfilePage(
      tester,
      profile: _profile(),
      space: space,
      followStore: store,
    );
    expect(find.text('已关注'), findsOneWidget);

    // Another device unfollowed: the persisted event carries no IDs, so the
    // client refetches the authoritative state.
    space.followStates[spacePeerAccount] = false;
    store.handleFollowChanged();
    await tester.pumpAndSettle();

    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);
  });
}

FakeSpaceProfileGateway _profile() {
  final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
  gateway.putPage(
    items: <SpaceProfileEntry>[
      profileEntry(postId: 'post-1', timelineAt: '2026-11-10T12:00:00Z'),
    ],
  );
  return gateway;
}
