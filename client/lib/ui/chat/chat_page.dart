import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../../services/media_stream_proxy.dart';
import 'chat_composer.dart';
import 'chat_format.dart';
import 'media_actions.dart';
import 'message_bubble.dart';

/// One-to-one chat with ordered text/image content and independent attachments.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.peer,
    required this.chat,
    this.openExternalStream,
    this.onMessagesChanged,
  });

  final ChatUser peer;
  final ChatService chat;

  /// Test seam for the desktop streaming hand-off. Production uses the
  /// platform opener on the authenticated loopback stream URL.
  final Future<void> Function(Uri uri)? openExternalStream;

  /// Test/inspection seam: emitted after every ordered merge.
  final void Function(List<ChatMessage> messages)? onMessagesChanged;

  static const Key listKey = Key('chat-message-list');
  static const Key errorKey = Key('chat-error');
  static const Key emptyKey = Key('chat-empty');
  static const Key refreshKey = Key('chat-refresh');

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _busyMedia = <String>{};
  final List<MediaStreamHandle> _streamHandles = <MediaStreamHandle>[];
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;

  /// Highest contiguous server position whose page has been fetched.
  int _fetchedThrough = 0;

  /// Highest position currently rendered (may be a local send beyond the
  /// fetched window). It must never advance the fetch cursor by itself.
  int _displayedMax = 0;
  bool _fetching = false;

  String get _consumerSession =>
      'ui:${widget.chat.selfAccount}:${widget.peer.account}';

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitial());
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_fetching) {
        unawaited(_pollNew());
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    for (final MediaStreamHandle handle in _streamHandles) {
      unawaited(handle.close());
    }
    _streamHandles.clear();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    if (_fetching) {
      return;
    }
    _fetching = true;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<ChatMessage> loaded = <ChatMessage>[];
      int cursor = 0;
      bool hasMore = true;
      int pages = 0;
      // Fetch the complete contiguous history rather than a fixed page cap.
      // A page that makes no progress terminates the loop instead of hiding a
      // gap behind has_more=true.
      while (hasMore && pages < 1000) {
        final MessagePage page = await widget.chat.loadConversation(
          peerAccount: widget.peer.account,
          afterPosition: cursor,
          limit: 100,
        );
        loaded.addAll(page.items);
        final int next = page.nextPosition > cursor
            ? page.nextPosition
            : cursor;
        final bool progressed = page.items.isNotEmpty || next > cursor;
        cursor = next;
        hasMore = page.hasMore && progressed;
        pages += 1;
        if (!progressed) {
          break;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _mergeMessages(loaded);
        _fetchedThrough = cursor;
        _loading = false;
      });
      widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
      _scrollToBottom(animate: false);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = failure.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '消息加载失败，请稍后重试';
      });
    } finally {
      _fetching = false;
    }
  }

  Future<void> _pollNew() async {
    if (_fetching) {
      return;
    }
    _fetching = true;
    try {
      final List<ChatMessage> loaded = <ChatMessage>[];
      int cursor = _fetchedThrough;
      bool hasMore = true;
      int pages = 0;
      while (hasMore && pages < 1000) {
        final MessagePage page = await widget.chat.loadConversation(
          peerAccount: widget.peer.account,
          afterPosition: cursor,
          limit: 100,
        );
        loaded.addAll(page.items);
        final int next = page.nextPosition > cursor
            ? page.nextPosition
            : cursor;
        final bool progressed = page.items.isNotEmpty || next > cursor;
        cursor = next;
        hasMore = page.hasMore && progressed;
        pages += 1;
        if (!progressed) {
          break;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _mergeMessages(loaded);
        // Only a contiguous server read advances the fetch cursor. Local
        // sends in _onSent never touch this value.
        _fetchedThrough = cursor;
      });
      widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
      if (loaded.isNotEmpty) {
        _scrollToBottom();
      }
    } catch (_) {
      // Polling is best effort; the explicit refresh keeps the error visible.
    } finally {
      _fetching = false;
    }
  }

  /// Merge by stable message identity and keep the displayed order. Existing
  /// local sends are preserved when an in-flight history page arrives.
  void _mergeMessages(Iterable<ChatMessage> incoming) {
    final Map<String, ChatMessage> byIdentity = <String, ChatMessage>{
      for (final ChatMessage message in _messages) message.identity: message,
    };
    for (final ChatMessage message in incoming) {
      byIdentity.putIfAbsent(message.identity, () => message);
    }
    _messages
      ..clear()
      ..addAll(byIdentity.values)
      ..sort(
        (ChatMessage a, ChatMessage b) => a.position.compareTo(b.position),
      );
    _displayedMax = _messages.isEmpty ? 0 : _messages.last.position;
  }

  void _onSent(List<ChatMessage> messages) {
    final Set<String> known = _messages
        .map((ChatMessage message) => message.identity)
        .toSet();
    final List<ChatMessage> added = <ChatMessage>[
      for (final ChatMessage message in messages)
        if (known.add(message.identity)) message,
    ];
    if (added.isEmpty) {
      return;
    }
    final int before = _displayedMax;
    setState(() {
      _mergeMessages(added);
    });
    widget.onMessagesChanged?.call(List<ChatMessage>.unmodifiable(_messages));
    if (_displayedMax > before) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      final double target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  Future<void> _saveAs(Attachment attachment) async {
    try {
      final String? path = await MediaActions.pickSaveLocation(
        attachment.filename,
      );
      if (path == null) {
        return;
      }
      _setBusy(attachment.mediaId, true);
      final String saved = await widget.chat.saveAs(
        mediaId: attachment.mediaId,
        targetPath: path,
      );
      _snack('已保存到 $saved');
    } on AuthFailure catch (failure) {
      _snack(failure.message);
    } catch (_) {
      _snack('保存失败');
    } finally {
      _setBusy(attachment.mediaId, false);
    }
  }

  Future<void> _download(Attachment attachment) async {
    if (_busyMedia.contains(attachment.mediaId)) {
      return;
    }
    _setBusy(attachment.mediaId, true);
    try {
      final String operationId =
          'ui-dl-${attachment.mediaId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '')}';
      final DownloadTask started = await widget.chat.downloads.start(
        operationId: operationId,
        consumerSession: _consumerSession,
        mediaId: attachment.mediaId,
      );
      final DownloadTask done = await _waitForDownload(started);
      if (done.status == DownloadStatus.succeeded) {
        _snack('已下载到 ${done.actualPath}');
      } else {
        _snack('下载失败（${done.errorCode ?? '未知原因'}）');
      }
    } on AuthFailure catch (failure) {
      _snack(failure.message);
    } catch (_) {
      _snack('下载失败');
    } finally {
      _setBusy(attachment.mediaId, false);
    }
  }

  Future<DownloadTask> _waitForDownload(DownloadTask initial) async {
    DownloadTask task = initial;
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!task.status.terminal && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final DownloadTask? next = await widget.chat.downloads.get(
        taskId: task.taskId,
        consumerSession: _consumerSession,
      );
      if (next == null) {
        break;
      }
      task = next;
    }
    return task;
  }

  Future<void> _play(Attachment attachment) async {
    if (_busyMedia.contains(attachment.mediaId)) {
      return;
    }
    _setBusy(attachment.mediaId, true);
    MediaStreamHandle? handle;
    try {
      // Opening the stream is the click action. Nothing is requested for the
      // original video before this method runs.
      handle = await widget.chat.openMediaStream(attachment.mediaId);
      _streamHandles.add(handle);
      if (!mounted) {
        return;
      }
      if (attachment.kind == AttachmentKind.video &&
          (Platform.isAndroid || Platform.isIOS)) {
        await showDialog<void>(
          context: context,
          builder: (BuildContext context) => _VideoDialog(
            uri: handle!.uri,
            mediaId: attachment.mediaId,
            onClose: () => _closeStream(handle!),
          ),
        );
      } else {
        await (widget.openExternalStream ?? MediaActions.openUrl)(handle.uri);
        if (!mounted) {
          return;
        }
        final bool? stop = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => _StreamingDialog(
            kind: attachment.kind,
            filename: attachment.filename,
          ),
        );
        if (stop ?? true) {
          await _closeStream(handle);
        }
      }
    } on AuthFailure catch (failure) {
      _snack(failure.message);
      if (handle != null) {
        await _closeStream(handle);
      }
    } catch (_) {
      _snack('无法打开在线播放流');
      if (handle != null) {
        await _closeStream(handle);
      }
    } finally {
      _setBusy(attachment.mediaId, false);
    }
  }

  Future<void> _closeStream(MediaStreamHandle handle) async {
    _streamHandles.remove(handle);
    await handle.close();
  }

  void _setBusy(String mediaId, bool value) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (value) {
        _busyMedia.add(mediaId);
      } else {
        _busyMedia.remove(mediaId);
      }
    });
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.paper,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 1,
        titleSpacing: 0,
        title: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: AppColors.accentSoft,
                shape: BoxShape.circle,
              ),
              child: Text(
                initialsOf(widget.peer.username),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accentDeep,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.peer.username,
                  style: text.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${widget.peer.account} · '
                  '${widget.peer.presence == Presence.online ? '在线' : '离线'}',
                  style: text.bodySmall?.copyWith(fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            key: ChatPage.refreshKey,
            tooltip: '刷新消息',
            onPressed: _loadInitial,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(child: _buildBody()),
          ChatComposer(
            chat: widget.chat,
            peerAccount: widget.peer.account,
            onSent: _onSent,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.chat_bubble_outline_rounded,
                size: 36,
                color: AppColors.inkMuted,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                key: ChatPage.errorKey,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton(
                onPressed: _loadInitial,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.waving_hand_outlined,
              size: 34,
              color: AppColors.inkMuted,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '和 ${widget.peer.username} 还没有消息',
              key: ChatPage.emptyKey,
              style: const TextStyle(color: AppColors.inkMuted),
            ),
          ],
        ),
      );
    }
    final List<Widget> timeline = <Widget>[];
    DateTime? previous;
    for (final ChatMessage message in _messages) {
      if (shouldShowDaySeparator(previous, message.createdAt)) {
        timeline.add(
          _DaySeparator(label: formatDaySeparator(message.createdAt)),
        );
      } else if (shouldShowGapLabel(previous, message.createdAt)) {
        timeline.add(
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(
                formatClockTime(message.createdAt),
                style: const TextStyle(fontSize: 11, color: AppColors.inkMuted),
              ),
            ),
          ),
        );
      }
      final Attachment? attachment = message.attachment;
      timeline.add(
        MessageBubble(
          message: message,
          selfAccount: widget.chat.selfAccount,
          peerUsername: widget.peer.username,
          chat: widget.chat,
          busy: attachment != null && _busyMedia.contains(attachment.mediaId),
          onSaveAs: attachment == null ? null : () => _saveAs(attachment),
          onDownload: attachment == null ? null : () => _download(attachment),
          onPlay: attachment == null || attachment.kind == AttachmentKind.other
              ? null
              : () => _play(attachment),
        ),
      );
      previous = message.createdAt;
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          key: ChatPage.listKey,
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          children: timeline,
        ),
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.border.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.inkMuted),
          ),
        ),
      ),
    );
  }
}

