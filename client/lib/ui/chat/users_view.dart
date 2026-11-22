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
  /// Returning from a conversation is the direct signal that its view facts
  /// changed. The mounted list also refreshes when its own lightweight
  /// directory poll sees a conversation's last message change, so a message
  /// arriving while the reader is already back on the list appears without any
  /// user action. Both refreshes cover the already loaded pages instead of
  /// collapsing the list back to page one.
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

  /// Last-seen directory preview per account (presence = account was seen,
  /// value = its last message id or null).
  ///
  /// The 30s poll already fetches this page, so a preview that differs from
  /// the last successfully counted snapshot is the lightweight "recount
  /// needed" signal. It only triggers the shared unread derivation, never a
  /// locally guessed count and never a full-history scan on every tick.
  final Map<String, String?> _knownPreviews = <String, String?>{};

  /// Previews covered by the last successful unread derivation, captured when
  /// that derivation started. A row/preview that is not in here may postdate
  /// the counts on screen — including the first row after an empty directory —
  /// so it triggers a recount.
  Map<String, String?> _coveredPreviews = <String, String?>{};

  /// Counts may be stale and the next list trigger must recompute them.
  ///
  /// A failed derivation keeps this set, so the next poll retries instead of
  /// waiting for another preview change; a successful one clears it.
  bool _unreadDirty = false;
  bool _unreadRefreshInFlight = false;

  /// A trigger arrived while a derivation was running: run once more when it
  /// finishes so the counts cover that newer change.
  bool _unreadRetryNow = false;

  @override
  void initState() {
    super.initState();
    widget.presence?.addListener(_onPresenceChanged);
    // The first directory response is the first preview snapshot; _load starts
    // the shared derivation when it differs from the (empty) covered set.
    unawaited(_load(reset: true));
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
  /// Runs are coalesced: a trigger arriving while one is in flight schedules a
  /// single follow-up. On success the previews seen at the start become the
  /// covered snapshot, so a message arriving mid-flight is still detected by
  /// the next directory load, while unchanged previews never trigger a repeat
  /// scan. A failed attempt keeps the last confirmed badges and stays dirty so
  /// the next poll retries instead of waiting for another preview change.
  Future<void> _refreshUnread() async {
    if (_unreadRefreshInFlight) {
      _unreadRetryNow = true;
      return;
    }
    _unreadRefreshInFlight = true;
    _unreadDirty = false;
    final Map<String, String?> covered = Map<String, String?>.of(
      _knownPreviews,
    );
    try {
      final Map<String, int> unread = await widget.chat.incomingUnreadByPeer();
      if (!mounted) {
        return;
      }
      setState(() {
        _unread = unread;
        _coveredPreviews = covered;
      });
      _unreadRetryNow = _unreadRetryNow || _previewsDifferFromCovered();
    } catch (_) {
      // Keep the last confirmed badges; the next list trigger retries.
      _unreadDirty = true;
      _unreadRetryNow = false;
      return;
    } finally {
      _unreadRefreshInFlight = false;
      if (_unreadRetryNow && mounted) {
        _unreadRetryNow = false;
        unawaited(_refreshUnread());
      }
    }
  }

  /// Whether the directory shows a preview the counts on screen do not cover.
  bool _previewsDifferFromCovered() {
    if (_knownPreviews.length != _coveredPreviews.length) {
      return true;
    }
    for (final MapEntry<String, String?> entry in _knownPreviews.entries) {
      if (!_coveredPreviews.containsKey(entry.key) ||
          _coveredPreviews[entry.key] != entry.value) {
        return true;
      }
    }
    return false;
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
      // A reset refresh reloads the range already on screen, not just the
      // first page: returning from a conversation or the periodic poll must
      // not drop rows the reader loaded with "加载更多", and those rows need
      // the same preview/change detection as the first page.
      final int target = reset ? _users.length : 0;
      final List<ChatUser> fetched = <ChatUser>[];
      String after = reset ? '' : (_nextCursor ?? '');
      String? next;
      while (true) {
        final UserPage page = await widget.chat.listUsers(afterAccount: after);
        fetched.addAll(page.items);
        next = page.nextCursor;
        if (!reset || next == null || fetched.length >= target) {
          break;
        }
        if (next.compareTo(after) <= 0) {
          break;
        }
        after = next;
      }
      final Map<String, String?> previews = Map<String, String?>.of(
        _knownPreviews,
      );
      for (final ChatUser user in fetched) {
        previews[user.account] = user.lastMessage?.id;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _users
            ..clear()
            ..addAll(fetched);
        } else {
          final Set<String> seen = _users
              .map((ChatUser user) => user.account)
              .toSet();
          for (final ChatUser user in fetched) {
            if (seen.add(user.account)) {
              _users.add(user);
            }
          }
        }
        _knownPreviews
          ..clear()
          ..addAll(previews);
        _nextCursor = next;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
      // A preview that the last successful derivation did not cover (a new
      // row, the first row after an empty directory, or a moved last message)
      // may postdate the counts on screen; a dirty flag left by a failed
      // attempt is retried here too. Unchanged previews never trigger a scan.
      if (_previewsDifferFromCovered()) {
        _unreadDirty = true;
      }
      if (_unreadDirty) {
        unawaited(_refreshUnread());
      }
      // One fresh server response is authoritative for the accounts it
      // contains; share it so an open conversation cannot keep a stale header.
      // The ticket makes a request that started before a newer targeted read
      // lose.
      presence?.seed(fetched, observation: observation);
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
