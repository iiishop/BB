import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../models/space_models.dart';
import '../../../services/profile_service.dart';
import '../space_avatars.dart';
import '../space_image_viewer.dart';
import '../space_layout.dart';
import '../space_widgets.dart';
import 'space_profile_controller.dart';
import 'space_profile_follow_button.dart';
import 'space_profile_gateway.dart';
import 'space_profile_modules.dart';
import 'space_profile_month_directory.dart';

/// Where the year/month directory lives for one frame.
enum SpaceProfileDirectoryPlacement {
  /// The server cannot answer the directory yet: no control is rendered.
  none,

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
/// avatar) open exactly this page.
class SpaceProfilePage extends StatefulWidget {
  const SpaceProfilePage({
    super.key,
    required this.gateway,
    required this.userId,
    required this.viewerAccount,
    required this.images,
    this.initialIdentity,
    this.actions,
    this.profile,
    this.modules,
  });

  final SpaceProfileGateway gateway;
  final String userId;
  final String viewerAccount;

  /// Shared Space image loader; images keep the existing cache and viewer.
  final SpaceImageLoader images;

  final SpaceProfileIdentity? initialIdentity;
  final SpaceProfileActions? actions;

  /// Existing authorized Profile entry, used for avatars only.
  final ProfileGateway? profile;

  /// Test/caller supplied module composition. Defaults to the shipped
  /// registry (posts only).
  final SpaceProfileModuleRegistry? modules;

  static const Key pageKey = Key('space-profile-page');
  static const Key backKey = Key('space-profile-back');
  static const Key identityKey = Key('space-profile-identity');
  static const Key dateButtonKey = Key('space-profile-date');
  static const Key sideDirectoryKey = Key('space-profile-side-directory');
  static const Key followKey = SpaceProfileFollowButton.buttonKey;
  static const Key unfollowDialogKey = Key('space-profile-unfollow-dialog');
  static const Key unfollowConfirmKey = Key('space-profile-unfollow-confirm');
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

  @override
  void initState() {
    super.initState();
    _registry = widget.modules ?? SpaceProfileModuleRegistry.standard();
    _controller = SpaceProfileController(
      gateway: widget.gateway,
      userId: widget.userId,
      viewerAccount: widget.viewerAccount,
      initialIdentity: widget.initialIdentity,
    );
    _controller.addListener(_onChanged);
    final ProfileGateway? profile = widget.profile;
    if (profile != null) {
      _avatars = SpaceAvatarStore(profile: profile);
    }
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
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
    if (!_controller.directoryAvailable) {
      return SpaceProfileDirectoryPlacement.none;
    }
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
    final SpaceProfileController controller = _controller;
    if (controller.followingBusy || !controller.followAvailable) {
      return;
    }
    final bool currentlyFollowing = controller.following == true;
    if (currentlyFollowing) {
      final String name = controller.identity?.username ?? '该用户';
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          key: SpaceProfilePage.unfollowDialogKey,
          title: const Text('取消关注？'),
          content: Text('取消后将不再关注 $name。关注关系会立即解除。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: SpaceProfilePage.unfollowConfirmKey,
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('取消关注'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    final bool applied = await controller.setFollowing(!currentlyFollowing);
    if (!mounted) {
      return;
    }
    if (!applied && controller.followError != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(controller.followError!)));
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
    final bool? followState = _controller.following;
    final bool showFollow =
        _controller.followAvailable &&
        (followState != null || _controller.followingBusy);
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
                    SpaceProfileFollowButton(
                      following: followState ?? false,
                      busy: _controller.followingBusy,
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
      case SpaceProfileDirectoryPlacement.none:
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
      actions: widget.actions,
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
/// exactly the same page and share the same module composition.
Future<void> openSpaceProfile(
  BuildContext context, {
  required SpaceProfileGateway gateway,
  required String userId,
  required String viewerAccount,
  required SpaceImageLoader images,
  SpaceProfileIdentity? initialIdentity,
  SpaceProfileActions? actions,
  ProfileGateway? profile,
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => SpaceProfilePage(
        gateway: gateway,
        userId: userId,
        viewerAccount: viewerAccount,
        images: images,
        initialIdentity: initialIdentity,
        actions: actions,
        profile: profile,
      ),
    ),
  );
}
