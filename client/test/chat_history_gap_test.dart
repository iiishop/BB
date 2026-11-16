import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const ChatUser _bob = ChatUser(
  account: '10000002',
  username: 'bob',
  avatarUrl: '/avatars/10000002.png',
  avatarVersion: 'v1',
  presence: Presence.online,
);

/// Positions 1..1000, alternating sender.
List<ChatMessage> thousandMessages() {
  final DateTime base = DateTime.utc(2026, 1, 1, 12);
  return <ChatMessage>[
    for (int position = 1; position <= 1000; position++)
      ChatMessage(
        id: 'm$position',
        position: position,
        senderAccount: position.isEven ? _self.account : _bob.account,
        targetAccount: position.isEven ? _bob.account : _self.account,
        createdAt: base.add(Duration(seconds: position)),
        kind: ChatMessageKind.body,
        parts: <MessagePart>[TextPart('m$position')],
      ),
  ];
}

Future<void> pumpChat(
  WidgetTester tester,
  FakeChatService chat, {
  void Function(List<ChatMessage> messages)? onMessages,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ChatPage(
        peer: _bob,
        chat: chat,
        profile: FakeProfileGateway(),
        onMessagesChanged: onMessages,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a long conversation opens on the newest window only', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{_bob.account: thousandMessages()},
      pageSize: 100,
    );

    List<ChatMessage> captured = const <ChatMessage>[];
    await pumpChat(tester, chat, onMessages: (List<ChatMessage> m) => captured = m);

    // One backward request, one page: 901..1000. Not ten serial round trips.
    expect(chat.beforeCalls.length, 1);
    expect(chat.beforeCalls.single, isNotNull);
    expect(chat.conversationCalls, hasLength(1));
    expect(captured, hasLength(100));
    expect(captured.first.position, 901);
    expect(captured.last.position, 1000);
    expect(find.text('m1000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reaching the top backfills one older page at a time', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{_bob.account: thousandMessages()},
      pageSize: 100,
    );

    await pumpChat(tester, chat);
    expect(chat.beforeCalls, hasLength(1));

    // Drag toward the past until a second page has been requested.
    for (int attempt = 0; attempt < 12; attempt++) {
      await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 700));
      await tester.pumpAndSettle();
      if (chat.beforeCalls.length > 1) {
        break;
      }
    }

    expect(
      chat.beforeCalls.length,
      greaterThan(1),
      reason: 'reaching the top must ask for older messages',
    );
    // The second boundary is the oldest loaded position, so the pages abut.
    expect(chat.beforeCalls[1], 901);
    expect(find.text('m900'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
