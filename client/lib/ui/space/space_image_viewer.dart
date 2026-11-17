import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../app.dart';
import '../../models/space_models.dart';
import '../../services/media_disk_cache.dart';
import '../../ui/chat/media_actions.dart';
import '../../ui/chat/media_save.dart';
import 'space_gateway.dart';

/// Thrown when an image response arrives after the image was invalidated, or
/// when a viewer asks for bytes that are no longer current.
class SpaceImageInvalidated implements Exception {
  const SpaceImageInvalidated();
}

/// Account/server-scoped image cache for thumbnails and originals.
///
/// Bytes come from the shared Space service (`get_image`), so authorization and
/// deletion checks are re-applied on every fetch. The cache is bounded and is
/// cleared for a deleted post or on reconnect invalidation. A response that
/// was already in flight when the image was invalidated is discarded instead
/// of refilling the cache.
class SpaceImageLoader extends ChangeNotifier {
  SpaceImageLoader(this.gateway, {this.maxEntries = 96, this.disk});
  final SpaceGateway gateway;
  final int maxEntries;

  /// Survives restarts. Without it, reopening a picture re-downloaded the
  /// original even though it had been viewed a minute earlier.
  final MediaDiskCache? disk;

  final Map<String, Uint8List> _cache = <String, Uint8List>{};
  final List<String> _order = <String>[];
  final Map<String, Future<Uint8List>> _inflight =
      <String, Future<Uint8List>>{};
  final Map<String, int> _generation = <String, int>{};
  int _epoch = 0;

  int get epoch => _epoch;

  int generationFor(String imageId) => _generation[imageId] ?? 0;

  bool isStale(String imageId, int epoch, int generation) =>
      _epoch != epoch || generationFor(imageId) != generation;

  String _key(String imageId, String variant) => '$variant|$imageId';

  Uint8List? cached(String imageId, {String variant = 'thumb'}) =>
      _cache[_key(imageId, variant)];

  Future<Uint8List> load(String imageId, {String variant = 'thumb'}) {
    final String key = _key(imageId, variant);
    final Uint8List? hit = _cache[key];
    if (hit != null) {
      return Future<Uint8List>.value(hit);
    }
    final Future<Uint8List>? running = _inflight[key];
    if (running != null) {
      return running;
    }
    final Future<Uint8List> request = _loadWithDisk(imageId, variant, key);
    _inflight[key] = request;
    return request.whenComplete(() => _inflight.remove(key));
  }

  /// Memory, then disk, then network. A disk hit also warms the memory layer so
  /// paging back and forth inside the viewer stays synchronous.
  Future<Uint8List> _loadWithDisk(
    String imageId,
    String variant,
    String key,
  ) async {
    final MediaDiskCache? store = disk;
    if (store != null) {
      final Uint8List? stored = await store.read(key);
      if (stored != null) {
        _cache[key] = stored;
        _order.add(key);
        while (_order.length > maxEntries) {
          _cache.remove(_order.removeAt(0));
        }
        return stored;
      }
    }
    return _fetch(imageId, variant);
  }

  Future<Uint8List> _fetch(String imageId, String variant) async {
    final int epoch = _epoch;
    final int generation = generationFor(imageId);
    final SpaceImageContent content = await gateway.image(
      imageId,
      variant: variant,
    );
    if (isStale(imageId, epoch, generation)) {
      throw const SpaceImageInvalidated();
    }
    final Uint8List bytes = base64Decode(content.base64);
    final String key = _key(imageId, variant);
    _cache[key] = bytes;
    _order.add(key);
    while (_order.length > maxEntries) {
      _cache.remove(_order.removeAt(0));
    }
    // Persist in the background: the caller gets its bytes now, and a failed
    // write only costs a future re-download.
    final MediaDiskCache? store = disk;
    if (store != null) {
      unawaited(store.write(key, bytes));
    }
    return bytes;
  }

  void invalidateImage(String imageId) {
    _generation[imageId] = generationFor(imageId) + 1;
    for (final String variant in <String>['thumb', 'original']) {
      final String key = _key(imageId, variant);
      _cache.remove(key);
      _order.remove(key);
    }
    notifyListeners();
  }

  void clear() {
    _epoch += 1;
    _cache.clear();
    _order.clear();
    _inflight.clear();
    notifyListeners();
  }
}

/// Save hook for the viewer. Production uses the same gallery/file paths as
/// chat media; tests inject a recorder so no platform dialog is opened.
typedef SpaceImageSaver = Future<String?> Function(
  SpaceImage image,
  Uint8List bytes,
);

