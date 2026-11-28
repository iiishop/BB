import 'dart:io';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/notifications/notification_center.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-507 visual evidence for NotificationCenter A 方案 v5.
///
/// Opt-in because it writes files:
/// `QA_NOTIFICATION_SCREENSHOT_DIR=.qa-artifacts/notification-screenshots \
///  QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///  QA_ICON_FONT=.../MaterialIcons-Regular.otf \
///  flutter test test/notification_center_screenshot_test.dart --update-goldens`
void main() {
  final String? outputDir =
      Platform.environment['QA_NOTIFICATION_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_NOTIFICATION_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets(
    'capture NotificationCenter A v5 at 1440x900, 390x844, and 320x568',
    (WidgetTester tester) async {
      final Directory directory = Directory(outputDir!);
      directory.createSync(recursive: true);
      if (fontPath != null && File(fontPath).existsSync()) {
        final Uint8List bytes = File(fontPath).readAsBytesSync();
        await tester.runAsync(() async {
          for (final String family in <String>['Roboto', 'Ahem']) {
            await (FontLoader(
                  family,
                )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer))))
                .load();
          }
        });
      }
      if (iconFontPath != null && File(iconFontPath).existsSync()) {
        final Uint8List bytes = File(iconFontPath).readAsBytesSync();
        await tester.runAsync(() async {
          await (FontLoader('MaterialIcons')
                ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer))))
              .load();
        });
      }

      final List<NotificationEntry> entries = <NotificationEntry>[
        NotificationEntry(
          id: 'notice-invite-run',
          type: 'group_invitation',
          title: '入群邀请',
          body: '林小满 邀请你加入「周末跑团」',
          timeLabel: '3 分钟前',
          read: false,
          statusLabel: '待处理',
          actions: <NotificationEntryAction>[
            NotificationEntryAction(
              id: 'accept',
              label: '接受',
              onPressed: () {},
            ),
            NotificationEntryAction(
              id: 'reject',
              label: '拒绝',
              onPressed: () {},
            ),
          ],
          onOpenDetails: () {},
          onMarkRead: () {},
        ),
        NotificationEntry(
          id: 'notice-apply-design',
          type: 'group_application',
          title: '入群申请',
          body: '陈以宁 申请加入「设计交流群」',
          timeLabel: '26 分钟前',
          read: true,
          statusLabel: '待处理',
          actions: <NotificationEntryAction>[
            NotificationEntryAction(
              id: 'approve',
              label: '同意',
              onPressed: () {},
            ),
            NotificationEntryAction(
              id: 'reject',
              label: '拒绝',
              onPressed: () {},
            ),
          ],
          onOpenDetails: () {},
        ),
        NotificationEntry(
          id: 'notice-result-book',
          type: 'group_join_result',
          title: '入群结果',
          body: '群主同意了你的「旧书交换」入群申请',
          timeLabel: '1 小时前',
          read: false,
          statusLabel: '仅告知',
          onOpenDetails: () {},
          onMarkRead: () {},
        ),
        NotificationEntry(
          id: 'notice-left-run',
          type: 'group_member_left',
          title: '成员退出',
          body: '苏晚 退出了「周末跑团」',
          timeLabel: '昨天 21:40',
          read: true,
          statusLabel: '仅告知',
          onOpenDetails: () {},
        ),
        NotificationEntry(
          id: 'notice-removed-canteen',
          type: 'group_member_removed',
          title: '移出群聊',
          body: '林小满 将你移出了「深夜食堂」',
          timeLabel: '昨天 09:12',
          read: false,
          statusLabel: '仅告知',
          onOpenDetails: () {},
          onMarkRead: () {},
        ),
        NotificationEntry(
          id: 'notice-invite-film',
          type: 'group_invitation',
          title: '入群邀请',
          body: '周野 邀请你加入「胶片摄影社」\n处理结果：已接受',
          timeLabel: '11月26日',
          read: true,
          statusLabel: '已处理',
          onOpenDetails: () {},
        ),
        NotificationEntry(
          id: 'notice-dissolved-books',
          type: 'group_dissolved',
          title: '群已解散',
          body: '沈迟 解散了「城市漫步与旧书交换」',
          timeLabel: '11月25日',
          read: true,
          statusLabel: '仅告知',
          onOpenDetails: () {},
        ),
      ];

      const AuthUser self = AuthUser(account: '10000001', username: '我');
      final FakeChatService chat = FakeChatService(
        self: self,
        users: const <ChatUser>[],
      );
      final FakeProfileGateway profile = FakeProfileGateway();
      final HeartbeatController heartbeat = HeartbeatController(
        auth: AuthService(
          api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
          session: AuthSession(),
        ),
      );
      addTearDown(heartbeat.dispose);

      final GlobalKey boundary = GlobalKey();

      Future<void> pumpHomeShell(
        Size size, {
        List<NotificationEntry>? customEntries,
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
              home: HomeView(
                user: self,
                profile: profile,
                auth: FakeAuthGateway(),
                heartbeat: heartbeat,
                chat: chat,
                notificationBuilder: (BuildContext _, bool _) =>
                    NotificationCenter(entries: customEntries ?? entries),
                onSignedOut: (_) {},
                onSessionExpired: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(HomeView.navNotificationsKey));
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        });
        await tester.pump();
        await expectLater(
          find.byKey(boundary),
          matchesGoldenFile('../.qa-artifacts/notification-screenshots/$name'),
        );
      }

      // 1. Desktop 1440x900
      await pumpHomeShell(const Size(1440, 900));
      await capture('dea507-desktop-1440x900.png');

      // 2. Mobile 390x844
      await pumpHomeShell(const Size(390, 844));
      await capture('dea507-mobile-390x844.png');

      // 3. Mobile 390x844 with "更多 ⌄" bottom sheet open
      await tester.tap(
        find.byKey(NotificationCenter.moreKey('notice-invite-run')),
      );
      await tester.pumpAndSettle();
      await capture('dea507-mobile-390x844-sheet.png');

      // 4. Mobile 390x844 pending-empty
      await pumpHomeShell(
        const Size(390, 844),
        customEntries: entries
            .where((NotificationEntry e) => !e.pending)
            .toList(),
      );
      await tester.tap(find.byKey(NotificationCenter.pendingKey));
      await tester.pumpAndSettle();
      await capture('dea507-mobile-390x844-pending-empty.png');

      // 5. Mobile 320x568
      await pumpHomeShell(const Size(320, 568));
      await capture('dea507-mobile-320x568.png');

      for (final String fileName in <String>[
        'dea507-desktop-1440x900.png',
        'dea507-mobile-390x844.png',
        'dea507-mobile-390x844-sheet.png',
        'dea507-mobile-390x844-pending-empty.png',
        'dea507-mobile-320x568.png',
      ]) {
        expect(
          File('${directory.path}${Platform.pathSeparator}$fileName')
              .existsSync(),
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 35));
    },
    skip: skipReason != null,
  );
}
