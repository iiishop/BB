import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/widgets/profile_avatar.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

ChatMessage _message(int position, {required String sender, String? text}) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: sender,
    targetAccount: sender == _self.account ? '10000002' : _self.account,
    createdAt: DateTime.now().toUtc(),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart(text ?? '消息 $position')],
  );
}

void main() {
  late FakeChatService chat;
  late FakeProfileGateway profile;
  late HeartbeatController heartbeat;

  const ChatUser bob = ChatUser(
    account: '10000002',
    username: 'bob',
    avatarUrl: '/avatars/10000002.png',
    avatarVersion: 'v1',
    presence: Presence.online,
  );
  const ChatUser carol = ChatUser(
    account: '10000003',
    username: 'carol',
    avatarUrl: '/avatars/10000003.png',
    avatarVersion: 'v1',
    presence: Presence.offline,
  );

  setUp(() {
    chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[bob, carol],
      conversations: <String, List<ChatMessage>>{
        bob.account: <ChatMessage>[
          for (int position = 1; position <= 6; position += 1)
            _message(
              position,
              sender: position.isEven ? _self.account : bob.account,
            ),
        ],
        carol.account: <ChatMessage>[_message(1, sender: carol.account)],
      },
    );
    profile = FakeProfileGateway();
    heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
  });

  Widget app() {
    return MaterialApp(
      theme: buildAppTheme(),
      home: HomeView(
        user: _self,
        profile: profile,
        auth: FakeAuthGateway(),
        heartbeat: heartbeat,
        chat: chat,
        onSignedOut: (LogoutResult? _) {},
        onSessionExpired: () {},
      ),
    );
  }

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  String headerName(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(ChatPage.headerNameKey)).data ?? '';
  String headerStatus(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(ChatPage.headerStatusKey)).data ?? '';
  Color? headerStatusColor(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(ChatPage.headerStatusKey)).style?.color;

  testWidgets('the phone header is back, avatar, name over status, refresh', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(390, 844));
    await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
    await tester.pumpAndSettle();

    // Back navigation comes first, then the peer avatar.
    expect(find.byType(BackButton), findsOneWidget);
    final Finder avatar = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(ProfileAvatar),
    );
    expect(avatar, findsOneWidget);
    expect(tester.widget<ProfileAvatar>(avatar).size, 48);
    expect(
      tester.getRect(find.byType(BackButton)).right,
      lessThan(tester.getRect(avatar).left),
      reason: 'back sits left of the avatar',
    );

    // Name above, live presence below, both from the conversation object.
    expect(headerName(tester), 'bob');
    expect(headerStatus(tester), '在线');
    expect(headerStatusColor(tester), AppColors.accent);
    expect(
      tester.getRect(find.byKey(ChatPage.headerNameKey)).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(ChatPage.headerStatusKey)).top,
      ),
    );
    expect(
      tester.getRect(avatar).right,
      lessThan(tester.getRect(find.byKey(ChatPage.headerNameKey)).left),
      reason: 'the two text lines sit to the right of the avatar',
    );

    // The existing refresh action stays; the reference's art and the
    // three-dot menu are intentionally absent.
    expect(find.byKey(ChatPage.refreshKey), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back returns to the list and refresh re-reads the thread', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(390, 844));
    await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
    await tester.pumpAndSettle();

    final int loadsBefore = chat.conversationCalls.length;
    await tester.tap(find.byKey(ChatPage.refreshKey));
    await tester.pumpAndSettle();
    expect(
      chat.conversationCalls.length,
      greaterThan(loadsBefore),
      reason: 'the header refresh keeps its original reload behaviour',
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsNothing);
    expect(find.byKey(UsersListView.listKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the split header follows the selected conversation', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(1280, 900));
    // The split surface auto-selects the first conversation.
    expect(find.byType(ChatPage), findsOneWidget);
    expect(headerName(tester), 'bob');
    expect(headerStatus(tester), '在线');
    // Embedded navigation: no back control, refresh stays.
    expect(find.byType(BackButton), findsNothing);
    expect(find.byKey(ChatPage.refreshKey), findsOneWidget);

    await tester.tap(find.byKey(UsersListView.rowKey(carol.account)));
    await tester.pumpAndSettle();
    expect(headerName(tester), 'carol');
    expect(headerStatus(tester), '离线');
    expect(headerStatusColor(tester), AppColors.inkMuted);
    expect(find.byType(BackButton), findsNothing);
    expect(find.byKey(ChatPage.refreshKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
