import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/space_models.dart';
import '../../services/profile_service.dart';
import 'space_avatars.dart';
import 'space_compose_page.dart';
import 'space_controller.dart';
import 'space_detail_controller.dart';
import 'space_detail_view.dart';
import 'space_gateway.dart';
import 'space_image_viewer.dart';
import 'space_layout.dart';
import 'space_lists_view.dart';
import 'space_local_store.dart';
import 'space_widgets.dart';

/// The signed-in Space surface.
///
/// One State owns the feed, detail stack, section and scroll positions. Form
/// factor changes rebuild the layout around that state, so expanding a fold can
/// turn a full-screen detail into a second pane without losing the post,
/// reply target, unsent text or the active visit ID.
class SpacePage extends StatefulWidget {
  const SpacePage({
    super.key,
    required this.gateway,
    required this.store,
    this.profile,
    this.onSessionExpired,
    this.pollInterval = const Duration(seconds: 20),
    this.autoPoll = true,
  });

  final SpaceGateway gateway;
  final SpaceLocalStore store;

  /// Existing authorized avatar entry. When absent, author avatars keep the
  /// deterministic initials (standalone widget tests, profile-less clients).
  final ProfileGateway? profile;
  final VoidCallback? onSessionExpired;
  final Duration? pollInterval;
  final bool autoPoll;

  static const Key pageKey = Key('space-page');
  static const PageStorageKey<String> feedListKey = PageStorageKey<String>(
    'space-feed-list',
  );
  static const Key newPostsKey = Key('space-new-posts-banner');
  static const Key offlineKey = Key('space-offline-banner');
  static const Key loadMoreKey = Key('space-load-more');
  static const Key capabilityKey = Key('space-capability');
  static const Key retryKey = Key('space-retry');

  @override
  State<SpacePage> createState() => _SpacePageState();
}

class _SpacePageState extends State<SpacePage> {
  late final SpaceController _space;
  final ScrollController _feedScroll = ScrollController();
  SpaceAvatarStore? _avatars;

  @override
  void initState() {
    super.initState();
    final ProfileGateway? profile = widget.profile;
    if (profile != null) {
      _avatars = SpaceAvatarStore(profile: profile);
    }
    _space = SpaceController(
      gateway: widget.gateway,
      store: widget.store,
      onSessionExpired: widget.onSessionExpired,
      pollInterval: widget.pollInterval,
      autoPoll: widget.autoPoll,
    );
    _space.addListener(_onChanged);
    _feedScroll.addListener(_onScroll);
    unawaited(_space.start());
  }

  @override
  void dispose() {
    _space.removeListener(_onChanged);
    _feedScroll.dispose();
    _space.dispose();
    _avatars?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onScroll() {
    if (!_feedScroll.hasClients) {
      return;
    }
    if (_feedScroll.position.extentAfter < 320) {
      unawaited(_space.loadMore());
    }
  }

  Future<void> _openCompose({SpacePost? reference, SpaceDraft? draft}) async {
    final String? created = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext context) => SpaceComposePage(
          gateway: widget.gateway,
          store: widget.store,
          images: _space.images,
          draftId: draft?.draftId,
          referenceId: draft?.referenceId ?? reference?.postId,
          referencePost: reference,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    await _space.loadDrafts(silent: true);
    if (created != null) {
      await _space.refresh(explicit: true);
      await _space.openPost(created);
    }
  }

  Future<void> _openViewer(SpacePost post, int index) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SpaceImageViewer(
          images: post.images,
          initialIndex: index,
          loader: _space.images,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(SpacePost post) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除这条说说？'),
        content: const Text('正文、图片和全部评论互动都会失效，无法恢复。别人的转发仍会保留。'),
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
      await _space.deletePost(post);
    }
  }

