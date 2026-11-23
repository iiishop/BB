import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../widgets/profile_avatar.dart';
import 'chat_avatars.dart';
import 'chat_format.dart';
import 'pending_send.dart';

/// Plays the entrance for a genuinely new message.
///
/// The flag is computed by the chat page from "this identity was not on screen
/// before", so history loads, scroll rebuilds, conversation switches and
/// refreshed pages pass `animate: false` and never replay an old bubble.
class MessageEntrance extends StatefulWidget {
  const MessageEntrance({
    super.key,
    required this.child,
    required this.animate,
    this.duration = const Duration(milliseconds: 160),
  });

  final Widget child;
  final bool animate;
  final Duration duration;

  static const Key animationKey = Key('message-entrance-animation');

  @override
  State<MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<MessageEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) {
      return;
    }
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Decide once per element: a later rebuild (pending -> committed, parent
    // setState, scroll) must not restart or cancel a running entrance.
    if (widget.animate && !reducedMotion) {
      _controller = AnimationController(vsync: this, duration: widget.duration)
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? controller = _controller;
    if (controller == null) {
      return widget.child;
    }
    return AnimatedBuilder(
      key: MessageEntrance.animationKey,
      animation: controller,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double value = Curves.easeOutCubic.transform(controller.value);
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 6),
            child: child,
          ),
        );
      },
    );
  }
}

