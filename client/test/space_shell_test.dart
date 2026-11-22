import 'dart:ui' show DisplayFeature;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/space/space_detail_view.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

const AuthUser _self = AuthUser(account: spaceSelfAccount, username: 'alice');

FakeSpaceGateway shellGateway() {
  final FakeSpaceGateway gateway = FakeSpaceGateway();
  final SpacePost post = spacePost(postId: 'post-1', text: '外壳里的说说');
  gateway.posts['post-1'] = post;
  gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
  return gateway;
}

Future<void> pumpHome(
  WidgetTester tester, {
  required FakeSpaceGateway gateway,
  Size size = spacePhone,
  List<DisplayFeature> features = const <DisplayFeature>[],
  bool remount = true,
  List<ChatUser> users = const <ChatUser>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final FakeChatService chat = FakeChatService(self: _self, users: users);
  final FakeProfileGateway profile = FakeProfileGateway(
    profile: const Profile(
      account: spaceSelfAccount,
      username: 'alice',
      signature: null,
      avatarUrl: '',
      avatarVersion: 'v1',
    ),
  );
  final HeartbeatController heartbeat = HeartbeatController(
    auth: AuthService(
      api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
      session: AuthSession(),
    ),
  );
  addTearDown(heartbeat.dispose);
  if (remount) {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(size: size, displayFeatures: features),
        child: child!,
      ),
      home: HomeView(
        user: _self,
        profile: profile,
        auth: FakeAuthGateway(),
        heartbeat: heartbeat,
        chat: chat,
        space: gateway,
        onSignedOut: (LogoutResult? result) {},
        onSessionExpired: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(SpaceLocalStore.resetForTest);

  testWidgets('phone uses the bottom chat/space bar and keeps both states', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = shellGateway();
    await pumpHome(tester, gateway: gateway);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(HomeView.navChatKey), findsOneWidget);
    expect(find.byKey(HomeView.navSpaceKey), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);

    await tester.tap(find.text('BB空间'));
    await tester.pumpAndSettle();
    expect(find.byKey(SpacePage.pageKey), findsOneWidget);
    expect(find.text('外壳里的说说'), findsOneWidget);

    await tester.tap(find.text('聊天'));
    await tester.pumpAndSettle();
    expect(find.text('消息'), findsOneWidget);

    await tester.tap(find.text('BB空间'));
    await tester.pumpAndSettle();
    expect(find.text('外壳里的说说'), findsOneWidget);
  });

  testWidgets('resizing phone/PC/fold keeps the open detail and its input', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = shellGateway();
    await pumpHome(tester, gateway: gateway, size: spaceWide);
    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('space-post-body-post-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('space-detail-input')),
      '还没发出去',
    );
    await tester.pump();

    await pumpHome(tester, gateway: gateway, size: spacePhone, remount: false);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('space-detail-input')))
          .controller!
          .text,
      '还没发出去',
    );
    expect(find.text('外壳里的说说'), findsWidgets);

    await pumpHome(
      tester,
      gateway: gateway,
      size: spaceFold,
      features: <DisplayFeature>[verticalHinge(512, 768)],
      remount: false,
    );
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('space-detail-input')))
          .controller!
          .text,
      '还没发出去',
    );
  });

  testWidgets('wide screen uses the narrow rail, not the phone bar', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = shellGateway();
    await pumpHome(tester, gateway: gateway, size: spaceWide);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(HomeView.navChatKey), findsOneWidget);
    expect(find.byKey(HomeView.navSpaceKey), findsOneWidget);
    expect(find.byKey(HomeView.railAvatarKey), findsOneWidget);

    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    expect(find.byKey(SpacePage.pageKey), findsOneWidget);
  });

  testWidgets('wide shell keeps the rail profile entry, not a header avatar', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = shellGateway();
    await pumpHome(tester, gateway: gateway, size: spaceWide);

    // The rail owns the profile entry on wide layouts, so the message header
    // keeps its brand badge and does not duplicate the avatar.
    expect(find.byKey(HomeView.railAvatarKey), findsOneWidget);
    expect(find.byKey(HomeView.avatarEntryKey), findsNothing);
  });

  testWidgets('phone puts the profile entry in the message header, no rail', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = shellGateway();
    await pumpHome(tester, gateway: gateway);

    expect(find.byKey(HomeView.railAvatarKey), findsNothing);
    expect(find.byKey(HomeView.avatarEntryKey), findsOneWidget);
    // Same header row, left of the account and above the 消息 title, instead of
    // the removed bottom-left floating entry.
    final Rect avatar = tester.getRect(find.byKey(HomeView.avatarEntryKey));
    final Rect title = tester.getRect(find.text('消息'));
    final Rect account = tester.getRect(find.text(spaceSelfAccount));
    expect(avatar.top, lessThan(title.top));
    expect(
      (avatar.center.dy - account.center.dy).abs(),
      lessThan(2),
      reason: 'avatar shares the header row with the account on the right',
    );
    expect(avatar.left, lessThan(account.left));
  });

  testWidgets(
    'wide message page keeps the phone filter out of the desktop list',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = shellGateway();
      await pumpHome(tester, gateway: gateway, size: spaceWide);
      expect(find.byKey(HomeView.railAvatarKey), findsOneWidget);
      expect(find.byKey(UsersListView.onlineOnlyKey), findsNothing);
      expect(find.text('只看在线'), findsNothing);
    },
  );

  testWidgets(
    'a phone filter turns off on the wide shell and restores the full list',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = shellGateway();
      final List<ChatUser> users = <ChatUser>[
        const ChatUser(
          account: '10000002',
          username: 'bob',
          avatarUrl: '',
          avatarVersion: 'v1',
          presence: Presence.online,
        ),
        const ChatUser(
          account: '10000003',
          username: 'carol',
          avatarUrl: '',
          avatarVersion: 'v1',
          presence: Presence.offline,
        ),
      ];
      await pumpHome(tester, gateway: gateway, users: users);
      expect(find.byKey(UsersListView.onlineOnlyKey), findsOneWidget);
      await tester.tap(find.byKey(UsersListView.onlineOnlyKey));
      await tester.pumpAndSettle();
      expect(find.byKey(UsersListView.rowKey('10000003')), findsNothing);

      await pumpHome(
        tester,
        gateway: gateway,
        users: users,
        size: spaceWide,
        remount: false,
      );
      expect(find.byKey(HomeView.railAvatarKey), findsOneWidget);
      expect(find.byKey(UsersListView.onlineOnlyKey), findsNothing);
      expect(find.byKey(UsersListView.rowKey('10000002')), findsOneWidget);
      expect(find.byKey(UsersListView.rowKey('10000003')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide space shows master-detail and restores the single feed', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = shellGateway();
    await pumpHome(tester, gateway: gateway, size: spaceWide);
    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    expect(find.byKey(SpacePage.feedListKey), findsOneWidget);
    expect(find.byKey(SpaceDetailView.detailKey), findsNothing);

    await tester.tap(find.byKey(const Key('space-post-body-post-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(SpacePage.feedListKey), findsOneWidget);
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
    final Rect feed = tester.getRect(find.byKey(SpacePage.feedListKey));
    final Rect detail = tester.getRect(find.byKey(SpaceDetailView.detailKey));
    expect(feed.right, lessThanOrEqualTo(detail.left + 1));

    await tester.tap(find.byKey(SpaceDetailView.closeKey));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceDetailView.detailKey), findsNothing);
    expect(find.byKey(SpacePage.feedListKey), findsOneWidget);
  });

  testWidgets('vertical hinge becomes the pane boundary', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = shellGateway();
    await pumpHome(
      tester,
      gateway: gateway,
      size: spaceFold,
      features: <DisplayFeature>[verticalHinge(512, 768)],
    );
    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('space-post-body-post-1')));
    await tester.pumpAndSettle();

    final Rect feed = tester.getRect(find.byKey(SpacePage.feedListKey));
    final Rect detail = tester.getRect(find.byKey(SpaceDetailView.detailKey));
    expect(feed.right, lessThanOrEqualTo(512));
    expect(detail.left, greaterThanOrEqualTo(504));
    expect(detail.right, lessThanOrEqualTo(spaceFold.width));
  });

  testWidgets('horizontal occlusion confines content to the larger band', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = shellGateway();
    await pumpHome(
      tester,
      gateway: gateway,
      size: const Size(900, 700),
      features: <DisplayFeature>[horizontalHinge(350, 900)],
    );
    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    final Rect feed = tester.getRect(find.byKey(SpacePage.feedListKey));
    // The lower band is slightly taller, so all content stays below the hinge.
    expect(feed.top, greaterThanOrEqualTo(350));
  });
}
