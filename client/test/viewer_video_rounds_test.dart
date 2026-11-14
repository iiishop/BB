import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/media_stream_proxy.dart';
import 'package:bb_client/ui/chat/media_save.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:bb_client/ui/chat/viewer_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_chat_service.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const String _peer = '10000002';

class _Handle implements MediaStreamHandle {
  final StreamController<MediaStreamProgress> events =
      StreamController<MediaStreamProgress>.broadcast();
  Completer<void>? closeGate;
  bool closed = false;
  bool closing = false;

  @override
  Uri get uri => Uri.parse('http://127.0.0.1:1/synthetic-video');

  @override
  Stream<MediaStreamProgress> get progress => events.stream;

  @override
  Future<void> close() async {
    closing = true;
    await closeGate?.future;
    closed = true;
  }
}

class _RoundChat extends FakeChatService {
  _RoundChat() : super(self: _self, users: const <ChatUser>[]);

  final List<_Handle> handles = <_Handle>[];

  @override
  Future<MediaStreamHandle> openMediaStream(String mediaId) async {
    final _Handle handle = _Handle();
    handles.add(handle);
    return handle;
  }
}

class _NativeRounds extends VideoPlayerPlatform {
  final List<Completer<int?>> creates = <Completer<int?>>[];
  final Map<int, StreamController<VideoEvent>> streams =
      <int, StreamController<VideoEvent>>{};
  final Set<int> disposed = <int>{};

  @override
  Future<void> init() async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    return const ColoredBox(color: Colors.blue);
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) {
    final Completer<int?> gate = Completer<int?>();
    creates.add(gate);
    return gate.future;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) {
    final StreamController<VideoEvent> events =
        StreamController<VideoEvent>.broadcast();
    streams[id] = events;
    return events.stream;
  }

  @override
  Future<void> dispose(int id) async {
    disposed.add(id);
  }

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int id,
    bool value,
  ) async {}

  @override
  Future<void> setLooping(int id, bool value) async {}

  @override
  Future<void> setVolume(int id, double value) async {}

  @override
  Future<void> setPlaybackSpeed(int id, double value) async {}

  @override
  Future<void> play(int id) async {}

  @override
  Future<void> pause(int id) async {}

  @override
  Future<Duration> getPosition(int id) async => Duration.zero;

  Future<void> ready(int round, int id) async {
    creates[round].complete(id);
    await until(() => streams.containsKey(id));
    streams[id]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(320, 240),
      ),
    );
  }

  Future<void> cleanup() async {
    for (final StreamController<VideoEvent> stream in streams.values) {
      await stream.close();
    }
  }
}

Future<void> until(bool Function() condition) async {
  for (int attempt = 0; attempt < 200 && !condition(); attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue, reason: 'probe prerequisite completed');
}

ChatMediaItem _item() {
  final ChatMessage message = ChatMessage(
    id: 'video',
    position: 1,
    senderAccount: _peer,
    targetAccount: _self.account,
    createdAt: DateTime.utc(2026, 11, 14),
    kind: ChatMessageKind.attachment,
    attachment: const Attachment(
      mediaId: 'video-1',
      kind: AttachmentKind.video,
      filename: 'video.mp4',
      mimeType: 'video/mp4',
      byteSize: 4096,
    ),
  );
  return ChatMediaItem(
    message: message,
    kind: ChatMediaKind.video,
    mediaId: 'video-1',
    senderLabel: 'bob',
    byteSize: 4096,
  );
}

MediaSaveService _saveService(_RoundChat chat) {
  return MediaSaveService(
    chat: chat,
    pickSaveLocation: (String _) async => null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('R2 old failure cleanup cannot overwrite a ready retry round', () async {
    final VideoPlayerPlatform previous = VideoPlayerPlatform.instance;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    final _NativeRounds platform = _NativeRounds();
    VideoPlayerPlatform.instance = platform;
    final _RoundChat chat = _RoundChat();
    final StreamingViewerVideoSession session = StreamingViewerVideoSession(
      chat: chat,
      item: _item(),
    );
    addTearDown(() async {
      await session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await platform.cleanup();
      for (final _Handle handle in chat.handles) {
        await handle.events.close();
      }
    });

    await session.start();
    await until(() => platform.creates.length == 1);
    final Completer<void> closeGate = Completer<void>();
    chat.handles[0].closeGate = closeGate;
    platform.creates[0].complete(100);
    await until(() => platform.streams.containsKey(100));
    platform.streams[100]!.addError(
      PlatformException(code: 'VideoError', message: 'synthetic failure'),
    );
    await until(
      () =>
          chat.handles[0].closing &&
          session.phase.value == ViewerVideoPhase.failed,
    );

    await session.retry();
    await until(() => platform.creates.length == 2);
    await platform.ready(1, 101);
    await until(
      () =>
          session.phase.value == ViewerVideoPhase.ready &&
          session.playing.value,
    );

    closeGate.complete();
    await until(() => chat.handles[0].closed);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.phase.value, ViewerVideoPhase.ready);
    expect(chat.handles[1].closed, isFalse);
    expect(platform.disposed, isNot(contains(101)));
  });

  testWidgets(
    'R3 retry button succeeds and old failure cleanup keeps the player visible',
    (WidgetTester tester) async {
      final VideoPlayerPlatform previous = VideoPlayerPlatform.instance;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final _NativeRounds platform = _NativeRounds();
      VideoPlayerPlatform.instance = platform;
      final _RoundChat chat = _RoundChat();
      final StreamingViewerVideoSession session = StreamingViewerVideoSession(
        chat: chat,
        item: _item(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            items: <ChatMediaItem>[_item()],
            initialIndex: 0,
            chat: chat,
            saveService: _saveService(chat),
            videoSessionFactory: (ChatMediaItem _) => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('media-viewer-play-video-1')),
      );
      await tester.pump();

      final Completer<void> closeGate = Completer<void>();
      chat.handles[0].closeGate = closeGate;
      platform.creates[0].complete(100);
      for (int i = 0; i < 5; i += 1) {
        await tester.pump();
      }
      expect(platform.streams.containsKey(100), isTrue);
      platform.streams[100]!.addError(
        PlatformException(code: 'VideoError', message: 'synthetic failure'),
      );
      for (int i = 0; i < 5; i += 1) {
        await tester.pump();
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      expect(chat.handles[0].closing, isTrue);
      expect(find.byKey(const Key('media-viewer-video-retry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('media-viewer-video-retry')));
      for (int i = 0; i < 5; i += 1) {
        await tester.pump();
      }
      expect(platform.creates, hasLength(2));
      platform.creates[1].complete(101);
      for (int i = 0; i < 5; i += 1) {
        await tester.pump();
      }
      expect(platform.streams.containsKey(101), isTrue);
      platform.streams[101]!.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 10),
          size: const Size(320, 240),
        ),
      );
      for (int i = 0; i < 5; i += 1) {
        await tester.pump();
      }
      expect(
        find.byKey(const Key('media-viewer-video-toggle')),
        findsOneWidget,
      );

      closeGate.complete();
      for (int i = 0; i < 5; i += 1) {
        await tester.pump();
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      expect(find.text('视频播放失败'), findsNothing);
      expect(
        find.byKey(const Key('media-viewer-video-toggle')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    },
  );
}
