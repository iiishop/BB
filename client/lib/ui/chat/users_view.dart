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
import 'conversation_order.dart';

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
  });

  final ChatService chat;
  final ProfileGateway profile;

  /// Last-confirmed presence shared with the open conversation; when absent
  /// the page falls back to the presence each list page carried.
  final PresenceDirectory? presence;

  /// Opens the conversation. The returned future completes when the chat page
  /// pops, so the list can re-read the server's new last-message time instead
  /// of showing the old order until the next 30s tick.
  final Future<void> Function(ChatUser user) onOpenChat;
  final VoidCallback? onSessionExpired;

  static const Key listKey = Key('users-list');
  static const Key emptyKey = Key('users-empty');
  static const Key errorKey = Key('users-error');
  static const Key refreshKey = Key('users-refresh');
  static const Key onlineOnlyKey = Key('users-online-only');
  static const Key onlineEmptyKey = Key('users-online-empty');
  static Key rowKey(String account) => Key('user-row-$account');
  static Key unreadKey(String account) => Key('user-unread-$account');

  @override
  State<UsersListView> createState() => _UsersListViewState();
}

class _UsersListViewState extends State<UsersListView> {
  final List<ChatUser> _users = <ChatUser>[];

  /// Server-derived incoming unread per conversation, absent when zero.
  Map<String, int> _unread = <String, int>{};
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;
  bool _inFlight = false;

  /// Set when a refresh is requested while a directory read is still running
  /// (for example, returning from a chat whose send committed meanwhile).
  /// The in-flight snapshot may predate that send, so it is discarded and the
  /// directory is read again before anything is applied.
  bool _reloadQueued = false;

  /// Last-seen directory preview per account (presence = account was seen,
  /// value = its last message id or null).
  ///
  /// The 30s poll already fetches this page, so a preview that differs from
  /// the last successfully counted snapshot is the lightweight "recount
  /// needed" signal. It only triggers the shared unread derivation, never a
  /// locally guessed count and never a full-history scan on every tick.
  Map<String, String?> _knownPreviews = <String, String?>{};

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

  /// "Only show online" is a view filter: it never rewrites [_users] or clears
  /// the server-derived unread counts, so turning it off restores the complete
  /// list in the same sorted order.
  bool _onlineOnly = false;

  /// The same last-confirmed presence the row badge renders, so a row cannot
  /// say 在线 while the filter hides it (or the other way round).
  Presence _presenceOf(ChatUser user) =>
      widget.presence?.valueFor(user.account) ?? user.presence;