class _VideoDialog extends StatefulWidget {
  const _VideoDialog({
    required this.uri,
    required this.mediaId,
    required this.onClose,
  });

  final Uri uri;
  final String mediaId;
  final Future<void> Function() onClose;

  @override
  State<_VideoDialog> createState() => _VideoDialogState();
}

class _VideoDialogState extends State<_VideoDialog> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final VideoPlayerController controller = VideoPlayerController.networkUrl(
      widget.uri,
    );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) {
        return;
      }
      await controller.play();
      setState(() {
        _error = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '在线播放初始化失败，请重试';
      });
    }
  }

  Future<void> _retry() async {
    await _controller?.dispose();
    _controller = null;
    setState(() {
      _error = null;
    });
    await _initialize();
  }

  Future<void> _cancel() async {
    await widget.onClose();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    unawaited(widget.onClose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    return Dialog(
      child: AspectRatio(
        aspectRatio: controller != null && controller.value.isInitialized
            ? controller.value.aspectRatio
            : 16 / 9,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.inkMuted),
                        ),
                      ),
                    )
                  : controller != null && controller.value.isInitialized
                  ? GestureDetector(
                      onTap: () {
                        if (controller.value.isPlaying) {
                          controller.pause();
                        } else {
                          controller.play();
                        }
                        setState(() {});
                      },
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          VideoPlayer(controller),
                          if (!controller.value.isPlaying)
                            const Icon(
                              Icons.play_circle_fill,
                              size: 56,
                              color: Colors.white70,
                            ),
                        ],
                      ),
                    )
                  : const Center(child: CircularProgressIndicator()),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: '取消',
                onPressed: _cancel,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            if (_error != null)
              Positioned(
                bottom: 8,
                left: 8,
                child: TextButton(onPressed: _retry, child: const Text('重试')),
              ),
          ],
        ),
      ),
    );
  }
}

class _StreamingDialog extends StatelessWidget {
  const _StreamingDialog({required this.kind, required this.filename});

  final AttachmentKind kind;
  final String filename;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('在线播放'),
      content: Text(
        kind == AttachmentKind.video
            ? '正在通过本机回环流播放 $filename。视频原始文件不会被预先下载。'
            : '正在使用系统播放器打开 $filename 的在线流。',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('继续播放'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('停止'),
        ),
      ],
    );
  }
}
