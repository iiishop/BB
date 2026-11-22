import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-491 step 2 through the real widget surface: the list's 只看在线 switch is
/// off by default, filters on the same last-confirmed presence the row badge
/// renders, reacts to the next refresh, keeps the recent-message order and never
/// clears server-derived unread counts.
const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
final DateTime _now = DateTime.now().toUtc();

ChatUser _user(
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

const String _bob = '10000002';
const String _carol = '10000003';
const String _dave = '10000004';

ChatUser _bobUser(Presence presence) => _user(
  _bob,
  'bob',
  presence,
  lastContactAt: _now.subtract(const Duration(minutes: 6)),
  lastMessage: const UserPreview(
    id: 'm-bob',
    senderAccount: _bob,
    senderUsername: 'bob',
    previewBody: '五点见',
  ),
);

ChatUser _carolUser(Presence presence) => _user(
  _carol,
  'carol',
  presence,
  lastContactAt: _now.subtract(const Duration(minutes: 2)),
  lastMessage: const UserPreview(
    id: 'm-carol',
    senderAccount: _carol,
    senderUsername: 'carol',
    previewBody: '早点回',
  ),
);

ChatUser _daveUser(Presence presence) => _user(_dave, 'dave', presence);

void main() {
  late FakeChatService chat;
  late FakeProfileGateway profile;
  late HeartbeatController heartbeat;

  setUp(() {
    chat = FakeChatService(
      self: _self,
      users: <ChatUser>[
        _bobUser(Presence.online),
        _carolUser(Presence.offline),
        _daveUser(Presence.online),
      ],
      conversations: <String, List<ChatMessage>>{
        _bob: <ChatMessage>[
          _message(id: 'u1', position: 1, sender: _bob, target: _self.account),
          _message(id: 'u2', position: 2, sender: _bob, target: _self.account),
        ],
        _carol: <ChatMessage>[
          _message(
            id: 'u3',
            position: 1,
            sender: _carol,
            target: _self.account,
          ),
        ],
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

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  String? unreadLabel(WidgetTester tester, String account) {
    final Finder finder = find.byKey(UsersListView.unreadKey(account));
    if (finder.evaluate().isEmpty) {
      return null;
    }
    return tester.widget<Text>(finder).data;
  }

  Future<void> toggleFilter(WidgetTester tester) async {
    await tester.tap(find.byKey(UsersListView.onlineOnlyKey));
    await tester.pumpAndSettle();
  }

  testWidgets('defaults to every conversation and filters only online while '
      'keeping the last-message order and unread counts', (
    WidgetTester tester,
  ) async {
    await pumpHome(tester);

    expect(
      tester.widget<Switch>(find.byKey(UsersListView.onlineOnlyKey)).value,
      isFalse,
    );
    expect(find.byKey(UsersListView.rowKey(_bob)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_carol)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_dave)), findsOneWidget);
    // Recent-message order: carol (2m) then bob (6m), never-contacted dave last.
    expect(
      tester.getTopLeft(find.byKey(UsersListView.rowKey(_carol))).dy,
      lessThan(tester.getTopLeft(find.byKey(UsersListView.rowKey(_bob))).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(UsersListView.rowKey(_bob))).dy,
      lessThan(tester.getTopLeft(find.byKey(UsersListView.rowKey(_dave))).dy),
    );
    expect(unreadLabel(tester, _bob), '2');
    expect(unreadLabel(tester, _carol), '1');

    await toggleFilter(tester);

    expect(find.byKey(UsersListView.rowKey(_bob)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_dave)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_carol)), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(UsersListView.rowKey(_bob))).dy,
      lessThan(tester.getTopLeft(find.byKey(UsersListView.rowKey(_dave))).dy),
      reason: 'filtering must not reorder the remaining rows',
    );
    expect(
      unreadLabel(tester, _bob),
      '2',
      reason: 'unread survives the filter',
    );

    await toggleFilter(tester);

    expect(find.byKey(UsersListView.rowKey(_carol)), findsOneWidget);
    expect(unreadLabel(tester, _carol), '1');
    expect(unreadLabel(tester, _bob), '2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the next refresh applies the newest presence while filtering', (
    WidgetTester tester,
  ) async {
    await pumpHome(tester);
    await toggleFilter(tester);
    expect(find.byKey(UsersListView.rowKey(_bob)), findsOneWidget);

    // bob stops heartbeating: the normal list refresh confirms offline and the
    // filtered view drops the row without touching the underlying order.
    chat.users[0] = _bobUser(Presence.offline);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byKey(UsersListView.rowKey(_bob)), findsNothing);

    // Back online on the next refresh, again without a manual toggle.
    chat.users[0] = _bobUser(Presence.online);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byKey(UsersListView.rowKey(_bob)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no online contacts shows the empty hint and the switch still '
      'restores the full list', (WidgetTester tester) async {
    chat.users[0] = _bobUser(Presence.offline);
    chat.users[2] = _daveUser(Presence.offline);
    await pumpHome(tester);
    await toggleFilter(tester);

    expect(find.byKey(UsersListView.onlineEmptyKey), findsOneWidget);
    expect(find.text('暂无在线联系人'), findsOneWidget);
    expect(find.byKey(UsersListView.onlineOnlyKey), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_bob)), findsNothing);

    // The switch stays operable from the empty state.
    await toggleFilter(tester);
    expect(find.byKey(UsersListView.onlineEmptyKey), findsNothing);
    expect(find.byKey(UsersListView.rowKey(_bob)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_carol)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_dave)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty directory shows the filtered hint only while the phone '
      'switch is enabled', (WidgetTester tester) async {
    // QA reproduction: only the signed-in account exists.
    chat.users.clear();
    await pumpHome(tester);
    expect(find.text('服务器上还没有其他注册用户'), findsOneWidget);
    expect(find.byKey(UsersListView.onlineEmptyKey), findsNothing);

    await toggleFilter(tester);
    expect(
      tester.widget<Switch>(find.byKey(UsersListView.onlineOnlyKey)).value,
      isTrue,
    );
    expect(find.byKey(UsersListView.onlineEmptyKey), findsOneWidget);
    expect(find.text('暂无在线联系人'), findsOneWidget);

    await toggleFilter(tester);
    expect(find.byKey(UsersListView.onlineEmptyKey), findsNothing);
    expect(find.text('服务器上还没有其他注册用户'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone filter is not applied on a wide layout and the full '
      'list returns', (WidgetTester tester) async {
    await pumpHome(tester);
    await toggleFilter(tester);
    expect(find.byKey(UsersListView.rowKey(_carol)), findsNothing);

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();

    expect(find.byKey(UsersListView.onlineOnlyKey), findsNothing);
    expect(find.text('只看在线'), findsNothing);
    expect(find.byKey(UsersListView.rowKey(_bob)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_carol)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(_dave)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
