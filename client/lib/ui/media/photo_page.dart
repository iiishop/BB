/// The one image page used by both full-screen viewers.
///
/// Chat media and Space images used to have separate widget trees; the chat one
/// had preview/original switching but no pinch zoom and no disk cache, the Space
/// one had zoom and a disk cache but always downloaded the original. This file
/// owns that behaviour once:
///
/// * memory/held bytes, then the on-disk original, then a bounded preview;
/// * the DEA-471 rule that anything over [mediaDirectOriginalMaxBytes] waits for
///   an explicit "原图" action;
/// * [InteractiveViewer] pinch zoom, reporting zoom state so the enclosing
///   pager can stop stealing horizontal drags.
///
/// Where the bytes come from is a [PhotoSource]; the chrome (top bar, save
/// button, status line, paging arrows) belongs to the caller.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../config/media_policy.dart';
import 'photo_format.dart';
import 'photo_source.dart';

enum PhotoPhase {
  /// Asking the source for a bounded preview.
  loadingPreview,

  /// A derivative preview is on screen; the original is available on request.
  showingPreview,

  /// Fetching the original (either the user asked, or it was small enough).
  downloadingOriginal,

  /// Best available bytes are on screen.
  ready,

  /// Neither preview nor original could be shown.
  failed,
}

/// Byte state machine for one image.
///
/// Separate from the widget so the ordering rules are unit-testable without
/// pumping frames, and so a caller can drive the "查看原图" affordance from
/// wherever its layout puts it.
class PhotoPageController extends ChangeNotifier {
  PhotoPageController({required this.source}) {
    source.changes?.addListener(_onSourceChanged);
  }

  final PhotoSource source;

  int _generation = 0;
  bool _disposed = false;
  Uint8List? _bytes;
  bool _isOriginal = false;
  PhotoPhase _phase = PhotoPhase.loadingPreview;
  int _received = 0;
  int? _total;
  bool _originalFailed = false;

  Uint8List? get bytes => _bytes;

  /// True when [_bytes] are the original, so no "查看原图" affordance applies.
  bool get isOriginal => _isOriginal;

  PhotoPhase get phase => _phase;

  bool get isDownloading => _phase == PhotoPhase.downloadingOriginal;

  /// True when the in-flight original fetch failed; the label turns into a
  /// retry and the page keeps showing whatever it already had.
  bool get originalFailed => _originalFailed;

  /// A preview is on screen and the original has not been fetched: exactly the
  /// case the explicit-original rule is about.
  bool get offersOriginal => _bytes != null && !_isOriginal;

  int? get byteSize => source.byteSize;

  String get originalLabel {
    if (_phase == PhotoPhase.downloadingOriginal) {
      final int? total = _total;
      if (total != null && total > 0) {
        final int percent = (_received * 100 ~/ total).clamp(0, 100);
        return '原图下载中 $percent%';
      }
      return '原图下载中…';
    }
    final int? size = source.byteSize;
    final String base = size == null ? '原图' : '原图 ${formatBytes(size)}';
    return _originalFailed ? '重试 $base' : (size == null ? '查看原图' : base);
  }

  /// Fraction of the original transferred, or null while the size is unknown.
  double? get progress {
    final int? total = _total;
    if (total == null || total <= 0) {
      return null;
    }
    return (_received / total).clamp(0.0, 1.0);
  }

  /// Resolves what to show: held bytes, then a preview, then — if the preview
  /// was a derivative — the cached original, so a picture viewed earlier opens
  /// at full quality. Whether the preview is already the original is the
  /// source's call; this never fetches a large original on its own.
  Future<void> start() async {
    final int generation = ++_generation;
    final Uint8List? held = source.heldOriginal;
    if (held != null && held.isNotEmpty) {
      _bytes = held;
      _isOriginal = true;
      _phase = PhotoPhase.ready;
      _emit();
      return;
    }
    try {
      final PhotoPreview preview = await source.loadPreview();
      if (_isStale(generation)) {
        return;
      }
      _bytes = preview.bytes;
      _isOriginal = !preview.isDerivative;
      _phase = _isOriginal ? PhotoPhase.ready : PhotoPhase.showingPreview;
      _emit();
      if (_isOriginal) {
        return;
      }
    } catch (_) {
      if (_isStale(generation)) {
        return;
      }
      _phase = PhotoPhase.failed;
      _emit();
      return;
    }
    // A previously viewed original is the whole point of the disk cache: no
    // network and no "查看原图" round trip after the viewer is reopened.
    final Uint8List? cached = await source.readCachedOriginal();
    if (_isStale(generation) || cached == null) {
      return;
    }
    _bytes = cached;
    _isOriginal = true;
    _phase = PhotoPhase.ready;
    _emit();
  }