/// One incoming/outgoing chat bubble with ordered text/image content or an
/// independent attachment card.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.selfAccount,
    required this.peerUsername,
    required this.chat,
    required this.avatars,
    this.onSaveAs,
    this.onDownload,
    this.onPlay,
    this.onOpenMedia,
    this.localMediaPreview,
    this.busy = false,
    this.sendState,
    this.onRetry,
    this.statusUnconfirmed = false,
    this.showAvatar = true,
    this.isRunEnd = true,
    this.originKeyFor,
  });

  final ChatMessage message;
  final String selfAccount;
  final String peerUsername;
  final ChatService chat;

  /// One request per account per chat visit, shared with the AppBar.
  final ChatAvatarController avatars;
  final VoidCallback? onSaveAs;
  final VoidCallback? onDownload;
  final VoidCallback? onPlay;

  /// Opens the full-screen viewer at this media slot; null disables the tap.
  final void Function(ChatMessage message, int? partIndex)? onOpenMedia;

  /// Already-held bytes for a just-sent or still-pending image of the current
  /// account.
  final Uint8List? Function(String mediaId)? localMediaPreview;
  final bool busy;

  /// Local only: null means the server committed this message.
  final SendFeedbackState? sendState;
  final VoidCallback? onRetry;

  /// A local failure whose authoritative operation lookup is not terminal.
  /// It keeps the retry entry but must not claim the message was not sent.
  final bool statusUnconfirmed;

  /// Grouping: only the first bubble of a same-sender run shows the avatar.
  final bool showAvatar;

  /// Grouping: the sender-side bottom corner tightens at the run end.
  final bool isRunEnd;

  /// Page-owned key for one painted thumbnail occurrence of this message.
  ///
  /// The same media id may legitimately appear in several messages (the user
  /// sends one image twice). Each occurrence needs its own key — keyed by the
  /// message and the content slot — or the viewer transition anchors two live
  /// `RepaintBoundary`s on one `GlobalKey`.
  final GlobalKey? Function(ChatMessage message, int? partIndex)? originKeyFor;

  static const Key sendingKey = Key('chat-bubble-sending');
  static const Key failedKey = Key('chat-bubble-failed');

  bool get mine => message.senderAccount == selfAccount;

  @override
  Widget build(BuildContext context) {
    final bool failed = sendState == SendFeedbackState.failed;
    final bool unconfirmed = failed && statusUnconfirmed;
    final bool sending = sendState == SendFeedbackState.sending;
    final bool interactive = sendState == null;
    final Color textColor = failed
        ? AppColors.ink
        : mine
        ? AppColors.surface
        : AppColors.ink;
    final Color mutedColor = unconfirmed
        ? AppColors.warning
        : failed
        ? AppColors.danger
        : mine
        ? AppColors.surface.withValues(alpha: 0.78)
        : AppColors.inkMuted;
    final double maxWidth = math.min(
      340,
      MediaQuery.sizeOf(context).width * 0.74,
    );

    final Widget bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 8),
      decoration: BoxDecoration(
        color: failed
            ? unconfirmed
                  ? AppColors.warningSurface
                  : AppColors.dangerSurface
            : mine
            ? AppColors.accent
            : AppColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(!mine && isRunEnd ? 6 : 18),
          bottomRight: Radius.circular(mine && isRunEnd ? 6 : 18),
        ),
        border: failed
            ? Border.all(
                color: unconfirmed
                    ? AppColors.warningBorder
                    : AppColors.dangerBorder,
              )
            : mine
            ? null
            : Border.all(color: AppColors.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (message.kind == ChatMessageKind.attachment)
              _AttachmentCard(
                message: message,
                chat: chat,
                mine: mine,
                busy: busy,
                interactive: interactive,
                textColor: textColor,
                mutedColor: mutedColor,
                localMediaPreview: localMediaPreview,
                onSaveAs: interactive ? onSaveAs : null,
                onDownload: interactive ? onDownload : null,
                onOpenMedia: interactive ? onOpenMedia : null,
                originKeyFor: originKeyFor,
              )
            else
              ..._bodyContent(context, textColor, interactive),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: _StatusSlot(
                message: message,
                mine: mine,
                sending: sending,
                failed: failed,
                unconfirmed: unconfirmed,
                mutedColor: mutedColor,
              ),
            ),
          ],
        ),
      ),
    );

    final Widget content = Row(
      // The group's first bubble keeps its avatar at the top of the run; later
      // bubbles keep the hidden 32px slot on the text edge.
      crossAxisAlignment: showAvatar
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: <Widget>[
        if (!mine) ...<Widget>[
          _avatarSlot(false),
          const SizedBox(width: AppSpacing.sm),
        ],
        Flexible(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: failed ? onRetry : null,
            onSecondaryTapDown: (TapDownDetails details) =>
                _showMenu(context, details.globalPosition),
            onLongPressStart: (LongPressStartDetails details) =>
                _showMenu(context, details.globalPosition),
            child: Semantics(
              button: failed,
              label: failed
                  ? unconfirmed
                        ? '消息状态待确认，点按重试'
                        : '消息未发送，点按重试'
                  : sending
                  ? '消息发送中'
                  : null,
              child: bubble,
            ),
          ),
        ),
        if (mine) ...<Widget>[
          const SizedBox(width: AppSpacing.sm),
          _avatarSlot(true),
        ],
      ],
    );
    return content;
  }

  /// A hidden 30px slot keeps consecutive bubbles on one text edge without
  /// repeating the same avatar for every message in a run.
  Widget _avatarSlot(bool isMine) {
    if (!showAvatar) {
      return const SizedBox(width: 32, height: 32);
    }
    return _MessageAvatar(
      avatars: avatars,
      account: message.senderAccount,
      semanticLabel: isMine ? '我的头像' : '$peerUsername 的头像',
    );
  }

  List<Widget> _bodyContent(
    BuildContext context,
    Color textColor,
    bool interactive,
  ) {
    final List<Widget> children = <Widget>[];
    for (int index = 0; index < message.parts.length; index += 1) {
      final MessagePart part = message.parts[index];
      if (part is TextPart) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: SelectableText(
              part.text,
              style: TextStyle(fontSize: 15.5, height: 1.45, color: textColor),
            ),
          ),
        );
      } else if (part is ImagePart) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: GestureDetector(
              key: ValueKey<String>('chat-media-${part.mediaId}'),
              behavior: HitTestBehavior.opaque,
              onTap: onOpenMedia == null
                  ? null
                  : () => onOpenMedia!(message, index),
              child: RepaintBoundary(
                key: originKeyFor?.call(message, index),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _MediaImage(
                    chat: chat,
                    mediaId: part.mediaId,
                    localBytes: localMediaPreview?.call(part.mediaId),
                    // A fixed 4:3 slot reserves the layout before the preview
                    // arrives, so a late image never pushes reading text.
                    width: 200,
                    height: 150,
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    return children;
  }

  void _showMenu(BuildContext context, Offset position) {
    final bool hasAttachment = message.kind == ChatMessageKind.attachment;
    if (!hasAttachment && onSaveAs == null) {
      return;
    }
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        if (onDownload != null)
          const PopupMenuItem<String>(value: 'download', child: Text('下载')),
        if (onPlay != null && message.isAttachmentKind(AttachmentKind.video))
          const PopupMenuItem<String>(value: 'play', child: Text('播放')),
        if (onSaveAs != null)
          const PopupMenuItem<String>(value: 'save', child: Text('另存为')),
      ],
    ).then((String? value) {
      if (!context.mounted) {
        return;
      }
      switch (value) {
        case 'download':
          onDownload?.call();
        case 'play':
          onPlay?.call();
        case 'save':
          onSaveAs?.call();
      }
    });
  }
}

