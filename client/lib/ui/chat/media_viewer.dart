/// Full-screen image/video viewer for one conversation (DEA-471).
///
/// It receives the ordered media sequence built by `buildConversationMedia`,
/// opens at the tapped item and keeps per-item download state local, so a
/// late original download for page A can never replace the preview of page B.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/chat_media.dart';
import '../../services/chat_service.dart';
import '../../services/media_disk_cache.dart';
import '../media/photo_page.dart';
import '../media/photo_pager.dart';
import 'chat_format.dart';
import 'chat_photo_source.dart';
import 'media_save.dart';
import 'viewer_video.dart';

typedef MediaViewerReload =
    Future<({List<ChatMediaItem> items, bool complete})> Function();

class MediaViewer extends StatefulWidget {
  const MediaViewer({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.chat,
    required this.saveService,
    this.onPlayVideo,
    this.onReload,
    this.sequenceComplete = true,
    this.localPreviewFor,
    this.videoSessionFactory,
    this.inlineVideoSupported,
  });

  final List<ChatMediaItem> items;
  final int initialIndex;
  final ChatService chat;
  final MediaSaveService saveService;

  /// Reuses the chat page's existing online-stream play action.
  final Future<void> Function(ChatMediaItem item)? onPlayVideo;

  /// Re-fetches the conversation when the viewer was opened on a partial
  /// history. Null when the caller has no retry path.
  final MediaViewerReload? onReload;

  /// False when the conversation history is not fully loaded; the viewer then
  /// shows a boundary badge instead of pretending the count is complete.
  final bool sequenceComplete;

  /// Already-held bytes of the current account's just-sent images.
  final Uint8List? Function(String mediaId)? localPreviewFor;

  /// Test seam for the full-screen player. Production selects the platform
  /// implementation; null keeps the existing external-player hand-off.
  final ViewerVideoSessionFactory? videoSessionFactory;

  /// Test/platform override for inline playback support.
  final bool? inlineVideoSupported;

  static const PhotoViewerKeys keys = PhotoViewerKeys('media-viewer');

  static const Key pageViewKey = Key('media-viewer-pages');
  static const Key closeKey = Key('media-viewer-close');
  static const Key saveKey = Key('media-viewer-save');
  static const Key indexKey = Key('media-viewer-index');
  static const Key senderKey = Key('media-viewer-sender');
  static const Key boundaryKey = Key('media-viewer-boundary');
  static const Key reloadKey = Key('media-viewer-reload');

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late List<ChatMediaItem> _items;
  late final PageController _controller;
  late int _index;
  bool _saving = false;
  bool _reloading = false;
  bool _complete = true;
  double _dragOffset = 0;
  final Map<String, GlobalKey<_ViewerVideoState>> _videoKeys =
      <String, GlobalKey<_ViewerVideoState>>{};
  double _pointerStartX = 0;
  double _pointerStartY = 0;

  /// One byte-controller per media item; the shared registry keeps a picture
  /// it has already fetched from refetching when the pager rebuilds it.
  final PhotoPageRegistry _pages = PhotoPageRegistry();

  /// Shared with the Space viewer so originals downloaded on either surface
  /// count against one ceiling.
  final MediaDiskCache _disk = sharedMediaDiskCache();

  /// True while the current page is pinch-zoomed: the downward drag that closes
  /// the viewer must not fight the pan gesture.
  bool _pageZoomed = false;

