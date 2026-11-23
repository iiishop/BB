import 'dart:async';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/services/presence_directory.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-476 rework: presence reads can complete out of order. A targeted read
/// captured before a newer list result must never win, even when its response
/// arrives last or the conversation is closed and reopened meanwhile.
const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

/// Waits for an async side effect instead of assuming a fixed sleep is enough
/// under a loaded parallel test run.
Future<void> _waitFor(bool Function() condition) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached before timeout');
}

ChatUser _peer(String account, String username, Presence presence) {
  return ChatUser(
    account: account,
    username: username,
    avatarUrl: '/avatars/$account.png',
    avatarVersion: 'v1',
    presence: presence,
  );
}

/// Takes the reply snapshot first and then delays it, exactly like a slow HTTP
/// response whose body already reflects the old state.
class _OrderingChat extends FakeChatService {
  _OrderingChat({required super.self, required super.users});

  Completer<void>? holdTargeted;
  Completer<void>? holdList;
  int heldTargeted = 0;
  int heldList = 0;

  @override
  Future<UserPage> listUsers({
    String afterAccount = '',
    int limit = 50,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final UserPage snapshot = await super.listUsers(
      afterAccount: afterAccount,
      limit: limit,
      expectedIdentity: expectedIdentity,
    );
    final Completer<void>? hold = limit == 1 ? holdTargeted : holdList;
    if (hold != null && !hold.isCompleted) {
      if (limit == 1) {
        heldTargeted += 1;
      } else {
        heldList += 1;
      }
      await hold.future;
    }
    return snapshot;
  }
}

void main() {
  late _OrderingChat chat;
  late FakeProfileGateway profile;
  late HeartbeatController heartbeat;

  setUp(() {
    chat = _OrderingChat(
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

  /// The header's presence line under the peer name (the conversation header
  /// shows the status itself, not the account id).
  String headerStatus(WidgetTester tester) {
    final Text text = tester.widget<Text>(find.byKey(ChatPage.headerStatusKey));
    return text.data ?? '';
  }

  for (final bool reopen in <bool>[false, true]) {
    testWidgets('a late targeted read cannot overwrite a newer list result '
        '(reopen: $reopen)', (WidgetTester tester) async {
      await pumpHome(tester);
      await tester.pump(const Duration(seconds: 28));

      // The targeted read that starts when bob's conversation opens is held
      // after capturing "offline".
      chat.holdTargeted = Completer<void>();
      await openPeer(tester, '10000002');
      expect(headerStatus(tester), contains('离线'));
      expect(chat.heldTargeted, 1);

      // The normal 30s list refresh confirms the newer "online" value.
      chat.users[0] = _peer('10000002', 'bob', Presence.online);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      if (reopen) {
        await tester.pageBack();
        await tester.pumpAndSettle();
        await openPeer(tester, '10000002');
      }
      expect(headerStatus(tester), contains('在线'));

      // Releasing the older held reply must not roll the confirmed value back.
      chat.holdTargeted!.complete();
      await tester.pumpAndSettle();
      final String observed = headerStatus(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        observed,
        contains('在线'),
        reason: 'the older read must not overwrite the newer confirmed value',
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('an older list page cannot overwrite a newer targeted read', () async {
    final PresenceDirectory directory = PresenceDirectory(chat: chat);
    addTearDown(directory.dispose);
    // A list request starts first...
    final int listStartedFirst = directory.beginObservation();

    // ...a targeted read starts later and confirms online first.
    chat.users[0] = _peer('10000002', 'bob', Presence.online);
    directory.watch('10000002');
    await _waitFor(() => directory.valueFor('10000002') != null);
    expect(directory.valueFor('10000002'), Presence.online);

    // ...then the older list page arrives last with the stale offline value.
    directory.seed(<ChatUser>[
      _peer('10000002', 'bob', Presence.offline),
    ], observation: listStartedFirst);
    expect(
      directory.valueFor('10000002'),
      Presence.online,
      reason: 'a page that started earlier loses to a newer read',
    );
  });

  test('unwatch invalidates a targeted read that started earlier', () async {
    final Completer<void> hold = Completer<void>();
    chat.holdTargeted = hold;
    final PresenceDirectory directory = PresenceDirectory(chat: chat);
    addTearDown(directory.dispose);

    directory.watch('10000002');
    await Future<void>.delayed(Duration.zero);
    expect(chat.heldTargeted, 1);

    directory.unwatch('10000002');
    hold.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      directory.valueFor('10000002'),
      isNull,
      reason: "a closed page's in-flight read is stale",
    );
  });
}
