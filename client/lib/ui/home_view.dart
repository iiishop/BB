import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app.dart';
import '../models/auth_models.dart';
import '../models/profile_models.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/heartbeat_controller.dart';
import '../services/profile_service.dart';
import '../models/chat_models.dart';
import 'chat/chat_page.dart';
import 'chat/users_view.dart';
import 'profile/profile_panel.dart';
import 'widgets/profile_avatar.dart';

/// Signed-in home surface for STEP-2.
///
/// Profile is the only live module in this step. The avatar entry is pinned to
/// the bottom-left on every form factor and is the single way into Profile; the
/// heartbeat banner appears after three missed beats without logging the user
/// out.
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
  });

  final AuthUser user;
  final ProfileGateway profile;
  final AuthGateway auth;
  final HeartbeatController heartbeat;

  /// STEP-3 chat service. When present the signed-in home is the registered
  /// user list; when null the STEP-2 profile-only home is kept.
  final ChatService? chat;
  final void Function(LogoutResult? result) onSignedOut;
  final void Function() onSessionExpired;

  static const Key avatarEntryKey = Key('home-avatar-entry');
  static const Key reconnectingBannerKey = Key('home-reconnecting-banner');
  static const Key greetingKey = Key('home-greeting');
  static const Key signatureKey = Key('home-signature');
  static const Key errorKey = Key('home-profile-error');

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  Profile? _profile;
  Uint8List? _avatar;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.heartbeat.addListener(_onHeartbeatChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.heartbeat.removeListener(_onHeartbeatChanged);
    super.dispose();
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
      final AvatarImage image = await widget.profile.loadAvatar();
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
    // A barrier dismissal also returns null; reload anyway so edits made just
    // before closing can never leave the home surface stale.
    await _load();
  }

  void _openChat(ChatUser user) {
    final ChatService? chat = widget.chat;
    if (chat == null) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ChatPage(peer: user, chat: chat),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool reconnecting =
        widget.heartbeat.phase == HeartbeatPhase.reconnecting;
    final String nickname = _profile?.username ?? widget.user.username;

    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Column(
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
                                  _BrandRow(account: widget.user.account),
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
                              _BrandRow(account: widget.user.account),
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
                                    : '还没有签名。点左下角头像，写下第一句自我介绍。',
                                key: HomeView.signatureKey,
                                style: text.bodyLarge?.copyWith(
                                  color:
                                      (_profile?.signature?.isNotEmpty ?? false)
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
            Positioned(
              left: AppSpacing.lg,
              bottom: AppSpacing.lg,
              child: ProfileAvatar(
                key: HomeView.avatarEntryKey,
                bytes: _avatar,
                size: 60,
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
  const _BrandRow({required this.account});

  final String account;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
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