Future<String?> defaultSpaceImageSaver(
  SpaceImage image,
  Uint8List bytes,
) async {
  final String filename = image.filename.isEmpty
      ? 'space-image'
      : image.filename;
  final Directory directory = await getTemporaryDirectory();
  final String path = '${directory.path}${Platform.pathSeparator}$filename';
  final File file = File(path);
  await file.writeAsBytes(bytes, flush: true);
  try {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      final GallerySaveOutcome outcome = await const PlatformGallerySaver()
          .save(
            path: path,
            filename: filename,
            mimeType: image.mimeType,
            isVideo: false,
          );
      return outcome.location;
    }
    final String? destination = await MediaActions.pickSaveLocation(filename);
    if (destination == null) {
      return null;
    }
    await File(destination).writeAsBytes(bytes, flush: true);
    return destination;
  } finally {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Best effort: a surviving temp file is not a user-visible artifact.
    }
  }
}

/// Full-screen viewer for the current post's ordered images only.
///
/// Interaction mirrors the chat viewer: original bytes, previous/next,
/// save, and keyboard left/right/escape. Switching posts is impossible by
/// design, so an image sequence never blends with a reference or neighbour.
class SpaceImageViewer extends StatefulWidget {
  const SpaceImageViewer({
    super.key,
    required this.images,
    required this.initialIndex,
    required this.loader,
    this.saver,
  });

  final List<SpaceImage> images;
  final int initialIndex;
  final SpaceImageLoader loader;
  final SpaceImageSaver? saver;

  static const Key pagesKey = Key('space-viewer-pages');
  static const Key closeKey = Key('space-viewer-close');
  static const Key saveKey = Key('space-viewer-save');
  static const Key previousKey = Key('space-viewer-previous');
  static const Key nextKey = Key('space-viewer-next');
  static const Key indexKey = Key('space-viewer-index');
  static const Key statusKey = Key('space-viewer-status');

  @override
  State<SpaceImageViewer> createState() => _SpaceImageViewerState();
}

/// Paging request produced by the arrow keys.
///
/// Arrow keys are declared as shortcuts instead of being read in
/// [Focus.onKeyEvent]: WidgetsApp binds them to `DirectionalFocusIntent` above
/// the page, so a listener on this node never sees them and the keys travel
/// focus instead of paging. A shortcut closer to the focused node wins, and
/// this one is closer.
class _StepIntent extends Intent {
  const _StepIntent(this.delta);

  final int delta;
}

class _SpaceImageViewerState extends State<SpaceImageViewer> {
  late final PageController _controller;
  late int _index;
  bool _saving = false;

