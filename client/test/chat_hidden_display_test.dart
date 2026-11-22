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

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

ChatMessage _inbound(int position, String peer, {String? text}) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: peer,
    targetAccount: _self.account,
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
          for (int position = 1; position <= 30; position += 1)
            ChatMessage(
              id: 'm$position',
              position: position,
              senderAccount: position.isEven ? _self.account : bob.account,
              targetAccount: position.isEven ? bob.account : _self.account,
              createdAt: DateTime.now().toUtc(),
              kind: ChatMessageKind.body,
              parts: <MessagePart>[TextPart('消息 $position')],
            ),
        ],
        carol.account: <ChatMessage>[
          _inbound(1, carol.account, text: 'carol 消息'),
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

  Future<void> pumpWorkspace(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a hidden conversation does not confirm display for messages that arrive '
    'while its pane is not selected',
    (WidgetTester tester) async {
      await pumpWorkspace(tester);
      chat.viewedMessageIds.clear();

      await tester.tap(find.byKey(UsersListView.rowKey(carol.account)));
      await tester.pumpAndSettle();
      chat.conversations[bob.account]!.add(
        _inbound(31, bob.account, text: 'hidden arrival'),
      );

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(
        chat.viewedMessageIds,
        isNot(contains('m31')),
        reason: 'a hidden pane must not clear the account unread badge',
      );

      // Returning to the conversation is when the arrival may become a
      // display fact again.
      await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
      await tester.pumpAndSettle();
      expect(chat.viewedMessageIds, contains('m31'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a poll that started before the switch cannot confirm display after the '
    'pane becomes hidden',
    (WidgetTester tester) async {
      await pumpWorkspace(tester);
      chat.viewedMessageIds.clear();

      chat.gate = Completer<void>();
      chat.gateAtPosition = 30;
      chat.conversations[bob.account]!.add(
        _inbound(31, bob.account, text: 'poll in flight'),
      );
      await tester.pump(const Duration(seconds: 3));

      // The request is in flight; now switch away before it returns.
      await tester.tap(find.byKey(UsersListView.rowKey(carol.account)));
      await tester.pump();
      chat.gate!.complete();
      await tester.pumpAndSettle();

      expect(
        chat.viewedMessageIds,
        isNot(contains('m31')),
        reason: 'completion is judged by the pane state at return time',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'activating a page flushes the display facts staged while it was hidden',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Widget page(bool active) {
        return MaterialApp(
          home: ChatPage(
            key: const ValueKey<String>('activity-page'),
            peer: bob,
            chat: chat,
            profile: profile,
            active: active,
          ),
        );
      }

      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      chat.viewedMessageIds.clear();

      chat.gate = Completer<void>();
      chat.gateAtPosition = 30;
      chat.conversations[bob.account]!.add(
        _inbound(31, bob.account, text: 'staged while hidden'),
      );
      await tester.pump(const Duration(seconds: 3));

      // Rebuild the same element as hidden, then let the poll complete.
      await tester.pumpWidget(page(false));
      chat.gate!.complete();
      await tester.pumpAndSettle();
      expect(chat.viewedMessageIds, isNot(contains('m31')));

      // The staged batch is released only when the pane is visible again.
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expect(chat.viewedMessageIds, contains('m31'));
      expect(tester.takeException(), isNull);
    },
  );
}
