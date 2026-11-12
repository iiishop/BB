import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const ChatUser _bob = ChatUser(
  account: '10000002',
  username: 'bob',
  avatarUrl: '/avatars/10000002.png',
  avatarVersion: 'v1',
  presence: Presence.online,
);

void main() {
  testWidgets('1000-message backfill cannot be skipped by a send or a poll', (
    WidgetTester tester,
  ) async {
    final DateTime base = DateTime.utc(2026, 1, 1, 12);
    final List<ChatMessage> history = <ChatMessage>[
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
    final Completer<void> gate = Completer<void>();
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{_bob.account: history},
      pageSize: 100,
      gateAtPosition: 100,
      gate: gate,
    );
    List<ChatMessage> captured = const <ChatMessage>[];

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          peer: _bob,
          chat: chat,
          onMessagesChanged: (List<ChatMessage> messages) {
            captured = messages;
          },
        ),
      ),
    );

    // Let page 0 complete and page 100 block on the gate, then send while the
    // backfill is still in progress.
    for (int i = 0; i < 40 && !chat.conversationCalls.contains(100); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(chat.conversationCalls, contains(0));
    expect(chat.conversationCalls, contains(100));
    expect(chat.conversationCalls, isNot(contains(200)));

    await tester.enterText(find.byKey(ChatComposer.inputKey), '发送于补取过程中');
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();

    final List<int> positions = captured
        .map((ChatMessage message) => message.position)
        .toList();
    expect(
      positions,
      List<int>.generate(1001, (int index) => index + 1),
      reason: 'complete contiguous history plus the local send, no gap/dup',
    );
    expect(
      captured.map((ChatMessage message) => message.identity).toSet().length,
      captured.length,
    );
    expect(
      captured.any(
        (ChatMessage message) => message.parts.any(
          (MessagePart part) => part is TextPart && part.text == 'm601',
        ),
      ),
      isTrue,
      reason: '601 must be fetched, not skipped by the send cursor',
    );
    expect(
      captured.any(
        (ChatMessage message) => message.parts.any(
          (MessagePart part) => part is TextPart && part.text == '发送于补取过程中',
        ),
      ),
      isTrue,
    );
    expect(
      chat.conversationCalls,
      containsAll(<int>[0, 100, 200, 300, 400, 500, 600, 700, 800, 900]),
    );
    expect(tester.takeException(), isNull);
  });
}
