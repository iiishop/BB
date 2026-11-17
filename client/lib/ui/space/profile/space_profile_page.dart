import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../models/space_models.dart';
import '../../../services/profile_service.dart';
import '../../../services/space_download_log.dart';
import '../space_avatars.dart';
import '../space_follow_button.dart';
import '../space_follow_store.dart';
import '../space_gateway.dart';
import '../space_image_viewer.dart';
import '../space_compose_page.dart';
import '../space_layout.dart';
import '../space_local_store.dart';
import '../space_widgets.dart';
import 'space_profile_controller.dart';
import 'space_profile_gateway.dart';
import 'space_profile_modules.dart';
import 'space_profile_month_directory.dart';
import 'space_post_detail_page.dart';

/// Where the year/month directory lives for one frame.
enum SpaceProfileDirectoryPlacement {
  /// Phone/narrow: a date button opens a vertical drawer.
  drawer,

  /// Wide window: the directory sits next to the list.
  sideRail,

  /// Flat fold: the directory takes the second pane instead of stretching the
  /// single-pane phone layout.
  secondPane,
}

/// One user's home page.
///
/// The page is the module container: it owns identity, header, directory
/// placement and module order; the registered posts module owns its own list,
/// paging and scroll. Both product entries (Profile button, Space author
/// avatar) open exactly this page. Follow state comes from the shared
/// [SpaceFollowStore], never from a page-local copy.
class SpaceProfilePage extends StatefulWidget {
  const SpaceProfilePage({
    super.key,
    required this.gateway,
    required this.space,
    required this.followStore,
    required this.userId,
    required this.viewerAccount,
    required this.images,
    required this.displayOffsetMinutes,
    this.initialIdentity,
    this.profile,
    this.modules,
    this.localStore,
    this.downloads,
  });

  final SpaceProfileGateway gateway;

  /// Shared Space gateway used by card actions and the detail path.
  final SpaceGateway space;

  final SpaceFollowStore followStore;
  final String userId;
  final String viewerAccount;

  /// Shared Space image loader; images keep the existing cache and viewer.
  final SpaceImageLoader images;

  /// Fixed display offset captured when this home-page session opened.
  final int displayOffsetMinutes;

  final SpaceProfileIdentity? initialIdentity;

  /// Existing authorized Profile entry, used for avatars only.
  final ProfileGateway? profile;

  /// Test/caller supplied module composition. Defaults to the shipped
  /// registry (posts only).
  final SpaceProfileModuleRegistry? modules;

  /// Local effect/draft store shared with the Space surface; used by the
  /// reference repost path.
  final SpaceLocalStore? localStore;

  /// Per-account download log shared with the media viewer.
  final SpaceDownloadLog? downloads;

  static const Key pageKey = Key('space-profile-page');
  static const Key backKey = Key('space-profile-back');
  static const Key identityKey = Key('space-profile-identity');
  static const Key dateButtonKey = Key('space-profile-date');
  static const Key sideDirectoryKey = Key('space-profile-side-directory');
  static const Key followKey = Key('space-profile-follow');
  static const Key unfollowDialogKey = SpaceFollowButton.dialogKey;
  static const Key unfollowConfirmKey = SpaceFollowButton.confirmKey;
  static const Key emptyModulesKey = Key('space-profile-no-modules');

  /// Below this content width the directory becomes a drawer; at or above it
  /// the list and directory share the width.
  static const double sideBySideMin = 840;
  static const double sideRailWidth = 236;
  static const double minListPane = 320;

  /// Header and list+directory row share this maximum width, so a very wide
  /// window does not leave the directory detached from the content.
  static const double maxContentWidth = 1200;

  @override
  State<SpaceProfilePage> createState() => _SpaceProfilePageState();
}

class _SpaceProfilePageState extends State<SpaceProfilePage> {
  late final SpaceProfileController _controller;
  late final SpaceProfileModuleRegistry _registry;
  final ScrollController _scroll = ScrollController();
  SpaceAvatarStore? _avatars;
  SpaceDownloadLog? _ownedDownloads;

