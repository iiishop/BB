import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-489 acceptance through the real widget surface: per-conversation
/// incoming unread, nothing at zero, exact 1–99, 99+ from 100, own sends
/// excluded, entering clears that conversation only, and a later arrival shows
/// 1 again.
const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
final DateTime _now = DateTime.now().toUtc();

ChatUser _user(String account, String username) => ChatUser(
  account: account,
  username: username,
  avatarUrl: '/avatars/$account.png',
  avatarVersion: 'v1',
  presence: Presence.offline,
);

ChatMessage _message({
  required String id,
  required int position,
  required String sender,
  required String target,
  String text = 'hi',
}) {
  return ChatMessage(
    id: id,
    position: position,
    senderAccount: sender,
    targetAccount: target,
    createdAt: _now.subtract(Duration(minutes: 200 - position)),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart(text)],
  );
}

void main() {
  late FakeChatService chat;
  late HeartbeatController heartbeat;
  late FakeProfileGateway profile;
  final ChatUser bob = _user('10000002', 'bob');
  final ChatUser carol = _user('10000003', 'carol');
  final ChatUser dave = _user('10000004', 'dave');

  setUp(() {
    profile = FakeProfileGateway();
    heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
  });

  FakeChatService buildChat(Map<String, List<ChatMessage>> conversations) {
    return FakeChatService(
      self: _self,
      users: <ChatUser>[bob, carol, dave],
      conversations: conversations,
    );
  }

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

  Future<void> pumpAt(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  String? badgeOf(WidgetTester tester, String account) {
    final Finder finder = find.byKey(UsersListView.unreadKey(account));
    if (finder.evaluate().isEmpty) {
      return null;
    }
    return tester.widget<Text>(finder).data;
  }

  Future<void> pullToRefresh(WidgetTester tester) async {
    await tester.fling(
      find.byKey(UsersListView.listKey),
      const Offset(0, 320),
      1000,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('badges count peer inbound only, per conversation', (
    WidgetTester tester,
  ) async {
    chat = buildChat(<String, List<ChatMessage>>{
      bob.account: <ChatMessage>[
        _message(
          id: 'b1',
          position: 1,
          sender: bob.account,
          target: _self.account,
        ),
        _message(
          id: 'a2',
          position: 2,
          sender: _self.account,
          target: bob.account,
        ),
        _message(
          id: 'b3',
          position: 3,
          sender: bob.account,
          target: _self.account,
        ),
      ],
      carol.account: <ChatMessage>[
        _message(
          id: 'c1',
          position: 1,
          sender: carol.account,
          target: _self.account,
        ),
      ],
    });
    await pumpAt(tester);

    expect(
      badgeOf(tester, bob.account),
      '2',
      reason: 'own send is not counted',
    );
    expect(badgeOf(tester, carol.account), '1');
    expect(
      badgeOf(tester, dave.account),
      isNull,
      reason: 'no conversation means no badge, not a zero',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('boundary: 99 stays exact, 100 and above show 99+', (
    WidgetTester tester,
  ) async {
    List<ChatMessage> inbound(String peer, int count) => <ChatMessage>[
      for (int i = 1; i <= count; i++)
        _message(
          id: '$peer-$i',
          position: i,
          sender: peer,
          target: _self.account,
        ),
    ];
    chat = buildChat(<String, List<ChatMessage>>{
      bob.account: inbound(bob.account, 99),
      carol.account: inbound(carol.account, 100),
    });
    await pumpAt(tester);

    expect(badgeOf(tester, bob.account), '99');
    expect(badgeOf(tester, carol.account), '99+');
    expect(tester.takeException(), isNull);
  });

  testWidgets('entering clears only that conversation; own send adds none', (
    WidgetTester tester,
  ) async {
    chat = buildChat(<String, List<ChatMessage>>{
      bob.account: <ChatMessage>[
        _message(
          id: 'b1',
          position: 1,
          sender: bob.account,
          target: _self.account,
        ),
        _message(
          id: 'b3',
          position: 3,
          sender: bob.account,
          target: _self.account,
        ),
      ],
      carol.account: <ChatMessage>[
        _message(
          id: 'c1',
          position: 1,
          sender: carol.account,
          target: _self.account,
        ),
      ],
    });
    await pumpAt(tester);
    expect(badgeOf(tester, bob.account), '2');

    await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);

    await tester.enterText(find.byKey(ChatComposer.inputKey), '我发出的消息');
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pumpAndSettle();
    expect(chat.sentTexts, contains('我发出的消息'));

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      badgeOf(tester, bob.account),
      isNull,
      reason: 'entering clears; the later own send is not unread either',
    );
    expect(
      badgeOf(tester, carol.account),
      '1',
      reason: 'another conversation is untouched',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving then receiving one new message shows 1 again', (
    WidgetTester tester,
  ) async {
    chat = buildChat(<String, List<ChatMessage>>{
      bob.account: <ChatMessage>[
        _message(
          id: 'b1',
          position: 1,
          sender: bob.account,
          target: _self.account,
        ),
      ],
      carol.account: <ChatMessage>[
        _message(
          id: 'c1',
          position: 1,
          sender: carol.account,
          target: _self.account,
        ),
      ],
    });
    await pumpAt(tester);
    expect(badgeOf(tester, bob.account), '1');

    await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(badgeOf(tester, bob.account), isNull);

    // The other side sends once after the reader left.
    chat.conversations[bob.account]!.add(
      _message(
        id: 'b4',
        position: 4,
        sender: bob.account,
        target: _self.account,
        text: '离开后的一条',
      ),
    );
    await pullToRefresh(tester);

    expect(badgeOf(tester, bob.account), '1');
    expect(badgeOf(tester, carol.account), '1');
    expect(tester.takeException(), isNull);
  });
}
