import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../../models/chat_media.dart';
import '../../services/chat_service.dart';
import '../../services/media_stream_proxy.dart';

/// Playback lifecycle of one full-screen video item.
enum ViewerVideoPhase { idle, opening, buffering, ready, failed }

/// Bytes the loopback stream has delivered for the current playback request.
class ViewerVideoTransfer {
  const ViewerVideoTransfer({this.receivedBytes = 0, this.totalBytes});

  final int receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final int? total = totalBytes;
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

  /// Video surface once the first frame is available; empty before that.
  Widget buildSurface(BuildContext context);

  Future<void> start();

  Future<void> togglePlayPause();

  Future<void> retry();

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

  VideoPlayerController? _controller;
  MediaStreamHandle? _handle;
  StreamSubscription<MediaStreamProgress>? _progressSubscription;
  bool _disposed = false;
  bool _starting = false;

  @override
  ValueListenable<ViewerVideoPhase> get phase => _phase;

  @override
  ValueListenable<ViewerVideoTransfer> get transfer => _transfer;

  @override
  ValueListenable<bool> get playing => _playing;

  @override
  ValueListenable<bool> get buffering => _buffering;

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
    _phase.value = ViewerVideoPhase.opening;
    _transfer.value = const ViewerVideoTransfer();
    try {
      final MediaStreamHandle handle = await chat.openMediaStream(item.mediaId);
      if (_disposed) {
        await handle.close();
        return;
      }
      _handle = handle;
      _progressSubscription = handle.progress.listen((
        MediaStreamProgress progress,
      ) {
        if (_disposed) {
          return;
        }
        _transfer.value = ViewerVideoTransfer(
          receivedBytes: progress.receivedBytes,
          totalBytes: progress.totalBytes,
        );
      }, onError: (Object _) {});
      final VideoPlayerController controller = VideoPlayerController.networkUrl(
        handle.uri,
      );
      _controller = controller;
      controller.addListener(_onControllerChanged);
      await controller.initialize();
      if (_disposed) {
        return;
      }
      _phase.value = ViewerVideoPhase.ready;
      _buffering.value = controller.value.isBuffering;
      await controller.play();
      _playing.value = controller.value.isPlaying;
    } catch (_) {
      await _teardown();
      if (!_disposed) {
        _phase.value = ViewerVideoPhase.failed;
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
      if (_phase.value == ViewerVideoPhase.opening) {
        _phase.value = ViewerVideoPhase.ready;
      }
      _buffering.value = controller.value.isBuffering;
      _playing.value = controller.value.isPlaying;
    }
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
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _teardown();
    _phase.dispose();
    _transfer.dispose();
    _playing.dispose();
    _buffering.dispose();
  }

  Future<void> _teardown() async {
    await _progressSubscription?.cancel();
    _progressSubscription = null;
    final VideoPlayerController? controller = _controller;
    _controller = null;
    if (controller != null) {
      await controller.dispose();
    }
    final MediaStreamHandle? handle = _handle;
    _handle = null;
    if (handle != null) {
      await handle.close();
    }
    _playing.value = false;
    _buffering.value = false;
  }
}
