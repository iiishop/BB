import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import 'chat_composer.dart';
import 'chat_format.dart';
import 'media_actions.dart';
import 'message_bubble.dart';

/// One-to-one chat with ordered text/image content and independent attachments.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.peer, required this.chat});

  final ChatUser peer;
  final ChatService chat;

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
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  int _lastPosition = 0;
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
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<ChatMessage> loaded = <ChatMessage>[];
      int cursor = 0;
      bool hasMore = true;
      int pages = 0;
      while (hasMore && pages < 6) {
        final MessagePage page = await widget.chat.loadConversation(
          peerAccount: widget.peer.account,
          afterPosition: cursor,
          limit: 100,
        );
        loaded.addAll(page.items);
        cursor = page.nextPosition;
        hasMore = page.hasMore;
        pages += 1;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _messages
          ..clear()
          ..addAll(_dedupe(loaded));
        _lastPosition = _messages.isEmpty ? 0 : _messages.last.position;
        _loading = false;
      });
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
    }
  }

  Future<void> _pollNew() async {
    if (_fetching) {
      return;
    }
    _fetching = true;
    try {
      final MessagePage page = await widget.chat.loadConversation(
        peerAccount: widget.peer.account,
        afterPosition: _lastPosition,
        limit: 100,
      );
      if (!mounted || page.items.isEmpty) {
        return;
      }
      final Set<String> known = _messages
          .map((ChatMessage message) => message.identity)
          .toSet();
      final List<ChatMessage> fresh = <ChatMessage>[
        for (final ChatMessage message in page.items)
          if (known.add(message.identity)) message,
      ];
      if (fresh.isEmpty) {
        return;
      }
      setState(() {
        _messages.addAll(fresh);
        _lastPosition = page.nextPosition;
      });
      _scrollToBottom();
    } catch (_) {
      // Polling is best effort; the explicit refresh keeps the error visible.
    } finally {
      _fetching = false;
    }
  }

  List<ChatMessage> _dedupe(List<ChatMessage> input) {
    final Set<String> seen = <String>{};
    final List<ChatMessage> result = <ChatMessage>[];
    for (final ChatMessage message in input) {
      if (seen.add(message.identity)) {
        result.add(message);
      }
    }
    result.sort(
      (ChatMessage a, ChatMessage b) => a.position.compareTo(b.position),
    );
    return result;
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
    setState(() {
      _messages.addAll(added);
      _messages.sort(
        (ChatMessage a, ChatMessage b) => a.position.compareTo(b.position),
      );
      _lastPosition = _messages.last.position;
    });
    _scrollToBottom();
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
    try {
      final String operationId =
          'ui-play-${attachment.mediaId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '')}';
      final DownloadTask started = await widget.chat.downloads.start(
        operationId: operationId,
        consumerSession: _consumerSession,
        mediaId: attachment.mediaId,
      );
      final DownloadTask done = await _waitForDownload(started);
      if (done.status != DownloadStatus.succeeded || done.actualPath == null) {
        _snack('播放前下载失败（${done.errorCode ?? '未知原因'}）');
        return;
      }
      if (!mounted) {
        return;
      }
      if (attachment.kind == AttachmentKind.video &&
          (Platform.isAndroid || Platform.isIOS)) {
        await showDialog<void>(
          context: context,
          builder: (BuildContext context) =>
              _VideoDialog(path: done.actualPath!),
        );
      } else {
        await MediaActions.openLocalPath(done.actualPath!);
      }
    } on AuthFailure catch (failure) {
      _snack(failure.message);
    } catch (_) {
      _snack('无法打开该文件');
    } finally {
      _setBusy(attachment.mediaId, false);
    }
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
  const _VideoDialog({required this.path});

  final String path;

  @override
  State<_VideoDialog> createState() => _VideoDialogState();
}

class _VideoDialogState extends State<_VideoDialog> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    final VideoPlayerController controller = VideoPlayerController.file(
      File(widget.path),
    );
    _controller = controller;
    controller.initialize().then((_) {
      if (!mounted) {
        return;
      }
      controller.play();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
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
        child: controller == null || !controller.value.isInitialized
            ? const Center(child: CircularProgressIndicator())
            : GestureDetector(
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
              ),
      ),
    );
  }
}
