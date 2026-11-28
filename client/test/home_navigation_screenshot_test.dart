import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/notifications/notification_center.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';

/// DEA-509 visual evidence for the v4 mobile edgebar and desktop rail.
///
/// Opt-in because it writes files:
/// `QA_NAV_SCREENSHOT_DIR=.qa-artifacts/nav-screenshots \
///  QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///  QA_ICON_FONT=/home/iiishop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
///  flutter test test/home_navigation_screenshot_test.dart --update-goldens`
void main() {
  final String? outputDir = Platform.environment['QA_NAV_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_NAV_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  setUp(SpaceLocalStore.resetForTest);

  testWidgets('capture DEA-509 v4 navigation at mobile and desktop sizes', (
    WidgetTester tester,
  ) async {
    final Directory directory = Directory(outputDir!);
    directory.createSync(recursive: true);

    if (fontPath != null && File(fontPath).existsSync()) {
      final Uint8List bytes = File(fontPath).readAsBytesSync();
      await tester.runAsync(() async {
        for (final String family in <String>['Roboto', 'Ahem']) {
          await (FontLoader(family)
                ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer))))
              .load();
        }
      });
    }
    if (iconFontPath != null && File(iconFontPath).existsSync()) {
      final Uint8List bytes = File(iconFontPath).readAsBytesSync();
      await tester.runAsync(() async {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)))).load();
      });
    }

    const AuthUser self = AuthUser(account: '53551476', username: '我');
    final FakeChatService chat = FakeChatService(
      self: self,
      users: const <ChatUser>[
        ChatUser(
          account: '66279514',
          username: '林柚咲',
          avatarUrl: '',
          avatarVersion: 'v1',
          presence: Presence.online,
          lastMessage: UserPreview(
            id: 'm1',
            senderAccount: '53551476',
            senderUsername: '我',
            previewBody: '还没，等你一起',
          ),
        ),
        ChatUser(
          account: '66279515',
          username: '苏晚晴',
          avatarUrl: '',
          avatarVersion: 'v1',
          presence: Presence.offline,
          lastMessage: UserPreview(
            id: 'm2',
            senderAccount: '53551476',
            senderUsername: '我',
            previewBody: '去，票我买了',
          ),
        ),
      ],
    );
    final FakeSpaceGateway space = FakeSpaceGateway();
    final SpacePost post = spacePost(
      postId: 'p1',
      author: spaceAuthor(account: '66279514', username: '林柚咲'),
      text: '在写东西，刚把书架那面墙拍下来了，光线意外地好。',
    );
    space.posts['p1'] = post;
    space.postPages[''] = spacePagePost(<SpacePost>[post]);
    final FakeProfileGateway profile = FakeProfileGateway();
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);

    final GlobalKey boundary = GlobalKey();

    Future<void> pumpAt(
      Size size, {
      EdgeInsets padding = EdgeInsets.zero,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(padding: padding),
              child: child!,
            ),
            home: HomeView(
              user: self,
              profile: profile,
              auth: FakeAuthGateway(),
              heartbeat: heartbeat,
              chat: chat,
              space: space,
              notificationBuilder: (BuildContext _, bool _) =>
                  const NotificationCenter(entries: <NotificationEntry>[]),
              onSignedOut: (_) {},
              onSessionExpired: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();
      await expectLater(
        find.byKey(boundary),
        matchesGoldenFile(
          Uri.file('${directory.absolute.path}${Platform.pathSeparator}$name'),
        ),
      );
    }

    // 1. Mobile 390x844 (34px bottom safe area) - Chat selected
    await pumpAt(
      const Size(390, 844),
      padding: const EdgeInsets.only(bottom: 34),
    );
    await capture('dea509-mobile-390-chat.png');

    // 2. Mobile 390x844 (34px bottom safe area) - Notifications selected + Chat hovered
    await tester.tap(find.byKey(HomeView.navNotificationsKey));
    await tester.pumpAndSettle();
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(HomeView.navChatKey)));
    await tester.pumpAndSettle();
    await capture('dea509-mobile-390-hover.png');

    // 3. Mobile 320x568 (0px bottom safe area) - Space selected
    await pumpAt(const Size(320, 568), padding: EdgeInsets.zero);
    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    await capture('dea509-mobile-320-space.png');

    // 4. Desktop 1280x800 - Chat selected
    await pumpAt(const Size(1280, 800));
    await capture('dea509-desktop-1280-chat.png');

    // 5. Desktop 1280x800 - Space selected + Notifications hovered
    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    await mouse.moveTo(
      tester.getCenter(find.byKey(HomeView.navNotificationsKey)),
    );
    await tester.pumpAndSettle();
    await capture('dea509-desktop-1280-space-hover.png');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 35));
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);
}
