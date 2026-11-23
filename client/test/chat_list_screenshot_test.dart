import 'dart:io';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/profile_models.dart';
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

import 'support/avatar_fixtures.dart';
import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-494 visual evidence for the shared conversation list.
///
/// Opt-in because it writes files:
/// `QA_CHAT_SCREENSHOT_DIR=.qa-artifacts/screenshots \
///  QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///  QA_ICON_FONT=.../MaterialIcons-Regular.otf \
///  flutter test test/chat_list_screenshot_test.dart --update-goldens`
///
/// The last two captures are a review harness, not a production route: the
/// real two-pane shell belongs to DEA-493, and this test only places the same
/// shared list in a 400px left cell next to the existing ChatPage so the note
/// can be reviewed in its intended placement.
const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

void main() {
  final String? outputDir = Platform.environment['QA_CHAT_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_CHAT_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture the conversation list on phone and as a left column', (
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
    ChatUser user(
      String account,
      String username,
      Presence presence, {
      UserPreview? lastMessage,
      DateTime? lastContactAt,
    }) {
      return ChatUser(
        account: account,
        username: username,
        avatarUrl: '/avatars/$account.png',
        avatarVersion: 'v1',
        presence: presence,
        lastMessage: lastMessage,
        lastContactAt: lastContactAt,
      );
    }

    final ChatUser bob = user(
      '10000002',
      '星依',
      Presence.online,
      lastContactAt: now.subtract(const Duration(minutes: 2)),
      lastMessage: const UserPreview(
        id: 'm-bob',
        senderAccount: '10000002',
        senderUsername: '星依',
        previewBody: '给你看今天的月亮。',
      ),
    );
    final ChatUser carol = user(
      '10000003',
      '林晚',
      Presence.offline,
      lastContactAt: now.subtract(const Duration(minutes: 28)),
      lastMessage: const UserPreview(
        id: 'm-carol',
        senderAccount: '10000003',
        senderUsername: '林晚',
        previewBody: '明天的会议材料发你了',
      ),
    );
    final ChatUser dave = user(
      '10000004',
      '周予安',
      Presence.online,
      lastContactAt: now.subtract(const Duration(minutes: 66)),
      lastMessage: const UserPreview(
        id: 'm-dave',
        senderAccount: '10000004',
        senderUsername: '周予安',
        previewBody: '好的，收到',
      ),
    );
    final ChatUser erin = user(
      '10000005',
      '苏念',
      Presence.online,
      lastContactAt: now.subtract(const Duration(minutes: 88)),
      lastMessage: const UserPreview(
        id: 'm-erin',
        senderAccount: '10000005',
        senderUsername: '苏念',
        previewBody: '周末有空一起去看展吗？',
      ),
    );

    ChatMessage message({
      required String id,
      required int position,
      required String sender,
      required String target,
      required String text,
    }) {
      return ChatMessage(
        id: id,
        position: position,
        senderAccount: sender,
        targetAccount: target,
        createdAt: now.subtract(Duration(minutes: 60 - position)),
        kind: ChatMessageKind.body,
        parts: <MessagePart>[TextPart(text)],
      );
    }

    final FakeChatService chat = FakeChatService(
      self: _self,
      users: <ChatUser>[bob, carol, dave, erin],
      conversations: <String, List<ChatMessage>>{
        '10000002': <ChatMessage>[
          message(
            id: 'b1',
            position: 1,
            sender: '10000002',
            target: _self.account,
            text: '今晚的月亮很亮，拍给你看。',
          ),
          message(
            id: 'b2',
            position: 2,
            sender: _self.account,
            target: '10000002',
            text: '看到了，像一枚安静的印章。',
          ),
        ],
      },
    );
    final FakeProfileGateway profile = FakeProfileGateway();
    profile.profile = const Profile(
      account: '10000001',
      username: 'alice',
      signature: null,
      avatarUrl: '/avatars/10000001.png',
      avatarVersion: 'v-alice',
    );
    profile.avatars['10000001'] = selfIdenticon;
    profile.avatars['10000002'] = peerIdenticon;
    profile.avatars['10000003'] = peerReplacedAvatar;
    profile.avatars['10000004'] = selfIdenticon;
    profile.avatars['10000005'] = peerReplacedAvatar;
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
    final GlobalKey boundary = GlobalKey();

    Future<void> pump(Widget child, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            home: child,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await expectLater(
        find.byKey(boundary),
        matchesGoldenFile('../.qa-artifacts/screenshots/$name'),
      );
    }

    // Phone list page: the same list as before a conversation is opened. No row
    // is current yet, so no note is invented.
    await pump(
      HomeView(
        user: _self,
        profile: profile,
        auth: FakeAuthGateway(),
        heartbeat: heartbeat,
        chat: chat,
        onSignedOut: (LogoutResult? _) {},
        onSessionExpired: () {},
      ),
      const Size(390, 844),
    );
    await capture('dea494-list-phone.png');

    // Return from the conversation: the phone list keeps the note on 星依.
    await tester.tap(find.byKey(UsersListView.rowKey('10000002')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(UsersListView.noteKey('10000002')), findsOneWidget);
    await capture('dea494-list-phone-selected.png');

    Widget rail() {
      return SafeArea(
        child: UsersListView(
          chat: chat,
          profile: profile,
          selectedAccount: '10000002',
          onOpenChat: (ChatUser user) async {},
        ),
      );
    }

    // The shared list as the wide shell's left column, in a 400px cell.
    await pump(
      Scaffold(
        backgroundColor: AppColors.paper,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 844,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: AppColors.border)),
              ),
              child: rail(),
            ),
          ),
        ),
      ),
      const Size(400, 844),
    );
    await capture('dea494-list-left-column.png');

    // Review harness only: the real two-pane shell is DEA-493. This places the
    // same list next to the existing ChatPage so the note's placement and the
    // selected conversation can be seen together.
    await pump(
      Scaffold(
        backgroundColor: AppColors.paper,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: 400,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(right: BorderSide(color: AppColors.border)),
                ),
                child: rail(),
              ),
            ),
            Expanded(
              child: ChatPage(peer: bob, chat: chat, profile: profile),
            ),
          ],
        ),
      ),
      const Size(1440, 900),
    );
    await capture('dea494-list-dual-column.png');

    for (final String name in <String>[
      'dea494-list-phone.png',
      'dea494-list-phone-selected.png',
      'dea494-list-left-column.png',
      'dea494-list-dual-column.png',
    ]) {
      expect(
        File('${directory.path}${Platform.pathSeparator}$name').existsSync(),
        isTrue,
      );
    }
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);
}
