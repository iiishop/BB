import 'dart:async';

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
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';

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

  Widget app({bool withSpace = false}) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: HomeView(
        user: _self,
        profile: profile,
        auth: FakeAuthGateway(),
        heartbeat: heartbeat,
        chat: chat,
        space: withSpace ? FakeSpaceGateway() : null,
        onSignedOut: (LogoutResult? _) {},
        onSessionExpired: () {},
      ),
    );
  }

  Future<void> pumpWorkspace(
    WidgetTester tester, {
    bool withSpace = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(withSpace: withSpace));
    await tester.pumpAndSettle();
  }

  for (final bool desktop in <bool>[false, true]) {
    testWidgets('${desktop ? 'desktop' : 'phone'} entry confirms only its '
        'existing unread while peer profile covers the chat', (tester) async {
      final ChatUser peer = desktop ? carol : bob;
      chat.conversations[peer.account] = <ChatMessage>[
        for (int position = 101; position <= 201; position++)
          _inbound(position, peer.account),
      ];
      profile.profile = Profile(
        account: peer.account,
        username: peer.username,
        signature: null,
        avatarUrl: '',
        avatarVersion: 'v1',
      );
      if (desktop) {
        await pumpWorkspace(tester);
      } else {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
      }
      expect(chat.viewedMessageIds, isNot(contains('m101')));
      final entry = Completer<void>();
      chat.entryHistoryGate = entry;
      await tester.tap(find.byKey(UsersListView.rowKey(peer.account)));
      await tester.pumpAndSettle();
      expect(chat.viewedMessageIds, isNot(contains('m101')));
      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await tester.pumpAndSettle();
      expect(find.text('BB号 ${peer.account}'), findsOneWidget);
      chat.conversations[peer.account]!.add(_inbound(202, peer.account));
      entry.complete();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(chat.viewedMessageIds, contains('m101'));
      expect(chat.viewedMessageIds, isNot(contains('m202')));

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.text('消息 202'), findsOneWidget);
      expect(chat.viewedMessageIds, contains('m202'));
    });
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

  for (final String destination in ['Space', 'notifications']) {
    testWidgets(
      '$destination covering the shell cannot confirm chat display facts',
      (WidgetTester tester) async {
        // QA counterexample: in the real signed-in shell the chat surface keeps
        // running behind Space, so pane selection alone is not visibility.
        await pumpWorkspace(tester, withSpace: destination == 'Space');
        chat.viewedMessageIds.clear();
        expect(
          find.byKey(UsersListView.selectedKey(bob.account)),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(
            destination == 'Space'
                ? HomeView.navSpaceKey
                : HomeView.navNotificationsKey,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ChatPage), findsNothing);

        chat.conversations[bob.account]!.add(
          _inbound(31, bob.account, text: 'arrived behind Space'),
        );
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(
          chat.viewedMessageIds,
          isNot(contains('m31')),
          reason: 'the section is on screen, the chat pane is not',
        );

        // Coming back to the chat section is when the staged batch is released.
        await tester.tap(find.byKey(HomeView.navChatKey));
        await tester.pumpAndSettle();
        expect(chat.viewedMessageIds, contains('m31'));
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  testWidgets(
    'phone peer profile withholds in-flight and later arrivals until return',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      profile.profile = Profile(
        account: bob.account,
        username: bob.username,
        signature: null,
        avatarUrl: '',
        avatarVersion: 'v1',
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
      await tester.pumpAndSettle();
      chat.viewedMessageIds.clear();

      // Start a poll while the chat is visible, then cover it with the peer
      // profile before the in-flight request finishes.
      chat.gate = Completer<void>();
      chat.gateAtPosition = 30;
      chat.conversations[bob.account]!.add(
        _inbound(31, bob.account, text: 'in flight before profile'),
      );
      await tester.pump(const Duration(seconds: 3));

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await tester.pumpAndSettle();
      expect(find.text('BB号 ${bob.account}'), findsOneWidget);
      expect(find.byType(ChatPage), findsNothing);

      chat.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        chat.viewedMessageIds,
        isNot(contains('m31')),
        reason: 'in-flight poll must not confirm display behind peer profile',
      );

      // A later arrival while the profile remains open stays staged too.
      chat.conversations[bob.account]!.add(
        _inbound(32, bob.account, text: 'arrived during profile'),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(chat.viewedMessageIds, isNot(contains('m32')));

      // Closing the peer profile flushes both staged display facts.
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(chat.viewedMessageIds, containsAll(<String>['m31', 'm32']));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop peer profile dialog withholds arrivals until dismissed',
    (WidgetTester tester) async {
      profile.profile = Profile(
        account: bob.account,
        username: bob.username,
        signature: null,
        avatarUrl: '',
        avatarVersion: 'v1',
      );
      await pumpWorkspace(tester);
      chat.viewedMessageIds.clear();

      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await tester.pumpAndSettle();
      expect(find.text('BB号 ${bob.account}'), findsOneWidget);

      chat.conversations[bob.account]!.add(
        _inbound(31, bob.account, text: 'arrived behind dialog'),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(chat.viewedMessageIds, isNot(contains('m31')));

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(chat.viewedMessageIds, contains('m31'));
      expect(tester.takeException(), isNull);
    },
  );
}
