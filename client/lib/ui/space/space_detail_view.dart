import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/space_models.dart';
import 'space_avatars.dart';
import 'space_controller.dart';
import 'space_detail_controller.dart';
import 'space_format.dart';
import 'space_image_viewer.dart';
import 'space_layout.dart';
import 'space_local_store.dart';
import 'space_people_sheets.dart';
import 'space_widgets.dart';

/// One post's full surface: body, images, direct reference, comments and the
/// independent read/visit facts. It never loads a recursive comment tree.
class SpaceDetailView extends StatefulWidget {
  const SpaceDetailView({
    super.key,
    required this.controller,
    required this.space,
    required this.layout,
    required this.onClose,
    required this.onBack,
    required this.onOpenReference,
    this.showClose = true,
  });

  final SpaceDetailController controller;
  final SpaceController space;
  final SpaceLayout layout;
  final VoidCallback onClose;
  final VoidCallback onBack;
  final void Function(String postId) onOpenReference;
  final bool showClose;

  static const Key detailKey = Key('space-detail');
  static const Key bodyKey = Key('space-detail-body');
  static const Key commentsKey = Key('space-detail-comments');
  static const Key composerKey = Key('space-detail-composer');
  static const Key sendKey = Key('space-detail-send');
  static const Key replyChipKey = Key('space-detail-reply-chip');
  static const Key moreRootsKey = Key('space-detail-more-roots');
  static const Key visitorsKey = Key('space-detail-visitors');
  static const Key likesKey = Key('space-detail-likes');
  static const Key likeKey = Key('space-detail-like');
  static const Key deletePostKey = Key('space-detail-delete-post');
  static const Key backKey = Key('space-detail-back');
  static const Key closeKey = Key('space-detail-close');

  @override
  State<SpaceDetailView> createState() => _SpaceDetailViewState();
}

class _SpaceDetailViewState extends State<SpaceDetailView> {
  late final TextEditingController _text;
  String? _replyToId;
  final GlobalKey _focusKey = GlobalKey();
  String? _scrolledFor;
  bool _sending = false;
  String? _sendError;

  SpaceDetailController get _detail => widget.controller;

  @override
  void initState() {
    super.initState();
    final SpaceCommentBuffer? buffer = _detail.unsentComment;
    _text = TextEditingController(text: buffer?.text ?? '');
    _replyToId = buffer?.replyToId;
    _text.addListener(_remember);
    _detail.addListener(_onDetailChanged);
  }