  /// True while the current page is pinch-zoomed; the pager stops scrolling
  /// so gestures stay with [InteractiveViewer].
  bool _zoomed = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  SpaceImage get _current => widget.images[_index];

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final Uint8List bytes = await widget.loader.load(
        _current.imageId,
        variant: 'original',
      );
      final String? location = await (widget.saver ?? defaultSpaceImageSaver)(
        _current,
        bytes,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _notice = location == null ? '已取消保存' : '已保存：$location';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _notice = '保存失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// Desktop gets explicit paging affordances; mobile stays swipe-only.
  ///
  /// Reads `Theme.of(context).platform` rather than `Platform.isWindows` so a
  /// widget test can exercise both branches via an injected theme.
  static bool desktopOf(BuildContext context) {
    final TargetPlatform platform = Theme.of(context).platform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS;
  }

  void _step(int delta) {
    final int next = (_index + delta).clamp(0, widget.images.length - 1);
    if (next == _index) {
      return;
    }
    setState(() => _index = next);
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  /// Desktop-only affordance: the arrow keys page, but nothing on screen says
  /// so. Kept off mobile where it would cover the photo with no hover to hide.
  Widget _pagingArrow({
    required Key key,
    required int delta,
    required IconData icon,
    required String tooltip,
    required Alignment alignment,
  }) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        child: IconButton(
          key: key,
          onPressed: () => _step(delta),
          tooltip: tooltip,
          style: IconButton.styleFrom(
            backgroundColor: Colors.black54,
            foregroundColor: Colors.white,
            minimumSize: const Size(48, 48),
          ),
          icon: Icon(icon, size: 32),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool desktop = desktopOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _StepIntent: CallbackAction<_StepIntent>(
              onInvoke: (_StepIntent intent) {
                _step(intent.delta);
                return null;
              },
            ),
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                Navigator.of(context).maybePop();
                return null;
              },
            ),
          },
          child: Focus(
            autofocus: true,
            child: SafeArea(
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      children: <Widget>[
                        IconButton(
                          key: SpaceImageViewer.closeKey,
                          onPressed: () => Navigator.of(context).maybePop(),
                          color: Colors.white,
                          icon: const Icon(Icons.close_rounded),
                          tooltip: '关闭',
                        ),
                        const Spacer(),
                        Text(
                          '${_index + 1} / ${widget.images.length}',
                          key: SpaceImageViewer.indexKey,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          key: SpaceImageViewer.saveKey,
                          onPressed: _saving ? null : _save,
                          color: Colors.white,
                          icon: _saving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                          tooltip: '保存原图',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        PageView.builder(
                          key: SpaceImageViewer.pagesKey,
                          controller: _controller,
                          // A zoomed picture owns horizontal drags; letting the
                          // pager keep them would turn a two-finger pinch into a
                          // page swipe on the first finger.
                          physics: _zoomed
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          itemCount: widget.images.length,
                          onPageChanged: (int value) => setState(() {
                            _index = value;
                            _zoomed = false;
                          }),
                          itemBuilder: (BuildContext context, int index) {
                            return _ViewerImage(
                              key: ValueKey<String>(
                                widget.images[index].imageId,
                              ),
                              image: widget.images[index],
                              loader: widget.loader,
                              onZoomChanged: (bool zoomed) {
                                if (zoomed != _zoomed && mounted) {
                                  setState(() => _zoomed = zoomed);
                                }
                              },
                            );
                          },
                        ),
                        // Mobile stays swipe-only: a persistent arrow would sit on
                        // top of the photo and there is no hover to reveal it.
                        if (desktop && _index > 0)
                          _pagingArrow(
                            key: SpaceImageViewer.previousKey,
                            delta: -1,
                            icon: Icons.chevron_left_rounded,
                            tooltip: '上一张',
                            alignment: Alignment.centerLeft,
                          ),
                        if (desktop && _index < widget.images.length - 1)
                          _pagingArrow(
                            key: SpaceImageViewer.nextKey,
                            delta: 1,
                            icon: Icons.chevron_right_rounded,
                            tooltip: '下一张',
                            alignment: Alignment.centerRight,
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 40,
                    child: Center(
                      child: Text(
                        _notice ?? '',
                        key: SpaceImageViewer.statusKey,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerImage extends StatefulWidget {
  const _ViewerImage({
    super.key,
    required this.image,
    required this.loader,
    this.onZoomChanged,
  });

  final SpaceImage image;
  final SpaceImageLoader loader;

  /// Reports pinch-zoom state so the enclosing [PageView] can stop stealing
  /// horizontal drags while a picture is zoomed in.
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<_ViewerImage> createState() => _ViewerImageState();
}

class _ViewerImageState extends State<_ViewerImage> {
  late Future<Uint8List> _future;
  late int _epoch;
  late int _generation;
  bool _invalidated = false;
  final TransformationController _transform = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    widget.loader.addListener(_onLoaderChanged);
    _transform.addListener(_onTransformChanged);
    _load();
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    widget.loader.removeListener(_onLoaderChanged);
    super.dispose();
  }

  /// Pinch starts at scale 1. A single finger drag keeps it at 1, so this
  /// only flips while the user is actually zooming or panning a zoomed picture.
  void _onTransformChanged() {
    final bool zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) {
      return;
    }
    _zoomed = zoomed;
    widget.onZoomChanged?.call(zoomed);
  }

  void _load() {
    _invalidated = false;
    _epoch = widget.loader.epoch;
    _generation = widget.loader.generationFor(widget.image.imageId);
    _future = widget.loader.load(widget.image.imageId, variant: 'original');
  }

  void _onLoaderChanged() {
    if (!mounted) {
      return;
    }
    if (!widget.loader.isStale(widget.image.imageId, _epoch, _generation)) {
      return;
    }
    setState(() {
      _invalidated = true;
      _epoch = widget.loader.epoch;
      _generation = widget.loader.generationFor(widget.image.imageId);
    });
  }

  void _retry() {
    setState(_load);
  }

  Widget _errorView() {
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
          const Text('原图加载失败', style: TextStyle(color: Colors.white70)),
          TextButton(
            onPressed: _retry,
            child: const Text('重试', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_invalidated) {
      return _errorView();
    }
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        if (snapshot.hasData) {
          return InteractiveViewer(
            maxScale: 4,
            transformationController: _transform,
            child: Center(
              child: Image.memory(
                snapshot.data!,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return _errorView();
        }
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      },
    );
  }
}
