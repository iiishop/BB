import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../models/space_models.dart';
import '../space_image_viewer.dart';
import '../space_widgets.dart';
import 'space_profile_controller.dart';
import 'space_profile_gateway.dart';
import 'space_profile_modules.dart';

/// The only shipped home-page module: the author's mixed original/repost
/// timeline.
///
/// It reuses [SpacePostCard], the shared image loader and the shared month/time
/// helpers. Paging, the selected month and the visible-month highlight are read
/// from [SpaceProfileController]; the module owns only its scroll mechanics.
class SpaceProfilePostsModule extends StatefulWidget {
  const SpaceProfilePostsModule({
    super.key,
    required this.controller,
    required this.scroll,
    required this.images,
    this.actions,
    this.displayOffsetMinutes,
  });

  final SpaceProfileController controller;
  final ScrollController scroll;
  final SpaceImageLoader images;
  final SpaceProfileActions? actions;

  /// Fixed browsing offset for card dates; null keeps the feed's local-time
  /// formatting for standalone card tests.
  final int? displayOffsetMinutes;

  static const Key listKey = Key('space-profile-list');
  static const Key loadMoreKey = Key('space-profile-load-more');
  static const Key retryKey = Key('space-profile-retry');
  static const Key emptyKey = Key('space-profile-empty');

  @override
  State<SpaceProfilePostsModule> createState() =>
      _SpaceProfilePostsModuleState();
}

