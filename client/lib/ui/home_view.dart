import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app.dart';
import '../models/auth_models.dart';
import '../models/group_models.dart';
import '../models/profile_models.dart';
import '../services/auth_service.dart';
import '../services/auth_session.dart';
import '../services/chat_api_client.dart';
import '../services/chat_service.dart';
import '../services/group_service.dart';
import '../services/heartbeat_controller.dart';
import '../services/presence_directory.dart';
import '../services/media_disk_cache.dart';
import '../services/profile_service.dart';
import '../models/chat_models.dart';
import 'display_features.dart';
import 'home_navigation.dart';
import 'notifications/notification_center.dart';
import 'chat/chat_page.dart';
import 'chat/chat_workspace.dart';
import 'chat/users_view.dart';
import 'updates/update_scope.dart';
import 'updates/update_settings_host.dart';
import 'profile/avatar_picker.dart';
import 'profile/group_profile_host.dart';
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

/// Signed-in shell. General notifications remain available independently of
/// Space; hidden chat panes keep their existing display-confirmation rules.
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
    this.groups,
    this.shared,
    this.avatarPicker,
    this.space,
    this.notificationBuilder,
    this.onCreateGroup,
    this.onFindGroup,
  });

  final AuthUser user;
  final ProfileGateway profile;
  final AuthGateway auth;
  final HeartbeatController heartbeat;

  /// STEP-3 chat service. When present the signed-in home is the registered
  /// user list; when null the STEP-2 profile-only home is kept.
  final ChatService? chat;
  final GroupService? groups;
  final SharedConversationService? shared;
  final AvatarImagePicker? avatarPicker;
  final SpaceGateway? space;
  final Widget Function(BuildContext context, bool active)? notificationBuilder;
  final VoidCallback? onCreateGroup;
  final VoidCallback? onFindGroup;
  final void Function(LogoutResult? result) onSignedOut;
  final void Function() onSessionExpired;

  static const Key avatarEntryKey = Key('home-avatar-entry');
  static const Key reconnectingBannerKey = Key('home-reconnecting-banner');
  static const Key greetingKey = Key('home-greeting');
  static const Key signatureKey = Key('home-signature');
  static const Key errorKey = Key('home-profile-error');
  static const Key navChatKey = Key('home-nav-chat');
  static const Key navSpaceKey = Key('home-nav-space');
  static const Key navNotificationsKey = Key('home-nav-notifications');
  static const Key bottomNavKey = Key('home-bottom-nav');
  static const Key groupMenuKey = Key('home-group-menu');
  static const Key railAvatarKey = Key('home-rail-avatar');
  static const double railWidth = 92;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView>
    with SingleTickerProviderStateMixin {
  int _section = 0;
  final LayerLink _railNavLink = LayerLink();
  static Widget _buildSpaceNavIcon(
    BuildContext context,
    Color color,
    bool selected,
    double size,
  ) => HomeSpaceNavIcon(color: color, selected: selected, size: size);

  static const List<HomeNavItem> _navItems = <HomeNavItem>[
    HomeNavItem(
      itemKey: HomeView.navChatKey,
      label: '聊天',
      icon: Icons.chat_bubble_outline_rounded,
      selectedIcon: Icons.chat_bubble_rounded,
    ),
    HomeNavItem(
      itemKey: HomeView.navSpaceKey,
      label: 'BB空间',
      icon: Icons.public_outlined,
      selectedIcon: Icons.public_rounded,
      iconBuilder: _buildSpaceNavIcon,
    ),
    HomeNavItem(
      itemKey: HomeView.navNotificationsKey,
      label: '通知',
      icon: Icons.notifications_none_rounded,
      selectedIcon: Icons.notifications_rounded,
    ),
  ];
  Profile? _profile;
  Uint8List? _avatar;
  bool _loading = true;
  String? _error;
  bool _foldResetScheduled = false;

  /// One fold transition for the shell: the chat pane grows over the rail and
  /// the rail slides out from under it on the same progress, so the chat's left
  /// edge reaches physical screen x = 0 without a second animation to drift.
  late final AnimationController _foldController = AnimationController(
    vsync: this,
    duration: ChatWorkspace.foldDuration,
  );

  /// Shared by the user list and every conversation opened from it, so both
  /// surfaces read the same last-confirmed presence instead of each keeping a
  /// snapshot or its own poll.
  PresenceDirectory? _presence;

  /// Conversation the list marks with its message note. On the phone list the
  /// chat itself is a pushed page, so the note is what remains after coming
  /// back; a wide two-pane shell passes the conversation shown on the right.
  String? _selectedAccount;
  String? _selectedConversationId;
  final ValueNotifier<int> _groupsRefresh = ValueNotifier<int>(0);
  final ValueNotifier<int> _noticesRefresh = ValueNotifier<int>(0);
  Timer? _groupEventsTimer;
  WebSocket? _groupEventsSocket;
  StreamSubscription<dynamic>? _groupEventsSub;
  bool _groupSocketConnecting = false;
  int _lastGroupEventId = 0;
  bool _groupEventsInFlight = false;

  /// One relationship owner for the signed-in account's feed cards and the
  /// author home page. Recreated when the server/account scope changes.
  SpaceFollowStore? _followStore;
  SpaceLocalStore? _spaceStore;

  /// One "only online" state shared by the phone and split lists: growing the
  /// window swaps the arrangement, never the user's filter.
  final ValueNotifier<bool> _onlineFilter = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    widget.heartbeat.addListener(_onHeartbeatChanged);
    final ChatService? chat = widget.chat;
    if (chat != null) {
      _presence = PresenceDirectory(chat: chat);
    }
    _followStore = _buildFollowStore();
    if (widget.shared != null) {
      unawaited(_pollGroupEvents());
      unawaited(_ensureGroupEventSocket());
      _groupEventsTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!mounted) {
          return;
        }
        if (!_groupEventsInFlight) {
          unawaited(_pollGroupEvents());
        }
        if (_groupEventsSocket == null && !_groupSocketConnecting) {
          unawaited(_ensureGroupEventSocket());
        }
      });
    }
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
    _groupEventsTimer?.cancel();
    unawaited(_groupEventsSub?.cancel());
    unawaited(_groupEventsSocket?.close());
    _groupEventsSub = null;
    _groupEventsSocket = null;
    _presence?.dispose();
    _followStore?.dispose();
    _onlineFilter.dispose();
    _groupsRefresh.dispose();
    _noticesRefresh.dispose();
    _foldController.dispose();
    super.dispose();
  }

  void _bumpGroupsRefresh() {
    if (mounted) {
      _groupsRefresh.value += 1;
    }
  }

  void _bumpNoticesRefresh() {
    if (mounted) {
      _noticesRefresh.value += 1;
    }
  }

  Future<void> _applySharedEvent(String account, ServerEvent event) async {
    final SharedConversationService? shared = widget.shared;
    if (shared == null || event.eventId <= _lastGroupEventId) {
      return;
    }
    _lastGroupEventId = event.eventId;
    final ServerEventDisposition disposition = await shared.applyServerEvent(
      account,
      event,
    );
    switch (disposition) {
      case ServerEventDisposition.notificationAvailable:
        _bumpNoticesRefresh();
      case ServerEventDisposition.groupAccessGranted:
      case ServerEventDisposition.groupAccessRevoked:
      case ServerEventDisposition.groupCurrentMessage:
        _bumpGroupsRefresh();
      case ServerEventDisposition.directMessage:
      case ServerEventDisposition.staleGroupMessage:
      case ServerEventDisposition.revokedGroupMessage:
      case ServerEventDisposition.staleAccessEvent:
        break;
    }
  }

  Future<void> _ensureGroupEventSocket() async {
    final SharedConversationService? shared = widget.shared;
    final AuthIdentity? identity = shared?.session.identity;
    if (shared == null ||
        identity == null ||
        _groupSocketConnecting ||
        _groupEventsSocket != null ||
        !mounted) {
      return;
    }
    _groupSocketConnecting = true;
    try {
      final WebSocket socket = await shared.api.connectAllEvents(
        identity.token,
        includeGroups: true,
      );
      if (!mounted || !shared.session.isCurrent(identity)) {
        await socket.close();
        return;
      }
      _groupEventsSocket = socket;
      _groupEventsSub = socket.listen(
        (dynamic raw) {
          if (!mounted || !shared.session.isCurrent(identity)) {
            return;
          }
          if (raw is String) {
            try {
              final ServerEvent event = ServerEvent.fromJson(jsonDecode(raw));
              unawaited(_applySharedEvent(identity.account, event));
              return;
            } catch (_) {
              // Fall back to HTTP event replay with shared cursor below.
            }
          }
          unawaited(_pollGroupEvents());
        },
        onError: (_) {
          _groupEventsSub = null;
          _groupEventsSocket = null;
        },
        onDone: () {
          _groupEventsSub = null;
          _groupEventsSocket = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      // Best-effort hint socket; HTTP /events?include_groups=true polling stays active.
    } finally {
      _groupSocketConnecting = false;
    }
  }

  Future<void> _pollGroupEvents() async {
    final SharedConversationService? shared = widget.shared;
    if (shared == null || _groupEventsInFlight) {
      return;
    }
    final AuthIdentity? identity = shared.session.identity;
    if (identity == null) {
      return;
    }
    _groupEventsInFlight = true;
    try {
      while (mounted && shared.session.isCurrent(identity)) {
        final ServerEventPage page = await shared.api.events(
          token: identity.token,
          afterEventId: _lastGroupEventId,
          includeGroups: true,
        );
        for (final ServerEvent event in page.items) {
          await _applySharedEvent(identity.account, event);
        }
        if (!page.hasMore || page.nextEventId <= _lastGroupEventId) {
          if (page.nextEventId > _lastGroupEventId) {
            _lastGroupEventId = page.nextEventId;
          }
          break;
        }
        _lastGroupEventId = page.nextEventId;
      }
    } catch (_) {
      // Background event polling is best effort and resumes on next tick.
    } finally {
      _groupEventsInFlight = false;
    }
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
        .markConversationViewed(
          user.account,
          throughPosition: chat.observedConversationPosition(user.account),
        )
        .then<void>((int _) {})
        // A failed view record must not block opening or later refreshes; the
        // next refresh retries the derivation from the same server facts.
        .catchError((Object _) {});
    // Selection is stored by account, not row index: after a reorder or a
    // refresh the note still marks this contact. The wide shell reuses the
    // field it passes to UsersListView when it opens the right-hand pane.
    if (mounted &&
        (_selectedAccount != user.account || _selectedConversationId != null)) {
      setState(() {
        _selectedAccount = user.account;
        _selectedConversationId = null;
      });
    }
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
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

  Future<void> _openGroup(GroupConversationItem group) async {
    final ChatService? chat = widget.chat;
    if (chat == null) {
      return;
    }
    if (mounted && _selectedConversationId != group.conversation.id) {
      setState(() {
        _selectedConversationId = group.conversation.id;
        _selectedAccount = null;
      });
    }
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ChatPage(
          group: group,
          chat: chat,
          profile: widget.profile,
          shared: widget.shared,
          groups: widget.groups,
          onOpenDirectChat: _openChat,
          onGroupsChanged: _bumpGroupsRefresh,
          onGroupRevoked: (_) => _bumpGroupsRefresh(),
        ),
      ),
    );
    _bumpGroupsRefresh();
  }

  Future<void> _handleCreateGroup() async {
    if (widget.onCreateGroup != null) {
      widget.onCreateGroup!.call();
      return;
    }
    final GroupService? groups = widget.groups;
    final ChatService? chat = widget.chat;
    if (groups == null || chat == null) {
      return;
    }
    final GroupProfile? created = await openCreateGroupFlow(
      context,
      chat: chat,
      groups: groups,
      profile: widget.profile,
      avatarPicker: widget.avatarPicker,
      onSessionExpired: widget.onSessionExpired,
    );
    if (created == null || !mounted) {
      return;
    }
    _bumpGroupsRefresh();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已创建群聊 ${created.name}（群号 ${created.groupNumber}）'),
        ),
      );
  }

  Future<void> _handleFindGroup() async {
    if (widget.onFindGroup != null) {
      widget.onFindGroup!.call();
      return;
    }
    final GroupService? groups = widget.groups;
    if (groups == null) {
      return;
    }
    await openFindGroupDialog(
      context,
      groups: groups,
      chat: widget.chat,
      profile: widget.profile,
      onOpenDirectChat: _openChat,
      onGroupsChanged: _bumpGroupsRefresh,
      onSessionExpired: widget.onSessionExpired,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _appScaffold(context, widget.space);
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

  Widget _chatScaffold(
    BuildContext context, {
    required bool showHeaderAvatar,
    bool visible = true,
    double? displayWidth,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final ChatService? chat = widget.chat;
        if (chat != null &&
            ChatWorkspace.usesSplit(
              context,
              constraints.maxWidth,
              displayWidth: displayWidth,
            )) {
          return _splitChatScaffold(
            context,
            chat,
            showHeaderAvatar: showHeaderAvatar,
            visible: visible,
            displayWidth: displayWidth,
          );
        }
        return _singleChatScaffold(context, showHeaderAvatar: showHeaderAvatar);
      },
    );
  }

  /// Desktop / unfolded foldable: the same conversation list and the same
  /// chat page mounted side by side. Only selection and layout live here.
  Widget _splitChatScaffold(
    BuildContext context,
    ChatService chat, {
    required bool showHeaderAvatar,
    bool visible = true,
    double? displayWidth,
  }) {
    final bool reconnecting =
        widget.heartbeat.phase == HeartbeatPhase.reconnecting;
    final MediaQueryData media = MediaQuery.of(context);
    final EdgeInsets padding = media.padding;
    return Scaffold(
      backgroundColor: AppColors.paper,
      // SafeArea moves the workspace again after the rail translation.
      body: MediaQuery(
        data: media.copyWith(
          displayFeatures: translateDisplayFeatures(
            media.displayFeatures,
            Offset(-padding.left, -padding.top),
          ),
        ),
        child: SafeArea(
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
              Expanded(
                child: ChatWorkspace(
                  chat: chat,
                  profile: widget.profile,
                  shared: widget.shared,
                  groups: widget.groups,
                  refreshTrigger: _groupsRefresh,
                  onGroupsChanged: _bumpGroupsRefresh,
                  presence: _presence,
                  onlineFilter: _onlineFilter,
                  onSessionExpired: widget.onSessionExpired,
                  // The shell can cover this whole surface with Space; then the
                  // reader cannot see arrivals and the panes must not confirm
                  // display facts.
                  visible: visible,
                  foldController: _foldController,
                  // The unfolded breakpoint is a device width; this shell keeps
                  // 92 px for its rail, so an 800 px foldable must still split.
                  displayWidth: displayWidth,
                  listHeader: _chatHeader(
                    context,
                    showHeaderAvatar: showHeaderAvatar,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The brand/「消息」header shared by the phone list and the split list pane.
  Widget _chatHeader(BuildContext context, {required bool showHeaderAvatar}) {
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
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
                avatarEntry: showHeaderAvatar ? _headerAvatar() : null,
                trailing: PopupMenuButton<String>(
                  key: HomeView.groupMenuKey,
                  tooltip: '添加',
                  icon: const Icon(Icons.add_rounded),
                  onSelected: (value) => value == 'create'
                      ? unawaited(_handleCreateGroup())
                      : unawaited(_handleFindGroup()),
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    PopupMenuItem(
                      value: 'create',
                      enabled:
                          widget.onCreateGroup != null ||
                          (widget.groups != null && widget.chat != null),
                      child: const Text('创建群'),
                    ),
                    PopupMenuItem(
                      value: 'find',
                      enabled:
                          widget.onFindGroup != null || widget.groups != null,
                      child: const Text('申请加入群'),
                    ),
                  ],
                ),
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
              Text('当前服务器的注册用户都在这里，点一行开始聊天。', style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  Widget _singleChatScaffold(
    BuildContext context, {
    required bool showHeaderAvatar,
  }) {
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
                    _chatHeader(context, showHeaderAvatar: showHeaderAvatar),
                    Expanded(
                      child: UsersListView(
                        chat: widget.chat!,
                        profile: widget.profile,
                        shared: widget.shared,
                        groups: widget.groups,
                        refreshTrigger: _groupsRefresh,
                        presence: _presence,
                        onlineFilter: _onlineFilter,
                        selectedAccount: _selectedAccount,
                        selectedConversationId: _selectedConversationId,
                        onOpenChat: _openChat,
                        onOpenGroup: _openGroup,
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

  /// Signed-in shell. Chat keeps its existing surface;
  /// Space is a sibling tab, so switching never rebuilds either state tree.
  ///
  /// The rail is painted beneath the page stack and the stack sits at the
  /// rail's right edge. A full-screen chat has to reach physical screen x = 0,
  /// so the fold transition slides the rail out from under the pages instead
  /// of leaving 92 px reserved; both share one controller so they never drift.
  Widget _appScaffold(BuildContext context, SpaceGateway? space) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 720;
        final bool foldCapable =
            !compact &&
            ChatWorkspace.splitFeatureOf(context) != null &&
            // Device width, not the pane width: the 92 px rail must not push
            // an 800 px unfolded screen below the 720 px split breakpoint.
            constraints.maxWidth >= ChatWorkspace.foldedSplitMinWidth;
        return AnimatedBuilder(
          animation: _foldController,
          builder: (BuildContext context, Widget? child) {
            if (!foldCapable && _foldController.value != 0) {
              // The divider went away (resize/rotation): never leave the rail
              // hidden by a transition that can no longer be reversed.
              _scheduleFoldReset();
            }
            final double cover = compact || _section != 0 || !foldCapable
                ? 0.0
                : _foldController.value.clamp(0.0, 1.0);
            final double rail = compact
                ? 0.0
                : HomeView.railWidth * (1 - cover);
            final MediaQueryData media = MediaQuery.of(context);
            final Widget pages = MediaQuery(
              // The panes, the Space hinge maths and the chat split all work in
              // the frame to the right of the rail; translate the physical
              // display feature instead of letting the split drift by 92 px.
              data: media.copyWith(
                size: Size(
                  math.max(media.size.width - rail, 0),
                  media.size.height,
                ),
                displayFeatures: translateDisplayFeatures(
                  media.displayFeatures,
                  Offset(-rail, 0),
                ),
              ),
              child: Builder(
                builder: (BuildContext context) => IndexedStack(
                  index: _section,
                  children: <Widget>[
                    // Wide layouts have the rail, which already carries the
                    // profile entry; only narrow layouts put the avatar in the
                    // message header.
                    _chatScaffold(
                      context,
                      showHeaderAvatar: compact,
                      visible: _section == 0,
                      displayWidth: constraints.maxWidth,
                    ),
                    space == null
                        ? const Scaffold(
                            body: SafeArea(
                              child: Center(child: Text('BB空间暂不可用')),
                            ),
                          )
                        : _spacePage(context, space, active: _section == 1),
                    widget.notificationBuilder?.call(context, _section == 2) ??
                        (widget.groups != null
                            ? NotificationCenterHost(
                                groups: widget.groups!,
                                chat: widget.chat,
                                profile: widget.profile,
                                active: _section == 2,
                                refreshTrigger: _noticesRefresh,
                                onOpenDirectChat: _openChat,
                                onGroupsChanged: _bumpGroupsRefresh,
                                onSessionExpired: widget.onSessionExpired,
                              )
                            : const NotificationCenter(available: false)),
                  ],
                ),
              ),
            );
            return Scaffold(
              backgroundColor: AppColors.paper,
              body: Stack(
                children: <Widget>[
                  // The slot stays at index 0 even when the phone layout has
                  // no rail: dropping it would shift the page stack's
                  // position in the children list and rebuild the Space state
                  // tree on a resize.
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: compact ? 0 : HomeView.railWidth,
                    child: compact ? const SizedBox.shrink() : _rail(context),
                  ),
                  Positioned(
                    left: rail,
                    top: 0,
                    right: 0,
                    bottom: 0,
                    child: pages,
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    child: compact || cover >= 0.5
                        ? const SizedBox.shrink()
                        : IgnorePointer(
                            child: Opacity(
                              opacity: (1 - cover * 2).clamp(0.0, 1.0),
                              child: CompositedTransformFollower(
                                link: _railNavLink,
                                showWhenUnlinked: false,
                                offset: const Offset(
                                  HomeView.railWidth - 12,
                                  0,
                                ),
                                child: HomeRailSpineMark(
                                  itemCount: _navItems.length,
                                  selectedIndex: _section,
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
              bottomNavigationBar: compact
                  ? HomeBottomNavBar(
                      key: HomeView.bottomNavKey,
                      items: _navItems,
                      selectedIndex: _section,
                      onSelected: (int index) =>
                          setState(() => _section = index),
                    )
                  : null,
            );
          },
        );
      },
    );
  }

  void _scheduleFoldReset() {
    if (_foldResetScheduled) {
      return;
    }
    _foldResetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _foldResetScheduled = false;
      if (mounted && _foldController.value != 0) {
        _foldController.value = 0;
      }
    });
  }

  Widget _spacePage(
    BuildContext context,
    SpaceGateway space, {
    required bool active,
  }) {
    return SafeArea(
      child: SpacePage(
        key: ValueKey<String>('space-${space.scopeKey}'),
        gateway: space,
        store: _spaceStore ??= SpaceLocalStore.shared(scopeKey: space.scopeKey),
        followStore: _followStore!,
        active: active,
        profile: widget.profile,
        onSessionExpired: widget.onSessionExpired,
      ),
    );
  }

  Widget _rail(BuildContext context) {
    return HomeDesktopNavRail(
      width: HomeView.railWidth,
      items: _navItems,
      selectedIndex: _section,
      onSelected: (int index) => setState(() => _section = index),
      navLink: _railNavLink,
      footer: KeyedSubtree(
        key: widget.space == null ? HomeView.avatarEntryKey : null,
        child: ProfileAvatar(
          key: HomeView.railAvatarKey,
          bytes: _avatar,
          size: 48,
          loading: _loading && _avatar == null,
          onTap: _openProfile,
          semanticLabel: '打开个人资料',
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
  const _BrandRow({required this.account, this.avatarEntry, this.trailing});

  final String account;

  /// When present, the signed-in avatar replaces the BB badge on the same row
  /// as the account, above the "消息" title.
  final Widget? avatarEntry;
  final Widget? trailing;

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
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            account,
            textAlign: TextAlign.right,
            style: text.bodySmall?.copyWith(letterSpacing: 1),
          ),
        ),
        ?trailing,
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
