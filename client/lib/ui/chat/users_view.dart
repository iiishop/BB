import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../models/profile_models.dart';
import '../../services/chat_service.dart';
import '../../services/presence_directory.dart';
import '../../services/profile_service.dart';
import 'chat_format.dart';

/// Default signed-in home: every registered user on the connected server,
/// including people this account has never chatted with.
class UsersListView extends StatefulWidget {
  const UsersListView({
    super.key,
    required this.chat,
    required this.profile,
    required this.onOpenChat,
    this.presence,
    this.onSessionExpired,
    this.refreshToken = 0,
  });

  final ChatService chat;
  final ProfileGateway profile;

  /// Last-confirmed presence shared with the open conversation; when absent
  /// the page falls back to the presence each list page carried.
  final PresenceDirectory? presence;
  final void Function(ChatUser user) onOpenChat;
  final VoidCallback? onSessionExpired;

  /// Bumped by the parent after a conversation closes so the badges reload.
  ///
  /// Incoming unread belongs to the account and can only change while a
  /// conversation is open, so a return-triggered refresh is the cheap signal;
  /// the periodic list poll keeps its presence-only cost.
  final int refreshToken;

  static const Key listKey = Key('users-list');
  static const Key emptyKey = Key('users-empty');
  static const Key errorKey = Key('users-error');
  static const Key loadMoreKey = Key('users-load-more');
  static const Key refreshKey = Key('users-refresh');
  static Key rowKey(String account) => Key('user-row-$account');
  static Key unreadKey(String account) => Key('user-unread-$account');

  @override
  State<UsersListView> createState() => _UsersListViewState();
}

class _UsersListViewState extends State<UsersListView> {
  final List<ChatUser> _users = <ChatUser>[];

  /// Server-derived incoming unread per conversation, absent when zero.
  Map<String, int> _unread = <String, int>{};
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  Timer? _refreshTimer;
  bool _inFlight = false;

