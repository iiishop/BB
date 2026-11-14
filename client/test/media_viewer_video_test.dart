import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/media_save.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:bb_client/ui/chat/viewer_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const String _peer = '10000002';

ChatMediaItem _videoItem() {
  final ChatMessage message = ChatMessage(
    id: 'm1',
    position: 1,
    senderAccount: _peer,
    targetAccount: _self.account,
    createdAt: DateTime.utc(2026, 11, 14, 10),
    kind: ChatMessageKind.attachment,
    attachment: const Attachment(
      mediaId: 'video-1',
      kind: AttachmentKind.video,
      filename: 'clip.mp4',
      mimeType: 'video/mp4',
      byteSize: 4096,
      coverMediaId: 'cover-1',
    ),
  );
  return ChatMediaItem(
    message: message,
    kind: ChatMediaKind.video,
    mediaId: 'video-1',
    senderLabel: 'bob',
    coverMediaId: 'cover-1',
    byteSize: 4096,
    filename: 'clip.mp4',
    mimeType: 'video/mp4',
  );
}

class _FakeSession implements ViewerVideoSession {
  @override
  final ValueNotifier<ViewerVideoPhase> phase = ValueNotifier<ViewerVideoPhase>(
    ViewerVideoPhase.idle,
  );
  @override
  final ValueNotifier<ViewerVideoTransfer> transfer =
      ValueNotifier<ViewerVideoTransfer>(const ViewerVideoTransfer());
  @override
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
  @override
  final ValueNotifier<bool> buffering = ValueNotifier<bool>(false);

  @override
  final ValueNotifier<double?> bufferedFraction = ValueNotifier<double?>(null);

  @override
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(
    Duration.zero,
  );

  int starts = 0;
  int toggles = 0;
  int retries = 0;
  int stops = 0;
  int disposes = 0;

  @override
  Widget buildSurface(BuildContext context) {
    return const ColoredBox(
      color: Colors.green,
      child: Center(child: Text('VIDEO_SURFACE')),
    );
  }

  @override
  Future<void> start() async {
    starts += 1;
    phase.value = ViewerVideoPhase.opening;
  }

  @override
  Future<void> togglePlayPause() async {
    toggles += 1;
  }

  @override
  Future<void> retry() async {
    retries += 1;
  }

  @override
  Future<void> stop() async {
    stops += 1;
    phase.value = ViewerVideoPhase.idle;
  }

  @override
  Future<void> dispose() async {
    disposes += 1;
  }
}

class _FakeFactory {
  final List<_FakeSession> sessions = <_FakeSession>[];

  ViewerVideoSession call(ChatMediaItem item) {
    final _FakeSession session = _FakeSession();
    sessions.add(session);
    return session;
  }
}

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
    return const GallerySaveOutcome(location: 'Movies/BB/clip.mp4');
  }
}

MediaSaveService _saveService(FakeChatService chat) {
  return MediaSaveService(
    chat: chat,
    gallery: _FakeGallery(),
    pickSaveLocation: (String _) async => null,
  );
}

void main() {
  testWidgets('viewer plays video with stream progress and releases on close', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[],
    );
    final _FakeFactory factory = _FakeFactory();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => MediaViewer(
                    items: <ChatMediaItem>[_videoItem()],
                    initialIndex: 0,
                    chat: chat,
                    saveService: _saveService(chat),
                    videoSessionFactory: factory.call,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(factory.sessions, isEmpty);
    expect(chat.openMediaStreamCalls, isEmpty);
    expect(chat.mediaBytesCalls, contains('cover-1'));

    await tester.tap(
      find.byKey(const ValueKey<String>('media-viewer-play-video-1')),
    );
    await tester.pump();
    expect(factory.sessions, hasLength(1));
    final _FakeSession session = factory.sessions.single;
    expect(session.starts, 1);
    expect(find.text('正在请求视频…'), findsOneWidget);

    session.transfer.value = const ViewerVideoTransfer(
      receivedBytes: 40,
      requestBytes: 100,
      mediaBytes: 4096,
      rangeStart: 0,
      rangeEnd: 99,
    );
    session.phase.value = ViewerVideoPhase.buffering;
    await tester.pump();
    expect(find.text('缓冲中…'), findsOneWidget);
    expect(find.textContaining('本次 Range'), findsOneWidget);
    expect(find.textContaining('40 B / 100 B'), findsOneWidget);

    session.transfer.value = const ViewerVideoTransfer(
      receivedBytes: 100,
      requestBytes: 100,
      mediaBytes: 4096,
      rangeStart: 0,
      rangeEnd: 99,
    );
    session.bufferedFraction.value = 0.35;
    session.position.value = const Duration(seconds: 1);
    session.phase.value = ViewerVideoPhase.ready;
    await tester.pump();
    expect(find.text('VIDEO_SURFACE'), findsOneWidget);
    expect(find.text('已缓冲 35%'), findsOneWidget);
    expect(find.text('播放中 00:01'), findsOneWidget);
    expect(
      find.text('已缓冲 100%'),
      findsNothing,
      reason: 'a finished short Range must not look like the whole video',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('media-viewer-video-toggle')),
    );
    await tester.pump();
    expect(session.toggles, 1);

    session.phase.value = ViewerVideoPhase.failed;
    await tester.pump();
    expect(find.text('视频播放失败'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('media-viewer-video-retry')),
    );
    await tester.pump();
    expect(session.retries, 1);

    await tester.tap(find.byKey(MediaViewer.closeKey));
    await tester.pumpAndSettle();
    expect(session.disposes, 1);
    expect(chat.openMediaStreamCalls, isEmpty);
  });

  testWidgets('switching to the next media releases the video stream', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[],
    );
    final _FakeFactory factory = _FakeFactory();
    final ChatMessage imageMessage = ChatMessage(
      id: 'm2',
      position: 2,
      senderAccount: _peer,
      targetAccount: _self.account,
      createdAt: DateTime.utc(2026, 11, 14, 10, 1),
      kind: ChatMessageKind.body,
      parts: const <MessagePart>[ImagePart('image-2')],
    );
    final ChatMediaItem image = ChatMediaItem(
      message: imageMessage,
      kind: ChatMediaKind.image,
      mediaId: 'image-2',
      senderLabel: 'bob',
      partIndex: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: MediaViewer(
          items: <ChatMediaItem>[_videoItem(), image],
          initialIndex: 0,
          chat: chat,
          saveService: _saveService(chat),
          videoSessionFactory: factory.call,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('media-viewer-play-video-1')),
    );
    await tester.pump();
    final _FakeSession session = factory.sessions.single;
    session.phase.value = ViewerVideoPhase.ready;
    await tester.pump();

    await tester.drag(
      find.byKey(MediaViewer.pageViewKey),
      const Offset(-420, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 共 2'), findsOneWidget);
    expect(session.stops, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(session.disposes, 1);
  });

  testWidgets('desktop fallback stays an explicit external-player hand-off', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[],
    );
    bool external = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: MediaViewer(
          items: <ChatMediaItem>[_videoItem()],
          initialIndex: 0,
          chat: chat,
          saveService: _saveService(chat),
          inlineVideoSupported: false,
          onPlayVideo: (ChatMediaItem item) async {
            external = true;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('media-viewer-play-video-1')),
    );
    await tester.pumpAndSettle();
    expect(external, isTrue);
    expect(find.textContaining('系统播放器'), findsOneWidget);
  });
}
