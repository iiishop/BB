import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/media_save.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
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

class _FakeGallery implements GallerySaver {
  @override
  bool get isSupported => true;

  @override
  Future<GallerySaveOutcome> save({
    required String path,
    required String filename,
    required String mimeType,
    required bool isVideo,
  }) async {
    return const GallerySaveOutcome(location: 'Pictures/BB/test.jpg');
  }
}

void main() {
  testWidgets('large body image uses the bounded thumbnail in the chat list', (
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
            parts: const <MessagePart>[ImagePart('img-big')],
          ),
        ],
      },
    );
    chat.metadata = const Attachment(
      mediaId: 'img-big',
      kind: AttachmentKind.image,
      filename: 'big.jpg',
      mimeType: 'image/jpeg',
      byteSize: 3 * 1024 * 1024,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(peer: _bob, chat: chat),
      ),
    );
    await tester.pumpAndSettle();

    expect(chat.metadataCalls, contains('img-big'));
    expect(chat.previewThumbnailFlags, <bool>[true]);
    expect(
      chat.mediaBytesCalls,
      isNot(contains('img-big')),
      reason: 'a large list image must not fetch the original',
    );
  });

  testWidgets('chat image and video cover open the viewer at the tapped item', (
    WidgetTester tester,
  ) async {
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
            createdAt: now.subtract(const Duration(minutes: 9)),
            kind: ChatMessageKind.body,
            parts: const <MessagePart>[ImagePart('img1'), ImagePart('img2')],
          ),
          ChatMessage(
            id: 'm2',
            position: 2,
            senderAccount: _self.account,
            targetAccount: _bob.account,
            createdAt: now.subtract(const Duration(minutes: 8)),
            kind: ChatMessageKind.body,
            parts: const <MessagePart>[ImagePart('img3')],
          ),
          ChatMessage(
            id: 'm3',
            position: 3,
            senderAccount: _bob.account,
            targetAccount: _self.account,
            createdAt: now.subtract(const Duration(minutes: 7)),
            kind: ChatMessageKind.attachment,
            attachment: const Attachment(
              mediaId: 'video1',
              kind: AttachmentKind.video,
              filename: 'clip.mp4',
              mimeType: 'video/mp4',
              byteSize: 4096,
              coverMediaId: 'cover1',
            ),
          ),
        ],
      },
    );
    final MediaSaveService saveService = MediaSaveService(
      chat: chat,
      gallery: _FakeGallery(),
    );
    Uri? opened;
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          peer: _bob,
          chat: chat,
          saveService: saveService,
          openExternalStream: (Uri uri) async {
            opened = uri;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('chat-media-img2')));
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 共 4'), findsOneWidget);
    expect(find.textContaining('bob ·'), findsWidgets);

    await tester.tap(find.byKey(MediaViewer.closeKey));
    await tester.pumpAndSettle();
    expect(find.byKey(MediaViewer.closeKey), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('chat-media-video1')));
    await tester.pumpAndSettle();
    expect(find.text('第 4 / 共 4'), findsOneWidget);
    expect(
      chat.openMediaStreamCalls,
      isEmpty,
      reason: 'opening the viewer must not start the video stream',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('media-viewer-play-video1')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(chat.openMediaStreamCalls, <String>['video1']);
    expect(opened, isNotNull);
    expect(find.text('在线播放'), findsOneWidget);

    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(chat.lastStreamHandle!.closed, isTrue);
  });
}
