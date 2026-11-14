import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../../models/chat_media.dart';
import '../../services/chat_service.dart';
import '../../services/media_stream_proxy.dart';

/// Playback lifecycle of one full-screen video item.
enum ViewerVideoPhase { idle, opening, buffering, ready, failed }

/// Bytes the loopback stream has delivered for the current Range request.
///
/// [requestBytes] is the current response length; [mediaBytes] is the whole
/// video size. These must be displayed separately: a short Range finishing is
/// not the whole video being buffered.
class ViewerVideoTransfer {
  const ViewerVideoTransfer({
    this.receivedBytes = 0,
    this.requestBytes,
    this.mediaBytes,
    this.rangeStart,
    this.rangeEnd,
  });

  final int receivedBytes;
  final int? requestBytes;
  final int? mediaBytes;
  final int? rangeStart;
  final int? rangeEnd;

  double? get requestFraction {
    final int? total = requestBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// One click-scoped video playback inside the viewer.
///
/// Production wraps `video_player` over the authenticated loopback stream;
/// tests inject a fake so loading/progress/failure/release states are
/// deterministic without a platform video plugin.
abstract interface class ViewerVideoSession {
  ValueListenable<ViewerVideoPhase> get phase;

  ValueListenable<ViewerVideoTransfer> get transfer;

  ValueListenable<bool> get playing;

  ValueListenable<bool> get buffering;

  /// Whole-video buffering (0..1) reported by the player, null when unknown.
  ValueListenable<double?> get bufferedFraction;

  ValueListenable<Duration> get position;

  /// Video surface once the first frame is available; empty before that.
  Widget buildSurface(BuildContext context);

  Future<void> start();

  Future<void> togglePlayPause();

  Future<void> retry();

  /// Releases player and stream but keeps notifiers usable; the same session
  /// can start again when its page becomes active.
  Future<void> stop();

  Future<void> dispose();
}

typedef ViewerVideoSessionFactory = ViewerVideoSession Function(
  ChatMediaItem item,
);

/// Production playback: `video_player` reading the authenticated loopback
/// stream, with byte progress reported by [MediaStreamHandle.progress].
///
/// The stream is opened only by [start] (the human play action), so the video
/// original is never requested on arrival or while the cover is displayed.
class StreamingViewerVideoSession implements ViewerVideoSession {
  StreamingViewerVideoSession({required this.chat, required this.item});

  final ChatService chat;
  final ChatMediaItem item;

  final ValueNotifier<ViewerVideoPhase> _phase =
      ValueNotifier<ViewerVideoPhase>(ViewerVideoPhase.idle);
  final ValueNotifier<ViewerVideoTransfer> _transfer =
      ValueNotifier<ViewerVideoTransfer>(const ViewerVideoTransfer());
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _buffering = ValueNotifier<bool>(false);
  final ValueNotifier<double?> _bufferedFraction = ValueNotifier<double?>(null);
  final ValueNotifier<Duration> _position = ValueNotifier<Duration>(
    Duration.zero,
  );

  VideoPlayerController? _controller;
  MediaStreamHandle? _handle;
  StreamSubscription<MediaStreamProgress>? _progressSubscription;
  bool _disposed = false;
  bool _starting = false;
  int _generation = 0;

  @override
  ValueListenable<ViewerVideoPhase> get phase => _phase;

  @override
  ValueListenable<ViewerVideoTransfer> get transfer => _transfer;

  @override
  ValueListenable<bool> get playing => _playing;

  @override
  ValueListenable<bool> get buffering => _buffering;

  @override
  ValueListenable<double?> get bufferedFraction => _bufferedFraction;

  @override
  ValueListenable<Duration> get position => _position;

  @override
  Widget buildSurface(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final double ratio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    return Center(
      child: AspectRatio(aspectRatio: ratio, child: VideoPlayer(controller)),
    );
  }

  @override
  Future<void> start() async {
    if (_disposed || _starting) {
      return;
    }
    if (_phase.value == ViewerVideoPhase.opening ||
        _phase.value == ViewerVideoPhase.buffering ||
        _phase.value == ViewerVideoPhase.ready) {
      return;
    }
    _starting = true;
    final int generation = ++_generation;
    _phase.value = ViewerVideoPhase.opening;
    _transfer.value = const ViewerVideoTransfer();
    try {
      final MediaStreamHandle handle = await chat.openMediaStream(item.mediaId);
      if (_disposed || generation != _generation) {
        await handle.close();
        return;
      }
      _handle = handle;
      _progressSubscription = handle.progress.listen((
        MediaStreamProgress progress,
      ) {
        if (_disposed || generation != _generation) {
          return;
        }
        _transfer.value = ViewerVideoTransfer(
          receivedBytes: progress.receivedBytes,
          requestBytes: progress.requestBytes,
          mediaBytes: progress.mediaBytes,
          rangeStart: progress.rangeStart,
          rangeEnd: progress.rangeEnd,
        );
        if (_phase.value == ViewerVideoPhase.opening &&
            progress.receivedBytes > 0) {
          _phase.value = ViewerVideoPhase.buffering;
        }
      }, onError: (Object _) {});
      final VideoPlayerController controller = VideoPlayerController.networkUrl(
        handle.uri,
      );
      _controller = controller;
      controller.addListener(_onControllerChanged);
      await controller.initialize();
      if (_disposed || generation != _generation) {
        return;
      }
      _phase.value = ViewerVideoPhase.ready;
      _buffering.value = controller.value.isBuffering;
      await controller.play();
      _playing.value = controller.value.isPlaying;
    } catch (_) {
      if (generation == _generation) {
        await _teardown();
        if (!_disposed) {
          _phase.value = ViewerVideoPhase.failed;
        }
      }
    } finally {
      _starting = false;
    }
  }

  void _onControllerChanged() {
    final VideoPlayerController? controller = _controller;
    if (_disposed || controller == null) {
      return;
    }
    if (controller.value.hasError) {
      _phase.value = ViewerVideoPhase.failed;
      _buffering.value = false;
      _playing.value = false;
      return;
    }
    if (controller.value.isInitialized) {
      if (_phase.value != ViewerVideoPhase.ready) {
        _phase.value = ViewerVideoPhase.ready;
      }
      _buffering.value = controller.value.isBuffering;
      _playing.value = controller.value.isPlaying;
      _position.value = controller.value.position;
      _bufferedFraction.value = _bufferedFractionOf(controller.value);
    }
  }

  double? _bufferedFractionOf(VideoPlayerValue value) {
    if (!value.isInitialized || value.duration <= Duration.zero) {
      return null;
    }
    if (value.buffered.isEmpty) {
      return 0;
    }
    final Duration end = value.buffered.last.end;
    if (end <= Duration.zero) {
      return 0;
    }
    return (end.inMilliseconds / value.duration.inMilliseconds).clamp(0.0, 1.0);
  }

  @override
  Future<void> togglePlayPause() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    _playing.value = controller.value.isPlaying;
  }

  @override
  Future<void> retry() async {
    if (_disposed) {
      return;
    }
    await _teardown();
    _phase.value = ViewerVideoPhase.idle;
    await start();
  }

  @override
  Future<void> stop() async {
    if (_disposed) {
      return;
    }
    _generation += 1;
    await _teardown();
    _phase.value = ViewerVideoPhase.idle;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    await _teardown();
    _phase.dispose();
    _transfer.dispose();
    _playing.dispose();
    _buffering.dispose();
    _bufferedFraction.dispose();
    _position.dispose();
  }

  Future<void> _teardown() async {
    await _progressSubscription?.cancel();
    _progressSubscription = null;
    final MediaStreamHandle? handle = _handle;
    _handle = null;
    final VideoPlayerController? controller = _controller;
    _controller = null;
    // The authenticated stream must close even when native player creation is
    // still pending. video_player's dispose waits for that native call, so it
    // must not be sequenced before the handle close.
    if (handle != null) {
      await handle.close();
    }
    if (controller != null) {
      unawaited(() async {
        try {
          await controller.dispose();
        } catch (_) {
          // A late native create may fail after the stream was released.
        }
      }());
    }
    _playing.value = false;
    _buffering.value = false;
    _bufferedFraction.value = null;
    _position.value = Duration.zero;
  }
}
