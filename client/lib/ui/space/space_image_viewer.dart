import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../app.dart';
import '../../config/media_policy.dart';
import '../../models/space_models.dart';
import '../../services/media_disk_cache.dart';
import '../../services/space_download_log.dart';
import '../../ui/chat/media_actions.dart';
import '../../ui/chat/media_save.dart';
import '../../ui/media/photo_page.dart';
import '../../ui/media/photo_pager.dart';
import '../../ui/media/photo_source.dart';
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
    final Uint8List? stored = await peek(imageId, variant: variant);
    if (stored != null) {
      return stored;
    }
    return _fetch(imageId, variant);
  }

  /// Memory then disk, never the network.
  ///
  /// The viewer uses this to tell "this original was downloaded earlier" from
  /// "nothing cached", so reopening a picture can show the original without a
  /// download and without an extra "查看原图" tap.
  Future<Uint8List?> peek(String imageId, {String variant = 'thumb'}) async {
    final String key = _key(imageId, variant);
    final Uint8List? hit = _cache[key];
    if (hit != null) {
      return hit;
    }
    final MediaDiskCache? store = disk;
    if (store == null) {
      return null;
    }
    final Uint8List? stored = await store.read(key);
    if (stored == null) {
      return null;
    }
    _remember(key, stored);
    return stored;
  }

  void _remember(String key, Uint8List bytes) {
    if (_cache.containsKey(key)) {
      _order.remove(key);
    }
    _cache[key] = bytes;
    _order.add(key);
    while (_order.length > maxEntries) {
      _cache.remove(_order.removeAt(0));
    }
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
    _remember(key, bytes);
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

/// Adapts [SpaceImageLoader] to the shared photo contract.
///
/// Space image ids are immutable, so the cache key stays `variant|imageId`. The
/// loader's epoch/generation pair is what tells the viewer that a picture it is
/// already showing belongs to a post that no longer exists.
class SpacePhotoSource implements PhotoSource {
  SpacePhotoSource({required this.image, required this.loader})
    : _epoch = loader.epoch,
      _generation = loader.generationFor(image.imageId);

  final SpaceImage image;
  final SpaceImageLoader loader;
  final int _epoch;
  final int _generation;

  @override
  int? get byteSize => image.byteSize;

  /// Space images are never "just sent by this account"; there is no local copy
  /// to hand over.
  @override
  Uint8List? get heldOriginal => null;

  @override
  Listenable? get changes => loader;

  @override
  bool get invalidated => loader.isStale(image.imageId, _epoch, _generation);

  @override
  Future<Uint8List?> readCachedOriginal() =>
      loader.peek(image.imageId, variant: 'original');

  @override
  Future<PhotoPreview> loadPreview() async {
    // Same DEA-471 rule as chat: only a large image gets a bounded derivative
    // first, everything else is shown at full quality immediately.
    final bool derivative = mediaNeedsExplicitOriginal(image.byteSize);
    final Uint8List bytes = await loader.load(
      image.imageId,
      variant: derivative ? 'thumb' : 'original',
    );
    return PhotoPreview(bytes: bytes, isDerivative: derivative);
  }

  @override
  Future<Uint8List> loadOriginal({PhotoProgress? onProgress}) =>
      loader.load(image.imageId, variant: 'original');
}

/// Full-screen viewer for the current post's ordered images only.
///
/// Paging, pinch zoom, the preview→original switch and the on-disk cache all
/// come from `ui/media`; this file owns only what is Space-specific: the
/// ordered sequence of one post, the save flow with its download log, and the
/// status line. Switching posts is impossible by design, so an image sequence
/// never blends with a reference or a neighbour.
class SpaceImageViewer extends StatefulWidget {
  const SpaceImageViewer({
    super.key,
    required this.images,
    required this.initialIndex,
    required this.loader,
    this.saver,
    this.downloadLog,
  });

  final List<SpaceImage> images;
  final int initialIndex;
  final SpaceImageLoader loader;
  final SpaceImageSaver? saver;

  /// Remembers earlier downloads so re-saving the same picture asks first.
  final SpaceDownloadLog? downloadLog;

  static const PhotoViewerKeys keys = PhotoViewerKeys('space-viewer');

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

class _SpaceImageViewerState extends State<SpaceImageViewer> {
  late final PageController _controller;
  late int _index;
  bool _saving = false;
  String? _notice;
  final PhotoPageRegistry _pages = PhotoPageRegistry();

  @override
  void initState() {
    super.initState();
    _index = widget.images.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.images.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    _controller.dispose();
    super.dispose();
  }

  SpaceImage get _current => widget.images[_index];

  /// One controller per image, created on first sight so paging back and forth
  /// does not refetch. Starting the load is the registry's job.
  PhotoPageController _pageFor(int index) {
    final SpaceImage image = widget.images[index];
    return _pages.of(
      image.imageId,
      () => SpacePhotoSource(image: image, loader: widget.loader),
    );
  }

  /// Asks before saving a picture that was downloaded once before.
  ///
  /// On mobile the earlier location is a gallery handle, not a path we can stat,
  /// so the prompt says "saved once" rather than claiming the file is still
  /// there — the user may have deleted it.
  Future<bool> _confirmRedownload(SpaceDownloadRecord earlier) async {
    final bool mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final String when = _formatSavedAt(earlier.savedAt);
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('这张图保存过'),
        content: Text(
          mobile
              ? '你在 $when 保存过一次。相册里可能还在，也可能已经删了——系统查不到。还要再存一份吗？'
              : '你在 $when 保存过一次。还要再存一份吗？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('仍然保存'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  String _formatSavedAt(DateTime at) {
    final DateTime local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    final SpaceImage image = _current;
    final SpaceDownloadLog? log = widget.downloadLog;
    if (log != null) {
      await log.load();
      final SpaceDownloadRecord? earlier = log.find(image.imageId);
      if (earlier != null && mounted) {
        final bool again = await _confirmRedownload(earlier);
        if (!again) {
          return;
        }
      }
    }
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final Uint8List bytes = await widget.loader.load(
        image.imageId,
        variant: 'original',
      );
      final String? location = await (widget.saver ?? defaultSpaceImageSaver)(
        image,
        bytes,
      );
      if (location != null && log != null) {
        // Bookkeeping only; a failure here must not report a bad save.
        await log.record(image.imageId, location: location);
      }
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

  Widget _topBar() {
    return Padding(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final PhotoPageController current = _pageFor(_index);
    final Widget pager = PhotoPager(
      controller: _controller,
      initialIndex: _index,
      itemCount: widget.images.length,
      keys: SpaceImageViewer.keys,
      onPageChanged: (int value) => setState(() => _index = value),
      onDismiss: () => Navigator.of(context).maybePop(),
      itemBuilder: (BuildContext context, int index, ValueChanged<bool> onZoom) {
        return PhotoPage(
          key: ValueKey<String>(widget.images[index].imageId),
          controller: _pageFor(index),
          onZoomChanged: onZoom,
          retryKey: SpaceImageViewer.keys.previewRetry,
          failureLabel: '原图加载失败',
        );
      },
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _topBar(),
            Expanded(
              child: AnimatedBuilder(
                animation: current,
                child: pager,
                builder: (BuildContext context, Widget? child) {
                  return Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      child!,
                      if (current.offersOriginal)
                        Positioned(
                          left: AppSpacing.md,
                          bottom: AppSpacing.lg,
                          child: SafeArea(
                            right: false,
                            top: false,
                            child: OutlinedButton.icon(
                              key: SpaceImageViewer.keys.original,
                              onPressed: current.isDownloading
                                  ? null
                                  : () => unawaited(current.loadOriginal()),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: const Color(0x99000000),
                                side: const BorderSide(color: Colors.white24),
                                minimumSize: const Size(0, 44),
                              ),
                              icon: current.isDownloading
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.hd_outlined, size: 18),
                              label: Text(current.originalLabel),
                            ),
                          ),
                        ),
                      if (current.isDownloading)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            key: SpaceImageViewer.keys.originalProgress,
                            value: current.progress,
                            minHeight: 3,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(
              height: 40,
              child: Center(
                child: Text(
                  _notice ?? '',
                  key: SpaceImageViewer.statusKey,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
