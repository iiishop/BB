import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/chat_workspace.dart';
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

/// Opt-in DEA-493 evidence: split layout, foldable expansion frames, keyboard
/// frames and the new-message pill. Widget-test renders, not device captures.
///
/// `QA_CHAT_SCREENSHOT_DIR=.qa-artifacts/screenshots \
///  QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///  QA_ICON_FONT=.../MaterialIcons-Regular.otf \
///  flutter test test/chat_transition_screenshot_test.dart --update-goldens`
void main() {
  final String? outputDir = Platform.environment['QA_CHAT_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_CHAT_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  late FakeChatService chat;
  late FakeProfileGateway profile;
  late HeartbeatController heartbeat;
  late GlobalKey boundary;

  final DateTime now = DateTime.now().toUtc();
  final ChatUser bob = ChatUser(
    account: '10000002',
    username: 'bob',
    avatarUrl: '/avatars/10000002.png',
    avatarVersion: 'v1',
    presence: Presence.online,
    lastContactAt: now.subtract(const Duration(minutes: 2)),
    lastMessage: const UserPreview(
      id: 'm20',
      senderAccount: '10000002',
      senderUsername: 'bob',
      previewBody: '海边日落.mp4',
    ),
  );
  final ChatUser carol = ChatUser(
    account: '10000003',
    username: 'carol',
    avatarUrl: '/avatars/10000003.png',
    avatarVersion: 'v1',
    presence: Presence.offline,
  );
  final ChatUser dave = ChatUser(
    account: '10000004',
    username: 'dave',
    avatarUrl: '/avatars/10000004.png',
    avatarVersion: 'v1',
    presence: Presence.offline,
  );

  ChatMessage text(int position, {required String sender, String? body}) {
    return ChatMessage(
      id: 'm$position',
      position: position,
      senderAccount: sender,
      targetAccount: sender == _self.account ? bob.account : _self.account,
      createdAt: now.subtract(Duration(minutes: 40 - position)),
      kind: ChatMessageKind.body,
      parts: <MessagePart>[TextPart(body ?? '消息 $position')],
    );
  }

  void buildChat() {
    final List<ChatMessage> thread = <ChatMessage>[
      text(1, sender: bob.account, body: '到了吗？我带了两张照片。'),
      ChatMessage(
        id: 'm2',
        position: 2,
        senderAccount: _self.account,
        targetAccount: bob.account,
        createdAt: now.subtract(const Duration(minutes: 30)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[
          TextPart('刚出门，先看这张'),
          ImagePart('img-1'),
          TextPart('还有这张，顺序别弄反了。'),
          ImagePart('img-2'),
        ],
      ),
      text(3, sender: bob.account, body: '收到，路上慢点。'),
      text(4, sender: bob.account, body: '我把视频也发你。'),
      ChatMessage(
        id: 'm5',
        position: 5,
        senderAccount: bob.account,
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
      for (int position = 6; position <= 20; position += 1)
        text(
          position,
          sender: position.isEven ? _self.account : bob.account,
          body: position.isEven ? '我这边的第 $position 条' : '路上的第 $position 条',
        ),
    ];
    chat = FakeChatService(
      self: _self,
      users: <ChatUser>[bob, carol, dave],
      conversations: <String, List<ChatMessage>>{
        bob.account: thread,
        carol.account: <ChatMessage>[
          text(1, sender: carol.account, body: 'carol 的历史消息'),
        ],
      },
    );
    profile = FakeProfileGateway();
    profile.profile = const Profile(
      account: '10000001',
      username: 'alice',
      signature: null,
      avatarUrl: '/avatars/10000001.png',
      avatarVersion: 'v-alice',
    );
    profile.avatars['10000001'] = selfIdenticon;
    profile.avatars['10000002'] = peerIdenticon;
    heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
  }

  setUp(() {
    buildChat();
    boundary = GlobalKey();
  });

  tearDown(() {
    heartbeat.dispose();
  });

  Future<void> loadFonts(WidgetTester tester) async {
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
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await expectLater(
      find.byKey(boundary),
      matchesGoldenFile('../.qa-artifacts/screenshots/$name'),
    );
  }

  testWidgets('capture split, foldable and restored layouts', (
    WidgetTester tester,
  ) async {
    if (outputDir == null) {
      return;
    }
    await loadFonts(tester);

    Future<void> pumpApp(
      Size size, {
      List<DisplayFeature> features = const <DisplayFeature>[],
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding.zero;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
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
              profile: profile,
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
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    await pumpApp(const Size(1440, 900));
    expect(find.byType(ChatWorkspace), findsOneWidget);
    await capture(tester, 'dea493-workspace-dual.png');

    final DisplayFeature hinge = DisplayFeature(
      bounds: const Rect.fromLTWH(492, 0, 40, 768),
      type: DisplayFeatureType.hinge,
      state: DisplayFeatureState.postureFlat,
    );
    await pumpApp(const Size(1024, 768), features: <DisplayFeature>[hinge]);
    await capture(tester, 'dea493-foldable-dual.png');

    final Finder toggle = find.byKey(ChatWorkspace.toggleKey);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(0, 0.1),
    );
    await capture(tester, 'dea493-foldable-full.png');

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await capture(tester, 'dea493-foldable-restored.png');
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);

  testWidgets('capture fold animation frames and keyboard frames', (
    WidgetTester tester,
  ) async {
    if (outputDir == null) {
      return;
    }
    await loadFonts(tester);

    final DisplayFeature hinge = DisplayFeature(
      bounds: const Rect.fromLTWH(492, 0, 40, 768),
      type: DisplayFeatureType.hinge,
      state: DisplayFeatureState.postureFlat,
    );
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(displayFeatures: <DisplayFeature>[hinge]),
            child: child!,
          ),
          home: HomeView(
            user: _self,
            profile: profile,
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
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    await tester.tap(find.byKey(ChatWorkspace.toggleKey));
    for (int frame = 0; frame <= 13; frame += 1) {
      await tester.pump(const Duration(milliseconds: 30));
      await capture(
        tester,
        'dea493-fold-${frame.toString().padLeft(2, '0')}.png',
      );
    }

    // Keyboard frames on the phone conversation.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme().copyWith(platform: TargetPlatform.android),
          home: ChatPage(peer: bob, chat: chat, profile: profile),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await capture(tester, 'dea493-keyboard-closed.png');

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    for (int frame = 0; frame <= 10; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      await capture(
        tester,
        'dea493-keyboard-${frame.toString().padLeft(2, '0')}.png',
      );
    }

    // History + keyboard open: reading position must not jump.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 420));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await capture(tester, 'dea493-keyboard-history-open.png');
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);

  testWidgets('capture the new-message pill while reading history', (
    WidgetTester tester,
  ) async {
    if (outputDir == null) {
      return;
    }
    await loadFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme().copyWith(platform: TargetPlatform.android),
          home: ChatPage(peer: bob, chat: chat, profile: profile),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 500));
    await tester.pumpAndSettle();
    chat.conversations[bob.account]!.add(
      text(21, sender: bob.account, body: '你还在看旧消息吗？'),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(ChatPage.newMessagesKey), findsOneWidget);
    await capture(tester, 'dea493-new-messages-pill.png');
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);

  testWidgets('capture the signed-in shell fold over the navigation rail', (
    WidgetTester tester,
  ) async {
    if (outputDir == null) {
      return;
    }
    await loadFonts(tester);

    final DisplayFeature hinge = DisplayFeature(
      bounds: const Rect.fromLTWH(492, 0, 40, 768),
      type: DisplayFeatureType.hinge,
      state: DisplayFeatureState.postureFlat,
    );
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(displayFeatures: <DisplayFeature>[hinge]),
            child: child!,
          ),
          // The real signed-in shell, so the 92 px rail is in frame: this is
          // the surface QA measured, not the workspace alone.
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
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await capture(tester, 'dea493-shell-dual.png');

    await tester.tap(find.byKey(ChatWorkspace.toggleKey));
    for (int frame = 0; frame <= 13; frame += 1) {
      await tester.pump(const Duration(milliseconds: 30));
      await capture(
        tester,
        'dea493-shell-fold-${frame.toString().padLeft(2, '0')}.png',
      );
    }
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(0, 0.1),
    );
    await capture(tester, 'dea493-shell-full.png');

    await tester.tap(find.byKey(ChatWorkspace.toggleKey));
    await tester.pumpAndSettle();
    await capture(tester, 'dea493-shell-restored.png');
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(hinge.bounds.right, 0.5),
    );
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);

  testWidgets('capture the narrow unfolded shell over the rail', (
    WidgetTester tester,
  ) async {
    if (outputDir == null) {
      return;
    }
    await loadFonts(tester);

    final DisplayFeature fold = DisplayFeature(
      bounds: const Rect.fromLTWH(400, 0, 0, 840),
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureFlat,
    );
    tester.view.physicalSize = const Size(800, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(displayFeatures: <DisplayFeature>[fold]),
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
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // The 800 px unfolded screen keeps two panes next to the 92 px rail.
    final Finder toggle = find.byKey(ChatWorkspace.toggleKey);
    expect(toggle, findsOneWidget);
    await capture(tester, 'dea493-shell-800-dual.png');

    await tester.tap(toggle);
    for (int frame = 0; frame <= 9; frame += 1) {
      await tester.pump(const Duration(milliseconds: 30));
      await capture(
        tester,
        'dea493-shell-800-fold-${frame.toString().padLeft(2, '0')}.png',
      );
    }
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(0, 0.1),
    );
    await capture(tester, 'dea493-shell-800-full.png');
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);

  testWidgets('capture a narrow physical hinge: grip on the touchable side', (
    WidgetTester tester,
  ) async {
    if (outputDir == null) {
      return;
    }
    await loadFonts(tester);

    // Flutter reports a 4 lp physical gap as DisplayFeatureType.hinge. The
    // grip must stay off that strip, unlike a zero-width fold crease.
    final DisplayFeature hinge = DisplayFeature(
      bounds: const Rect.fromLTWH(510, 0, 4, 768),
      type: DisplayFeatureType.hinge,
      state: DisplayFeatureState.postureFlat,
    );
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(displayFeatures: <DisplayFeature>[hinge]),
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
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(
      tester
          .getRect(find.byKey(ChatWorkspace.toggleKey))
          .overlaps(hinge.bounds),
      isFalse,
    );
    await capture(tester, 'dea493-hinge4-dual.png');
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