  @override
  void initState() {
    super.initState();
    assert(widget.items.isNotEmpty, 'viewer needs at least one media item');
    _items = widget.items;
    _complete = widget.sequenceComplete;
    _index = widget.initialIndex.clamp(0, _items.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    _controller.dispose();
    super.dispose();
  }

  ChatMediaItem get _current => _items[_index];

  PhotoPageController _pageFor(int index) {
    final ChatMediaItem item = _items[index];
    return _pages.of(
      item.key,
      () => ChatPhotoSource(
        item: item,
        chat: widget.chat,
        heldBytes: widget.localPreviewFor?.call(item.mediaId),
        disk: _disk,
      ),
    );
  }

  void _close() {
    Navigator.of(context).maybePop();
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    final MediaSaveResult result = await widget.saveService.save(_current);
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    if (result.status == MediaSaveStatus.cancelled) {
      return;
    }
    _snack(result.message);
  }

  void _snack(String message) {
    if (!mounted || message.isEmpty) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _reload() async {
    final MediaViewerReload? reload = widget.onReload;
    if (_reloading || reload == null) {
      return;
    }
    final String currentKey = _current.key;
    setState(() => _reloading = true);
    try {
      final ({List<ChatMediaItem> items, bool complete}) refreshed =
          await reload();
      if (!mounted || refreshed.items.isEmpty) {
        return;
      }
      final int found = refreshed.items.indexWhere(
        (ChatMediaItem item) => item.key == currentKey,
      );
      final int next = found < 0 ? 0 : found;
      setState(() {
        _items = refreshed.items;
        _complete = refreshed.complete;
        _index = next;
      });
      if (_controller.hasClients) {
        _controller.jumpToPage(next);
      }
    } catch (_) {
      _snack('加载更多媒体失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _reloading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ChatMediaItem current = _current;
    final PhotoPageController? currentPage = current.isVideo
        ? null
        : _pageFor(_index);
    final Widget pager = PhotoPager(
      controller: _controller,
      initialIndex: _index,
      itemCount: _items.length,
      keys: MediaViewer.keys,
      onDismiss: _close,
      onPageChanged: (int index) {
        final ChatMediaItem previous = _items[_index];
        if (previous.isVideo) {
          _videoKeys[previous.key]?.currentState?.releasePlayback();
        }
        setState(() {
          _index = index;
          _pageZoomed = false;
        });
      },
      itemBuilder:
          (BuildContext context, int index, ValueChanged<bool> onZoom) {
            final ChatMediaItem item = _items[index];
            return item.isVideo
                ? _ViewerVideo(
                    key: _videoKeys.putIfAbsent(
                      item.key,
                      () => GlobalKey<_ViewerVideoState>(),
                    ),
                    item: item,
                    chat: widget.chat,
                    onPlay: widget.onPlayVideo,
                    sessionFactory: widget.videoSessionFactory,
                    inlineSupportedOverride: widget.inlineVideoSupported,
                  )
                : PhotoPage(
                    key: ValueKey<String>(item.key),
                    controller: _pageFor(index),
                    onZoomChanged: (bool zoomed) {
                      _pageZoomed = zoomed;
                      onZoom(zoomed);
                    },
                    retryKey: MediaViewer.keys.previewRetry,
                  );
          },
    );
    // The original-download affordance belongs to the current page, so the
    // chrome follows the page controller rather than the pager.
    final Widget pages = currentPage == null
        ? pager
        : AnimatedBuilder(
            animation: currentPage,
            child: pager,
            builder: (BuildContext context, Widget? child) {
              return Stack(
                children: <Widget>[
                  Positioned.fill(child: child!),
                  if (currentPage.offersOriginal)
                    Positioned(
                      left: AppSpacing.md,
                      bottom: AppSpacing.lg + MediaQuery.of(context).padding.bottom,
                      child: SafeArea(
                        right: false,
                        top: false,
                        child: OutlinedButton.icon(
                          key: MediaViewer.keys.original,
                          onPressed: currentPage.isDownloading
                              ? null
                              : () => unawaited(currentPage.loadOriginal()),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: const Color(0x99000000),
                            side: const BorderSide(color: Colors.white24),
                            minimumSize: const Size(0, 44),
                          ),
                          icon: currentPage.isDownloading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.hd_outlined, size: 18),
                          label: Text(currentPage.originalLabel),
                        ),
                      ),
                    ),
                  if (currentPage.isDownloading)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        key: MediaViewer.keys.originalProgress,
                        value: currentPage.progress,
                        minHeight: 3,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                ],
              );
            },
          );
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F10),
      body: Listener(
        onPointerDown: (PointerDownEvent event) {
          _pointerStartX = event.position.dx;
          _pointerStartY = event.position.dy;
        },
        onPointerMove: (PointerMoveEvent event) {
          // A zoomed picture owns the pointer: panning must not drag the whole
          // viewer down, and a pinch must not be read as a dismiss gesture.
          if (_pageZoomed) {
            return;
          }
          final double dy = event.position.dy - _pointerStartY;
          final double dx = event.position.dx - _pointerStartX;
          // A pointer listener never joins the gesture arena, so horizontal
          // PageView swipes and button taps keep working while a downward
          // drag is tracked for close.
          if (dy > 0 && dy > dx.abs()) {
            setState(() => _dragOffset = dy.clamp(0, 320));
          }
        },
        onPointerUp: (PointerUpEvent event) {
          if (_dragOffset > 96) {
            _close();
            return;
          }
          if (_dragOffset != 0) {
            setState(() => _dragOffset = 0);
          }
        },
        onPointerCancel: (PointerCancelEvent event) {
          if (_dragOffset != 0) {
            setState(() => _dragOffset = 0);
          }
        },
        child: Transform.translate(
          offset: Offset(0, _dragOffset),
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: pages),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: _TopBar(
                  index: _index,
                  total: _items.length,
                  item: current,
                  complete: _complete,
                  reloading: _reloading,
                  onClose: _close,
                  onReload: widget.onReload == null ? null : _reload,
                ),
              ),
              Positioned(
                right: AppSpacing.md,
                bottom: AppSpacing.lg + MediaQuery.of(context).padding.bottom,
                child: _SaveButton(busy: _saving, onTap: _save),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.index,
    required this.total,
    required this.item,
    required this.complete,
    required this.reloading,
    required this.onClose,
    this.onReload,
  });

  final int index;
  final int total;
  final ChatMediaItem item;
  final bool complete;
  final bool reloading;
  final VoidCallback onClose;
  final VoidCallback? onReload;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              IconButton(
                key: MediaViewer.closeKey,
                tooltip: '关闭',
                onPressed: onClose,
                color: Colors.white,
                icon: const Icon(Icons.close_rounded),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '第 ${index + 1} / 共 $total',
                      key: MediaViewer.indexKey,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.senderLabel} · ${formatContactTime(item.createdAt)}',
                      key: MediaViewer.senderKey,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    if (!complete)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              '仅显示已加载的 $total 项',
                              key: MediaViewer.boundaryKey,
                              style: const TextStyle(
                                color: AppColors.warningBorder,
                                fontSize: 12,
                              ),
                            ),
                            if (onReload != null)
                              TextButton(
                                key: MediaViewer.reloadKey,
                                onPressed: reloading ? null : onReload,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(0, 28),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.sm,
                                  ),
                                ),
                                child: reloading
                                    ? const SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text('重试加载'),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      left: false,
      top: false,
      child: FilledButton.icon(
        key: MediaViewer.saveKey,
        onPressed: busy ? null : onTap,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.ink,
          disabledBackgroundColor: Colors.white70,
          // The app theme stretches filled buttons to the full width; this
          // floating button must size to its content.
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm + 2,
          ),
        ),
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.download_rounded, size: 18),
        label: Text(busy ? '保存中…' : '保存'),
      ),
    );
  }
}