  /// Orders concurrent badge reads so a slow one cannot overwrite a newer
  /// result with stale facts.
  int _unreadGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.presence?.addListener(_onPresenceChanged);
    unawaited(_load(reset: true));
    unawaited(_refreshUnread());
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_inFlight) {
        unawaited(_load(reset: true, silent: true));
      }
    });
  }

  @override
  void didUpdateWidget(covariant UsersListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      // The conversation just closed; its view facts are already durable, so
      // recompute the badges instead of guessing locally. The directory stays
      // rendered while both reads run.
      unawaited(_load(reset: true, silent: true));
      unawaited(_refreshUnread());
    }
  }

  @override
  void dispose() {
    widget.presence?.removeListener(_onPresenceChanged);
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _onPresenceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Recomputes the badges from the shared account-level unread derivation.
  ///
  /// Kept separate from the directory request: rows render immediately and
  /// badges fill in, and the 30s presence poll never pays for a full-history
  /// scan. A failed badge read keeps the last confirmed badges instead of
  /// turning the whole list into an error.
  Future<void> _refreshUnread() async {
    final int generation = ++_unreadGeneration;
    Map<String, int> unread;
    try {
      unread = await widget.chat.incomingUnreadByPeer();
    } catch (_) {
      return;
    }
    if (!mounted || generation != _unreadGeneration) {
      return;
    }
    setState(() => _unread = unread);
  }

  Future<void> _load({required bool reset, bool silent = false}) async {
    if (_inFlight) {
      return;
    }
    _inFlight = true;
    if (!silent && mounted) {
      setState(() {
        if (reset) {
          _loading = true;
          _error = null;
        }
      });
    }
    // Reserve the presence ordering ticket before the request starts: a page
    // that started earlier must not overwrite a targeted read that started
    // later and already confirmed a value.
    final PresenceDirectory? presence = widget.presence;
    final int? observation = presence?.beginObservation();
    try {
      final UserPage page = await widget.chat.listUsers(
        afterAccount: reset ? '' : (_nextCursor ?? ''),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _users
            ..clear()
            ..addAll(page.items);
        } else {
          final Set<String> seen = _users
              .map((ChatUser user) => user.account)
              .toSet();
          for (final ChatUser user in page.items) {
            if (seen.add(user.account)) {
              _users.add(user);
            }
          }
        }
        _nextCursor = page.nextCursor;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
      // One fresh server page is authoritative for the accounts it contains;
      // share it so an open conversation cannot keep a stale header. The
      // ticket makes a page that started before a newer targeted read lose.
      presence?.seed(page.items, observation: observation);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      if (failure.status == 401) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
        widget.onSessionExpired?.call();
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (_users.isEmpty) {
          _error = failure.message;
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (_users.isEmpty) {
          _error = '用户列表加载失败，请检查网络后重试';
        }
      });
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _loadMore() async {
    if (_nextCursor == null || _loadingMore) {
      return;
    }
    setState(() => _loadingMore = true);
    await _load(reset: false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _users.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _users.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.cloud_off_rounded,
                size: 36,
                color: AppColors.inkMuted,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                key: UsersListView.errorKey,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton(
                key: UsersListView.refreshKey,
                onPressed: () {
                  unawaited(_load(reset: true));
                  unawaited(_refreshUnread());
                },
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    if (_users.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.group_outlined,
                size: 36,
                color: AppColors.inkMuted,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '服务器上还没有其他注册用户',
                key: UsersListView.emptyKey,
                style: const TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () {
                  unawaited(_load(reset: true));
                  unawaited(_refreshUnread());
                },
                child: const Text('刷新'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () =>
          Future.wait(<Future<void>>[_load(reset: true), _refreshUnread()]),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView.builder(
            key: UsersListView.listKey,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.xs,
              AppSpacing.lg,
              120,
            ),
            itemCount: _users.length + 1,
            itemBuilder: (BuildContext context, int index) {
              if (index == _users.length) {
                return _footer();
              }
              final ChatUser user = _users[index];
              return _UserRow(
                key: UsersListView.rowKey(user.account),
                user: user,
                presence:
                    widget.presence?.valueFor(user.account) ?? user.presence,
                unread: _unread[user.account] ?? 0,
                profile: widget.profile,
                selfAccount: widget.chat.selfAccount,
                onTap: () => widget.onOpenChat(user),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    if (_nextCursor != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: _loadingMore
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  key: UsersListView.loadMoreKey,
                  onPressed: _loadMore,
                  child: const Text('加载更多用户'),
                ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Text(
          '以上是当前服务器的全部注册用户',
          style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
        ),
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    super.key,
    required this.user,
    required this.presence,
    required this.unread,
    required this.profile,
    required this.selfAccount,
    required this.onTap,
  });

  final ChatUser user;
  final Presence presence;

  /// Server-derived incoming unread for this conversation; zero means no badge.
  final int unread;
  final ProfileGateway profile;
  final String selfAccount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final UserPreview? preview = user.lastMessage;
    final String senderName = preview == null
        ? ''
        : (preview.senderAccount == selfAccount ? '我' : preview.senderUsername);
    final String previewText = preview == null
        ? '暂无消息'
        : '$senderName：${preview.previewBody}';
    final String? unreadLabel = unreadBadgeLabel(unread);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.sm + 2,
        ),
        child: Row(
          children: <Widget>[
            Badge(
              isLabelVisible: unreadLabel != null,
              backgroundColor: AppColors.danger,
              label: Semantics(
                label: '$unread 条未读',
                excludeSemantics: true,
                child: Text(
                  unreadLabel ?? '',
                  key: UsersListView.unreadKey(user.account),
                ),
              ),
              child: _UserAvatar(user: user, profile: profile),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          user.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium,
                        ),
                      ),
                      if (user.account == selfAccount) ...<Widget>[
                        const SizedBox(width: AppSpacing.xs),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.accentSoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '本人',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.accentDeep,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    previewText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: preview == null
                          ? AppColors.inkMuted
                          : AppColors.ink,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  formatContactTime(user.lastContactAt),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: user.lastContactAt == null
                        ? AppColors.inkMuted
                        : AppColors.inkMuted,
                  ),
                ),
                const SizedBox(height: 6),
                _PresenceBadge(presence: presence),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PresenceBadge extends StatelessWidget {
  const _PresenceBadge({required this.presence});

  final Presence presence;

  @override
  Widget build(BuildContext context) {
    final bool online = presence == Presence.online;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: online ? AppColors.success : AppColors.inkMuted,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          online ? '在线' : '离线',
          style: TextStyle(
            fontSize: 10.5,
            color: online ? AppColors.success : AppColors.inkMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _UserAvatar extends StatefulWidget {
  const _UserAvatar({required this.user, required this.profile});

  final ChatUser user;
  final ProfileGateway profile;

  @override
  State<_UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<_UserAvatar> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.account != widget.user.account ||
        oldWidget.user.avatarVersion != widget.user.avatarVersion) {
      _future = _load();
    }
  }

  Future<Uint8List> _load() async {
    final AvatarImage image = await widget.profile.loadAvatar(
      account: widget.user.account,
      thumb: true,
    );
    return image.bytes;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<Uint8List>(
            future: _future,
            builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
              if (snapshot.hasData) {
                return Image.memory(
                  snapshot.data!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (
                    BuildContext context,
                    Object error,
                    StackTrace? stackTrace,
                  ) => _initials(),
                );
              }
              return _initials();
            },
          ),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(
              color: widget.user.presence == Presence.online
                  ? AppColors.success
                  : AppColors.inkMuted,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _initials() {
    return Center(
      child: Text(
        initialsOf(widget.user.username),
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.accentDeep,
        ),
      ),
    );
  }
}
