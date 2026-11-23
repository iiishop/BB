import 'dart:async';

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

/// Reproduction of DEA-476: an open conversation kept the presence snapshot it
/// was opened with, so a peer who logged in afterwards stayed "离线" in the
/// header until the user left and reopened the chat. The list's own 30s refresh
/// made the two surfaces disagree.
const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

ChatUser _peer(String account, String username, Presence presence) {
  return ChatUser(
    account: account,
    username: username,
    avatarUrl: '/avatars/$account.png',
    avatarVersion: 'v1',
    presence: presence,
  );
}

void main() {
  late FakeChatService chat;
  late FakeProfileGateway profile;
  late HeartbeatController heartbeat;

  setUp(() {
    chat = FakeChatService(
      self: _self,
      users: <ChatUser>[
        _peer('10000002', 'bob', Presence.offline),
        _peer('10000003', 'carol', Presence.offline),
      ],
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

  Future<void> openPeer(WidgetTester tester, String account) async {
    await tester.tap(find.byKey(UsersListView.rowKey(account)));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
  }

  /// The AppBar subtitle is the only "account · presence" line on screen.
  String headerStatus(WidgetTester tester) {
    final Text text = tester.widget<Text>(find.textContaining(' · '));
    return text.data ?? '';
  }

  testWidgets('an open conversation turns 在线 when the peer logs in, without '
      'reopening, and the list row shows the same value', (
    WidgetTester tester,
  ) async {
    await pumpHome(tester);
    await openPeer(tester, '10000002');
    expect(headerStatus(tester), contains('离线'));

    // The peer logs in after the conversation was opened. Broadcasting a
    // message must not be what proves they are online; the presence source is.
    chat.users[0] = _peer('10000002', 'bob', Presence.online);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();

    expect(
      headerStatus(tester),
      contains('在线'),
      reason: 'the open header must refresh within one interval',
    );
    expect(
      chat.listUsersCalls.where((({String afterAccount, int limit}) call) {
        return call.limit == 1;
      }),
      isNotEmpty,
      reason: 'the refresh reads one row instead of paging the directory',
    );
    expect(chat.listUsersCalls.last, (
      afterAccount: '10000001',
      limit: 1,
    ), reason: 'the peer row is read through the account keyset');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(UsersListView.rowKey('10000002')),
        matching: find.byKey(UsersListView.presenceDotKey('10000002')),
      ),
      findsOneWidget,
      reason: 'list and header share one last-confirmed value',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed presence refresh keeps the last confirmed value and '
      'recovers on the next tick', (WidgetTester tester) async {
    chat.users[0] = _peer('10000002', 'bob', Presence.online);
    await pumpHome(tester);
    await openPeer(tester, '10000002');
    expect(headerStatus(tester), contains('在线'));

    // Unreachable server: neither surface may invent offline.
    chat.listUsersFails = true;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(headerStatus(tester), contains('在线'));

    chat.listUsersFails = false;
    chat.users[0] = _peer('10000002', 'bob', Presence.offline);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(
      headerStatus(tester),
      contains('离线'),
      reason: 'recovery resumes updates instead of freezing the old value',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late response for a closed conversation cannot change the '
      'next conversation', (WidgetTester tester) async {
    await pumpHome(tester);
    await openPeer(tester, '10000002');
    expect(headerStatus(tester), contains('离线'));

    // Hold the next presence read, then make it answer "online" for bob while
    // the user leaves bob and opens carol.
    final Completer<void> gate = Completer<void>();
    chat.listUsersGate = gate;
    chat.users[0] = _peer('10000002', 'bob', Presence.online);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    await openPeer(tester, '10000003');
    expect(headerStatus(tester), contains('离线'));

    gate.complete();
    await tester.pumpAndSettle();
    expect(
      headerStatus(tester),
      contains('离线'),
      reason: 'a response for the previous peer never lands on this page',
    );
    expect(tester.takeException(), isNull);

    // The next tick still serves carol only.
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(headerStatus(tester), contains('离线'));
    expect(tester.takeException(), isNull);
  });
}