  @override
  void didUpdateWidget(SpaceDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onDetailChanged);
      widget.controller.addListener(_onDetailChanged);
    }
  }

  @override
  void dispose() {
    _detail.removeListener(_onDetailChanged);
    _text.removeListener(_remember);
    _remember();
    _text.dispose();
    super.dispose();
  }

  void _remember() {
    _detail.rememberUnsent(_text.text, _replyToId);
  }

  void _onDetailChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _scheduleFocus();
  }

  void _scheduleFocus() {
    final String? target = _detail.highlightedCommentId;
    if (target == null || _scrolledFor == target) {
      return;
    }
    _scrolledFor = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? targetContext = _focusKey.currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 220),
          alignment: 0.3,
        );
      }
    });
  }

  Future<void> _send() async {
    final String text = _text.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    setState(() {
      _sending = true;
      _sendError = null;
    });
    final String? failure = await _detail.submitComment(
      text,
      replyToId: _replyToId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _sending = false;
      _sendError = failure;
      if (failure == null) {
        _text.clear();
        _replyToId = null;
      }
    });
    _remember();
  }

  String _replyName(String id) {
    for (final SpaceComment comment in _detail.roots) {
      if (comment.commentId == id) {
        return comment.author.username;
      }
    }
    for (final List<SpaceComment> items in _detail.replies.values) {
      for (final SpaceComment comment in items) {
        if (comment.commentId == id) {
          return comment.author.username;
        }
      }
    }
    final SpaceCommentContext? context = _detail.context;
    if (context != null) {
      if (context.target.commentId == id) {
        return context.target.author.username;
      }
      for (final SpaceComment comment in context.nearby) {
        if (comment.commentId == id) {
          return comment.author.username;
        }
      }
    }
    return '评论';
  }

  Future<void> _deletePost() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除这条说说？'),
        content: const Text('删除后正文、图片和全部评论互动都会失效，且无法恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final bool ok = await _detail.deletePost();
      if (ok && mounted) {
        widget.onClose();
      }
    }
  }

  Future<void> _deleteComment(SpaceComment comment) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除这条评论？'),
        content: const Text('已有回复会保留，但正文不再显示。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _detail.deleteComment(comment.commentId);
    }
  }

  void _openViewer(SpacePost post, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SpaceImageViewer(
          images: post.images,
          initialIndex: index,
          loader: widget.space.images,
          downloadLog: widget.space.downloads,
        ),
      ),
    );
  }

  Future<void> _openVisitors() async {
    final SpacePost? post = _detail.post;
    if (post == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => _withAvatars(
        context,
        SpaceVisitorsSheet(load: _detail.loadVisitors, postId: post.postId),
      ),
    );
  }

  Future<void> _openLikes() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) =>
          _withAvatars(context, SpaceLikesSheet(load: _detail.loadLikes)),
    );
  }

  /// A bottom sheet builds on the root Navigator, outside this page's
  /// [SpaceAvatarScope] subtree; hand the existing store to it explicitly so
  /// the like/visitor rows show the same authorized avatar bytes.
  Widget _withAvatars(BuildContext sheetContext, Widget child) {
    final SpaceAvatarStore? avatars = SpaceAvatarScope.read(context);
    if (avatars == null) {
      return child;
    }
    return SpaceAvatarScope(store: avatars, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final SpaceDetailController detail = widget.controller;
    final SpacePost? post = detail.post;
    final TextTheme text = Theme.of(context).textTheme;
    if (post == null) {
      if (detail.phase == SpacePhase.error || detail.deleted) {
        return SpaceStateView(
          key: SpaceDetailView.detailKey,
          icon: detail.deleted
              ? Icons.delete_outline_rounded
              : Icons.cloud_off_rounded,
          title: detail.deleted ? '内容已删除' : '详情加载失败',
          message: detail.error ?? '请稍后重试',
          actionLabel: detail.deleted ? null : '重试',
          onAction: detail.deleted ? null : detail.load,
        );
      }
      return const Center(
        key: SpaceDetailView.detailKey,
        child: CircularProgressIndicator(),
      );
    }

    final Widget comments = SingleChildScrollView(
      key: SpaceDetailView.commentsKey,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (detail.offline)
                const SpaceInlineBanner(
                  message: '当前离线，评论和计数可能不是最新',
                  icon: Icons.cloud_off_rounded,
                ),
              if (detail.actionError != null)
                SpaceInlineBanner(
                  message: detail.actionError!,
                  tone: AppColors.danger,
                  background: AppColors.dangerSurface,
                  icon: Icons.error_outline_rounded,
                ),
              Row(
                children: <Widget>[
                  SpaceAvatar(author: post.author, size: 44),
                  const SizedBox(width: AppSpacing.sm + 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(post.author.username, style: text.titleMedium),
                        Text(
                          spaceExactTime(post.createdAt),
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (post.canDelete)
                    IconButton(
                      key: SpaceDetailView.deletePostKey,
                      onPressed: _deletePost,
                      tooltip: '删除说说',
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                post.text,
                key: SpaceDetailView.bodyKey,
                style: text.bodyLarge?.copyWith(
                  color: AppColors.ink,
                  fontSize: 16,
                ),
              ),
              if (post.images.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                SpaceImageGrid(
                  images: post.images,
                  loader: widget.space.images,
                  onOpen: (int index) => _openViewer(post, index),
                ),
              ],
              if (post.reference != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                SpaceReferenceCard(
                  reference: post.reference!,
                  onOpen: () => widget.onOpenReference(post.reference!.postId),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  TextButton.icon(
                    key: SpaceDetailView.likeKey,
                    onPressed: detail.likePending ? null : detail.toggleLike,
                    icon: Icon(
                      post.liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 18,
                      color: post.liked ? AppColors.accent : AppColors.inkMuted,
                    ),
                    label: Text(post.liked ? '取消赞' : '赞'),
                  ),
                  TextButton.icon(
                    key: SpaceDetailView.likesKey,
                    onPressed: _openLikes,
                    icon: const Icon(Icons.people_outline_rounded, size: 18),
                    label: Text('${post.likeCount} 人赞过'),
                  ),
                  TextButton.icon(
                    key: SpaceDetailView.visitorsKey,
                    onPressed: _openVisitors,
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    label: Text('浏览 ${post.viewCount}'),
                  ),
                  if (post.canListVisitors)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                      child: Text(
                        '访客明细仅作者可见',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ),
                ],
              ),
              const Divider(height: AppSpacing.lg),
              Row(
                children: <Widget>[
                  Text('评论', style: text.titleMedium),
                  const SizedBox(width: AppSpacing.sm),
                  Text('${post.commentCount}', style: text.bodySmall),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              ..._buildComments(context),
              if (detail.rootsHasMore)
                Center(
                  child: TextButton(
                    key: SpaceDetailView.moreRootsKey,
                    onPressed: detail.loadMoreRoots,
                    child: const Text('加载更多评论'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return Container(
      key: SpaceDetailView.detailKey,
      color: AppColors.surface,
      child: Column(
        children: <Widget>[
          _header(post, text),
          const Divider(height: 1),
          Expanded(child: comments),
          if (!detail.deleted) _composer(text),
        ],
      ),
    );
  }

  Widget _header(SpacePost post, TextTheme text) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          if (widget.space.detailHistory.length > 1)
            IconButton(
              key: SpaceDetailView.backKey,
              onPressed: widget.onBack,
              tooltip: '返回上一条',
              icon: const Icon(Icons.arrow_back_rounded),
            )
          else if (widget.showClose)
            IconButton(
              key: SpaceDetailView.closeKey,
              onPressed: widget.onClose,
              tooltip: '关闭详情',
              icon: const Icon(Icons.close_rounded),
            ),
          Expanded(child: Text('说说详情', style: text.titleMedium)),
          if (widget.layout.masterDetail)
            const Icon(
              Icons.vertical_split_rounded,
              size: 18,
              color: AppColors.inkMuted,
            ),
        ],
      ),
    );
  }

  Widget _composer(TextTheme text) {
    return Container(
      key: SpaceDetailView.composerKey,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm + MediaQuery.of(context).viewInsets.bottom,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_replyToId != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: InputChip(
                key: SpaceDetailView.replyChipKey,
                label: Text('回复 ${_replyName(_replyToId!)}'),
                onDeleted: () => setState(() => _replyToId = null),
              ),
            ),
          if (_sendError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                _sendError!,
                style: text.bodySmall?.copyWith(color: AppColors.danger),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('space-detail-input'),
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: _replyToId == null
                        ? '写下评论'
                        : '回复 ${_replyName(_replyToId!)}',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton.filled(
                key: SpaceDetailView.sendKey,
                onPressed: _sending ? null : _send,
                tooltip: '发送评论',
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildComments(BuildContext context) {
    final SpaceDetailController detail = widget.controller;
    final List<Widget> result = <Widget>[];
    for (final SpaceComment root in detail.roots) {
      result.add(
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: _commentTile(root, isRoot: true),
        ),
      );
      final List<SpaceComment> branch =
          detail.replies[root.commentId] ?? const <SpaceComment>[];
      for (final SpaceComment reply in branch) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg, top: 2),
            child: _commentTile(reply, isRoot: false),
          ),
        );
      }
      if (detail.loadingReplies.contains(root.commentId)) {
        const Padding(
          padding: EdgeInsets.only(left: AppSpacing.lg, top: AppSpacing.xs),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      if (branch.isEmpty &&
          !detail.probedReplies.contains(root.commentId) &&
          !detail.loadingReplies.contains(root.commentId) &&
          !(detail.repliesHasMore[root.commentId] ?? false)) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg),
            child: TextButton(
              key: Key('space-comment-replies-${root.commentId}'),
              onPressed: () => detail.expandReplies(root.commentId),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 32),
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              child: const Text('查看回复'),
            ),
          ),
        );
      }
      if (detail.repliesHasMore[root.commentId] ?? false) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.lg),
            child: TextButton(
              key: Key('space-detail-more-replies-${root.commentId}'),
              onPressed: () => detail.expandReplies(root.commentId, more: true),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 32),
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              child: const Text('加载更多回复'),
            ),
          ),
        );
      }
    }
    return result;
  }

  Widget _commentTile(SpaceComment comment, {required bool isRoot}) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool focus = _detail.highlightedCommentId == comment.commentId;
    final Widget tile = Padding(
      key: focus ? _focusKey : Key('space-comment-${comment.commentId}'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              SpaceAvatar(author: comment.author, size: 24),
              const SizedBox(width: AppSpacing.xs + 2),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: comment.author.username,
                        style: text.bodySmall?.copyWith(
                          color: AppColors.accentDeep,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!isRoot && comment.replyToAuthor != null)
                        TextSpan(
                          text: ' 回复 ${comment.replyToAuthor!.username}',
                          style: text.bodySmall?.copyWith(
                            color: AppColors.inkMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Text(
                spaceRelativeTime(comment.createdAt),
                style: text.bodySmall?.copyWith(fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: comment.deleted
                ? Text(
                    '该评论已删除',
                    style: text.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  )
                : Text(
                    comment.text ?? '',
                    style: text.bodySmall?.copyWith(
                      color: AppColors.ink,
                      fontSize: 14.5,
                    ),
                  ),
          ),
          Row(
            children: <Widget>[
              const SizedBox(width: 30),
              if (!comment.deleted)
                TextButton(
                  key: Key('space-comment-reply-${comment.commentId}'),
                  onPressed: () =>
                      setState(() => _replyToId = comment.commentId),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 30),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Text('回复'),
                ),
              if (comment.canDelete && !comment.deleted)
                TextButton(
                  key: Key('space-comment-delete-${comment.commentId}'),
                  onPressed: () => _deleteComment(comment),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 30),
                    padding: EdgeInsets.zero,
                    foregroundColor: AppColors.danger,
                  ),
                  child: const Text('删除'),
                ),
            ],
          ),
        ],
      ),
    );
    if (!focus) {
      return tile;
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.brand),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: tile,
    );
  }
}