  @override
  void initState() {
    super.initState();
    _registry = widget.modules ?? SpaceProfileModuleRegistry.standard();
    _controller = SpaceProfileController(
      gateway: widget.gateway,
      space: widget.space,
      userId: widget.userId,
      viewerAccount: widget.viewerAccount,
      displayOffsetMinutes: widget.displayOffsetMinutes,
      initialIdentity: widget.initialIdentity,
    );
    _controller.addListener(_onChanged);
    widget.followStore.addListener(_onChanged);
    if (!_controller.isSelf) {
      unawaited(widget.followStore.ensureLoaded(widget.userId));
    }
    final ProfileGateway? profile = widget.profile;
    if (profile != null) {
      _avatars = SpaceAvatarStore(profile: profile);
    }
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    widget.followStore.removeListener(_onChanged);
    _controller.dispose();
    _scroll.dispose();
    _avatars?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  SpaceProfileDirectoryPlacement _placement(SpaceLayout layout) {
    if (layout.verticalHingeX != null) {
      final ({double leftWidth, double rightWidth}) panes = layout.panes();
      if (panes.leftWidth >= SpaceProfilePage.minListPane &&
          panes.rightWidth >= SpaceProfilePage.sideRailWidth) {
        return SpaceProfileDirectoryPlacement.secondPane;
      }
    }
    if (layout.contentWidth >= SpaceProfilePage.sideBySideMin) {
      return SpaceProfileDirectoryPlacement.sideRail;
    }
    return SpaceProfileDirectoryPlacement.drawer;
  }

  Future<void> _selectMonth(SpaceProfileMonth month) async {
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    await _controller.jumpToMonth(month);
  }

  Future<void> _backToLatest() async {
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    await _controller.backToLatest();
  }

  Future<void> _openDirectorySheet() async {
    final _DirectoryChoice? choice =
        await showModalBottomSheet<_DirectoryChoice>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (BuildContext context) {
            return SafeArea(
              child: FractionallySizedBox(
                heightFactor: 0.72,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppRadius.panel),
                  ),
                  child: SpaceMonthDirectory(
                    months: _controller.months,
                    selected: _controller.anchoredMonth,
                    visible: _controller.visibleMonth,
                    atLatest: _controller.atLatest,
                    loading: _controller.monthsLoading,
                    error: _controller.monthsError,
                    onSelect: (SpaceProfileMonth month) =>
                        Navigator.of(context)
                            .pop(_DirectoryChoice.month(month)),
                    onLatest: () =>
                        Navigator.of(context)
                            .pop(const _DirectoryChoice.latest()),
                    onBack: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            );
          },
        );
    if (choice == null || !mounted) {
      return;
    }
    if (choice.latest) {
      await _backToLatest();
    } else if (choice.month != null) {
      await _selectMonth(choice.month!);
    }
  }

  Future<void> _onFollowPressed() async {
    final String name = _controller.identity?.username ?? widget.userId;
    await toggleSpaceFollow(
      context,
      store: widget.followStore,
      account: widget.userId,
      name: name,
    );
  }

  SpaceDownloadLog _downloads() =>
      widget.downloads ??
      (_ownedDownloads ??= SpaceDownloadLog(scopeKey: widget.space.scopeKey));

  SpaceProfileActions _actions() {
    return SpaceProfileActions(
      openPost: (SpacePost post) => _openDetail(post.postId),
      openComments: (SpacePost post) => _openDetail(post.postId),
      openReference: (SpacePost post) {
        final String? referenceId = post.reference?.postId;
        if (referenceId != null) {
          _openDetail(referenceId);
        }
      },
      toggleLike: _toggleLike,
      repost: _repost,
      openImage: _openViewer,
      deletePost: _confirmDelete,
    );
  }

  /// Reuses the existing detail route; closing it returns the final post so the
  /// card updates in place and the browse position is never reset.
  Future<void> _openDetail(String postId) async {
    final SpaceLocalStore? store = widget.localStore;
    if (store == null) {
      return;
    }
    final SpaceDetailOutcome? outcome = await SpacePostDetailPage.open(
      context,
      gateway: widget.space,
      store: store,
      postId: postId,
      images: widget.images,
      downloads: _downloads(),
    );
    if (!mounted || outcome == null) {
      return;
    }
    if (outcome.deleted || outcome.post == null) {
      _controller.removePost(postId);
      if (outcome.deleted) {
        await _controller.refresh();
      }
      return;
    }
    _controller.replacePost(outcome.post!);
  }