  @override
  void initState() {
    super.initState();
    widget.presence?.addListener(_onPresenceChanged);
    unawaited(_load());
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_inFlight) {
        unawaited(_load(silent: true));
      }
    });
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
    final Map<String, String?> covered = _knownPreviews;
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

  /// Walks the whole account-keyset directory.
  ///
  /// `GET /users` paginates by account, so one page cannot be globally ordered
  /// by message time: a later account may hold the newest conversation. The
  /// list therefore reads every page before ordering, exactly as the live
  /// chat test does, and refuses a cursor that does not advance instead of
  /// looping forever.
  Future<List<ChatUser>> _loadDirectory() async {
    final List<ChatUser> users = <ChatUser>[];
    final Set<String> seen = <String>{};
    String after = '';
    while (true) {
      final UserPage page = await widget.chat.listUsers(
        afterAccount: after,
        limit: 100,
      );
      for (final ChatUser user in page.items) {
        if (seen.add(user.account)) {
          users.add(user);
        }
      }
      final String? next = page.nextCursor;
      if (next == null) {
        return users;
      }
      if (next.compareTo(after) <= 0) {
        throw const FormatException('user cursor did not advance');
      }
      after = next;
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (_inFlight) {
      // A caller that needs the current directory (notably the refresh after
      // returning from a conversation) must not be dropped just because a
      // periodic read started earlier. Queue one more read; the in-flight
      // snapshot is discarded when it arrives.
      _reloadQueued = true;
      return;
    }
    _inFlight = true;
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final PresenceDirectory? presence = widget.presence;
    try {
      while (true) {
        _reloadQueued = false;
        // Reserve the presence ordering ticket for this read: a snapshot that
        // started earlier must not overwrite a targeted read that started
        // later and already confirmed a value.
        final int? observation = presence?.beginObservation();
        final List<ChatUser> users = sortChatUsersByLastMessage(
          await _loadDirectory(),
        );
        if (!mounted) {
          return;
        }
        if (_reloadQueued) {
          // A newer read was requested while this one was in flight; its
          // snapshot may be older than the send that triggered the request.
          continue;
        }
        setState(() {
          _users
            ..clear()
            ..addAll(users);
          _loading = false;
          _error = null;
        });
        // A fresh directory read is authoritative for the accounts it
        // contains; share it so an open conversation cannot keep a stale
        // header. The ticket makes an older read lose.
        presence?.seed(users, observation: observation);
        _knownPreviews = {
          for (final user in users) user.account: user.lastMessage?.id,
        };
        if (_unreadDirty || _previewsDifferFromCovered()) {
          unawaited(_refreshUnread());
        }
        break;
      }
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      if (failure.status == 401) {
        _reloadQueued = false;
        setState(() {
          _loading = false;
        });
        widget.onSessionExpired?.call();
        return;
      }
      setState(() {
        _loading = false;
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
        if (_users.isEmpty) {
          _error = '用户列表加载失败，请检查网络后重试';
        }
      });
    } finally {
      _inFlight = false;
      if (_reloadQueued) {
        // A request arrived after the loop's last check and could not be
        // joined, so start a fresh read instead of leaving its caller stale.
        _reloadQueued = false;
        if (mounted) {
          unawaited(_load(silent: true));
        }
      }
    }
  }

  // Explicit refreshes must recount even if viewing changed no preview id.
  Future<void> _refresh({bool silent = false}) async {
    await Future.wait([_load(silent: silent), _refreshUnread()]);
  }

  Future<void> _open(ChatUser user) async {
    await widget.onOpenChat(user);
    if (mounted) {
      await _refresh(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The switch is a phone-only control. Wide layouts (including the shell
    // with its rail) always show the complete directory, even if the phone
    // switch was left on before the viewport grew.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool phone = constraints.maxWidth < 720;
        final bool filtering = phone && _onlineOnly;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // The switch stays outside the list body so it is still operable
            // while the filtered result is empty (or loading/erroring).
            if (phone) _filterBar(context),
            Expanded(
              child: _content(
                context,
                filtering
                    ? _users
                          .where(
                            (ChatUser user) =>
                                _presenceOf(user) == Presence.online,
                          )
                          .toList(growable: false)
                    : _users,
                filtering: filtering,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _filterBar(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    // Match the list's centered 760 max width so the label does not sit at the
    // window edge while the rows are centered on wide layouts.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            0,
          ),
          child: Row(
            children: <Widget>[
              Text(
                '只看在线',
                style: text.labelLarge?.copyWith(
                  color: AppColors.inkMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Semantics(
                label: '只看在线',
                child: Switch(
                  key: UsersListView.onlineOnlyKey,
                  value: _onlineOnly,
                  onChanged: (bool value) =>
                      setState(() => _onlineOnly = value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    List<ChatUser> visible, {
    required bool filtering,
  }) {
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
                onPressed: _refresh,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    // Filter precedence: with the phone switch on, an empty result is the
    // online-empty state even when the directory itself has no other users.
    if (filtering && visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.people_outline_rounded,
                size: 36,
                color: AppColors.inkMuted,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '暂无在线联系人',
                key: UsersListView.onlineEmptyKey,
                style: const TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(onPressed: _refresh, child: const Text('刷新')),
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
              TextButton(onPressed: _refresh, child: const Text('刷新')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
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
            itemCount: visible.length + 1,
            itemBuilder: (BuildContext context, int index) {
              if (index == visible.length) {
                return _footer(filtering);
              }
              final ChatUser user = visible[index];
              return _UserRow(
                key: UsersListView.rowKey(user.account),
                user: user,
                presence: _presenceOf(user),
                unread: _unread[user.account] ?? 0,
                profile: widget.profile,
                selfAccount: widget.chat.selfAccount,
                onTap: () => _open(user),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _footer(bool filtering) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Text(
          filtering ? '以上是当前在线的联系人' : '以上是当前服务器的全部注册用户',
          style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
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
