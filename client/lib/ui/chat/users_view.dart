import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../models/group_models.dart';
import '../../services/chat_service.dart';
import '../../services/group_service.dart';
import '../../services/presence_directory.dart';
import '../../services/profile_service.dart';
import '../widgets/profile_avatar.dart';
import 'chat_format.dart';
import 'conversation_order.dart';
import 'user_identity_row.dart';

/// Width of the little speech tail that points from the current conversation's
/// note back towards its avatar. It is always reserved so names start on the
/// same vertical line whether the row is the current conversation or not.
const double _noteTailWidth = 12;

/// Default signed-in home: every registered user on the connected server,
/// including people this account has never chatted with.
///
/// The same widget is the whole phone list page and the left column of the
/// wide/folded two-pane shell. It must not grow a platform-specific variant:
/// the pane width only changes gutters and density, never the row content.
class UsersListView extends StatefulWidget {
  const UsersListView({
    super.key,
    required this.chat,
    required this.profile,
    required this.onOpenChat,
    this.shared,
    this.groups,
    this.selectedConversationId,
    this.onOpenGroup,
    this.onSelectGroup,
    this.onGroupsLoaded,
    this.refreshTrigger,
    this.presence,
    this.onSessionExpired,
    this.selectedAccount,
    this.onSelect,
    this.onDirectoryLoaded,
    this.onlineFilter,
  });

  final ChatService chat;
  final ProfileGateway profile;
  final SharedConversationService? shared;
  final GroupService? groups;
  final String? selectedConversationId;
  final Future<void> Function(GroupConversationItem group)? onOpenGroup;
  final void Function(GroupConversationItem group)? onSelectGroup;
  final void Function(List<GroupConversationItem> groups)? onGroupsLoaded;
  final Listenable? refreshTrigger;

  /// Last-confirmed presence shared with the open conversation; when absent
  /// the page falls back to the presence each list page carried.
  final PresenceDirectory? presence;

  /// Opens the conversation. The returned future completes when the chat page
  /// pops, so the list can re-read the server's new last-message time instead
  /// of showing the old order until the next 30s tick.
  final Future<void> Function(ChatUser user) onOpenChat;
  final VoidCallback? onSessionExpired;

  /// Account of the conversation currently shown next to this list in the
  /// wide/folded two-pane shell. Selection is stored by account, never by row
  /// index, so a reorder or refresh keeps the note on the same contact.
  ///
  /// A standalone phone list passes null until a shell has a conversation to
  /// show beside it; the phone list sets its last-opened conversation through
  /// [HomeView] so the note never invents a conversation that is not there.
  final String? selectedAccount;

  /// Split-layout row action: switch the chat pane without pushing a route.
  /// Null keeps the phone behaviour (open the conversation page).
  final void Function(ChatUser user)? onSelect;

  /// Called after each successful directory read, before any highlight is
  /// applied by the parent. Used once by the split surface to pick a first
  /// conversation; it must not loop.
  final void Function(List<ChatUser> users)? onDirectoryLoaded;

  /// Optional shared "only online" state. The phone and split surfaces both
  /// read and write this one value, so resizing the window cannot silently
  /// reset the filter.
  final ValueNotifier<bool>? onlineFilter;

  static const Key listKey = Key('users-list');
  static const Key emptyKey = Key('users-empty');
  static const Key errorKey = Key('users-error');
  static const Key refreshKey = Key('users-refresh');
  static const Key onlineOnlyKey = Key('users-online-only');
  static const Key onlineEmptyKey = Key('users-online-empty');
  static Key rowKey(String account) => Key('user-row-$account');
  static Key groupRowKey(String conversationId) =>
      Key('group-row-$conversationId');
  static Key unreadKey(String account) => Key('user-unread-$account');
  static Key selectedKey(String account) => Key('user-selected-$account');

  /// The light-teal note around the current conversation. It exists only for
  /// the selected account, which makes tests and visual review unambiguous.
  static Key noteKey(String account) => Key('user-note-$account');

  /// The round avatar; it stays outside the note and its tail.
  static Key avatarKey(String account) => Key('user-avatar-$account');