  /// User asked for the original (or for a retry after a failed fetch).
  Future<void> loadOriginal() async {
    if (_phase == PhotoPhase.downloadingOriginal) {
      return;
    }
    await _fetchOriginal(++_generation);
  }

  Future<void> _fetchOriginal(int generation) async {
    _phase = PhotoPhase.downloadingOriginal;
    _received = 0;
    _total = source.byteSize;
    _originalFailed = false;
    _emit();
    try {
      final Uint8List original = await source.loadOriginal(
        onProgress: (int received, int? total) {
          if (_isStale(generation) ||
              _phase != PhotoPhase.downloadingOriginal) {
            return;
          }
          _received = received;
          _total = total ?? _total;
          _emit();
        },
      );
      if (_isStale(generation)) {
        return;
      }
      _bytes = original;
      _isOriginal = true;
      _phase = PhotoPhase.ready;
      _emit();
    } catch (_) {
      if (_isStale(generation)) {
        return;
      }
      _originalFailed = true;
      _phase = _bytes == null ? PhotoPhase.failed : PhotoPhase.showingPreview;
      _emit();
    }
  }

  bool _isStale(int generation) => _disposed || generation != _generation;

  /// The post was deleted or the cache was cleared: whatever is on screen is no
  /// longer allowed to be, so drop it rather than keep showing stale bytes.
  void _onSourceChanged() {
    if (!source.invalidated || _phase == PhotoPhase.failed) {
      return;
    }
    _generation += 1;
    _bytes = null;
    _isOriginal = false;
    _originalFailed = false;
    _phase = PhotoPhase.failed;
    _emit();
  }

  void _emit() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    source.changes?.removeListener(_onSourceChanged);
    super.dispose();
  }
}

/// Keeps one [PhotoPageController] per item for the life of a viewer.
///
/// `PageView.builder` rebuilds items freely, so a controller created inside
/// `itemBuilder` would refetch bytes on every rebuild and lose the "already
/// fetched" state. Both viewers therefore resolve pages through this registry:
/// first use creates the controller and starts loading, later builds reuse it.
class PhotoPageRegistry {
  final Map<String, PhotoPageController> _controllers =
      <String, PhotoPageController>{};

  PhotoPageController of(String key, PhotoSource Function() create) {
    final PhotoPageController? existing = _controllers[key];
    if (existing != null) {
      return existing;
    }
    final PhotoPageController controller = PhotoPageController(source: create());
    _controllers[key] = controller;
    unawaited(controller.start());
    return controller;
  }

  void dispose() {
    for (final PhotoPageController controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }
}

/// The image itself: pinch zoom, plus the loading and failure states.
class PhotoPage extends StatefulWidget {
  const PhotoPage({
    super.key,
    required this.controller,
    this.onZoomChanged,
    this.onPanDelta,
    this.onPanEnd,
    this.retryKey,
    this.failureLabel = '图片加载失败',
  });

  final PhotoPageController controller;

  /// Reports pinch-zoom so the enclosing [PageView] can stop stealing
  /// horizontal drags while a picture is zoomed in.
  final ValueChanged<bool>? onZoomChanged;

  /// Single-finger swipe, relayed to the pager.
  ///
  /// The scale recognizer wins a single finger here no matter what the pager
  /// does, so the movement is handed out instead of fought for; the pager turns
  /// it into a page drag.
  final ValueChanged<Offset>? onPanDelta;

  /// End of a single-finger swipe; the pager snaps to a page.
  final VoidCallback? onPanEnd;

  /// Key for the whole-page retry button, so callers can find it in tests.
  final Key? retryKey;

  /// Wording of the whole-page failure state. The Space viewer only ever shows
  /// originals, so it keeps its own phrasing.
  final String failureLabel;

  /// The transform that carries the current zoom, so a test can read it back
  /// instead of guessing from pixels.
  static const Key zoomKey = Key('photo-viewer-zoom');

  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  static const double _maxScale = 4;

