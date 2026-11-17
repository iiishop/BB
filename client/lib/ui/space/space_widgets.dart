import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/space_models.dart';
import '../chat/chat_format.dart';
import 'space_avatars.dart';
import 'space_follow_button.dart';
import 'space_format.dart';
import 'space_image_viewer.dart';

/// Author avatar from the authorized Profile entry, with deterministic initials
/// only as the loading/failure placeholder.
///
/// `SpaceAuthor.avatarUrl` is the server's `/avatars/{account}.png`; Space does
/// not fetch that path itself because the existing `ProfileGateway` owns the
/// token, ETag revalidation and shared avatar cache. Without a scope (e.g. a
/// standalone widget test) or with an empty `avatarUrl` the initials are final.
class SpaceAvatar extends StatefulWidget {
  const SpaceAvatar({super.key, required this.author, this.size = 40});

  final SpaceAuthor author;
  final double size;

  @override
  State<SpaceAvatar> createState() => _SpaceAvatarState();
}

class _SpaceAvatarState extends State<SpaceAvatar> {
  static const List<Color> _palette = <Color>[
    Color(0xFF0E6F68),
    Color(0xFF7A4E00),
    Color(0xFF3A5A8C),
    Color(0xFF8C3A5A),
    Color(0xFF4A6B2A),
  ];