  /// The online dot on the avatar. Absent while the peer is offline: presence
  /// is shown by the dot, the filter and the row semantics, not a text label.
  static Key presenceDotKey(String account) => Key('user-presence-$account');

  @override
  State<UsersListView> createState() => _UsersListViewState();
}

class _UsersListViewState extends State<UsersListView> {
  final List<ChatUser> _users = <ChatUser>[];
  final List<GroupConversationItem> _groups = <GroupConversationItem>[];

  /// Server-derived incoming unread per conversation, absent when zero.
  Map<String, int> _unread = <String, int>{};
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;
  StreamSubscription<void>? _displayedSub;
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
  bool _localOnlineOnly = false;

  bool get _onlineOnly => widget.onlineFilter?.value ?? _localOnlineOnly;

  /// The same last-confirmed presence the row badge renders, so a row cannot
  /// say 在线 while the filter hides it (or the other way round).
  Presence _presenceOf(ChatUser user) =>
      widget.presence?.valueFor(user.account) ?? user.presence;

  @override
  void initState() {
    super.initState();
    widget.presence?.addListener(_onPresenceChanged);
    widget.onlineFilter?.addListener(_onFilterChanged);
    widget.shared?.access.addListener(_onAccessOrRefreshTriggered);
    _displayedSub = widget.shared?.displayedChanges.listen((_) {
      _onDisplayedChanged();
    });
    widget.refreshTrigger?.addListener(_onAccessOrRefreshTriggered);
    unawaited(_load());
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_inFlight) {
        unawaited(_load(silent: true));
      }
    });
  }

  @override
  void didUpdateWidget(covariant UsersListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onlineFilter != widget.onlineFilter) {
      oldWidget.onlineFilter?.removeListener(_onFilterChanged);
      widget.onlineFilter?.addListener(_onFilterChanged);
    }
    if (oldWidget.shared?.access != widget.shared?.access) {
      oldWidget.shared?.access.removeListener(_onAccessOrRefreshTriggered);
      widget.shared?.access.addListener(_onAccessOrRefreshTriggered);
    }
    if (oldWidget.shared != widget.shared) {
      unawaited(_displayedSub?.cancel());
      _displayedSub = widget.shared?.displayedChanges.listen((_) {
        _onDisplayedChanged();
      });
    }
    if (oldWidget.refreshTrigger != widget.refreshTrigger) {
      oldWidget.refreshTrigger?.removeListener(_onAccessOrRefreshTriggered);
      widget.refreshTrigger?.addListener(_onAccessOrRefreshTriggered);
    }
  }

  @override
  void dispose() {
    widget.presence?.removeListener(_onPresenceChanged);
    widget.onlineFilter?.removeListener(_onFilterChanged);
    widget.shared?.access.removeListener(_onAccessOrRefreshTriggered);
    unawaited(_displayedSub?.cancel());
    _displayedSub = null;
    widget.refreshTrigger?.removeListener(_onAccessOrRefreshTriggered);
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _onDisplayedChanged() {
    if (!mounted) {
      return;
    }
    _unreadDirty = true;
    unawaited(_refreshUnread());
  }

  void _onAccessOrRefreshTriggered() {
    if (mounted) {
      unawaited(_load(silent: true));
    }
  }

  void _onPresenceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onFilterChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _setOnlineOnly(bool value) {
    final ValueNotifier<bool>? shared = widget.onlineFilter;
    if (shared != null) {
      shared.value = value;
    } else {
      setState(() => _localOnlineOnly = value);
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
      final Map<String, int> unread = Map<String, int>.from(
        await widget.chat.incomingUnreadByPeer(),
      );
      if (widget.shared != null && _groups.isNotEmpty) {
        unread.addAll(
          await widget.shared!.incomingUnreadByGroup(
            groups: List<GroupConversationItem>.of(_groups),
            ledger: widget.chat.ledger,
          ),
        );
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _unread = Map<String, int>.unmodifiable(unread);
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

  Future<List<GroupConversationItem>> _loadSharedGroups() async {
    final SharedConversationService? shared = widget.shared;
    if (shared == null) {
      return const <GroupConversationItem>[];
    }
    final List<GroupConversationItem> groups = <GroupConversationItem>[];
    final Set<String> seen = <String>{};
    String afterId = '';
    while (true) {
      final SharedConversationPage page = await shared.listSharedConversations(
        afterId: afterId,
        limit: 100,
      );
      for (final SharedConversation item in page.items) {
        if (item is GroupConversationItem &&
            seen.add(item.conversation.id) &&
            !shared.access.isRevoked(
              widget.chat.selfAccount,
              item.conversation.id,
            )) {
          groups.add(item);
        }
      }
      final String? next = page.nextCursor;
      if (next == null || next.compareTo(afterId) <= 0) {
        groups.sort(
          (GroupConversationItem a, GroupConversationItem b) =>
              b.lastActivityAt.compareTo(a.lastActivityAt),
        );
        return groups;
      }
      afterId = next;
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
        final Future<List<ChatUser>> directoryFuture = _loadDirectory();
        final Future<List<GroupConversationItem>> groupsFuture =
            widget.shared != null
            ? _loadSharedGroups()
            : Future<List<GroupConversationItem>>.value(
                const <GroupConversationItem>[],
              );
        final List<ChatUser> users = sortChatUsersByLastMessage(
          await directoryFuture,
        );
        final List<GroupConversationItem> groups = await groupsFuture;
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
          _groups
            ..clear()
            ..addAll(groups);
          _loading = false;
          _error = null;
        });
        widget.onDirectoryLoaded?.call(List<ChatUser>.unmodifiable(_users));
        widget.onGroupsLoaded?.call(
          List<GroupConversationItem>.unmodifiable(_groups),
        );
        // A fresh directory read is authoritative for the accounts it
        // contains; share it so an open conversation cannot keep a stale
        // header. The ticket makes an older read lose.
        presence?.seed(users, observation: observation);
        _knownPreviews = <String, String?>{
          for (final ChatUser user in users) user.account: user.lastMessage?.id,
          for (final GroupConversationItem group in groups)
            'group:${group.conversation.id}:${group.membershipRevision}':
                '${group.latestPosition}:${group.historyThrough}',
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
    // The same directory and selection drive every placement: the phone list
    // page, the wide shell's left column and an unfolded foldable's left pane.
    // Narrow panes only tighten gutters; the note and its tail stay identical.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 520;
        final double gutter = compact ? AppSpacing.md : AppSpacing.lg;
        final bool filtering = _onlineOnly;
        final List<ChatUser> visible = filtering
            ? _users
                  .where(
                    (ChatUser user) => _presenceOf(user) == Presence.online,
                  )
                  .toList(growable: false)
            : _users;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // The switch stays outside the list body so it is still operable
            // while the filtered result is empty (or loading/erroring).
            _filterBar(context, gutter),
            Expanded(
              child: _content(
                context,
                visible,
                filtering: filtering,
                gutter: gutter,
                compact: compact,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _filterBar(BuildContext context, double gutter) {
    final TextTheme text = Theme.of(context).textTheme;
    // Match the list's centered 760 max width so the label does not sit at the
    // window edge while the rows are centered on wide layouts.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, AppSpacing.xs, gutter, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '只看在线',
                  style: text.labelLarge?.copyWith(
                    color: AppColors.inkMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Semantics(
                label: '只看在线',
                child: Switch(
                  key: UsersListView.onlineOnlyKey,
                  value: _onlineOnly,
                  onChanged: _setOnlineOnly,
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
    required double gutter,
    required bool compact,
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
    if (_users.isEmpty && _groups.isEmpty) {
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
    final List<GroupConversationItem> visibleGroups = filtering
        ? const <GroupConversationItem>[]
        : _groups;
    final List<Object> rows = _mergedRows(visible, visibleGroups);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView.builder(
            key: UsersListView.listKey,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(gutter, AppSpacing.xs, gutter, 120),
            itemCount: rows.length + 1,
            itemBuilder: (BuildContext context, int index) {
              if (index == rows.length) {
                return _footer(filtering);
              }
              final Object entry = rows[index];
              if (entry is GroupConversationItem) {
                return _GroupRow(
                  key: UsersListView.groupRowKey(entry.conversation.id),
                  group: entry,
                  unread: _unread[entry.conversation.id] ?? 0,
                  groups: widget.groups,
                  selfAccount: widget.chat.selfAccount,
                  current:
                      entry.conversation.id == widget.selectedConversationId,
                  compact: compact,
                  onTap: widget.onSelectGroup != null
                      ? () => widget.onSelectGroup!(entry)
                      : () => _openGroup(entry),
                );
              }
              final ChatUser user = entry as ChatUser;
              return _UserRow(
                key: UsersListView.rowKey(user.account),
                user: user,
                presence: _presenceOf(user),
                unread: _unread[user.account] ?? 0,
                profile: widget.profile,
                selfAccount: widget.chat.selfAccount,
                current:
                    widget.selectedConversationId == null &&
                    user.account == widget.selectedAccount,
                compact: compact,
                onTap: widget.onSelect == null
                    ? () => _open(user)
                    : () => widget.onSelect!(user),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Object> _mergedRows(
    List<ChatUser> users,
    List<GroupConversationItem> groups,
  ) {
    if (groups.isEmpty) {
      return users;
    }
    final List<Object> combined = <Object>[...groups, ...users];
    DateTime activityOf(Object item) {
      if (item is GroupConversationItem) {
        return item.lastActivityAt;
      }
      final ChatUser u = item as ChatUser;
      return u.lastContactAt ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }

    combined.sort(
      (Object a, Object b) => activityOf(b).compareTo(activityOf(a)),
    );
    return combined;
  }

  Future<void> _openGroup(GroupConversationItem group) async {
    if (widget.onOpenGroup != null) {
      await widget.onOpenGroup!(group);
      if (mounted) {
        await _refresh(silent: true);
      }
    }
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
    required this.current,
    required this.compact,
    required this.onTap,
  });

  final ChatUser user;
  final Presence presence;

  /// Server-derived incoming unread for this conversation; zero means no badge.
  final int unread;
  final ProfileGateway profile;
  final String selfAccount;

  /// Whether this is the conversation shown on the right of the wide shell.
  final bool current;
  final bool compact;
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
    final bool online = presence == Presence.online;
    final String? unreadLabel = unreadBadgeLabel(unread);

    final double avatarSize = compact ? 46 : 50;
    final double avatarGap = compact ? AppSpacing.sm : AppSpacing.sm + 2;
    final double notePaddingVertical = compact
        ? AppSpacing.sm + 4
        : AppSpacing.md + 2;
    final EdgeInsets notePadding = EdgeInsets.fromLTRB(
      _noteTailWidth + (compact ? AppSpacing.md : AppSpacing.lg - 2),
      notePaddingVertical,
      compact ? AppSpacing.md : AppSpacing.lg - 2,
      notePaddingVertical,
    );

    // Only the current conversation sits in a note; every other row stays on
    // the warm paper with no fill. The tail is part of the note, never the
    // avatar, so the avatar remains outside the teal surface.
    final Widget noteContent = Padding(
      padding: notePadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        user.username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: compact ? 17 : 18,
                        ),
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
                          color: current
                              ? AppColors.surface
                              : AppColors.accentSoft,
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
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  formatContactTime(user.lastContactAt),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) => Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: unreadLabel == null ? 0 : AppSpacing.sm,
                    ),
                    child: Text(
                      previewText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontSize: 14,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ),
                ),
                if (unreadLabel != null) ...<Widget>[
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: _UnreadBadge(
                      count: unread,
                      label: unreadLabel,
                      account: user.account,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    // The note keeps its own key; the split shell's selectedKey lives on the
    // content so one row can answer both contracts.
    final Widget content = KeyedSubtree(
      key: current ? UsersListView.selectedKey(user.account) : null,
      child: noteContent,
    );
    final Widget note = current
        ? Ink(
            key: UsersListView.noteKey(user.account),
            decoration: const _ConversationNoteDecoration(
              color: AppColors.accentSoft,
              tailWidth: _noteTailWidth,
              radius: AppRadius.card,
            ),
            child: content,
          )
        : content;

    return Semantics(
      selected: current,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: compact ? 4 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                UserIdentityAvatar(
                  user: user,
                  profile: profile,
                  online: online,
                  size: avatarSize,
                  avatarKey: UsersListView.avatarKey(user.account),
                  presenceKey: UsersListView.presenceDotKey(user.account),
                ),
                SizedBox(width: avatarGap),
                Expanded(child: note),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A left-pointing rounded note with a short speech tail.
///
/// It paints the same shape for the wide shell's left column as for any other
/// placement. The tail lives entirely inside the widget's box, so it cannot
/// overlap the avatar that sits outside the note.
class _ConversationNoteDecoration extends Decoration {
  const _ConversationNoteDecoration({
    required this.color,
    required this.tailWidth,
    required this.radius,
  });

  final Color color;
  final double tailWidth;
  final double radius;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return _ConversationNotePainter(this);
  }

  @override
  bool operator ==(Object other) {
    return other is _ConversationNoteDecoration &&
        other.color == color &&
        other.tailWidth == tailWidth &&
        other.radius == radius;
  }

  @override
  int get hashCode => Object.hash(color, tailWidth, radius);
}

class _ConversationNotePainter extends BoxPainter {
  _ConversationNotePainter(this.decoration);

  final _ConversationNoteDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final Size? size = configuration.size;
    if (size == null || size.isEmpty) {
      return;
    }
    final double tail = math.min(decoration.tailWidth, size.width / 4);
    final double radius = math.min(
      decoration.radius,
      math.min(size.height, size.width - tail) / 2,
    );
    final double right = size.width;
    final double bottom = size.height;
    final Path path = Path()
      ..moveTo(tail + radius, 0)
      ..lineTo(right - radius, 0)
      ..arcToPoint(Offset(right, radius), radius: Radius.circular(radius))
      ..lineTo(right, bottom - radius)
      ..arcToPoint(
        Offset(right - radius, bottom),
        radius: Radius.circular(radius),
      )
      ..lineTo(tail + radius, bottom)
      ..arcToPoint(
        Offset(tail, bottom - radius),
        radius: Radius.circular(radius),
      )
      // The short arc points at the avatar, then returns to the left edge.
      ..lineTo(tail, bottom * 0.62)
      ..quadraticBezierTo(tail * 0.42, bottom * 0.565, 0, bottom * 0.46)
      ..quadraticBezierTo(tail * 0.42, bottom * 0.355, tail, bottom * 0.30)
      ..lineTo(tail, radius)
      ..arcToPoint(Offset(tail + radius, 0), radius: Radius.circular(radius))
      ..close();
    canvas.drawPath(path.shift(offset), Paint()..color = decoration.color);
  }
}

class _GroupRow extends StatefulWidget {
  const _GroupRow({
    super.key,
    required this.group,
    required this.unread,
    required this.selfAccount,
    required this.current,
    required this.compact,
    required this.onTap,
    this.groups,
  });

  final GroupConversationItem group;
  final int unread;
  final GroupService? groups;
  final String selfAccount;
  final bool current;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  Uint8List? _avatar;
  int _avatarTicket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAvatar());
  }

  @override
  void didUpdateWidget(covariant _GroupRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.avatarUrl != widget.group.avatarUrl ||
        oldWidget.group.avatarVersion != widget.group.avatarVersion ||
        oldWidget.group.groupNumber != widget.group.groupNumber) {
      unawaited(_loadAvatar());
    }
  }

  Future<void> _loadAvatar() async {
    final GroupService? groups = widget.groups;
    final int ticket = ++_avatarTicket;
    final String groupNumber = widget.group.groupNumber;
    final String avatarUrl = widget.group.avatarUrl;
    if (groups == null || avatarUrl.isEmpty) {
      if (mounted && _avatar != null && avatarUrl.isEmpty) {
        setState(() => _avatar = null);
      }
      return;
    }
    try {
      final GroupAvatarImage img = await groups.loadGroupAvatar(
        groupNumber: groupNumber,
        avatarUrl: avatarUrl,
        thumb: true,
      );
      if (mounted &&
          _avatarTicket == ticket &&
          widget.group.groupNumber == groupNumber &&
          widget.group.avatarUrl == avatarUrl) {
        setState(() => _avatar = Uint8List.fromList(img.bytes));
      }
    } catch (_) {
      // Fallback placeholder cleanly without spinning.
    }
  }

  String _previewLabel(ChatMessage? last) {
    if (last == null) {
      return '暂无消息';
    }
    if (last.isSystem) {
      return last.systemText ?? '系统提示';
    }
    final String sender = last.senderAccount == widget.selfAccount
        ? '我'
        : ((last.senderUsername?.isNotEmpty ?? false)
              ? last.senderUsername!
              : last.senderAccount);
    final String body;
    if (last.attachment != null) {
      body = switch (last.attachment!.kind) {
        AttachmentKind.video => '[视频]',
        AttachmentKind.audio => '[语音]',
        AttachmentKind.image => '[图片]',
        _ => '[文件] ${last.attachment!.filename}',
      };
    } else if (last.parts.isEmpty) {
      body = '';
    } else {
      body = last.parts
          .map((MessagePart p) => p is TextPart ? p.text : '[图片]')
          .join(' ');
    }
    return sender.isEmpty ? body : '$sender：$body';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String? unreadLabel = unreadBadgeLabel(widget.unread);
    final double avatarSize = widget.compact ? 46 : 50;
    final double avatarGap = widget.compact ? AppSpacing.sm : AppSpacing.sm + 2;
    final double notePaddingVertical = widget.compact
        ? AppSpacing.sm + 4
        : AppSpacing.md + 2;
    final EdgeInsets notePadding = EdgeInsets.fromLTRB(
      _noteTailWidth + (widget.compact ? AppSpacing.md : AppSpacing.lg - 2),
      notePaddingVertical,
      widget.compact ? AppSpacing.md : AppSpacing.lg - 2,
      notePaddingVertical,
    );
    final Widget noteContent = Padding(
      padding: notePadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        widget.group.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: widget.compact ? 17 : 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: widget.current
                            ? AppColors.surface
                            : AppColors.accentSoft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '群聊',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.accentDeep,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                formatContactTime(widget.group.lastActivityAt),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.inkMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) => Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: unreadLabel == null ? 0 : AppSpacing.sm,
                    ),
                    child: Text(
                      _previewLabel(widget.group.lastMessage),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontSize: 14,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ),
                ),
                if (unreadLabel != null)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: _UnreadBadge(
                      count: widget.unread,
                      label: unreadLabel,
                      account: widget.group.conversation.id,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final Widget content = KeyedSubtree(
      key: widget.current
          ? UsersListView.selectedKey(widget.group.conversation.id)
          : null,
      child: noteContent,
    );
    final Widget note = widget.current
        ? Ink(
            key: UsersListView.noteKey(widget.group.conversation.id),
            decoration: const _ConversationNoteDecoration(
              color: AppColors.accentSoft,
              tailWidth: _noteTailWidth,
              radius: AppRadius.card,
            ),
            child: content,
          )
        : content;
    return Semantics(
      selected: widget.current,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: widget.compact ? 4 : 6),
            child: Row(
              children: <Widget>[
                ProfileAvatar(
                  bytes: _avatar,
                  size: avatarSize,
                  semanticLabel: '${widget.group.displayName} 群头像',
                ),
                SizedBox(width: avatarGap),
                Expanded(child: note),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({
    required this.count,
    required this.label,
    required this.account,
  });

  final int count;
  final String label;
  final String account;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$count 条未读',
      excludeSemantics: true,
      // 不要把 `alignment` 交给 Container：那会让它撑满父级给的 maxWidth，
      // 未读胶囊就会被拉成整行宽（2026-11-28 现场）。靠对称 padding + minWidth
      // 撑出胶囊，宽度只跟着标签走，被外层限宽时收紧而不是溢出。
      child: Container(
        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.accentDeep,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          key: UsersListView.unreadKey(account),
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: const TextStyle(
            color: AppColors.surface,
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