  /// Below this the picture counts as un-zoomed, so a single-finger drag
  /// belongs to the pager again.
  static const double _zoomedThreshold = 1.01;

  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;

  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  /// True between the second finger going down and the pinch ending, even while
  /// the scale is still 1: the first finger must not turn into a page swipe.
  bool _pinching = false;

  /// True while a single finger is swiping: the pager owns the movement and
  /// this page only relays it.
  bool _panning = false;

  bool get _zoomed => _scale > _zoomedThreshold;

  /// Whether the enclosing pager must stop scrolling.
  bool get _frozen => _zoomed || _pinching;

  void _notifyFreeze(bool wasFrozen) {
    if (_frozen != wasFrozen) {
      widget.onZoomChanged?.call(_frozen);
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = details.localFocalPoint;
    if (details.pointerCount >= 2) {
      _panning = false;
      if (!_pinching) {
        final bool wasFrozen = _frozen;
        setState(() => _pinching = true);
        _notifyFreeze(wasFrozen);
      }
      return;
    }
    // One finger on an un-zoomed picture is a page swipe. The scale recognizer
    // wins that arena either way (it sits closer to the pixels than the pager's
    // drag recognizer), so the swipe is relayed out instead of fought for.
    _panning = !_zoomed;
  }

  /// Scales around the pinch focal point and follows it, then clamps the pan so
  /// the picture cannot be dragged off the viewport.
  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_panning && details.pointerCount <= 1) {
      widget.onPanDelta?.call(details.focalPointDelta);
      return;
    }
    _panning = false;
    if (_startScale <= 0) {
      return;
    }
    final Offset center = _viewport.center(Offset.zero);
    final double scale = (_startScale * details.scale).clamp(1.0, _maxScale);
    // Point of the content (relative to the viewport centre) under the fingers
    // when the gesture began.
    final Offset anchor = (_startFocal - center - _startOffset) / _startScale;
    final Offset offset = details.localFocalPoint - center - anchor * scale;
    _apply(scale, _clampOffset(offset, scale));
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_panning) {
      _panning = false;
      widget.onPanEnd?.call();
    }
    final bool wasFrozen = _frozen;
    setState(() {
      _pinching = false;
      if (_scale <= _zoomedThreshold) {
        _scale = 1;
        _offset = Offset.zero;
      }
    });
    _notifyFreeze(wasFrozen);
  }

  void _apply(double scale, Offset offset) {
    final bool wasFrozen = _frozen;
    setState(() {
      _scale = scale;
      _offset = offset;
    });
    _notifyFreeze(wasFrozen);
  }

  Offset _clampOffset(Offset offset, double scale) {
    final double maxX = (_viewport.width * (scale - 1)) / 2;
    final double maxY = (_viewport.height * (scale - 1)) / 2;
    return Offset(
      offset.dx.clamp(-maxX, maxX),
      offset.dy.clamp(-maxY, maxY),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final Uint8List? bytes = widget.controller.bytes;
        if (bytes != null) {
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              _viewport = constraints.biggest;
              return ClipRect(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                  onScaleEnd: _onScaleEnd,
                  child: Center(
                    child: Transform(
                      key: PhotoPage.zoomKey,
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                        ..scaleByDouble(_scale, _scale, 1, 1),
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true,
                        errorBuilder:
                            (
                              BuildContext context,
                              Object error,
                              StackTrace? stackTrace,
                            ) => const _PhotoBroken(label: '图片无法显示'),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        }
        if (widget.controller.phase == PhotoPhase.failed) {
          return _PhotoBroken(
            label: widget.failureLabel,
            retryKey: widget.retryKey,
            onRetry: () => unawaited(widget.controller.start()),
          );
        }
        return const Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white70,
            ),
          ),
        );
      },
    );
  }
}

class _PhotoBroken extends StatelessWidget {
  const _PhotoBroken({required this.label, this.onRetry, this.retryKey});

  final String label;
  final VoidCallback? onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.broken_image_outlined,
            color: Colors.white54,
            size: 40,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(label, style: const TextStyle(color: Colors.white70)),
          if (onRetry != null)
            TextButton(
              key: retryKey,
              onPressed: onRetry,
              child: const Text('重试', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
    );
  }
}
