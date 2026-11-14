import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/media_actions.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
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

class _FakeClipboard implements ClipboardMediaReader {
  _FakeClipboard(this.media);

  final PickedMedia media;

  @override
  Future<PickedMedia?> read() async => media;
}

void main() {
  testWidgets(
    'just-sent image stays visible when metadata and thumbnails fail',
    (WidgetTester tester) async {
      final FakeChatService chat = FakeChatService(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[],
        },
      );
      chat.metadataFails = true;
      chat.listPreviewFails = true;
      chat.previewFails = true;
      final _FakeClipboard clipboard = _FakeClipboard(
        PickedMedia(
          bytes: chat.pngBytes,
          filename: 'sent.png',
          mimeType: 'image/png',
        ),
      );
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(peer: _bob, chat: chat, profile: FakeProfileGateway(), clipboard: clipboard),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ChatComposer.pasteKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();

      final List<ChatMessage> conversation = chat.conversations[_bob.account]!;
      final ChatMessage sent = conversation.lastWhere(
        (ChatMessage message) =>
            message.parts.whereType<ImagePart>().isNotEmpty,
      );
      final String mediaId = sent.parts.whereType<ImagePart>().first.mediaId;

      expect(
        find.byKey(ValueKey<String>('chat-media-$mediaId')),
        findsOneWidget,
      );
      expect(
        find.byType(Image),
        findsWidgets,
        reason: 'the sender still holds the local bytes for its own image',
      );

      await tester.tap(find.byKey(ValueKey<String>('chat-media-$mediaId')));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewer), findsOneWidget);
      expect(
        find.byType(Image),
        findsWidgets,
        reason:
            'the viewer reuses the sender local bytes while derivatives fail',
      );
      expect(
        chat.originalCalls,
        isEmpty,
        reason: 'local preview must never be backed by a remote original fetch',
      );
    },
  );

  testWidgets('receiver image failure never requests the remote original', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[
          ChatMessage(
            id: 'm1',
            position: 1,
            senderAccount: _bob.account,
            targetAccount: _self.account,
            createdAt: DateTime.now().toUtc(),
            kind: ChatMessageKind.body,
            parts: const <MessagePart>[ImagePart('peer-image')],
          ),
        ],
      },
    );
    chat.metadataFails = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(peer: _bob, chat: chat, profile: FakeProfileGateway()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(chat.mediaBytesCalls, isNot(contains('peer-image')));
    expect(chat.originalCalls, isEmpty);
  });
}