  SpaceAvatarStore? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = SpaceAvatarScope.maybeOf(context);
    _requestAvatar();
  }

  @override
  void didUpdateWidget(covariant SpaceAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.author.account != widget.author.account ||
        oldWidget.author.avatarUrl != widget.author.avatarUrl) {
      _requestAvatar();
    }
  }

  void _requestAvatar() {
    if (widget.author.avatarUrl.isEmpty) {
      return;
    }
    _store?.ensureLoaded(widget.author.account);
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _store?.bytesFor(widget.author.account);
    final Widget avatar = bytes == null || bytes.isEmpty
        ? _initials()
        : ClipOval(
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: Image.memory(
                bytes,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (
                  BuildContext context,
                  Object error,
                  StackTrace? stack,
                ) => _initials(),
              ),
            ),
          );
    return Semantics(label: '${widget.author.username}的头像', child: avatar);
  }

  Widget _initials() {
    final int hash = widget.author.account.codeUnits.fold<int>(
      0,
      (int a, int b) => a + b,
    );
    final Color color = _palette[hash % _palette.length];
    return Container(
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        initialsOf(widget.author.username),
        style: TextStyle(
          color: color,
          fontSize: widget.size * 0.34,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Ordered image preview: three columns, at most nine tiles, the ninth carries
/// the hidden count. Seven or eight images simply leave the last row short.
class SpaceImageGrid extends StatelessWidget {
  const SpaceImageGrid({
    super.key,
    required this.images,
    required this.loader,
    required this.onOpen,
  });

  final List<SpaceImage> images;
  final SpaceImageLoader loader;
  final void Function(int index) onOpen;

  static const int previewLimit = 9;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return const SizedBox.shrink();
    }
    final int shown = images.length < previewLimit
        ? images.length
        : previewLimit;
    final int hidden = images.length - shown;
    return GridView.count(
      key: const Key('space-image-grid'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      crossAxisCount: 3,
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      childAspectRatio: 1,
      children: List<Widget>.generate(shown, (int index) {
        final SpaceImage image = images[index];
        return GestureDetector(
          key: Key('space-image-${image.imageId}'),
          onTap: () => onOpen(index),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _SpaceThumb(image: image, loader: loader),
              if (index == previewLimit - 1 && hidden > 0)
                Container(
                  key: const Key('space-image-more'),
                  color: Colors.black.withValues(alpha: 0.52),
                  alignment: Alignment.center,
                  child: Text(
                    '+$hidden',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}

class _SpaceThumb extends StatelessWidget {
  const _SpaceThumb({required this.image, required this.loader});

  final SpaceImage image;
  final SpaceImageLoader loader;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: loader.load(image.imageId),
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.brand),
          child: Container(
            color: AppColors.paper,
            child: snapshot.hasData
                ? Image.memory(
                    snapshot.data!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    semanticLabel: image.filename,
                  )
                : Center(
                    child: snapshot.hasError
                        ? const Icon(
                            Icons.broken_image_outlined,
                            size: 22,
                            color: AppColors.inkMuted,
                          )
                        : const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                  ),
          ),
        );
      },
    );
  }
}

/// One direct reference level. A deleted source is stated in place and never
/// recursively expands or leaks a cached body.
class SpaceReferenceCard extends StatelessWidget {
  const SpaceReferenceCard({
    super.key,
    required this.reference,
    required this.onOpen,
  });

  final SpaceReference reference;
  final void Function() onOpen;

  static const Key cardKey = Key('space-reference-card');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool deleted = reference.deleted;
    return Material(
      color: AppColors.paper,
      borderRadius: BorderRadius.circular(AppRadius.brand),
      child: InkWell(
        key: cardKey,
        borderRadius: BorderRadius.circular(AppRadius.brand),
        onTap: deleted ? null : onOpen,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                deleted ? Icons.link_off_rounded : Icons.format_quote_rounded,
                size: 18,
                color: deleted ? AppColors.inkMuted : AppColors.accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (reference.author != null && !deleted)
                      Text(
                        reference.author!.username,
                        style: text.labelLarge?.copyWith(
                          color: AppColors.accentDeep,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      referenceStateLabel(reference),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: deleted ? AppColors.inkMuted : AppColors.ink,
                        fontStyle: deleted ? FontStyle.italic : null,
                      ),
                    ),
                  ],
                ),
              ),
              if (reference.image != null && !deleted) ...<Widget>[
                const SizedBox(width: AppSpacing.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 48,
                    height: 48,
                    color: AppColors.border,
                    child: const Icon(
                      Icons.image_outlined,
                      color: AppColors.inkMuted,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SpacePostCard extends StatelessWidget {
  const SpacePostCard({
    super.key,
    required this.post,
    required this.loader,
    required this.onOpen,
    required this.onOpenReference,
    required this.onLike,
    required this.onComment,
    required this.onRepost,
    required this.onOpenImage,
    this.onDelete,
    this.onOpenVisitors,
    this.onOpenAuthor,
    this.timelineAt,
    this.timezoneOffsetMinutes,
    this.following,
    this.onFollow,
    this.followBusy = false,
    this.actionsEnabled = true,
  });

  final SpacePost post;
  final SpaceImageLoader loader;
  final void Function() onOpen;
  final void Function() onOpenReference;
  final void Function() onLike;
  final void Function() onComment;
  final void Function() onRepost;
  final void Function(int index) onOpenImage;
  final void Function()? onDelete;
  final void Function()? onOpenVisitors;

  /// Opens the author's home page. Null keeps the header inert, so a read-only
  /// host (or a widget test) never renders a dead affordance.
  final void Function()? onOpenAuthor;

  /// Author-scoped timeline time for this row. Defaults to the post's own
  /// publication time; a repost row passes the repost time so the visible date
  /// matches the month it is archived under.
  final String? timelineAt;

  /// Fixed DEA-485 browsing offset for the visible date. Null keeps the legacy
  /// local-zone label for the global feed.
  final int? timezoneOffsetMinutes;

  /// Author follow state from the shared store. Null renders no follow control
  /// (own posts, unknown state, read-only hosts).
  final bool? following;
  final void Function()? onFollow;
  final bool followBusy;
  final bool actionsEnabled;

  static const int previewLines = 4;

  Key get cardKey => Key('space-post-${post.postId}');
  Key get authorKey => Key('space-post-author-${post.postId}');
  Key get bodyKey => Key('space-post-body-${post.postId}');
  Key get likeKey => Key('space-post-like-${post.postId}');
  Key get commentKey => Key('space-post-comment-${post.postId}');
  Key get repostKey => Key('space-post-repost-${post.postId}');
  Key get expandKey => Key('space-post-expand-${post.postId}');
  Key get deleteKey => Key('space-post-delete-${post.postId}');
  Key get followKey => Key('space-post-follow-${post.postId}');
  Key get visitorsKey => Key('space-post-visitors-${post.postId}');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      key: cardKey,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: InkWell(
                  key: authorKey,
                  onTap: onOpenAuthor,
                  borderRadius: BorderRadius.circular(AppRadius.brand),
                  child: Row(
                    children: <Widget>[
                      SpaceAvatar(author: post.author),
                      const SizedBox(width: AppSpacing.sm + 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(post.author.username, style: text.titleMedium),
                            Text(
                              spaceRelativeTime(
                                timelineAt ?? post.createdAt,
                                offsetMinutes: timezoneOffsetMinutes,
                              ),
                              style: text.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (following != null && onFollow != null)
                SpaceFollowButton(
                  key: followKey,
                  following: following!,
                  busy: followBusy,
                  compact: true,
                  onPressed: onFollow,
                ),
              if (post.canDelete && onDelete != null)
                IconButton(
                  key: deleteKey,
                  onPressed: onDelete,
                  tooltip: '删除说说',
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          InkWell(
            key: bodyKey,
            onTap: onOpen,
            borderRadius: BorderRadius.circular(AppRadius.brand),
            child: _ClampedBody(
              text: post.text,
              onOpen: onOpen,
              expandKey: expandKey,
            ),
          ),
          if (post.images.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm + 2),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SpaceImageGrid(
                  images: post.images,
                  loader: loader,
                  onOpen: onOpenImage,
                ),
              ),
            ),
          ],
          if (post.reference != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm + 2),
            SpaceReferenceCard(
              reference: post.reference!,
              onOpen: onOpenReference,
            ),
          ],
          if (post.previewComments.isNotEmpty ||
              post.remainingRoots > 0) ...<Widget>[
            const SizedBox(height: AppSpacing.sm + 2),
            _CommentPreview(post: post, onOpen: onComment),
          ],
          const SizedBox(height: AppSpacing.sm + 2),
          Row(
            children: <Widget>[
              _CountAction(
                key: likeKey,
                icon: post.liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                active: post.liked,
                count: post.likeCount,
                label: post.liked ? '取消赞' : '赞',
                onTap: actionsEnabled ? onLike : null,
              ),
              _CountAction(
                key: commentKey,
                icon: Icons.mode_comment_outlined,
                count: post.commentCount,
                label: '评论',
                onTap: actionsEnabled ? onComment : null,
              ),
              _CountAction(
                key: repostKey,
                icon: Icons.repeat_rounded,
                count: post.repostCount,
                label: '转发',
                onTap: actionsEnabled ? onRepost : null,
              ),
              const Spacer(),
              TextButton.icon(
                key: visitorsKey,
                onPressed: onOpenVisitors,
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: Text('浏览 ${post.viewCount}'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClampedBody extends StatelessWidget {
  const _ClampedBody({
    required this.text,
    required this.onOpen,
    required this.expandKey,
  });

  final String text;
  final VoidCallback onOpen;
  final Key expandKey;

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.bodyLarge
        ?.copyWith(color: AppColors.ink);
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: SpacePostCard.previewLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool clipped = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (clipped)
              ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (Rect bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: <double>[0.55, 1],
                  colors: <Color>[Colors.white, Colors.transparent],
                ).createShader(bounds),
                child: Text(
                  text,
                  maxLines: SpacePostCard.previewLines,
                  overflow: TextOverflow.clip,
                  style: style,
                ),
              )
            else
              Text(text, style: style),
            if (clipped)
              TextButton(
                key: expandKey,
                onPressed: onOpen,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 36),
                  alignment: Alignment.centerLeft,
                ),
                child: const Text('查看全文'),
              ),
          ],
        );
      },
    );
  }
}

class _CountAction extends StatelessWidget {
  const _CountAction({
    super.key,
    required this.icon,
    required this.count,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final int count;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final Color color = active ? AppColors.accent : AppColors.inkMuted;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.brand),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 19, color: color),
              if (count > 0) ...<Widget>[
                const SizedBox(width: 4),
                Text(
                  '$count',
                  style: TextStyle(
                    color: color,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SpaceSectionHeader extends StatelessWidget {
  const SpaceSectionHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.onPublish,
    this.onNotifications,
    this.onDrafts,
    this.onRefresh,
    this.unreadNotifications = 0,
    this.draftCount = 0,
    this.onBack,
    this.dense = false,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onPublish;
  final VoidCallback? onNotifications;
  final VoidCallback? onDrafts;
  final VoidCallback? onRefresh;
  final int unreadNotifications;
  final int draftCount;
  final VoidCallback? onBack;

  /// Narrow master-detail pane: keep every action, drop the subtitle.
  final bool dense;

  static const Key publishKey = Key('space-publish');
  static const Key notificationsKey = Key('space-notifications');
  static const Key notificationDotKey = Key('space-notification-dot');
  static const Key draftsKey = Key('space-drafts');
  static const Key refreshKey = Key('space-refresh');
  static const Key backKey = Key('space-header-back');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          if (onBack != null)
            IconButton(
              key: backKey,
              onPressed: onBack,
              tooltip: '返回',
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: dense ? text.titleMedium : text.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!dense)
                  Text(
                    subtitle,
                    style: text.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (onRefresh != null)
            IconButton(
              key: refreshKey,
              onPressed: onRefresh,
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
            ),
          if (onDrafts != null)
            Badge(
              isLabelVisible: draftCount > 0,
              label: Text('$draftCount'),
              child: IconButton(
                key: draftsKey,
                onPressed: onDrafts,
                tooltip: '草稿',
                icon: const Icon(Icons.edit_note_rounded),
              ),
            ),
          if (onNotifications != null)
            Badge(
              isLabelVisible: unreadNotifications > 0,
              backgroundColor: AppColors.danger,
              label: Text(
                unreadNotifications > 99 ? '99+' : '$unreadNotifications',
                key: notificationDotKey,
              ),
              child: IconButton(
                key: notificationsKey,
                onPressed: onNotifications,
                tooltip: '互动通知',
                icon: const Icon(Icons.notifications_none_rounded),
              ),
            ),
          if (onPublish != null) ...<Widget>[
            const SizedBox(width: AppSpacing.xs),
            if (dense)
              IconButton.filled(
                key: publishKey,
                onPressed: onPublish,
                tooltip: '发布',
                icon: const Icon(Icons.add_rounded, size: 20),
              )
            else
              FilledButton.icon(
                key: publishKey,
                onPressed: onPublish,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                  ),
                ),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('发布'),
              ),
          ],
        ],
      ),
    );
  }
}

class SpaceStateView extends StatelessWidget {
  const SpaceStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.tone = AppColors.inkMuted,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 40, color: tone),
              const SizedBox(height: AppSpacing.md),
              Text(title, style: text.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.sm),
              Text(message, style: text.bodySmall, textAlign: TextAlign.center),
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SpaceInlineBanner extends StatelessWidget {
  const SpaceInlineBanner({
    super.key,
    required this.message,
    this.tone = AppColors.warning,
    this.background = AppColors.warningSurface,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    this.icon = Icons.info_outline_rounded,
  });

  final String message;
  final Color tone;
  final Color background;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.brand),
        border: Border.all(color: tone.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: tone),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(message, style: TextStyle(color: tone, fontSize: 13.5)),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              key: actionKey,
              onPressed: onAction,
              style: TextButton.styleFrom(foregroundColor: tone),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// The feed card previews at most five roots and three replies per root; the
/// remaining counts are separate affordances, never mixed.
class _CommentPreview extends StatelessWidget {
  const _CommentPreview({required this.post, required this.onOpen});

  final SpacePost post;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm + 2),
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: BorderRadius.circular(AppRadius.brand),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final SpaceBranch branch in post.previewComments) ...<Widget>[
            InkWell(
              key: Key('space-preview-root-${branch.root.commentId}'),
              onTap: onOpen,
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: branch.root.deleted
                          ? '该评论已删除'
                          : '${branch.root.author.username}：',
                      style: text.bodySmall?.copyWith(
                        color: AppColors.accentDeep,
                        fontWeight: FontWeight.w600,
                        fontStyle: branch.root.deleted
                            ? FontStyle.italic
                            : null,
                      ),
                    ),
                    if (!branch.root.deleted)
                      TextSpan(
                        text: branch.root.text ?? '',
                        style: text.bodySmall?.copyWith(color: AppColors.ink),
                      ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final SpaceComment reply in branch.replies)
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.md, top: 2),
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: reply.deleted
                            ? '${reply.author.username}：该评论已删除'
                            : '${reply.author.username} 回复 '
                                  '${reply.replyToAuthor?.username ?? '楼主'}：',
                        style: text.bodySmall?.copyWith(
                          color: AppColors.inkMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (!reply.deleted)
                        TextSpan(
                          text: reply.text ?? '',
                          style: text.bodySmall?.copyWith(color: AppColors.ink),
                        ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (branch.remainingReplies > 0)
              TextButton(
                key: Key('space-preview-more-replies-${branch.root.commentId}'),
                onPressed: onOpen,
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 32),
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                ),
                child: Text('还有 ${branch.remainingReplies} 条回复'),
              ),
          ],
          if (post.remainingRoots > 0)
            TextButton(
              key: Key('space-preview-more-roots-${post.postId}'),
              onPressed: onOpen,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 32),
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              child: Text('还有 ${post.remainingRoots} 条评论'),
            ),
        ],
      ),
    );
  }
}
