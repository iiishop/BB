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
import '../../config/media_policy.dart';
import '../../models/chat_media.dart';
import '../../models/chat_models.dart';
import '../../services/chat_api_client.dart';
import '../../services/chat_service.dart';
import 'chat_format.dart';
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
    _controller.dispose();
    super.dispose();
  }

  ChatMediaItem get _current => _items[_index];

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
    final Widget pages = PageView.builder(
      key: MediaViewer.pageViewKey,
      controller: _controller,
      itemCount: _items.length,
      onPageChanged: (int index) {
        final ChatMediaItem previous = _items[_index];
        if (previous.isVideo) {
          _videoKeys[previous.key]?.currentState?.releasePlayback();
        }
        setState(() => _index = index);
      },
      itemBuilder: (BuildContext context, int index) {
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
            : _ViewerImage(
                key: ValueKey<String>(item.key),
                item: item,
                chat: widget.chat,
                localBytes: widget.localPreviewFor?.call(item.mediaId),
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

class _ViewerImage extends StatefulWidget {
  const _ViewerImage({
    super.key,
    required this.item,
    required this.chat,
    this.localBytes,
  });

  final ChatMediaItem item;
  final ChatService chat;
  final Uint8List? localBytes;

  @override
  State<_ViewerImage> createState() => _ViewerImageState();
}

enum _OriginalState { idle, loading, failed, loaded }

class _ViewerImageState extends State<_ViewerImage> {
  MediaPreview? _preview;
  String? _previewError;
  bool _loadingPreview = true;
  int? _size;

  Uint8List? _original;
  _OriginalState _originalState = _OriginalState.idle;
  int _received = 0;
  int? _total;

  int _previewGeneration = 0;
  int _originalGeneration = 0;

  @override
  void initState() {
    super.initState();
    final Uint8List? local = widget.localBytes;
    if (local != null && local.isNotEmpty) {
      _original = local;
      _size = local.length;
      _preview = MediaPreview(bytes: local, isDerivative: false);
      _loadingPreview = false;
      return;
    }
    _size = widget.item.byteSize;
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _previewGeneration += 1;
    _originalGeneration += 1;
    super.dispose();
  }

  /// Resolve the original size first (metadata for historical body images),
  /// then fetch bounded thumbnail bytes for large images and the original for
  /// small ones. A metadata failure is retryable and never assumes "small".
  Future<void> _initialize() async {
    final int generation = ++_previewGeneration;
    setState(() {
      _loadingPreview = true;
      _previewError = null;
    });
    try {
      int? size = widget.item.byteSize;
      if (size == null) {
        final Attachment metadata = await widget.chat.loadMediaMetadata(
          widget.item.mediaId,
        );
        size = metadata.byteSize;
      }
      final int resolvedSize = size;
      if (!mounted || generation != _previewGeneration) {
        return;
      }
      final MediaPreview preview = await widget.chat.loadMediaPreview(
        widget.item.mediaId,
        thumbnail: mediaNeedsExplicitOriginal(resolvedSize),
      );
      if (!mounted || generation != _previewGeneration) {
        return;
      }
      setState(() {
        _size = resolvedSize;
        _preview = preview;
        _loadingPreview = false;
      });
    } catch (_) {
      if (!mounted || generation != _previewGeneration) {
        return;
      }
      setState(() {
        _loadingPreview = false;
        _previewError = '图片加载失败';
      });
    }
  }

  bool get _showOriginalButton =>
      (_preview?.isDerivative ?? false) &&
      _original == null &&
      _size != null &&
      mediaNeedsExplicitOriginal(_size!);

  String get _originalLabel {
    if (_originalState == _OriginalState.loading) {
      final int? total = _total;
      if (total != null && total > 0) {
        final int percent = (_received * 100 ~/ total).clamp(0, 100);
        return '原图下载中 $percent%';
      }
      return '原图下载中…';
    }
    final String size = _size == null ? '原图' : '原图 ${formatBytes(_size!)}';
    if (_originalState == _OriginalState.failed) {
      return '重试 $size';
    }
    return _size == null ? '查看原图' : size;
  }

  Future<void> _loadOriginal() async {
    if (_originalState == _OriginalState.loading) {
      return;
    }
    final int generation = ++_originalGeneration;
    setState(() {
      _originalState = _OriginalState.loading;
      _received = 0;
      _total = _size;
    });
    try {
      final MediaResponse media = await widget.chat.fetchOriginalMedia(
        widget.item.mediaId,
        onProgress: (int received, int? total) {
          if (!mounted || generation != _originalGeneration) {
            return;
          }
          setState(() {
            _received = received;
            _total = total ?? _total;
          });
        },
      );
      if (!mounted || generation != _originalGeneration) {
        return;
      }
      setState(() {
        _original = media.bytes;
        _size = media.bytes.length;
        _originalState = _OriginalState.loaded;
      });
    } catch (_) {
      if (!mounted || generation != _originalGeneration) {
        return;
      }
      setState(() => _originalState = _OriginalState.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _original ?? _preview?.bytes;
    return ColoredBox(
      color: const Color(0xFF0B0F10),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: bytes != null
                ? Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (
                      BuildContext context,
                      Object error,
                      StackTrace? stackTrace,
                    ) => const _BrokenMedia(label: '图片无法显示'),
                  )
                : _previewError != null
                ? _BrokenMedia(label: _previewError!, onRetry: _initialize)
                : const Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                  ),
          ),
          if (bytes != null && _loadingPreview && _preview == null)
            const Center(child: CircularProgressIndicator()),
          if (_showOriginalButton)
            Positioned(
              left: AppSpacing.md,
              bottom: AppSpacing.lg + MediaQuery.of(context).padding.bottom,
              child: SafeArea(
                right: false,
                top: false,
                child: OutlinedButton.icon(
                  key: const Key('media-viewer-original'),
                  onPressed: _originalState == _OriginalState.loading
                      ? null
                      : _loadOriginal,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: const Color(0x99000000),
                    side: const BorderSide(color: Colors.white24),
                    minimumSize: const Size(0, 44),
                  ),
                  icon: _originalState == _OriginalState.loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.hd_outlined, size: 18),
                  label: Text(_originalLabel),
                ),
              ),
            ),
          if (_originalState == _OriginalState.loading)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                key: const Key('media-viewer-original-progress'),
                value: (_total != null && _total! > 0)
                    ? (_received / _total!).clamp(0.0, 1.0)
                    : null,
                minHeight: 3,
                backgroundColor: Colors.white12,
              ),
            ),
        ],
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

class _BrokenMedia extends StatelessWidget {
  const _BrokenMedia({required this.label, this.onRetry});

  final String label;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.broken_image_outlined,
            color: Colors.white54,
            size: 34,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(label, style: const TextStyle(color: Colors.white70)),
          if (onRetry != null)
            TextButton(
              key: const Key('media-viewer-preview-retry'),
              onPressed: onRetry,
              child: const Text('重试'),
            ),
        ],
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