/// Time or local send feedback in one fixed-height slot.
class _StatusSlot extends StatelessWidget {
  const _StatusSlot({
    required this.message,
    required this.mine,
    required this.sending,
    required this.failed,
    required this.unconfirmed,
    required this.mutedColor,
  });

  final ChatMessage message;
  final bool mine;
  final bool sending;
  final bool failed;
  final bool unconfirmed;
  final Color mutedColor;

  @override
  Widget build(BuildContext context) {
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Widget child;
    if (sending) {
      child = Row(
        key: MessageBubble.sendingKey,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 9,
            height: 9,
            child: CircularProgressIndicator(
              strokeWidth: 1.4,
              color: mutedColor,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '发送中…',
              style: TextStyle(fontSize: 11, color: mutedColor),
            ),
          ),
        ],
      );
    } else if (failed) {
      final Color color = unconfirmed ? AppColors.warning : AppColors.danger;
      child = Row(
        key: MessageBubble.failedKey,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            unconfirmed
                ? Icons.help_outline_rounded
                : Icons.error_outline_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              unconfirmed ? '状态待确认 · 点按重试' : '未发送 · 点按重试',
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      );
    } else {
      child = Text(
        formatClockTime(message.createdAt),
        style: TextStyle(fontSize: 11, color: mutedColor),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 14),
      child: AnimatedSwitcher(
        duration: reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 150),
        child: KeyedSubtree(
          key: ValueKey<String>(
            sending
                ? 'sending'
                : failed
                ? 'failed'
                : 'sent',
          ),
          child: child,
        ),
      ),
    );
  }
}

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.message,
    required this.chat,
    required this.mine,
    required this.busy,
    required this.interactive,
    required this.textColor,
    required this.mutedColor,
    this.localMediaPreview,
    this.onSaveAs,
    this.onDownload,
    this.onOpenMedia,
    this.originKeyFor,
  });

  final ChatMessage message;
  final ChatService chat;
  final bool mine;
  final bool busy;
  final bool interactive;
  final Color textColor;
  final Color mutedColor;
  final Uint8List? Function(String mediaId)? localMediaPreview;
  final VoidCallback? onSaveAs;
  final VoidCallback? onDownload;
  final void Function(ChatMessage message, int? partIndex)? onOpenMedia;

  /// One key per message/attachment occurrence; see [MessageBubble.originKeyFor].
  final GlobalKey? Function(ChatMessage message, int? partIndex)? originKeyFor;

  @override
  Widget build(BuildContext context) {
    final Attachment attachment = message.attachment!;
    final bool video = attachment.kind == AttachmentKind.video;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (video)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              key: ValueKey<String>('chat-media-${attachment.mediaId}'),
              behavior: HitTestBehavior.opaque,
              onTap: onOpenMedia == null
                  ? null
                  : () => onOpenMedia!(message, null),
              child: RepaintBoundary(
                key: originKeyFor?.call(message, null),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 260,
                    height: 150,
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        if (attachment.coverMediaId != null)
                          _MediaImage(
                            chat: chat,
                            mediaId: attachment.coverMediaId!,
                            localBytes: localMediaPreview?.call(
                              attachment.coverMediaId!,
                            ),
                            width: 260,
                            height: 150,
                          )
                        else
                          Container(
                            color: AppColors.ink,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.videocam_outlined,
                              color: AppColors.surface,
                              size: 34,
                            ),
                          ),
                        Center(
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: AppColors.ink.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                            ),
                            child: busy
                                ? const Padding(
                                    padding: EdgeInsets.all(13),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.surface,
                                    ),
                                  )
                                : const Icon(
                                    Icons.play_arrow_rounded,
                                    color: AppColors.surface,
                                    size: 32,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (video)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  attachment.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: mutedColor),
                ),
              ),
              Text(
                ' · ${formatBytes(attachment.byteSize)}',
                style: TextStyle(fontSize: 11.5, color: mutedColor),
              ),
            ],
          )
        else
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: mine
                      ? AppColors.surface.withValues(alpha: 0.16)
                      : AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  attachmentIcon(attachment.mimeType),
                  color: mine
                      ? AppColors.surface
                      : attachmentColor(attachment.mimeType),
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      attachment.filename,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${attachment.kind.previewLabel} · '
                      '${formatBytes(attachment.byteSize)}',
                      style: TextStyle(fontSize: 12, color: mutedColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        // Videos keep only the picture and its actions on long press / right
        // click. Other attachments keep the visible download/save shortcuts.
        if (interactive && !video) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            children: <Widget>[
              _TinyAction(
                icon: Icons.download_rounded,
                label: busy ? '下载中…' : '下载',
                color: mutedColor,
                onTap: busy ? null : onDownload,
              ),
              _TinyAction(
                icon: Icons.save_alt_rounded,
                label: '另存为',
                color: mutedColor,
                onTap: busy ? null : onSaveAs,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TinyAction extends StatelessWidget {
  const _TinyAction({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lazily fetches an authorized media image from the client service.
class _MediaImage extends StatefulWidget {
  const _MediaImage({
    required this.chat,
    required this.mediaId,
    this.localBytes,
    this.width,
    this.height,
  });

  final ChatService chat;
  final String mediaId;
  final Uint8List? localBytes;
  final double? width;
  final double? height;

  @override
  State<_MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<_MediaImage> {
  /// One request per media id.
  ///
  /// Creating this future inside `build` re-fetched every visible image on any
  /// ancestor setState — presence ticks, the 3s poll, avatar arrival — which is
  /// what made opening a conversation with photos feel like it loaded
  /// everything at once.
  Future<Uint8List>? _preview;

  /// Lazily created, and never when a local preview already covers the bubble:
  /// an unused error future would otherwise surface as an unhandled async error.
  ///
  /// `Future.sync` so a loader that throws before returning a future (a fake, or
  /// a synchronous validation failure) still arrives as a failed future the
  /// builder can render instead of exploding during build.
  Future<Uint8List> _previewFuture() => _preview ??= Future<Uint8List>.sync(
    () => widget.chat.loadListPreview(widget.mediaId),
  );

  @override
  void didUpdateWidget(covariant _MediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaId != widget.mediaId) {
      _preview = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? local = widget.localBytes;
    if (local != null && local.isNotEmpty) {
      return Image.memory(
        local,
        width: widget.width,
        height: widget.height,
        fit: widget.height == null ? BoxFit.contain : BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                _placeholder(
                  widget.width ?? 220,
                  widget.height ?? 120,
                  Icons.broken_image_outlined,
                ),
      );
    }
    return FutureBuilder<Uint8List>(
      future: _previewFuture(),
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        final double w = widget.width ?? 220;
        final double h = widget.height ?? 120;
        if (snapshot.hasData) {
          return Image.memory(
            snapshot.data!,
            width: w,
            height: widget.height,
            fit: widget.height == null ? BoxFit.contain : BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder:
                (BuildContext context, Object error, StackTrace? stackTrace) {
                  return _placeholder(w, h, Icons.broken_image_outlined);
                },
          );
        }
        if (snapshot.hasError) {
          return _placeholder(w, h, Icons.image_not_supported_outlined);
        }
        return Container(
          width: w,
          height: h,
          alignment: Alignment.center,
          color: AppColors.border.withValues(alpha: 0.35),
          child: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
    );
  }

  Widget _placeholder(double w, double h, IconData icon) {
    return Container(
      width: w,
      height: h,
      alignment: Alignment.center,
      color: AppColors.border.withValues(alpha: 0.25),
      child: Icon(icon, color: AppColors.inkMuted, size: 22),
    );
  }
}

/// Bubble avatar: the real bytes fetched for the sender's account.
///
/// Loading and failure both stay inside [ProfileAvatar]; a failed fetch shows
/// its explicit placeholder instead of an invented initial.
class _MessageAvatar extends StatelessWidget {
  const _MessageAvatar({
    required this.avatars,
    required this.account,
    required this.semanticLabel,
  });

  final ChatAvatarController avatars;
  final String account;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return ProfileAvatar(
      bytes: avatars.bytesFor(account),
      size: 32,
      showBorder: false,
      loading: avatars.isLoading(account),
      semanticLabel: semanticLabel,
    );
  }
}
