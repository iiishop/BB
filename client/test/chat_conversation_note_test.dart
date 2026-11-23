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
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-494 through the real shared list widget: the current conversation is the
/// only row wrapped in the light-teal note (with its short left tail); the
/// avatar dot, unread number and selection stay independent; and the same
/// widget renders as the wide shell's left column without a second variant.
const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
final DateTime _now = DateTime.now().toUtc();

const String _bob = '10000002';
const String _carol = '10000003';
const String _dave = '10000004';

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

ChatUser _bobUser() => _user(
  _bob,
  'bob',
  Presence.online,
  lastContactAt: _now.subtract(const Duration(minutes: 2)),
  lastMessage: const UserPreview(
    id: 'm-bob',
    senderAccount: _bob,
    senderUsername: 'bob',
    previewBody: '晚上见',
  ),
);

ChatUser _carolUser() => _user(
  _carol,
  'carol',
  Presence.offline,
  lastContactAt: _now.subtract(const Duration(minutes: 5)),
  lastMessage: const UserPreview(
    id: 'm-carol',
    senderAccount: _carol,
    senderUsername: 'carol',
    previewBody: '早点回',
  ),
);

ChatUser _daveUser() => _user(_dave, 'dave', Presence.online);

ChatMessage _message({
  required String id,
  required int position,
  required String sender,
  required String target,
}) {
  return ChatMessage(
    id: id,
    position: position,
    senderAccount: sender,
    targetAccount: target,
    createdAt: _now.subtract(Duration(minutes: 100 - position)),
    kind: ChatMessageKind.body,
    parts: const <MessagePart>[TextPart('hi')],
  );
}