class _VideoChip extends StatelessWidget {
  const _VideoChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }
}

class _ViewerVideo extends StatefulWidget {
  const _ViewerVideo({
    super.key,
    required this.item,
    required this.chat,
    this.onPlay,
    this.sessionFactory,
    this.inlineSupportedOverride,
  });

  final ChatMediaItem item;
  final ChatService chat;
  final Future<void> Function(ChatMediaItem item)? onPlay;

  /// Injected by tests. Null selects the platform default: inline playback on
  /// Android/iOS/macOS/Linux/Windows, explicit external-player hand-off
  /// elsewhere.
  final ViewerVideoSessionFactory? sessionFactory;

  final bool? inlineSupportedOverride;

  @override
  State<_ViewerVideo> createState() => _ViewerVideoState();
}

class _ViewerVideoState extends State<_ViewerVideo> {
  Uint8List? _cover;
  bool _loading = true;
  ViewerVideoSession? _session;

  bool get _inlineCapable {
    final bool? override = widget.inlineSupportedOverride;
    if (override != null) {
      return override;
    }
    if (widget.sessionFactory != null) {
      return true;
    }
    if (kIsWeb) {
      return false;
    }
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isWindows;
  }

  ViewerVideoSessionFactory? get _factory {
    final ViewerVideoSessionFactory? injected = widget.sessionFactory;
    if (injected != null) {
      return injected;
    }
    if (!_inlineCapable) {
      return null;
    }
    return (ChatMediaItem item) =>
        StreamingViewerVideoSession(chat: widget.chat, item: item);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadCover());
  }

  void releasePlayback() {
    unawaited(_session?.stop());
  }

  @override
  void dispose() {
    unawaited(_session?.dispose());
    super.dispose();
  }

  Future<void> _loadCover() async {
    final String? coverId = widget.item.coverMediaId;
    if (coverId == null) {
      if (mounted) {
        setState(() => _loading = false);
      }
      return;
    }
    try {
      final Uint8List bytes = await widget.chat.loadListPreview(coverId);
      if (!mounted) {
        return;
      }
      setState(() {
        _cover = bytes;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _play() async {
    if (!mounted) {
      return;
    }
    final ViewerVideoSessionFactory? factory = _factory;
    if (factory == null) {
      await widget.onPlay?.call(widget.item);
      return;
    }
    final ViewerVideoSession? existing = _session;
    if (existing != null) {
      if (existing.phase.value == ViewerVideoPhase.idle) {
        await existing.start();
      }
      return;
    }
    final ViewerVideoSession session = factory(widget.item);
    setState(() => _session = session);
    await session.start();
  }

  String _rangeLabel(ViewerVideoTransfer transfer) {
    final String received = formatBytes(transfer.receivedBytes);
    final int? requestBytes = transfer.requestBytes;
    if (requestBytes == null) {
      return '本次 Range 已接收 $received';
    }
    return '本次 Range 接收 $received / ${formatBytes(requestBytes)}';
  }

  String _formatPosition(Duration position) {
    final String minutes = position.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final String seconds = position.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    if (position.inHours > 0) {
      return '${position.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Widget _coverWidget() {
    if (_cover != null) {
      return Image.memory(
        _cover!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                const Center(
                  child: Icon(
                    Icons.movie_outlined,
                    color: Colors.white54,
                    size: 46,
                  ),
                ),
      );
    }
    if (_loading) {
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
    }
    return const Center(
      child: Icon(Icons.movie_outlined, color: Colors.white54, size: 46),
    );
  }

  Widget _idleContent() {
    final bool externalOnly = _factory == null;
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        IconButton.filled(
          key: ValueKey<String>('media-viewer-play-${widget.item.mediaId}'),
          onPressed: widget.onPlay == null && externalOnly
              ? null
              : () => unawaited(_play()),
          style: IconButton.styleFrom(
            backgroundColor: const Color(0x99000000),
            foregroundColor: Colors.white,
            minimumSize: const Size(64, 64),
          ),
          icon: const Icon(Icons.play_arrow_rounded, size: 38),
        ),
        if (externalOnly)
          Positioned(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            bottom: AppSpacing.xxl,
            child: Text(
              '当前桌面构建使用系统播放器，暂不支持内嵌播放',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _sessionContent(ViewerVideoSession session) {
    return ValueListenableBuilder<ViewerVideoPhase>(
      valueListenable: session.phase,
      builder: (BuildContext context, ViewerVideoPhase phase, Widget? child) {
        if (phase == ViewerVideoPhase.failed) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.white70,
                  size: 34,
                ),
                const SizedBox(height: AppSpacing.sm),
                const Text('视频播放失败', style: TextStyle(color: Colors.white)),
                TextButton(
                  key: const Key('media-viewer-video-retry'),
                  onPressed: () => unawaited(session.retry()),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        if (phase == ViewerVideoPhase.idle) {
          return _idleContent();
        }
        if (phase == ViewerVideoPhase.ready) {
          return Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Positioned.fill(child: session.buildSurface(context)),
              Positioned(
                left: AppSpacing.md,
                bottom: AppSpacing.lg,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ValueListenableBuilder<double?>(
                      valueListenable: session.bufferedFraction,
                      builder:
                          (
                            BuildContext context,
                            double? fraction,
                            Widget? child,
                          ) {
                            return _VideoChip(
                              key: const Key('media-viewer-video-buffered'),
                              text: fraction == null
                                  ? '已缓冲 —'
                                  : '已缓冲 ${(fraction * 100).round()}%',
                            );
                          },
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    ValueListenableBuilder<Duration>(
                      valueListenable: session.position,
                      builder:
                          (
                            BuildContext context,
                            Duration position,
                            Widget? child,
                          ) {
                            return _VideoChip(
                              key: const Key('media-viewer-video-position'),
                              text: '播放中 ${_formatPosition(position)}',
                            );
                          },
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: Align(
                  alignment: Alignment.center,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: session.playing,
                    builder:
                        (BuildContext context, bool playing, Widget? child) {
                          return IconButton.filled(
                            key: const Key('media-viewer-video-toggle'),
                            onPressed: () =>
                                unawaited(session.togglePlayPause()),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0x66000000),
                              foregroundColor: Colors.white,
                              minimumSize: const Size(56, 56),
                            ),
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 34,
                            ),
                          );
                        },
                  ),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: session.buffering,
                builder: (BuildContext context, bool buffering, Widget? child) {
                  if (!buffering) {
                    return const SizedBox.shrink();
                  }
                  return const Positioned(
                    top: AppSpacing.md,
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        }
        return Center(
          child: ValueListenableBuilder<ViewerVideoTransfer>(
            valueListenable: session.transfer,
            builder:
                (
                  BuildContext context,
                  ViewerVideoTransfer transfer,
                  Widget? child,
                ) {
                  final double? fraction = transfer.requestFraction;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          phase == ViewerVideoPhase.opening
                              ? '正在请求视频…'
                              : '缓冲中…',
                          style: const TextStyle(color: Colors.white),
                        ),
                        if (transfer.receivedBytes > 0 ||
                            transfer.requestBytes != null) ...<Widget>[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            _rangeLabel(transfer),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.sm),
                        SizedBox(
                          width: 220,
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      ],
                    ),
                  );
                },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ViewerVideoSession? session = _session;
    return ColoredBox(
      color: const Color(0xFF0B0F10),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned.fill(child: _coverWidget()),
          Positioned.fill(
            child: session == null ? _idleContent() : _sessionContent(session),
          ),
        ],
      ),
    );
  }
}
