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
import 'space_follow_button.dart';
import 'space_follow_store.dart';
import 'profile/space_profile_adapter.dart';
import 'profile/space_profile_gateway.dart';
import 'profile/space_profile_page.dart';

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
    required this.followStore,
    this.active = true,
    this.profile,
    this.onSessionExpired,
    this.pollInterval = const Duration(seconds: 20),
    this.autoPoll = true,
  });

  final SpaceGateway gateway;
  final SpaceLocalStore store;

  /// Shared follow relationship owner; the same store feeds the author home
  /// page so card and header states never diverge.
  final SpaceFollowStore followStore;

  /// Whether the Space main area is the visible primary section. Leaving and
  /// re-entering ends the Space session (the scope switch is not remembered).
  final bool active;

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
  static const Key scopeAllKey = Key('space-scope-all');
  static const Key scopeFollowingKey = Key('space-scope-following');
  static const Key followingEmptyKey = Key('space-following-empty');
  static const Key feedNoticeKey = Key('space-feed-notice');

  @override
  State<SpacePage> createState() => _SpacePageState();
}

class _SpacePageState extends State<SpacePage> {
  late final SpaceController _space;
  final ScrollController _feedScroll = ScrollController();
  final Map<SpaceFeedScope, double> _scopeOffsets = <SpaceFeedScope, double>{};
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
      followStore: widget.followStore,
      onSessionExpired: widget.onSessionExpired,
      pollInterval: widget.pollInterval,
      autoPoll: widget.autoPoll,
    );
    _space.addListener(_onChanged);
    widget.followStore.addListener(_onChanged);
    _feedScroll.addListener(_onScroll);
    unawaited(_space.start());
  }

  @override
  void didUpdateWidget(SpacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) {
      // Re-entered the Space main area: default back to "all" and drop both
      // parked browse positions.
      _scopeOffsets.clear();
      unawaited(_space.resetSession());
    }
  }

  @override
  void dispose() {
    _space.removeListener(_onChanged);
    widget.followStore.removeListener(_onChanged);
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

  /// Explicit refresh: reload the feed and revalidate every author avatar.
  ///
  /// [SpaceAvatarStore] asks at most once per account per page visit, so a
  /// profile image changed while this page stayed open would never appear.
  /// Revalidation is cheap: an unchanged avatar comes back as a 304.
  Future<void> _refresh() {
    _avatars?.reset();
    return _space.refresh(explicit: true);
  }

  void _onScroll() {
    if (!_feedScroll.hasClients) {
      return;
    }
    if (_feedScroll.position.extentAfter < 320) {
      unawaited(_space.loadMore());
    }
  }

  Future<void> _switchScope(SpaceFeedScope target) async {
    if (_space.scope == target) {
      return;
    }
    if (_feedScroll.hasClients) {
      _scopeOffsets[_space.scope] = _feedScroll.offset;
    }
    await _space.switchScope(target);
    if (!mounted) {
      return;
    }
    final double targetOffset = _scopeOffsets[target] ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_feedScroll.hasClients) {
        return;
      }
      _feedScroll.jumpTo(
        targetOffset.clamp(0, _feedScroll.position.maxScrollExtent),
      );
    });
  }

  /// Both product entries reach the same page; the Space card avatar reuses the
  /// shared timeline, cards, image loader and month directory.
  /// Fixed browsing offset for one home-page session. A real device zone is
  /// read once here; tests inject the page offset directly.
  int _displayOffsetMinutes() =>
      DateTime.now().timeZoneOffset.inMinutes.clamp(-840, 840);

  Future<void> _openAuthor(SpacePost post) async {
    await openSpaceProfile(
      context,
      gateway: SpaceProfileAdapter(
        space: widget.gateway,
        profile: widget.profile,
      ),
      space: widget.gateway,
      followStore: widget.followStore,
      userId: post.author.account,
      viewerAccount: widget.gateway.account,
      images: _space.images,
      displayOffsetMinutes: _displayOffsetMinutes(),
      initialIdentity: SpaceProfileIdentity(
        account: post.author.account,
        username: post.author.username,
        avatarUrl: post.author.avatarUrl,
      ),
      profile: widget.profile,
      localStore: widget.store,
      downloads: _space.downloads,
    );
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
      await _refresh();
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
          downloadLog: _space.downloads,
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
      images: _space.images,
      downloads: _space.downloads,
      layout: layout,
      historyDepth: _space.detailHistory.length,
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
          onRefresh: () => _refresh(),
          onDrafts: _space.showDrafts,
          onNotifications: _space.showNotifications,
          onPublish: () => _openCompose(),
        ),
        _ScopeSwitch(scope: _space.scope, onChanged: _switchScope),
        if (_space.refreshing) const LinearProgressIndicator(minHeight: 2),
        if (_space.feedNotice != null)
          SpaceInlineBanner(
            key: SpacePage.feedNoticeKey,
            message: _space.feedNotice!,
            icon: Icons.sync_rounded,
            tone: AppColors.accentDeep,
            background: AppColors.accentSoft,
          ),
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
            onAction: () => _refresh(),
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
        onAction: () => _refresh(),
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
          onAction: () => _refresh(),
        ),
        _ when _space.scope == SpaceFeedScope.following => SpaceStateView(
          key: SpacePage.followingEmptyKey,
          icon: Icons.person_search_rounded,
          title: '只看已关注里还没有说说',
          message: '这里只显示已关注用户的原创和主动转发，包括关注前的历史；没有内容时不会退回全部。',
        ),
        _ => const SpaceStateView(
          icon: Icons.forum_outlined,
          title: '还没有说说',
          message: '点右上角的“发布”，写下第一条。',
        ),
      };
    }
    return RefreshIndicator(
      onRefresh: () => _refresh(),
      child: ListView.builder(
        key: SpacePage.feedListKey,
        controller: _feedScroll,
        // Without this a short feed cannot overscroll, so pull-to-refresh
        // silently does nothing until the list is tall enough to scroll.
        physics: const AlwaysScrollableScrollPhysics(),
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
          final SpaceFollowStore follows = widget.followStore;
          final bool ownAuthor = post.author.account == widget.gateway.account;
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: SpacePostCard(
              post: post,
              loader: _space.images,
              following: ownAuthor
                  ? null
                  : follows.stateFor(post.author.account),
              followBusy: follows.isWriting(post.author.account),
              onFollow: ownAuthor
                  ? null
                  : () => toggleSpaceFollow(
                      context,
                      store: follows,
                      account: post.author.account,
                      name: post.author.username,
                    ),
              actionsEnabled: !_space.refreshing,
              onOpen: () => _space.openPost(post.postId),
              onOpenReference: () => _space.openPost(post.reference!.postId),
              onLike: () => _space.togglePostLike(post),
              onComment: () => _space.openPost(post.postId),
              onRepost: () => _openCompose(reference: post),
              onOpenImage: (int imageIndex) => _openViewer(post, imageIndex),
              onDelete: post.canDelete ? () => _confirmDelete(post) : null,
              onOpenVisitors: () => _space.openPost(post.postId),
              onOpenAuthor: () => _openAuthor(post),
            ),
          );
        },
      ),
    );
  }
}

class _ScopeSwitch extends StatelessWidget {
  const _ScopeSwitch({required this.scope, required this.onChanged});

  final SpaceFeedScope scope;
  final ValueChanged<SpaceFeedScope> onChanged;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            borderRadius: BorderRadius.circular(AppRadius.brand),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final SpaceFeedScope value in SpaceFeedScope.values)
                InkWell(
                  key: value == SpaceFeedScope.all
                      ? SpacePage.scopeAllKey
                      : SpacePage.scopeFollowingKey,
                  onTap: () => onChanged(value),
                  borderRadius: BorderRadius.circular(AppRadius.brand),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: scope == value
                          ? AppColors.surface
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.brand),
                    ),
                    child: Text(
                      value.label,
                      style: text.labelMedium?.copyWith(
                        color: scope == value
                            ? AppColors.accentDeep
                            : AppColors.inkMuted,
                        fontWeight: scope == value
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