void main() {
  late FakeChatService chat;
  late FakeProfileGateway profile;

  setUp(() {
    chat = FakeChatService(
      self: _self,
      users: <ChatUser>[_bobUser(), _carolUser(), _daveUser()],
      conversations: <String, List<ChatMessage>>{
        _bob: <ChatMessage>[
          _message(id: 'b1', position: 1, sender: _bob, target: _self.account),
          _message(id: 'b2', position: 2, sender: _bob, target: _self.account),
        ],
        _carol: <ChatMessage>[
          _message(
            id: 'c1',
            position: 1,
            sender: _carol,
            target: _self.account,
          ),
        ],
      },
    );
    profile = FakeProfileGateway();
  });

  Widget listOnly({String? selected, required double width}) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.paper,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 844,
            child: UsersListView(
              chat: chat,
              profile: profile,
              selectedAccount: selected,
              onOpenChat: (ChatUser user) async {},
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpList(
    WidgetTester tester, {
    String? selected,
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(listOnly(selected: selected, width: width));
    await tester.pumpAndSettle();
  }

  String? unreadText(WidgetTester tester, String account) {
    final Finder finder = find.byKey(UsersListView.unreadKey(account));
    if (finder.evaluate().isEmpty) {
      return null;
    }
    return tester.widget<Text>(finder).data;
  }

  testWidgets('only the current conversation is wrapped in the note', (
    WidgetTester tester,
  ) async {
    await pumpList(tester, selected: _bob);

    expect(find.byKey(UsersListView.noteKey(_bob)), findsOneWidget);
    expect(find.byKey(UsersListView.noteKey(_carol)), findsNothing);
    expect(find.byKey(UsersListView.noteKey(_dave)), findsNothing);

    final Rect avatar = tester.getRect(
      find.byKey(UsersListView.avatarKey(_bob)),
    );
    final Rect note = tester.getRect(find.byKey(UsersListView.noteKey(_bob)));
    final Rect row = tester.getRect(find.byKey(UsersListView.rowKey(_bob)));
    // The avatar stays outside the note, and the note's left tail points back
    // across the gap instead of being painted under the avatar.
    expect(note.left, greaterThan(avatar.right));
    expect(note.right, lessThanOrEqualTo(row.right));
    expect(note.top, lessThan(row.center.dy));
    expect(note.bottom, greaterThan(row.center.dy));

    // A row with no selection keeps the paper background: no note at all.
    final Finder carolRow = find.byKey(UsersListView.rowKey(_carol));
    expect(
      find.descendant(of: carolRow, matching: find.byType(Ink)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('online dot, unread number and the note are independent', (
    WidgetTester tester,
  ) async {
    await pumpList(tester, selected: _bob);

    // Selected, online and unread all together: three separate facts.
    expect(find.byKey(UsersListView.noteKey(_bob)), findsOneWidget);
    expect(find.byKey(UsersListView.presenceDotKey(_bob)), findsOneWidget);
    expect(unreadText(tester, _bob), '2');
    expect(find.byKey(UsersListView.presenceDotKey(_carol)), findsNothing);
    expect(unreadText(tester, _carol), '1');
    expect(find.byKey(UsersListView.presenceDotKey(_dave)), findsOneWidget);
    expect(unreadText(tester, _dave), isNull);

    // Move the selection to an offline peer: the note follows, the dot stays
    // absent and the unread count is unchanged.
    await tester.pumpWidget(listOnly(selected: _carol, width: 390));
    await tester.pumpAndSettle();
    expect(find.byKey(UsersListView.noteKey(_bob)), findsNothing);
    expect(find.byKey(UsersListView.noteKey(_carol)), findsOneWidget);
    expect(find.byKey(UsersListView.presenceDotKey(_carol)), findsNothing);
    expect(unreadText(tester, _carol), '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection is stored by account and survives a reorder', (
    WidgetTester tester,
  ) async {
    await pumpList(tester, selected: _bob);
    expect(
      tester.getTopLeft(find.byKey(UsersListView.rowKey(_bob))).dy,
      lessThan(tester.getTopLeft(find.byKey(UsersListView.rowKey(_carol))).dy),
    );

    // A newer message for carol puts her first; the selected conversation is
    // still bob, addressed by account rather than the old row number.
    chat.users[1] = _user(
      _carol,
      'carol',
      Presence.offline,
      lastContactAt: _now.subtract(const Duration(minutes: 1)),
      lastMessage: const UserPreview(
        id: 'm-carol-new',
        senderAccount: _carol,
        senderUsername: 'carol',
        previewBody: '刚发的消息',
      ),
    );
    chat.users[0] = _user(
      _bob,
      'bob',
      Presence.online,
      lastContactAt: _now.subtract(const Duration(minutes: 30)),
      lastMessage: const UserPreview(
        id: 'm-bob',
        senderAccount: _bob,
        senderUsername: 'bob',
        previewBody: '晚上见',
      ),
    );
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(UsersListView.rowKey(_carol))).dy,
      lessThan(tester.getTopLeft(find.byKey(UsersListView.rowKey(_bob))).dy),
    );
    expect(
      find.descendant(
        of: find.byKey(UsersListView.rowKey(_bob)),
        matching: find.byKey(UsersListView.noteKey(_bob)),
      ),
      findsOneWidget,
    );
    expect(find.byKey(UsersListView.noteKey(_carol)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the phone list keeps the note on the conversation just opened', (
    WidgetTester tester,
  ) async {
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(UsersListView.noteKey(_bob)), findsNothing);
    await tester.tap(find.byKey(UsersListView.rowKey(_bob)));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(UsersListView.noteKey(_bob)), findsOneWidget);
    expect(find.byKey(UsersListView.noteKey(_carol)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the shared list renders as a narrow left column without overflow',
    (WidgetTester tester) async {
      chat.users[0] = _user(
        _bob,
        'bob-a-very-long-display-name-that-must-not-push-the-time',
        Presence.online,
        lastContactAt: _now.subtract(const Duration(minutes: 2)),
        lastMessage: const UserPreview(
          id: 'm-bob',
          senderAccount: _bob,
          senderUsername: 'bob',
          previewBody:
              '这是一条很长的最后消息预览，用来确认左栏在窄宽度下仍然保持单行省略，'
              '不会把时间或未读数字挤出可见区域。',
        ),
      );
      await pumpList(tester, selected: _bob, width: 380);

      final Finder note = find.byKey(UsersListView.noteKey(_bob));
      expect(note, findsOneWidget);
      expect(tester.getRect(note).right, lessThanOrEqualTo(380));
      expect(tester.takeException(), isNull);

      final Finder name = find.text(
        'bob-a-very-long-display-name-that-must-not-push-the-time',
      );
      expect(tester.widget<Text>(name).overflow, TextOverflow.ellipsis);

      // An even tighter pane still keeps the note, unread badge and dot inside.
      await tester.pumpWidget(listOnly(selected: _bob, width: 320));
      await tester.pumpAndSettle();
      expect(find.byKey(UsersListView.noteKey(_bob)), findsOneWidget);
      expect(
        tester.getRect(find.byKey(UsersListView.noteKey(_bob))).right,
        lessThanOrEqualTo(320),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'filtering hides and restores the selected row without losing it',
    (WidgetTester tester) async {
      await pumpList(tester, selected: _carol);
      expect(find.byKey(UsersListView.noteKey(_carol)), findsOneWidget);

      await tester.tap(find.byKey(UsersListView.onlineOnlyKey));
      await tester.pumpAndSettle();
      expect(find.byKey(UsersListView.rowKey(_carol)), findsNothing);
      expect(find.byKey(UsersListView.noteKey(_carol)), findsNothing);
      expect(unreadText(tester, _carol), isNull);

      await tester.tap(find.byKey(UsersListView.onlineOnlyKey));
      await tester.pumpAndSettle();
      expect(find.byKey(UsersListView.rowKey(_carol)), findsOneWidget);
      expect(find.byKey(UsersListView.noteKey(_carol)), findsOneWidget);
      expect(unreadText(tester, _carol), '1');
      expect(tester.takeException(), isNull);
    },
  );
}
