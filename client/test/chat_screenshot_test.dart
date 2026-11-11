import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

/// Renders the STEP-3 users home and chat thread to PNG evidence.
///
/// Opt-in because it writes files:
/// `QA_CHAT_SCREENSHOT_DIR=.qa-artifacts/screenshots \
///  QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///  QA_ICON_FONT=.../MaterialIcons-Regular.otf \
///  flutter test test/chat_screenshot_test.dart --update-goldens`
///
/// Widget-test renders, not Android/Windows runtime screenshots.
void main() {
  final String? outputDir = Platform.environment['QA_CHAT_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_CHAT_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture users home and chat thread in three form factors', (
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

    final DateTime now = DateTime.now().toUtc();
    final List<ChatMessage> thread = <ChatMessage>[
      ChatMessage(
        id: 'm1',
        position: 1,
        senderAccount: '10000002',
        targetAccount: _self.account,
        createdAt: now.subtract(const Duration(minutes: 12)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('到了吗？我带了两张照片。')],
      ),
      ChatMessage(
        id: 'm2',
        position: 2,
        senderAccount: _self.account,
        targetAccount: '10000002',
        createdAt: now.subtract(const Duration(minutes: 11)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[
          TextPart('刚出门，先看这张'),
          ImagePart('img-1'),
          TextPart('还有这张，顺序别弄反了。'),
          ImagePart('img-2'),
        ],
      ),
      ChatMessage(
        id: 'm3',
        position: 3,
        senderAccount: '10000002',
        targetAccount: _self.account,
        createdAt: now.subtract(const Duration(minutes: 6)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('收到，路上慢点。')],
      ),
      ChatMessage(
        id: 'm4',
        position: 4,
        senderAccount: '10000002',
        targetAccount: _self.account,
        createdAt: now.subtract(const Duration(minutes: 4)),
        kind: ChatMessageKind.attachment,
        attachment: const Attachment(
          mediaId: 'video-1',
          kind: AttachmentKind.video,
          filename: '海边日落.mp4',
          mimeType: 'video/mp4',
          byteSize: 5 * 1024 * 1024,
          coverMediaId: 'cover-1',
        ),
      ),
    ];
    final List<ChatUser> users = <ChatUser>[
      ChatUser(
        account: '10000002',
        username: 'bob',
        avatarUrl: '/avatars/10000002.png',
        avatarVersion: 'v1',
        presence: Presence.online,
        lastContactAt: now.subtract(const Duration(minutes: 4)),
        lastMessage: const UserPreview(
          id: 'm4',
          senderAccount: '10000002',
          senderUsername: 'bob',
          previewBody: '[视频]海边日落.mp4',
        ),
      ),
      ChatUser(
        account: '10000003',
        username: 'carol',
        avatarUrl: '/avatars/10000003.png',
        avatarVersion: 'v1',
        presence: Presence.offline,
      ),
      ChatUser(
        account: '10000004',
        username: 'dave',
        avatarUrl: '/avatars/10000004.png',
        avatarVersion: 'v1',
        presence: Presence.online,
        lastContactAt: now.subtract(const Duration(days: 1)),
        lastMessage: const UserPreview(
          id: 'p1',
          senderAccount: '10000001',
          senderUsername: 'alice',
          previewBody: '明天见',
        ),
      ),
    ];
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: users,
      conversations: <String, List<ChatMessage>>{'10000002': thread},
    );
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
    final GlobalKey key = GlobalKey();

    Future<void> pumpAt(
      Size size, {
      List<DisplayFeature> features = const <DisplayFeature>[],
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(size: size, displayFeatures: features),
              child: child!,
            ),
            home: HomeView(
              user: _self,
              profile: FakeProfileGateway(),
              auth: FakeAuthGateway(),
              heartbeat: heartbeat,
              chat: chat,
              onSignedOut: (LogoutResult? _) {},
              onSessionExpired: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      // Image.memory decodes on an engine task; give it a real slice before
      // rasterizing so body images/cover are present in the evidence.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await expectLater(
        find.byKey(key),
        matchesGoldenFile('../.qa-artifacts/screenshots/$name'),
      );
    }

    await pumpAt(const Size(390, 844));
    await capture('chat-users-phone.png');

    await pumpAt(const Size(1440, 900));
    await capture('chat-users-wide.png');

    await pumpAt(
      const Size(1024, 768),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(512, 0, 0, 768),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await capture('chat-users-folded.png');

    await pumpAt(const Size(390, 844));
    await tester.tap(find.byKey(UsersListView.rowKey('10000002')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
    await capture('chat-thread-phone.png');

    await pumpAt(const Size(1440, 900));
    await tester.tap(find.byKey(UsersListView.rowKey('10000002')));
    await tester.pumpAndSettle();
    await capture('chat-thread-wide.png');

    await pumpAt(
      const Size(1024, 768),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(512, 0, 0, 768),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await tester.tap(find.byKey(UsersListView.rowKey('10000002')));
    await tester.pumpAndSettle();
    await capture('chat-thread-folded.png');

    for (final String name in <String>[
      'chat-users-phone.png',
      'chat-users-wide.png',
      'chat-users-folded.png',
      'chat-thread-phone.png',
      'chat-thread-wide.png',
      'chat-thread-folded.png',
    ]) {
      expect(
        File('${directory.path}${Platform.pathSeparator}$name').existsSync(),
        isTrue,
      );
    }
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);
}

ThemeData _theme() {
  final ThemeData base = buildAppTheme();
  TextStyle label(double size, FontWeight weight) {
    return TextStyle(
      fontFamily: 'Roboto',
      fontSize: size,
      fontWeight: weight,
      color: AppColors.surface,
    );
  }

  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle>(
          label(16, FontWeight.w600),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle>(
          label(14.5, FontWeight.w600).copyWith(color: AppColors.accent),
        ),
      ),
    ),
  );
}