class _SpaceProfilePostsModuleState extends State<SpaceProfilePostsModule> {
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};
  bool _visibleMonthScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_onScroll);
    _scheduleVisibleMonthCheck();
  }

  @override
  void didUpdateWidget(SpaceProfilePostsModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scroll != widget.scroll) {
      oldWidget.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    super.dispose();
  }

  GlobalKey _keyFor(String postId) =>
      _itemKeys.putIfAbsent(postId, () => GlobalKey());

  void _pruneKeys() {
    if (_itemKeys.length <= widget.controller.entries.length + 40) {
      return;
    }
    final Set<String> live = <String>{
      for (final SpaceProfileEntry entry in widget.controller.entries)
        entry.post.postId,
    };
    _itemKeys.removeWhere((String id, GlobalKey _) => !live.contains(id));
  }

  void _onScroll() {
    if (!mounted) {
      return;
    }
    if (widget.scroll.position.extentAfter < 320) {
      unawaited(widget.controller.loadMore());
    }
    _scheduleVisibleMonthCheck();
  }

  void _scheduleVisibleMonthCheck() {
    if (_visibleMonthScheduled) {
      return;
    }
    _visibleMonthScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibleMonthScheduled = false;
      if (!mounted) {
        return;
      }
      _reportVisibleMonth();
    });
  }

  /// The visible month is the month of the row occupying the top of the list.
  /// Rows just outside the viewport are still built by the sliver cache, so the
  /// scan never depends on a magic item height.
  void _reportVisibleMonth() {
    final SpaceProfileController controller = widget.controller;
    if (controller.entries.isEmpty) {
      return;
    }
    final RenderBox? host = context.findRenderObject() as RenderBox?;
    if (host == null || !host.attached) {
      return;
    }
    final double origin = host.localToGlobal(Offset.zero).dy;
    SpaceProfileEntry? anchored;
    double anchoredTop = double.negativeInfinity;
    for (final SpaceProfileEntry entry in controller.entries) {
      final GlobalKey? key = _itemKeys[entry.post.postId];
      final RenderObject? render = key?.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.attached) {
        continue;
      }
      final double top = render.localToGlobal(Offset.zero).dy - origin;
      if (top <= 0 && top > anchoredTop) {
        anchoredTop = top;
        anchored = entry;
      }
    }
    if (anchored == null) {
      double best = double.infinity;
      for (final SpaceProfileEntry entry in controller.entries) {
        final GlobalKey? key = _itemKeys[entry.post.postId];
        final RenderObject? render = key?.currentContext?.findRenderObject();
        if (render is! RenderBox || !render.attached) {
          continue;
        }
        final double top = render.localToGlobal(Offset.zero).dy - origin;
        if (top >= 0 && top < best) {
          best = top;
          anchored = entry;
        }
      }
    }
    if (anchored != null) {
      controller.reportVisibleMonth(controller.monthOf(anchored.timelineAt));
    }
  }

  @override
  Widget build(BuildContext context) {
    final SpaceProfileController controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (controller.refreshing) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _body(controller)),
      ],
    );
  }

  Widget _body(SpaceProfileController controller) {
    if (controller.entries.isEmpty) {
      return switch (controller.phase) {
        SpaceProfilePhase.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        SpaceProfilePhase.error => SpaceStateView(
          key: SpaceProfilePostsModule.retryKey,
          icon: Icons.error_outline_rounded,
          title: '主页加载失败',
          message: controller.error ?? '请稍后重试',
          actionLabel: '重试',
          onAction: () => controller.refresh(),
        ),
        SpaceProfilePhase.empty => SpaceStateView(
          key: SpaceProfilePostsModule.emptyKey,
          icon: Icons.forum_outlined,
          title: '还没有可见的说说',
          message: controller.atLatest
              ? '原创说说和主动转发会出现在这里。'
              : '这个月份没有可见内容，换个日期看看。',
        ),
        SpaceProfilePhase.ready => const SizedBox.shrink(),
      };
    }
    final SpaceProfileActions? actions = widget.actions;
    final List<SpaceProfileEntry> entries = controller.entries;
    _pruneKeys();
    _scheduleVisibleMonthCheck();
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView.builder(
        key: SpaceProfilePostsModule.listKey,
        controller: widget.scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        itemCount: entries.length + (controller.hasMore ? 1 : 0),
        itemBuilder: (BuildContext context, int index) {
          if (index == entries.length) {
            return Center(
              child: TextButton(
                key: SpaceProfilePostsModule.loadMoreKey,
                onPressed: controller.loadingMore ? null : controller.loadMore,
                child: controller.loadingMore
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('加载更早的说说'),
              ),
            );
          }
          final SpaceProfileEntry entry = entries[index];
          final SpacePost post = entry.post;
          return Padding(
            key: _keyFor(post.postId),
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: SpacePostCard(
              post: post,
              loader: widget.images,
              timelineAt: entry.timelineAt,
              timezoneOffsetMinutes: widget.displayOffsetMinutes,
              actionsEnabled: actions != null,
              onOpen: () => actions?.openPost?.call(post),
              onOpenAuthor: null,
              onOpenReference: () => actions?.openReference?.call(post),
              onLike: () => actions?.toggleLike?.call(post),
              onComment: () => actions?.openComments?.call(post),
              onRepost: () => actions?.repost?.call(post),
              onOpenImage: (int imageIndex) =>
                  actions?.openImage?.call(post, imageIndex),
              onDelete: post.canDelete && actions?.deletePost != null
                  ? () => actions!.deletePost!.call(post)
                  : null,
              // The card's visitor counter belongs to the shared detail
              // surface; it stays inert until the host provides it.
              onOpenVisitors: actions?.openPost == null
                  ? null
                  : () => actions!.openPost!.call(post),
            ),
          );
        },
      ),
    );
  }
}

SpaceProfileModule spacePostsModule() {
  return SpaceProfileModule(
    id: SpaceProfileModuleRegistry.postsModuleId,
    title: '说说',
    order: 0,
    builder: (BuildContext context, SpaceProfileModuleScope scope) =>
        SpaceProfilePostsModule(
          controller: scope.controller,
          scroll: scope.scrollController,
          images: scope.images,
          actions: scope.actions,
          displayOffsetMinutes: scope.displayOffsetMinutes,
        ),
  );
}
