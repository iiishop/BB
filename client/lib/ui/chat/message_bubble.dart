import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../widgets/profile_avatar.dart';
import 'chat_avatars.dart';
import 'chat_format.dart';

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
    this.busy = false,
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
  final bool busy;

  bool get mine => message.senderAccount == selfAccount;

  @override
  Widget build(BuildContext context) {
    final Widget bubble = Container(
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm + 2,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: mine ? AppColors.accent : AppColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadius.card),
          topRight: const Radius.circular(AppRadius.card),
          bottomLeft: Radius.circular(mine ? AppRadius.card : AppSpacing.xs),
          bottomRight: Radius.circular(mine ? AppSpacing.xs : AppRadius.card),
        ),
        border: mine ? null : Border.all(color: AppColors.border),
      ),
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
              onSaveAs: onSaveAs,
              onDownload: onDownload,
              onPlay: onPlay,
            )
          else
            ..._bodyContent(context),
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              formatClockTime(message.createdAt),
              style: TextStyle(
                fontSize: 10.5,
                color: mine
                    ? AppColors.surface.withValues(alpha: 0.7)
                    : AppColors.inkMuted,
              ),
            ),
          ),
        ],
      ),
    );

    final Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: <Widget>[
        if (!mine) ...<Widget>[
          _MessageAvatar(
            avatars: avatars,
            account: message.senderAccount,
            semanticLabel: '$peerUsername 的头像',
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        Flexible(
          child: GestureDetector(
            onSecondaryTapDown: (TapDownDetails details) =>
                _showMenu(context, details.globalPosition),
            onLongPressStart: (LongPressStartDetails details) =>
                _showMenu(context, details.globalPosition),
            child: bubble,
          ),
        ),
        if (mine) ...<Widget>[
          const SizedBox(width: AppSpacing.sm),
          _MessageAvatar(
            avatars: avatars,
            account: message.senderAccount,
            semanticLabel: '我的头像',
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: content,
    );
  }

  List<Widget> _bodyContent(BuildContext context) {
    final List<Widget> children = <Widget>[];
    for (final MessagePart part in message.parts) {
      if (part is TextPart) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: SelectableText(
              part.text,
              style: TextStyle(
                fontSize: 15.5,
                height: 1.45,
                color: mine ? AppColors.surface : AppColors.ink,
              ),
            ),
          ),
        );
      } else if (part is ImagePart) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.brand),
              child: _MediaImage(
                chat: chat,
                mediaId: part.mediaId,
                width: 160,
                height: 160,
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

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.message,
    required this.chat,
    required this.mine,
    required this.busy,
    this.onSaveAs,
    this.onDownload,
    this.onPlay,
  });

  final ChatMessage message;
  final ChatService chat;
  final bool mine;
  final bool busy;
  final VoidCallback? onSaveAs;
  final VoidCallback? onDownload;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final Attachment attachment = message.attachment!;
    final Color textColor = mine ? AppColors.surface : AppColors.ink;
    final Color mutedColor = mine
        ? AppColors.surface.withValues(alpha: 0.75)
        : AppColors.inkMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (attachment.kind == AttachmentKind.video &&
            attachment.coverMediaId != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: GestureDetector(
              onTap: busy ? null : onPlay,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.brand),
                    child: _MediaImage(
                      chat: chat,
                      mediaId: attachment.coverMediaId!,
                      width: 260,
                      height: 150,
                    ),
                  ),
                  Container(
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
                            size: 30,
                          ),
                  ),
                ],
              ),
            ),
          ),
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
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.xs,
          children: <Widget>[
            if (attachment.kind == AttachmentKind.video)
              _TinyAction(
                icon: Icons.play_arrow_rounded,
                label: '播放',
                color: mutedColor,
                onTap: busy ? null : onPlay,
              ),
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
class _MediaImage extends StatelessWidget {
  const _MediaImage({
    required this.chat,
    required this.mediaId,
    this.width,
    this.height,
  });

  final ChatService chat;
  final String mediaId;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: chat.mediaBytes(mediaId),
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        final double w = width ?? 220;
        final double h = height ?? (width == null ? 120 : height ?? 120);
        if (snapshot.hasData) {
          return Image.memory(
            snapshot.data!,
            width: w,
            height: height,
            fit: height == null ? BoxFit.contain : BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (
              BuildContext context,
              Object error,
              StackTrace? stackTrace,
            ) => _placeholder(w, h, Icons.broken_image_outlined),
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