  @override
  Widget build(BuildContext context) {
    final SpaceLayout layout = SpaceLayout.of(context);
    final bool split = layout.masterDetail && _space.detailOpen;
    final Widget left = switch (_space.section) {
      SpaceSection.feed => _feedPane(layout, dense: split),
      SpaceSection.notifications => SpaceNotificationsView(space: _space),
      SpaceSection.drafts => SpaceDraftsView(
        space: _space,
        onOpenDraft: (SpaceDraft draft) => _openCompose(draft: draft),
      ),
    };
    final Widget content;
    if (split) {
      final ({double leftWidth, double rightWidth}) panes = layout.panes();
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: panes.leftWidth, child: left),
          const VerticalDivider(width: 1),
          Expanded(
            child: _detailPane(
              layout,
              key: ValueKey<String>(_space.selectedPostId ?? ''),
            ),
          ),
        ],
      );
    } else if (_space.detailOpen) {
      content = _detailPane(
        layout,
        key: ValueKey<String>(_space.selectedPostId ?? ''),
      );
    } else {
      content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: left,
        ),
      );
    }

    final Widget page = PopScope(
      canPop: !_space.detailOpen && _space.section == SpaceSection.feed,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        if (_space.detailOpen) {
          _space.closeDetail();
        } else if (_space.section != SpaceSection.feed) {
          _space.showFeed();
        }
      },
      child: Material(
        key: SpacePage.pageKey,
        color: AppColors.paper,
        child: SpaceOcclusion(layout: layout, child: content),
      ),
    );
    final SpaceAvatarStore? avatars = _avatars;
    if (avatars == null) {
      return page;
    }
    return SpaceAvatarScope(store: avatars, child: page);
  }

  Widget _detailPane(SpaceLayout layout, {required Key key}) {
    final SpaceDetailController? detail = _space.detail;
    if (detail == null) {
      return const SizedBox.shrink();
    }
    return SpaceDetailView(
      key: key,
      controller: detail,
      space: _space,
      layout: layout,
      onClose: _space.closeDetail,
      onBack: _space.backDetail,
      onOpenReference: (String postId) => _space.openReference(postId),
    );
  }

  Widget _feedPane(SpaceLayout layout, {required bool dense}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SpaceSectionHeader(
          title: 'BB 空间',
          subtitle: '本服务器所有人的说说，按发布时间倒序。',
          dense: dense,
          unreadNotifications: _space.unreadNotifications,
          draftCount: _space.drafts.length,
          onRefresh: () => _space.refresh(explicit: true),
          onDrafts: _space.showDrafts,
          onNotifications: _space.showNotifications,
          onPublish: () => _openCompose(),
        ),
        if (_space.refreshing) const LinearProgressIndicator(minHeight: 2),
        if (_space.hasUnseenNewPosts)
          SpaceInlineBanner(
            key: SpacePage.newPostsKey,
            message: '有 ${_space.pendingNewPosts} 条新说说',
            tone: AppColors.accentDeep,
            background: AppColors.accentSoft,
            icon: Icons.arrow_upward_rounded,
            actionLabel: '查看',
            onAction: _space.applyPendingPosts,
          ),
        if (_space.offline && _space.posts.isNotEmpty)
          const SpaceInlineBanner(
            key: SpacePage.offlineKey,
            message: '当前离线，显示的是本次会话已加载的内容。',
            icon: Icons.cloud_off_rounded,
          ),
        if (_space.feedError != null && _space.posts.isNotEmpty)
          SpaceInlineBanner(
            message: _space.feedError!,
            tone: AppColors.danger,
            background: AppColors.dangerSurface,
            icon: Icons.error_outline_rounded,
            actionLabel: '重试',
            onAction: () => _space.refresh(explicit: true),
          ),
        Expanded(child: _feedBody(layout)),
      ],
    );
  }

  Widget _feedBody(SpaceLayout layout) {
    if (_space.unsupportedServer) {
      return SpaceStateView(
        key: SpacePage.capabilityKey,
        icon: Icons.dns_outlined,
        title: '当前服务器不支持 BB 空间',
        message: '聊天、登录和个人资料仍可正常使用。升级服务器后再回来。',
        actionLabel: '重新检查',
        onAction: () => _space.refresh(explicit: true),
      );
    }
    if (_space.posts.isEmpty) {
      return switch (_space.phase) {
        SpacePhase.loading => const Center(child: CircularProgressIndicator()),
        SpacePhase.error => SpaceStateView(
          key: SpacePage.retryKey,
          icon: _space.offline
              ? Icons.cloud_off_rounded
              : Icons.error_outline_rounded,
          title: _space.offline ? '暂时无法连接服务器' : '空间加载失败',
          message: _space.feedError ?? '请稍后重试',
          actionLabel: '重试',
          onAction: () => _space.refresh(explicit: true),
        ),
        _ => const SpaceStateView(
          icon: Icons.forum_outlined,
          title: '还没有说说',
          message: '点右上角的“发布”，写下第一条。',
        ),
      };
    }
    return RefreshIndicator(
      onRefresh: () => _space.refresh(explicit: true),
      child: ListView.builder(
        key: SpacePage.feedListKey,
        controller: _feedScroll,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        itemCount: _space.posts.length + (_space.hasMore ? 1 : 0),
        itemBuilder: (BuildContext context, int index) {
          if (index == _space.posts.length) {
            return Center(
              child: TextButton(
                key: SpacePage.loadMoreKey,
                onPressed: _space.loadingMore ? null : _space.loadMore,
                child: _space.loadingMore
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('加载更多说说'),
              ),
            );
          }
          final SpacePost post = _space.posts[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: SpacePostCard(
              post: post,
              loader: _space.images,
              actionsEnabled: !_space.refreshing,
              onOpen: () => _space.openPost(post.postId),
              onOpenReference: () => _space.openPost(post.reference!.postId),
              onLike: () => _space.togglePostLike(post),
              onComment: () => _space.openPost(post.postId),
              onRepost: () => _openCompose(reference: post),
              onOpenImage: (int imageIndex) => _openViewer(post, imageIndex),
              onDelete: post.canDelete ? () => _confirmDelete(post) : null,
              onOpenVisitors: () => _space.openPost(post.postId),
            ),
          );
        },
      ),
    );
  }
}
