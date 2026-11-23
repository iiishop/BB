import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature;

import 'package:flutter/material.dart';

import '../app.dart';
import '../models/auth_models.dart';
import '../models/profile_models.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/heartbeat_controller.dart';
import '../services/presence_directory.dart';
import '../services/media_disk_cache.dart';
import '../services/profile_service.dart';
import '../models/chat_models.dart';
import 'chat/chat_page.dart';
import 'chat/users_view.dart';
import 'updates/update_scope.dart';
import 'updates/update_settings_host.dart';
import 'profile/profile_panel.dart';
import 'space/space_follow_store.dart';
import 'space/space_gateway.dart';
import 'space/space_image_viewer.dart';
import 'space/space_local_store.dart';
import 'space/space_page.dart';
import 'space/profile/space_profile_adapter.dart';
import 'space/profile/space_profile_gateway.dart';
import 'space/profile/space_profile_page.dart';
import 'widgets/profile_avatar.dart';

/// Signed-in home surface for STEP-2.
///
/// Profile is the only live module in this step. The signed-in avatar is the
/// single way into Profile: narrow message layouts replace the header BB badge
/// with it, while wide layouts keep the rail entry. The heartbeat banner appears
/// after three missed beats without logging the user out.
class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    required this.user,
    required this.profile,
    required this.auth,
    required this.heartbeat,
    required this.onSignedOut,
    required this.onSessionExpired,
    this.chat,
    this.space,
  });

  final AuthUser user;
  final ProfileGateway profile;
  final AuthGateway auth;
  final HeartbeatController heartbeat;

  /// STEP-3 chat service. When present the signed-in home is the registered
  /// user list; when null the STEP-2 profile-only home is kept.
  final ChatService? chat;
  final SpaceGateway? space;
  final void Function(LogoutResult? result) onSignedOut;
  final void Function() onSessionExpired;

  static const Key avatarEntryKey = Key('home-avatar-entry');
  static const Key reconnectingBannerKey = Key('home-reconnecting-banner');
  static const Key greetingKey = Key('home-greeting');
  static const Key signatureKey = Key('home-signature');
  static const Key errorKey = Key('home-profile-error');
  static const Key navChatKey = Key('home-nav-chat');
  static const Key navSpaceKey = Key('home-nav-space');
  static const Key railAvatarKey = Key('home-rail-avatar');
  static const double railWidth = 92;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  int _section = 0;
  Profile? _profile;
  Uint8List? _avatar;
  bool _loading = true;
  String? _error;

  /// Shared by the user list and every conversation opened from it, so both
  /// surfaces read the same last-confirmed presence instead of each keeping a
  /// snapshot or its own poll.
  PresenceDirectory? _presence;

  /// Conversation the list marks with its message note. On the phone list the
  /// chat itself is a pushed page, so the note is what remains after coming
  /// back; a wide two-pane shell passes the conversation shown on the right.
  String? _selectedAccount;

  /// One relationship owner for the signed-in account's feed cards and the
  /// author home page. Recreated when the server/account scope changes.
  SpaceFollowStore? _followStore;
  SpaceLocalStore? _spaceStore;

  @override
  void initState() {
    super.initState();
    widget.heartbeat.addListener(_onHeartbeatChanged);
    final ChatService? chat = widget.chat;
    if (chat != null) {
      _presence = PresenceDirectory(chat: chat);
    }
    _followStore = _buildFollowStore();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(HomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.space?.scopeKey != widget.space?.scopeKey) {
      _followStore?.dispose();
      _followStore = _buildFollowStore();
      _spaceStore = null;
    }
  }

  @override
  void dispose() {
    widget.heartbeat.removeListener(_onHeartbeatChanged);
    _presence?.dispose();
    _followStore?.dispose();
    super.dispose();
  }

  SpaceFollowStore? _buildFollowStore() {
    final SpaceGateway? space = widget.space;
    if (space == null) {
      return null;
    }
    return SpaceFollowStore(gateway: space, viewerAccount: space.account);
  }

  void _onHeartbeatChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Profile profile = await widget.profile.loadProfile();
      // Rail avatar is 48 px; the original can be hundreds of KB.
      final AvatarImage image = await widget.profile.loadAvatar(thumb: true);
      if (!mounted) {
        return;
      }
      setState(() {
        _profile = profile;
        _avatar = image.bytes;
        _loading = false;
      });
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      if (failure.status == 401) {
        setState(() => _loading = false);
        widget.onSessionExpired();
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
        _error = '资料加载失败，请稍后重试';
      });
    }
  }

  Future<void> _openProfile() async {
    final ProfilePanelResult? result = await openProfilePanel(
      context,
      gateway: widget.profile,
      user: widget.user,
      initialProfile: _profile,
      initialAvatar: _avatar,
      onLogout: widget.auth.logout,
    );
    if (!mounted) {
      return;
    }
    if (result?.signedOut ?? false) {
      widget.onSignedOut(result!.logout);
      return;
    }
    if (result?.openSettings ?? false) {
      await _openSettings();
      if (!mounted) {
        return;
      }
    }
    final String? homeAccount = result?.openHomeAccount;
    if (homeAccount != null) {
      await _openAuthorHome(homeAccount);
      if (!mounted) {
        return;
      }
    }
    // A barrier dismissal also returns null; reload anyway so edits made just
    // before closing can never leave the home surface stale.
    await _load();
  }

  /// Opens the shared author home page through the same page the Space surface
  /// uses. The production adapter uses the existing author-scoped Space page
  /// and the existing authorized Profile entry; no second transport is added.
  Future<void> _openAuthorHome(String account) async {
    final SpaceGateway? space = widget.space;
    if (space == null) {
      return;
    }
    final Profile? me = _profile;
    final SpaceProfileIdentity? identity = me != null && me.account == account
        ? SpaceProfileIdentity(
            account: me.account,
            username: me.username,
            signature: me.signature,
            avatarUrl: me.avatarUrl,
          )
        : null;
    final SpaceFollowStore? follows = _followStore;
    if (follows == null) {
      return;
    }
    _spaceStore ??= SpaceLocalStore.shared(scopeKey: space.scopeKey);
    await openSpaceProfile(
      context,
      gateway: SpaceProfileAdapter(space: space, profile: widget.profile),
      space: space,
      followStore: follows,
      userId: account,
      viewerAccount: space.account,
      images: SpaceImageLoader(space, disk: sharedMediaDiskCache()),
      displayOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes.clamp(
        -840,
        840,
      ),
      initialIdentity: identity,
      profile: widget.profile,
      localStore: _spaceStore,
    );
  }

  Future<void> _openSettings() async {
    final UpdateScopeData? updates = UpdateScope.maybeOf(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            updates?.buildSettingsPage() ??
            const UpdateSettingsHost.unsupported(),
      ),
    );
  }

  /// Opens [user]'s conversation and records the entry as a view fact.
  ///
  /// The recording starts before the route is pushed so navigation never waits
  /// on a long history, but it is awaited when the conversation closes: the
  /// list refresh then reads confirmed display facts instead of racing them.
  /// It is display bookkeeping only — not a consumption ACK and not an
  /// outbound read receipt.
  Future<void> _openChat(ChatUser user) async {
    final ChatService? chat = widget.chat;
    if (chat == null) {
      return;
    }
    final Future<void> viewed = chat
        .markConversationViewed(user.account)
        .then<void>((int _) {})
        // A failed view record must not block opening or later refreshes; the
        // next refresh retries the derivation from the same server facts.
        .catchError((Object _) {});
    // Selection is stored by account, not row index: after a reorder or a
    // refresh the note still marks this contact. The wide shell reuses the
    // field it passes to UsersListView when it opens the right-hand pane.
    if (mounted && _selectedAccount != user.account) {
      setState(() => _selectedAccount = user.account);
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ChatPage(
          peer: user,
          chat: chat,
          profile: widget.profile,
          presence: _presence,
        ),
      ),
    );
    await viewed;
  }

  @override
  Widget build(BuildContext context) {
    final SpaceGateway? space = widget.space;
    if (space == null) {
      // No rail in this shell, so the header avatar is the only profile entry.
      return _chatScaffold(context, showHeaderAvatar: true);
    }
    return _appScaffold(context, space);
  }

  /// The header entry that replaces the BB badge on narrow layouts.
  ///
  /// A phone opens Profile as a full-screen route, so the avatar is a Hero that
  /// flies to the cover edge; desktop/folded keep the dialog and stay plain.
  Widget _headerAvatar() {
    final Widget avatar = ProfileAvatar(
      key: HomeView.avatarEntryKey,
      bytes: _avatar,
      size: 44,
      loading: _loading && _avatar == null,
      onTap: _openProfile,
      semanticLabel: '打开个人资料',
    );
    if (MediaQuery.sizeOf(context).width >= 600) {
      return avatar;
    }
    return Hero(
      tag: ProfilePanel.avatarHeroTag,
      flightShuttleBuilder: ProfilePanel.avatarFlightShuttle,
      child: avatar,
    );
  }

  Widget _chatScaffold(BuildContext context, {required bool showHeaderAvatar}) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool reconnecting =
        widget.heartbeat.phase == HeartbeatPhase.reconnecting;
    final String nickname = _profile?.username ?? widget.user.username;

    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: reconnecting
                  ? _ReconnectBanner(key: HomeView.reconnectingBannerKey)
                  : const SizedBox(width: double.infinity),
            ),
            if (widget.chat != null)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.sm,
                            AppSpacing.lg,
                            AppSpacing.xs,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _BrandRow(
                                account: widget.user.account,
                                avatarEntry: showHeaderAvatar
                                    ? _headerAvatar()
                                    : null,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                '消息',
                                style: text.headlineMedium?.copyWith(
                                  fontSize: 30,
                                  letterSpacing: -0.6,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '当前服务器的注册用户都在这里，点一行开始聊天。',
                                style: text.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: UsersListView(
                        chat: widget.chat!,
                        profile: widget.profile,
                        presence: _presence,
                        selectedAccount: _selectedAccount,
                        onOpenChat: _openChat,
                        onSessionExpired: widget.onSessionExpired,
                      ),
                    ),
                  ],
                ),
              )
            else
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xl,
                    AppSpacing.lg,
                    120,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _BrandRow(
                            account: widget.user.account,
                            avatarEntry: showHeaderAvatar
                                ? _headerAvatar()
                                : null,
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          Text(
                            '你好，$nickname',
                            key: HomeView.greetingKey,
                            style: text.headlineMedium?.copyWith(
                              fontSize: 30,
                              letterSpacing: -0.6,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            (_profile?.signature?.isNotEmpty ?? false)
                                ? _profile!.signature!
                                : '还没有签名。点左上角头像，写下第一句自我介绍。',
                            key: HomeView.signatureKey,
                            style: text.bodyLarge?.copyWith(
                              color: (_profile?.signature?.isNotEmpty ?? false)
                                  ? AppColors.ink
                                  : AppColors.inkMuted,
                              fontStyle:
                                  (_profile?.signature?.isNotEmpty ?? false)
                                  ? null
                                  : FontStyle.italic,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xxl),
                          const _ComingSoonCard(),
                          if (_error != null) ...<Widget>[
                            const SizedBox(height: AppSpacing.lg),
                            Text(
                              _error!,
                              key: HomeView.errorKey,
                              style: text.bodySmall?.copyWith(
                                color: AppColors.danger,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextButton(
                              onPressed: _load,
                              child: const Text('重新加载资料'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Signed-in shell when Space is available. Chat keeps its existing surface;
  /// Space is a sibling tab, so switching never rebuilds either state tree.
  Widget _appScaffold(BuildContext context, SpaceGateway space) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 720;
        final Widget pages = IndexedStack(
          index: _section,
          children: <Widget>[
            // Wide layouts have the rail, which already carries the profile
            // entry; only narrow layouts put the avatar in the message header.
            _chatScaffold(context, showHeaderAvatar: compact),
            _spacePage(
              context,
              space,
              railWidth: compact ? 0 : HomeView.railWidth,
              active: _section == 1,
            ),
          ],
        );
        return Scaffold(
          backgroundColor: AppColors.paper,
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: compact ? 0 : HomeView.railWidth,
                child: compact ? null : _rail(context),
              ),
              Expanded(child: pages),
            ],
          ),
          bottomNavigationBar: compact
              ? NavigationBar(
                  selectedIndex: _section,
                  onDestinationSelected: (int index) =>
                      setState(() => _section = index),
                  destinations: const <NavigationDestination>[
                    NavigationDestination(
                      key: HomeView.navChatKey,
                      icon: Icon(Icons.chat_bubble_outline_rounded),
                      selectedIcon: Icon(Icons.chat_bubble_rounded),
                      label: '聊天',
                    ),
                    NavigationDestination(
                      key: HomeView.navSpaceKey,
                      icon: Icon(Icons.public_outlined),
                      selectedIcon: Icon(Icons.public_rounded),
                      label: 'BB空间',
                    ),
                  ],
                )
              : null,
        );
      },
    );
  }

  /// The rail consumes [railWidth] screen pixels. Shift the Space media
  /// rectangle so a hinge stays a real pane boundary instead of drifting by
  /// the navigation width.
  Widget _spacePage(
    BuildContext context,
    SpaceGateway space, {
    required double railWidth,
    required bool active,
  }) {
    return Builder(
      builder: (BuildContext context) {
        final MediaQueryData media = MediaQuery.of(context);
        final Size size = media.size;
        return MediaQuery(
          data: media.copyWith(
            size: Size(math.max(size.width - railWidth, 0), size.height),
            displayFeatures: <DisplayFeature>[
              for (final DisplayFeature feature in media.displayFeatures)
                DisplayFeature(
                  bounds: feature.bounds.translate(-railWidth, 0),
                  type: feature.type,
                  state: feature.state,
                ),
            ],
          ),
          child: SafeArea(
            child: SpacePage(
              key: ValueKey<String>('space-${space.scopeKey}'),
              gateway: space,
              store: _spaceStore ??= SpaceLocalStore.shared(
                scopeKey: space.scopeKey,
              ),
              followStore: _followStore!,
              active: active,
              profile: widget.profile,
              onSessionExpired: widget.onSessionExpired,
            ),
          ),
        );
      },
    );
  }

  Widget _rail(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      width: 92,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                'BB',
                style: text.labelLarge?.copyWith(
                  color: AppColors.accentDeep,
                  letterSpacing: 1.6,
                  fontSize: 18,
                ),
              ),
            ),
            _RailButton(
              key: HomeView.navChatKey,
              icon: _section == 0
                  ? Icons.chat_bubble_rounded
                  : Icons.chat_bubble_outline_rounded,
              label: '聊天',
              selected: _section == 0,
              onTap: () => setState(() => _section = 0),
            ),
            const SizedBox(height: AppSpacing.sm),
            _RailButton(
              key: HomeView.navSpaceKey,
              icon: _section == 1
                  ? Icons.public_rounded
                  : Icons.public_outlined,
              label: 'BB空间',
              selected: _section == 1,
              onTap: () => setState(() => _section = 1),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: ProfileAvatar(
                key: HomeView.railAvatarKey,
                bytes: _avatar,
                size: 48,
                loading: _loading && _avatar == null,
                onTap: _openProfile,
                semanticLabel: '打开个人资料',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? AppColors.accentDeep : AppColors.inkMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.brand),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.brand),
          ),
          child: Column(
            children: <Widget>[
              Icon(icon, color: color, size: 22),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      color: AppColors.warningSurface,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: AppColors.warning,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '连接已断开，正在重连',
              style: text.bodySmall?.copyWith(
                color: AppColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandRow extends StatelessWidget {
  const _BrandRow({required this.account, this.avatarEntry});

  final String account;

  /// When present, the signed-in avatar replaces the BB badge on the same row
  /// as the account, above the "消息" title.
  final Widget? avatarEntry;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        avatarEntry ??
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm + 2,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(AppRadius.brand),
              ),
              child: Text(
                'BB',
                style: text.labelLarge?.copyWith(
                  color: AppColors.accentDeep,
                  letterSpacing: 1.6,
                ),
              ),
            ),
        const Spacer(),
        Text(account, style: text.bodySmall?.copyWith(letterSpacing: 1)),
      ],
    );
  }
}

class _ComingSoonCard extends StatelessWidget {
  const _ComingSoonCard();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.auto_awesome_outlined,
                size: 20,
                color: AppColors.accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('下一步', style: text.titleMedium),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Profile 已接入真实服务端。Chat 与 Space 会在这里展开；'
            'AI Actor 会作为普通联系人出现，不会把底层会话直接暴露成消息。',
            style: text.bodyLarge,
          ),
        ],
      ),
    );
  }
}
