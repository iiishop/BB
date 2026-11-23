import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/avatar_fixtures.dart';
import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

/// Before/after evidence for the DEA-493 visual rework (phone size, one
/// screen): two consecutive peer lines, one landscape photo, one own reply and
/// a composer draft — the same content as the reference image.
///
/// Opt-in because it writes files:
/// `QA_CHAT_SCREENSHOT_DIR=.qa-artifacts/screenshots \
///  QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///  QA_ICON_FONT=.../MaterialIcons-Regular.otf \
///  flutter test test/chat_visual_reference_test.dart --update-goldens`
void main() {
  final String? outputDir = Platform.environment['QA_CHAT_SCREENSHOT_DIR'];
  final String shotName =
      Platform.environment['QA_CHAT_REFERENCE_NAME'] ?? 'dea493-visual-after';
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_CHAT_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture the reference conversation on a phone', (
    WidgetTester tester,
  ) async {
    if (outputDir == null) {
      return;
    }
    final Uint8List? cjk = fontPath != null && File(fontPath).existsSync()
        ? File(fontPath).readAsBytesSync()
        : null;
    if (cjk != null) {
      await tester.runAsync(() async {
        for (final String family in <String>['Roboto', 'Ahem']) {
          await (FontLoader(
            family,
          )..addFont(Future<ByteData>.value(ByteData.view(cjk.buffer)))).load();
        }
      });
    }
    if (iconFontPath != null && File(iconFontPath).existsSync()) {
      final Uint8List icon = File(iconFontPath).readAsBytesSync();
      await tester.runAsync(() async {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future<ByteData>.value(ByteData.view(icon.buffer)))).load();
      });
    }

    final Uint8List photo = File('test/fixtures/media/horizon.png')
        .readAsBytesSync();
    final DateTime now = DateTime.now().toUtc();
    final ChatMessage peerOne = ChatMessage(
      id: 'v1',
      position: 1,
      senderAccount: '10000002',
      targetAccount: _self.account,
      createdAt: now.subtract(const Duration(minutes: 9)),
      kind: ChatMessageKind.body,
      parts: const <MessagePart>[TextPart('刚从海边回来。')],
    );
    final ChatMessage peerTwo = ChatMessage(
      id: 'v2',
      position: 2,
      senderAccount: '10000002',
      targetAccount: _self.account,
      createdAt: now.subtract(const Duration(minutes: 8)),
      kind: ChatMessageKind.body,
      parts: const <MessagePart>[TextPart('给你看今天的月亮。')],
    );
    final ChatMessage peerPhoto = ChatMessage(
      id: 'v3',
      position: 3,
      senderAccount: '10000002',
      targetAccount: _self.account,
      createdAt: now.subtract(const Duration(minutes: 7)),
      kind: ChatMessageKind.body,
      parts: const <MessagePart>[ImagePart('photo-1')],
    );
    final ChatMessage mine = ChatMessage(
      id: 'v4',
      position: 4,
      senderAccount: _self.account,
      targetAccount: '10000002',
      createdAt: now.subtract(const Duration(minutes: 5)),
      kind: ChatMessageKind.body,
      parts: const <MessagePart>[TextPart('这个蓝色好漂亮。')],
    );

    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[
        ChatUser(
          account: '10000002',
          username: 'bob',
          avatarUrl: '/avatars/10000002.png',
          avatarVersion: 'v1',
          presence: Presence.online,
        ),
      ],
      conversations: <String, List<ChatMessage>>{
        '10000002': <ChatMessage>[peerOne, peerTwo, peerPhoto, mine],
      },
      png: photo,
    );
    final FakeProfileGateway profile = FakeProfileGateway();
    profile.avatars['10000001'] = selfIdenticon;
    profile.avatars['10000002'] = peerIdenticon;
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());
    addTearDown(() => tester.view.resetViewInsets());

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding.zero;
    final GlobalKey boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          // A real phone opens the conversation as a pushed route, so the
          // header shows its back control. Two initial routes give the
          // Navigator something to pop without building a fake list page.
          home: Navigator(
            onGenerateInitialRoutes:
                (NavigatorState navigator, String initialRoute) =>
                    <Route<void>>[
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            const Scaffold(backgroundColor: AppColors.paper),
                      ),
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) => ChatPage(
                          peer: const ChatUser(
                            account: '10000002',
                            username: 'bob',
                            avatarUrl: '/avatars/10000002.png',
                            avatarVersion: 'v1',
                            presence: Presence.online,
                          ),
                          chat: chat,
                          profile: profile,
                        ),
                      ),
                    ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(ChatComposer.inputKey), '好啊，等一个晴天。');
    await tester.pump();
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(boundary),
      matchesGoldenFile('../.qa-artifacts/screenshots/$shotName.png'),
    );
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);

  testWidgets('capture the same conversation in the two-pane shell', (
    WidgetTester tester,
  ) async {
    if (outputDir == null) {
      return;
    }
    final Uint8List? cjk = fontPath != null && File(fontPath).existsSync()
        ? File(fontPath).readAsBytesSync()
        : null;
    if (cjk != null) {
      await tester.runAsync(() async {
        for (final String family in <String>['Roboto', 'Ahem']) {
          await (FontLoader(
            family,
          )..addFont(Future<ByteData>.value(ByteData.view(cjk.buffer)))).load();
        }
      });
    }
    if (iconFontPath != null && File(iconFontPath).existsSync()) {
      final Uint8List icon = File(iconFontPath).readAsBytesSync();
      await tester.runAsync(() async {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future<ByteData>.value(ByteData.view(icon.buffer)))).load();
      });
    }

    final Uint8List photo = File('test/fixtures/media/horizon.png')
        .readAsBytesSync();
    final DateTime now = DateTime.now().toUtc();
    final List<ChatMessage> thread = <ChatMessage>[
      ChatMessage(
        id: 'd1',
        position: 1,
        senderAccount: '10000002',
        targetAccount: _self.account,
        createdAt: now.subtract(const Duration(minutes: 9)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('刚从海边回来。')],
      ),
      ChatMessage(
        id: 'd2',
        position: 2,
        senderAccount: '10000002',
        targetAccount: _self.account,
        createdAt: now.subtract(const Duration(minutes: 8)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('给你看今天的月亮。')],
      ),
      ChatMessage(
        id: 'd3',
        position: 3,
        senderAccount: '10000002',
        targetAccount: _self.account,
        createdAt: now.subtract(const Duration(minutes: 7)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[ImagePart('photo-1')],
      ),
      ChatMessage(
        id: 'd4',
        position: 4,
        senderAccount: _self.account,
        targetAccount: '10000002',
        createdAt: now.subtract(const Duration(minutes: 5)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('这个蓝色好漂亮。')],
      ),
    ];
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[
        ChatUser(
          account: '10000002',
          username: 'bob',
          avatarUrl: '/avatars/10000002.png',
          avatarVersion: 'v1',
          presence: Presence.online,
        ),
      ],
      conversations: <String, List<ChatMessage>>{'10000002': thread},
      png: photo,
    );
    final FakeProfileGateway profile = FakeProfileGateway();
    profile.avatars['10000001'] = selfIdenticon;
    profile.avatars['10000002'] = peerIdenticon;
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());

    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    final GlobalKey boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              displayFeatures: <DisplayFeature>[
                DisplayFeature(
                  bounds: const Rect.fromLTWH(492, 0, 40, 768),
                  type: DisplayFeatureType.hinge,
                  state: DisplayFeatureState.postureFlat,
                ),
              ],
            ),
            child: child!,
          ),
          home: HomeView(
            user: _self,
            profile: profile,
            auth: FakeAuthGateway(),
            heartbeat: heartbeat,
            chat: chat,
            space: FakeSpaceGateway(),
            onSignedOut: (LogoutResult? _) {},
            onSessionExpired: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(ChatComposer.inputKey), '好啊，等一个晴天。');
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(boundary),
      matchesGoldenFile(
        '../.qa-artifacts/screenshots/${shotName.replaceAll('-after', '')}-dual.png',
      ),
    );
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);
}
