import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/fake_space_profile_gateway.dart';
import 'support/space_fixtures.dart';

void main() {
  testWidgets('follow persists only the authoritative result', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gateway();
    await _pump(tester, gateway);

    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();

    expect(gateway.writeCalls, <bool>[true]);
    expect(find.text('已关注'), findsOneWidget);
  });

  testWidgets('cancelling the unfollow dialog keeps the relationship', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gateway(following: true);
    await _pump(tester, gateway);

    expect(find.text('已关注'), findsOneWidget);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();

    // The confirmation names the target and can be dismissed without writing.
    expect(find.byKey(SpaceProfilePage.unfollowDialogKey), findsOneWidget);
    expect(find.textContaining('bob'), findsWidgets);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    expect(gateway.writeCalls, isEmpty);
    expect(find.text('已关注'), findsOneWidget);
  });

  testWidgets('confirming the unfollow dialog writes the desired state', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gateway(following: true);
    await _pump(tester, gateway);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SpaceProfilePage.unfollowConfirmKey));
    await tester.pumpAndSettle();

    expect(gateway.writeCalls, <bool>[false]);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);
  });

  testWidgets('a failed follow never renders a fake success', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gateway();
    gateway.writeFailure = const AuthFailure(
      status: 500,
      code: 'error',
      message: 'boom',
    );
    await _pump(tester, gateway);

    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();

    expect(gateway.writeCalls, <bool>[true]);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);
    expect(find.text('操作失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('a failed unfollow keeps the real following state', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gateway(following: true);
    gateway.writeFailure = const AuthFailure(
      status: 503,
      code: 'upstream_unavailable',
      message: 'offline',
    );
    await _pump(tester, gateway);

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
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway(
      account: spaceSelfAccount,
      viewer: spaceSelfAccount,
    );
    gateway.putPage(
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'post-1', timelineAt: '2026-11-10T12:00:00Z'),
      ],
    );
    await _pump(tester, gateway);

    expect(find.byKey(SpaceProfilePage.followKey), findsNothing);
    expect(gateway.writeCalls, isEmpty);
    expect(find.text('bob'), findsOneWidget);
  });
}

FakeSpaceProfileGateway _gateway({bool following = false}) {
  final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
  gateway.followingState = following;
  gateway.putPage(
    items: <SpaceProfileEntry>[
      profileEntry(postId: 'post-1', timelineAt: '2026-11-10T12:00:00Z'),
    ],
  );
  return gateway;
}

Future<void> _pump(
  WidgetTester tester,
  FakeSpaceProfileGateway gateway, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final FakeSpaceGateway space = FakeSpaceGateway(account: spaceSelfAccount);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SpaceProfilePage(
          gateway: gateway,
          userId: gateway.account,
          viewerAccount: gateway.viewer,
          images: SpaceImageLoader(space),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
