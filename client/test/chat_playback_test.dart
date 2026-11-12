import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
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
  testWidgets(
    'video arrives without original request and play opens an online stream',
    (WidgetTester tester) async {
      final DateTime now = DateTime.now().toUtc();
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
              createdAt: now,
              kind: ChatMessageKind.attachment,
              attachment: const Attachment(
                mediaId: 'video-1',
                kind: AttachmentKind.video,
                filename: 'clip.mp4',
                mimeType: 'video/mp4',
                byteSize: 4096,
                coverMediaId: 'cover-1',
              ),
            ),
          ],
        },
      );
      Uri? opened;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(
            peer: _bob,
            chat: chat,
            openExternalStream: (Uri uri) async {
              opened = uri;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(chat.mediaBytesCalls, contains('cover-1'));
      expect(
        chat.mediaBytesCalls,
        isNot(contains('video-1')),
        reason: 'the original video is not requested on arrival',
      );
      expect((chat.downloads as FakeDownloads).starts, isEmpty);
      expect(chat.openMediaStreamCalls, isEmpty);

      await tester.tap(find.text('播放'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(chat.openMediaStreamCalls, <String>['video-1']);
      expect(opened, isNotNull);
      expect(opened!.host, '127.0.0.1');
      expect(
        (chat.downloads as FakeDownloads).starts,
        isEmpty,
        reason: 'online play must not start an async full download',
      );
      expect(find.text('在线播放'), findsOneWidget);
      final FakeMediaStreamHandle handle = chat.lastStreamHandle!;
      expect(handle.closed, isFalse);

      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();
      expect(handle.closed, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
