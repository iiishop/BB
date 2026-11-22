import 'dart:async';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/conversation_order.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

/// DEA-488: the home conversation list is ordered by the last persisted
/// message time, newest first, whether the current account or the peer sent
/// it. Opening a conversation writes no message and must not move rows.
const AuthUser _self = AuthUser(account: '10000001', username: 'me');
const String _aliceAccount = '10000002';
const String _zoeAccount = '10000003';

/// Test double whose next directory response is captured first and delivered
/// later, so the periodic refresh can overlap sending and returning.
class DelayedDirectory extends FakeChatService {
  DelayedDirectory({required super.self, required super.users});

  Completer<void>? delayNext;
  bool captured = false;

  @override
  Future<UserPage> listUsers({
    String afterAccount = '',
    int limit = 50,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final Completer<void>? gate = delayNext;
    delayNext = null;
    final UserPage snapshot = await super.listUsers(
      afterAccount: afterAccount,
      limit: limit,
      expectedIdentity: expectedIdentity,
    );
    if (gate != null) {
      captured = true;
      await gate.future;
    }
    return snapshot;
  }
}

ChatUser _peer(
  String account,
  String username, {
  DateTime? lastContactAt,
  String? preview,
}) {
  return ChatUser(
    account: account,
    username: username,
    avatarUrl: '/avatars/$account.png',
    avatarVersion: 'v1',
    presence: Presence.offline,
    lastContactAt: lastContactAt,
    lastMessage: preview == null
        ? null
        : UserPreview(
            id: 'm-$account',
            senderAccount: account,
            senderUsername: username,
            previewBody: preview,
          ),
  );
}

void main() {
  test('last-message order ignores sender and keeps no-message rows last', () {
    final DateTime base = DateTime.utc(2026, 1, 1, 10);
    final ChatUser alice = _peer(
      _aliceAccount,
      'alice',
      lastContactAt: base,
      preview: '来自 Alice',
    );
    final ChatUser zoe = _peer(
      _zoeAccount,
      'zoe',
      lastContactAt: base.add(const Duration(minutes: 1)),
      preview: '来自 Zoe',
    );
    final ChatUser noMessage = _peer('10000004', 'nobody');
    final ChatUser sameTime = _peer(
      '10000005',
      'same',
      lastContactAt: base,
      preview: '同一时刻',
    );

    expect(
      sortChatUsersByLastMessage(<ChatUser>[noMessage, alice, zoe, sameTime])
          .map((ChatUser user) => user.account),
      <String>['10000003', '10000002', '10000005', '10000004'],
    );
  });

  group('home conversation order', () {
    late DelayedDirectory chat;
    late HeartbeatController heartbeat;
    late FakeProfileGateway profile;

    setUp(() {
      chat = DelayedDirectory(
        self: _self,
        users: <ChatUser>[
          _peer(_aliceAccount, 'alice'),
          _peer(_zoeAccount, 'zoe'),
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

    /// Visual order of the asserted rows, top to bottom.
    List<String> rowOrder(WidgetTester tester, List<String> accounts) {
      final List<({String account, double top})> rows =
          <({String account, double top})>[];
      for (final String account in accounts) {
        final Finder row = find.byKey(UsersListView.rowKey(account));
        expect(row, findsOneWidget, reason: 'row for $account is on screen');
        rows.add((account: account, top: tester.getTopLeft(row).dy));
      }
      rows.sort((a, b) => a.top.compareTo(b.top));
      return rows.map((row) => row.account).toList();
    }

    /// Advances the 30s silent refresh and lets its response land.
    Future<void> nextRefresh(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'Alice, then Zoe, then a reply to Alice, then opening Zoe keeps order',
      (WidgetTester tester) async {
        await pumpHome(tester);
        expect(rowOrder(tester, <String>[_aliceAccount, _zoeAccount]), <String>[
          _aliceAccount,
          _zoeAccount,
        ], reason: 'accounts sort deterministically before any message');

        // 1. A message from Alice arrives first.
        chat.users[0] = _peer(
          _aliceAccount,
          'alice',
          lastContactAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 2),
          ),
          preview: 'Alice 的第一条',
        );
        await nextRefresh(tester);
        expect(rowOrder(tester, <String>[_aliceAccount, _zoeAccount]), <String>[
          _aliceAccount,
          _zoeAccount,
        ]);

        // 2. Zoe's message is newer, so Zoe overtakes Alice.
        chat.users[1] = _peer(
          _zoeAccount,
          'zoe',
          lastContactAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 1),
          ),
          preview: 'Zoe 的最新消息',
        );
        await nextRefresh(tester);
        expect(rowOrder(tester, <String>[_aliceAccount, _zoeAccount]), <String>[
          _zoeAccount,
          _aliceAccount,
        ], reason: 'newest last message comes first, whoever sent it');
        expect(find.text('zoe：Zoe 的最新消息'), findsOneWidget);

        // 3. A periodic refresh captures the directory before the reply is
        // sent; its delayed response must not win over the post-send refresh
        // that returning from the chat requests.
        await tester.tap(find.byKey(UsersListView.rowKey(_aliceAccount)));
        await tester.pumpAndSettle();
        final Completer<void> staleDirectory = Completer<void>();
        chat.delayNext = staleDirectory;
        await tester.pump(const Duration(seconds: 30));
        expect(chat.captured, isTrue);
        await tester.enterText(
          find.byKey(ChatComposer.inputKey),
          '给 Alice 的回复',
        );
        await tester.tap(find.byKey(ChatComposer.sendKey));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        staleDirectory.complete();
        await tester.pumpAndSettle();

        expect(
          rowOrder(tester, <String>[_aliceAccount, _zoeAccount]),
          <String>[_aliceAccount, _zoeAccount],
          reason:
              'a sent reply is the newest last message even when an older '
              'directory read lands afterwards',
        );
        expect(find.text('我：给 Alice 的回复'), findsOneWidget);

        // 4. Opening Zoe without sending changes nothing.
        await tester.tap(find.byKey(UsersListView.rowKey(_zoeAccount)));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(rowOrder(tester, <String>[_aliceAccount, _zoeAccount]), <String>[
          _aliceAccount,
          _zoeAccount,
        ], reason: 'opening a conversation is not message activity');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a newest conversation on a later account page still sorts first',
      (WidgetTester tester) async {
        final List<ChatUser> directory = <ChatUser>[
          for (int i = 2; i <= 106; i++)
            _peer((10000000 + i).toString(), 'user$i'),
        ];
        final String newest = directory.last.account;
        directory[directory.length - 1] = _peer(
          newest,
          'newest',
          lastContactAt: DateTime.now().toUtc(),
          preview: '最后一页的最新消息',
        );
        chat.users
          ..clear()
          ..addAll(directory);

        await pumpHome(tester);

        expect(chat.listUsersCalls.length, greaterThanOrEqualTo(2));
        expect(chat.listUsersCalls.first, (
          afterAccount: '',
          limit: 100,
        ), reason: 'the directory walk uses the contract page size');
        expect(rowOrder(tester, <String>[newest, '10000002']), <String>[
          newest,
          '10000002',
        ], reason: 'later account pages participate in the global order');
        expect(find.text('newest：最后一页的最新消息'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
