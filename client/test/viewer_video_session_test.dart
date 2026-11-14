import 'dart:async';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/media_stream_proxy.dart';
import 'package:bb_client/ui/chat/media_save.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:bb_client/ui/chat/viewer_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

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

class _ProbeHandle implements MediaStreamHandle {
  final StreamController<MediaStreamProgress> events =
      StreamController<MediaStreamProgress>.broadcast();
  bool closed = false;

  @override
  Uri get uri => Uri.parse('http://127.0.0.1:1/synthetic');

  @override
  Stream<MediaStreamProgress> get progress => events.stream;

  @override
  Future<void> close() async {
    closed = true;
    await events.close();
  }
}

class _ProbeChat extends FakeChatService {
  _ProbeChat() : super(self: _self, users: const <ChatUser>[]);

  final _ProbeHandle handle = _ProbeHandle();

  @override
  Future<MediaStreamHandle> openMediaStream(String mediaId) async {
    openMediaStreamCalls.add(mediaId);
    return handle;
  }
}

class _PendingPlatform extends VideoPlayerPlatform {
  final Completer<int?> created = Completer<int?>();
  final StreamController<VideoEvent> events =
      StreamController<VideoEvent>.broadcast();
  bool entered = false;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) {
    entered = true;
    return created.future;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) => events.stream;

  @override
  Future<void> dispose(int id) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int id,
    bool value,
  ) async {}
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
  testWidgets('request progress enters buffering and labels the Range bytes', (
    WidgetTester tester,
  ) async {
    final VideoPlayerPlatform previous = VideoPlayerPlatform.instance;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    final _PendingPlatform platform = _PendingPlatform();
    VideoPlayerPlatform.instance = platform;
    final _ProbeChat chat = _ProbeChat();
    late StreamingViewerVideoSession session;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: MediaViewer(
          items: <ChatMediaItem>[_videoItem()],
          initialIndex: 0,
          chat: chat,
          saveService: _saveService(chat),
          videoSessionFactory: (ChatMediaItem item) =>
              session = StreamingViewerVideoSession(chat: chat, item: item),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(chat.openMediaStreamCalls, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('media-viewer-play-video-1')),
    );
    await tester.pump();
    expect(platform.entered, isTrue);

    chat.handle.events.add(
      const MediaStreamProgress(
        receivedBytes: 4,
        requestBytes: 8,
        mediaBytes: 4096,
        rangeStart: 0,
        rangeEnd: 7,
      ),
    );
    await tester.pump();
    expect(session.phase.value, ViewerVideoPhase.buffering);
    expect(session.transfer.value.receivedBytes, 4);
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.5);
    expect(find.textContaining('本次 Range'), findsOneWidget);
    expect(find.textContaining('4 B / 8 B'), findsOneWidget);
    expect(
      find.text('正在请求视频…'),
      findsNothing,
      reason: 'a byte-bearing production session must not stay in the opening label',
    );
    expect(find.textContaining('已缓冲'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    platform.created.complete(1);
    await tester.pump();
    await platform.events.close();
  });

  test(
    'closing during pending native create releases the stream immediately',
    () async {
      final VideoPlayerPlatform previous = VideoPlayerPlatform.instance;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final _PendingPlatform platform = _PendingPlatform();
      VideoPlayerPlatform.instance = platform;
      final _ProbeChat chat = _ProbeChat();
      final StreamingViewerVideoSession session = StreamingViewerVideoSession(
        chat: chat,
        item: _videoItem(),
      );

      unawaited(session.start());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(platform.entered, isTrue);

      final Future<void> closing = session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        chat.handle.closed,
        isTrue,
        reason: 'stream release must not wait for native create',
      );

      platform.created.complete(1);
      await closing.timeout(const Duration(seconds: 2));
      await platform.events.close();
    },
  );
}