  Future<void> _toggleLike(SpacePost post) async {
    await _controller.toggleLike(post);
    if (!mounted || _controller.actionError == null) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(_controller.actionError!)));
  }

  Future<void> _openViewer(SpacePost post, int index) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SpaceImageViewer(
          images: post.images,
          initialIndex: index,
          loader: widget.images,
          downloadLog: _downloads(),
        ),
      ),
    );
  }

  Future<void> _repost(SpacePost post) async {
    final SpaceLocalStore? store = widget.localStore;
    if (store == null) {
      return;
    }
    final String? created = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext context) => SpaceComposePage(
          gateway: widget.space,
          store: store,
          images: widget.images,
          referenceId: post.postId,
          referencePost: post,
        ),
      ),
    );
    if (!mounted || created == null) {
      return;
    }
    // A new repost enters at "latest" and may add a month; refresh the current
    // view from its first page.
    await _controller.refresh();
  }

  Future<void> _confirmDelete(SpacePost post) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除这条说说？'),
        content: const Text('正文、图片和全部评论互动都会失效。别人的转发仍会保留。'),
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
    if (confirmed != true || !mounted) {
      return;
    }
    final bool deleted = await _controller.deletePost(post);
    if (!deleted && mounted && _controller.actionError != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_controller.actionError!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final SpaceLayout layout = SpaceLayout.of(context);
    final SpaceProfileDirectoryPlacement placement = _placement(layout);
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(layout, placement),
        const Divider(height: 1, color: AppColors.border),
        Expanded(child: _body(layout, placement)),
      ],
    );
    final Widget page = Material(
      key: SpaceProfilePage.pageKey,
      color: AppColors.paper,
      child: SpaceOcclusion(
        layout: layout,
        child: SafeArea(child: content),
      ),
    );
    final SpaceAvatarStore? avatars = _avatars;
    if (avatars == null) {
      return page;
    }
    return SpaceAvatarScope(store: avatars, child: page);
  }

  Widget _header(SpaceLayout layout, SpaceProfileDirectoryPlacement placement) {
    final TextTheme text = Theme.of(context).textTheme;
    final SpaceProfileIdentity? identity = _controller.identity;
    final String nickname = identity?.username ?? '加载中…';
    final String signature = identity?.signature ?? '';
    final bool isSelf = _controller.isSelf;
    final bool? followState = isSelf
        ? null
        : widget.followStore.stateFor(widget.userId);
    final bool followBusy =
        !isSelf && widget.followStore.isWriting(widget.userId);
    final bool showFollow =
        !isSelf &&
        (followState != null || followBusy || _controller.identity != null);
    final bool showDate = placement == SpaceProfileDirectoryPlacement.drawer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: SpaceProfilePage.maxContentWidth,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  IconButton(
                    key: SpaceProfilePage.backKey,
                    onPressed: () => Navigator.of(context).maybePop(),
                    tooltip: '返回',
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  SpaceAvatar(
                    author: SpaceAuthor(
                      account: widget.userId,
                      username: nickname,
                      avatarUrl: identity?.avatarUrl ?? '',
                    ),
                    size: 52,
                  ),
                  const SizedBox(width: AppSpacing.sm + 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          nickname,
                          key: SpaceProfilePage.identityKey,
                          style: text.titleMedium?.copyWith(fontSize: 18),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          identity?.account ?? widget.userId,
                          style: text.bodySmall?.copyWith(letterSpacing: 0.8),
                        ),
                        if (signature.isNotEmpty)
                          Text(
                            signature,
                            style: text.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (showFollow) ...<Widget>[
                    const SizedBox(width: AppSpacing.sm),
                    SpaceFollowButton(
                      key: SpaceProfilePage.followKey,
                      following: followState ?? false,
                      busy: followBusy,
                      onPressed: followState == null ? null : _onFollowPressed,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (showDate)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: SpaceProfilePage.maxContentWidth,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _moduleTitle(),
                        style: text.titleMedium?.copyWith(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    OutlinedButton.icon(
                      key: SpaceProfilePage.dateButtonKey,
                      onPressed: _openDirectorySheet,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm + 4,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.calendar_month_outlined, size: 18),
                      label: Text(
                        (_controller.anchoredMonth ?? _controller.visibleMonth)
                                ?.label ??
                            '日期',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _moduleTitle() {
    final List<SpaceProfileModule> modules = _registry.ordered;
    if (modules.isEmpty) {
      return '主页';
    }
    return modules.first.title;
  }

  Widget _body(SpaceLayout layout, SpaceProfileDirectoryPlacement placement) {
    final Widget list = _modules();
    switch (placement) {
      case SpaceProfileDirectoryPlacement.drawer:
        return _centered(list);
      case SpaceProfileDirectoryPlacement.sideRail:
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: SpaceProfilePage.maxContentWidth,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: _centered(list)),
                const VerticalDivider(width: 1, color: AppColors.border),
                SizedBox(
                  width: SpaceProfilePage.sideRailWidth,
                  child: _directoryPanel(
                    key: SpaceProfilePage.sideDirectoryKey,
                  ),
                ),
              ],
            ),
          ),
        );
      case SpaceProfileDirectoryPlacement.secondPane:
        final ({double leftWidth, double rightWidth}) panes = layout.panes();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(width: panes.leftWidth, child: list),
            const VerticalDivider(width: 1, color: AppColors.border),
            SizedBox(
              width: panes.rightWidth,
              child: _directoryPanel(key: SpaceProfilePage.sideDirectoryKey),
            ),
          ],
        );
    }
  }

  Widget _centered(Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: child,
      ),
    );
  }

  Widget _directoryPanel({Key? key}) {
    return SpaceMonthDirectory(
      key: key ?? SpaceProfilePage.sideDirectoryKey,
      months: _controller.months,
      selected: _controller.anchoredMonth,
      visible: _controller.visibleMonth,
      atLatest: _controller.atLatest,
      loading: _controller.monthsLoading,
      error: _controller.monthsError,
      onSelect: _selectMonth,
      onLatest: _backToLatest,
    );
  }

  Widget _modules() {
    final List<SpaceProfileModule> modules = _registry.ordered;
    if (modules.isEmpty) {
      return const SpaceStateView(
        key: SpaceProfilePage.emptyModulesKey,
        icon: Icons.dashboard_customize_outlined,
        title: '主页还没有模块',
        message: '注册一个主页模块后，它会出现在这里。',
      );
    }
    final SpaceProfileModuleScope scope = SpaceProfileModuleScope(
      controller: _controller,
      scrollController: _scroll,
      images: widget.images,
      actions: _actions(),
      displayOffsetMinutes: widget.displayOffsetMinutes,
      localStore: widget.localStore,
      downloads: widget.downloads,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final SpaceProfileModule module in modules)
          Expanded(
            key: ValueKey<String>('space-profile-module-${module.id}'),
            child: module.builder(context, scope),
          ),
      ],
    );
  }
}

class _DirectoryChoice {
  const _DirectoryChoice.month(this.month) : latest = false;
  const _DirectoryChoice.latest() : month = null, latest = true;

  final SpaceProfileMonth? month;
  final bool latest;
}

/// Single navigation helper used by every entry so both product entries open
/// exactly the same page and share the same module composition, follow store
/// and fixed browsing offset.
Future<void> openSpaceProfile(
  BuildContext context, {
  required SpaceProfileGateway gateway,
  required SpaceGateway space,
  required SpaceFollowStore followStore,
  required String userId,
  required String viewerAccount,
  required SpaceImageLoader images,
  required int displayOffsetMinutes,
  SpaceProfileIdentity? initialIdentity,
  ProfileGateway? profile,
  SpaceLocalStore? localStore,
  SpaceDownloadLog? downloads,
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => SpaceProfilePage(
        gateway: gateway,
        space: space,
        followStore: followStore,
        userId: userId,
        viewerAccount: viewerAccount,
        images: images,
        displayOffsetMinutes: displayOffsetMinutes,
        initialIdentity: initialIdentity,
        profile: profile,
        localStore: localStore,
        downloads: downloads,
      ),
    ),
  );
}
