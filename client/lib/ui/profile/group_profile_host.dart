import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../models/group_models.dart';
import '../../services/chat_service.dart';
import '../../services/group_service.dart';
import '../../services/media_source.dart';
import '../../services/profile_service.dart';
import '../chat/chat_format.dart';
import '../chat/user_directory_picker.dart';
import '../chat/user_identity_row.dart';
import '../notifications/notification_center.dart';
import 'avatar_picker.dart';
import 'group_profile_panel.dart';
import 'profile_panel.dart';

/// Opens the complete group creation workflow:
/// 1) pick initial invitees (optional / skippable);
/// 2) fill group name (required) & description/avatar;
/// 3) call [GroupService.createGroup] and return the created [GroupProfile].
Future<GroupProfile?> openCreateGroupFlow(
  BuildContext context, {
  required ChatService chat,
  required GroupService groups,
  required ProfileGateway profile,
  AvatarImagePicker? avatarPicker,
  VoidCallback? onSessionExpired,
}) async {
  final List<ChatUser>? picked = await openUserDirectoryPicker(
    context,
    chat: chat,
    profile: profile,
    allowEmpty: true,
    onSessionExpired: onSessionExpired,
  );
  if (picked == null || !context.mounted) {
    return null;
  }
  return openProfileSurface<GroupProfile>(
    context,
    label: '创建群',
    builder: (BuildContext surfaceContext) => _CreateGroupSheet(
      groups: groups,
      invitees: picked.map((ChatUser u) => u.account).toList(growable: false),
      avatarPicker: avatarPicker ?? const FileSelectorAvatarImagePicker(),
      onSessionExpired: onSessionExpired,
    ),
  );
}

/// Opens the group-number lookup surface and transitions to [openGroupProfileByNumber]
/// once a valid group is found.
Future<void> openFindGroupDialog(
  BuildContext context, {
  required GroupService groups,
  ChatService? chat,
  ProfileGateway? profile,
  Future<void> Function(ChatUser user)? onOpenDirectChat,
  VoidCallback? onGroupsChanged,
  VoidCallback? onSessionExpired,
}) async {
  final GroupProfile? found = await openProfileSurface<GroupProfile>(
    context,
    label: '申请加入群',
    builder: (BuildContext surfaceContext) =>
        _FindGroupSheet(groups: groups, onSessionExpired: onSessionExpired),
  );
  if (found == null || !context.mounted) {
    return;
  }
  await openGroupProfileByNumber(
    context,
    groupNumber: found.groupNumber,
    initialProfile: found,
    groups: groups,
    chat: chat,
    profile: profile,
    onOpenDirectChat: onOpenDirectChat,
    onGroupsChanged: onGroupsChanged,
    onSessionExpired: onSessionExpired,
  );
}

/// Opens a live [GroupProfilePanel] inside [openProfileSurface] (phone/folded/
/// desktop adaptive) backed by [GroupService].
Future<void> openGroupProfileByNumber(
  BuildContext context, {
  required String groupNumber,
  required GroupService groups,
  GroupProfile? initialProfile,
  ChatService? chat,
  ProfileGateway? profile,
  AvatarImagePicker? avatarPicker,
  Future<void> Function(ChatUser user)? onOpenDirectChat,
  VoidCallback? onGroupsChanged,
  VoidCallback? onSessionExpired,
}) => openProfileSurface<void>(
  context,
  label: '群资料',
  builder: (_) => _GroupProfileHost(
    groupNumber: groupNumber,
    initialProfile: initialProfile,
    groups: groups,
    chat: chat,
    profile: profile,
    avatarPicker: avatarPicker ?? const FileSelectorAvatarImagePicker(),
    onOpenDirectChat: onOpenDirectChat,
    onGroupsChanged: onGroupsChanged,
    onSessionExpired: onSessionExpired,
  ),
);

/// Wired general notification center backed by [GroupService].
///
/// Separate from Space notifications; reading or filtering never marks notices
/// read or triggers actions automatically.
class NotificationCenterHost extends StatefulWidget {
  const NotificationCenterHost({
    super.key,
    required this.groups,
    this.chat,
    this.profile,
    this.active = true,
    this.refreshTrigger,
    this.onOpenDirectChat,
    this.onGroupsChanged,
    this.onSessionExpired,
  });

  final GroupService groups;
  final ChatService? chat;
  final ProfileGateway? profile;
  final bool active;
  final ValueListenable<int>? refreshTrigger;
  final Future<void> Function(ChatUser user)? onOpenDirectChat;
  final VoidCallback? onGroupsChanged;
  final VoidCallback? onSessionExpired;

  @override
  State<NotificationCenterHost> createState() => NotificationCenterHostState();
}

class _NoticeFilterFeed {
  const _NoticeFilterFeed({
    this.items = const <Notice>[],
    this.nextCursor,
    this.loaded = false,
    this.pagesLoaded = 0,
  });

  final List<Notice> items;
  final String? nextCursor;
  final bool loaded;
  final int pagesLoaded;
}

class NotificationCenterHostState extends State<NotificationCenterHost> {
  NoticeFilter _filter = NoticeFilter.all;
  final Map<NoticeFilter, _NoticeFilterFeed> _feeds =
      <NoticeFilter, _NoticeFilterFeed>{};
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _loadMoreError;
  bool _busyAction = false;
  int _filterGeneration = 0;
  int _reloadGeneration = 0;
  int _loadMoreGeneration = 0;
  String? _inFlightLoadMoreCursor;

  _NoticeFilterFeed get _currentFeed =>
      _feeds[_filter] ?? const _NoticeFilterFeed();

  List<Notice> get _notices => _currentFeed.items;

  NoticeFilter get _otherFilter =>
      _filter == NoticeFilter.all ? NoticeFilter.pending : NoticeFilter.all;

  void _onRefreshSignal() {
    if (mounted) {
      _feeds.remove(_otherFilter);
      unawaited(reload(silent: true));
    }
  }

  @override
  void initState() {
    super.initState();
    widget.refreshTrigger?.addListener(_onRefreshSignal);
    unawaited(reload());
  }

  @override
  void dispose() {
    widget.refreshTrigger?.removeListener(_onRefreshSignal);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant NotificationCenterHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTrigger != widget.refreshTrigger) {
      oldWidget.refreshTrigger?.removeListener(_onRefreshSignal);
      widget.refreshTrigger?.addListener(_onRefreshSignal);
    }
    if (!oldWidget.active && widget.active) {
      _feeds.remove(_otherFilter);
      unawaited(reload(silent: true));
    }
  }

  static List<Notice> _mergeNotices(
    List<Notice> existing,
    List<Notice> incoming,
  ) {
    final List<Notice> merged = <Notice>[];
    final Set<String> seenIds = <String>{};
    for (final Notice item in existing) {
      if (seenIds.add(item.id)) {
        merged.add(item);
      }
    }
    for (final Notice item in incoming) {
      if (seenIds.add(item.id)) {
        merged.add(item);
      }
    }
    return List<Notice>.unmodifiable(merged);
  }

  void _onFilterChanged(bool pendingOnly) {
    final NoticeFilter target = pendingOnly
        ? NoticeFilter.pending
        : NoticeFilter.all;
    if (target == _filter && _error == null) {
      return;
    }
    _filterGeneration += 1;
    _reloadGeneration += 1;
    _loadMoreGeneration += 1;
    _inFlightLoadMoreCursor = null;
    final bool hasCached = _feeds[target]?.loaded ?? false;
    setState(() {
      _filter = target;
      _loading = !hasCached;
      _loadingMore = false;
      _error = null;
      _loadMoreError = null;
    });
    unawaited(reload(silent: hasCached));
  }

  Future<void> reload({bool silent = false}) async {
    final NoticeFilter target = _filter;
    final _NoticeFilterFeed previous =
        _feeds[target] ?? const _NoticeFilterFeed();
    final int filterGen = _filterGeneration;
    final int reloadGen = ++_reloadGeneration;
    if ((!silent || !previous.loaded) && mounted) {
      _loadMoreGeneration += 1;
      _inFlightLoadMoreCursor = null;
      setState(() {
        _loading = true;
        _loadingMore = false;
        _error = null;
        _loadMoreError = null;
      });
    }
    try {
      final List<Notice> collected = <Notice>[];
      final Set<String> seenIds = <String>{};
      String? cursor;
      String? nextCursor;
      int pagesLoaded = 0;
      while (true) {
        final NoticePage page = await widget.groups.listNotices(
          filter: target,
          cursor: cursor,
          limit: 100,
        );
        if (!mounted ||
            filterGen != _filterGeneration ||
            reloadGen != _reloadGeneration ||
            target != _filter) {
          return;
        }
        for (final Notice item in page.items) {
          if (seenIds.add(item.id)) {
            collected.add(item);
          }
        }
        pagesLoaded += 1;
        nextCursor = page.nextCursor;
        // Re-check expanded page count after each page fetch so a concurrent
        // loadMore() that completed while refresh was in flight keeps its pages.
        final int desiredPages = math.max(
          math.max(1, previous.pagesLoaded),
          _feeds[target]?.pagesLoaded ?? 1,
        );
        if (pagesLoaded >= desiredPages ||
            nextCursor == null ||
            nextCursor == cursor) {
          break;
        }
        cursor = nextCursor;
      }
      setState(() {
        _feeds[target] = _NoticeFilterFeed(
          items: List<Notice>.unmodifiable(collected),
          nextCursor: nextCursor,
          loaded: true,
          pagesLoaded: pagesLoaded,
        );
        _loading = false;
        _loadingMore = _inFlightLoadMoreCursor != null;
        _error = null;
        if (_inFlightLoadMoreCursor == null) {
          _loadMoreError = null;
        }
      });
    } on AuthFailure catch (failure) {
      if (!mounted ||
          filterGen != _filterGeneration ||
          reloadGen != _reloadGeneration ||
          target != _filter) {
        return;
      }
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = _inFlightLoadMoreCursor != null;
        if (_notices.isEmpty) {
          _error = failure.message;
        }
      });
    } catch (_) {
      if (!mounted ||
          filterGen != _filterGeneration ||
          reloadGen != _reloadGeneration ||
          target != _filter) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = _inFlightLoadMoreCursor != null;
        if (_notices.isEmpty) {
          _error = '通知加载失败，请重试';
        }
      });
    }
  }

  Future<void> loadMore() async {
    final NoticeFilter target = _filter;
    final _NoticeFilterFeed feed = _feeds[target] ?? const _NoticeFilterFeed();
    final String? initialCursor = feed.nextCursor;
    if (_loading || _loadingMore || initialCursor == null) {
      return;
    }
    final int filterGen = _filterGeneration;
    final int loadMoreGen = ++_loadMoreGeneration;
    _inFlightLoadMoreCursor = initialCursor;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    String cursor = initialCursor;
    try {
      while (true) {
        final NoticePage page = await widget.groups.listNotices(
          filter: target,
          cursor: cursor,
          limit: 100,
        );
        if (!mounted ||
            filterGen != _filterGeneration ||
            loadMoreGen != _loadMoreGeneration ||
            target != _filter) {
          return;
        }
        final _NoticeFilterFeed latest =
            _feeds[target] ?? const _NoticeFilterFeed();
        // If a concurrent reload changed the first-page tail cursor while we
        // were awaiting this cursor, follow the updated cursor (or stop if none).
        if (latest.loaded && latest.nextCursor != cursor) {
          final String? updatedCursor = latest.nextCursor;
          if (updatedCursor == null) {
            _inFlightLoadMoreCursor = null;
            setState(() {
              _loadingMore = false;
              _loadMoreError = null;
            });
            return;
          }
          cursor = updatedCursor;
          _inFlightLoadMoreCursor = updatedCursor;
          continue;
        }
        _inFlightLoadMoreCursor = null;
        setState(() {
          _feeds[target] = _NoticeFilterFeed(
            items: _mergeNotices(latest.items, page.items),
            nextCursor: page.nextCursor,
            loaded: true,
            pagesLoaded: latest.pagesLoaded + 1,
          );
          _loadingMore = false;
          _loadMoreError = null;
        });
        return;
      }
    } on AuthFailure catch (failure) {
      if (!mounted ||
          filterGen != _filterGeneration ||
          loadMoreGen != _loadMoreGeneration ||
          target != _filter) {
        return;
      }
      _inFlightLoadMoreCursor = null;
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
        return;
      }
      setState(() {
        _loadingMore = false;
        _loadMoreError = failure.message;
      });
    } catch (_) {
      if (!mounted ||
          filterGen != _filterGeneration ||
          loadMoreGen != _loadMoreGeneration ||
          target != _filter) {
        return;
      }
      _inFlightLoadMoreCursor = null;
      setState(() {
        _loadingMore = false;
        _loadMoreError = '加载更多失败，请重试';
      });
    }
  }

  Future<void> _executeAction(Notice notice, NoticeAction action) async {
    if (_busyAction) {
      return;
    }
    setState(() => _busyAction = true);
    try {
      await widget.groups.executeNoticeAction(
        notificationId: notice.id,
        actionId: action.id,
      );
      _feeds.remove(_otherFilter);
      widget.onGroupsChanged?.call();
      await reload(silent: true);
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
        _feeds.remove(_otherFilter);
        await reload(silent: true);
      }
    } catch (_) {
      _snack('处理通知失败，请重试');
      _feeds.remove(_otherFilter);
      await reload(silent: true);
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  Future<void> _markRead(Notice notice) async {
    try {
      await widget.groups.markNoticeRead(notice.id);
      _feeds.remove(_otherFilter);
      await reload(silent: true);
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
      }
    } catch (_) {
      _snack('标为已读失败');
    }
  }

  Future<void> _openLink(NoticeLink link) async {
    if (link.type == 'group') {
      await openGroupProfileByNumber(
        context,
        groupNumber: link.id,
        groups: widget.groups,
        chat: widget.chat,
        profile: widget.profile,
        onOpenDirectChat: widget.onOpenDirectChat,
        onGroupsChanged: widget.onGroupsChanged,
        onSessionExpired: widget.onSessionExpired,
      );
      if (mounted) {
        _feeds.remove(_otherFilter);
        await reload(silent: true);
      }
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final _NoticeFilterFeed feed = _currentFeed;
    final List<NotificationEntry> entries = <NotificationEntry>[
      for (final Notice notice in feed.items)
        NotificationEntry(
          id: notice.id,
          title: notice.title,
          body: notice.text,
          timeLabel: formatContactTime(notice.createdAt),
          read: notice.read,
          statusLabel: switch (notice.state) {
            NoticeState.pending => '待处理',
            NoticeState.processed => '已处理',
            NoticeState.invalidated || NoticeState.informational => null,
          },
          invalidated: notice.state == NoticeState.invalidated,
          actions: <NotificationEntryAction>[
            for (final NoticeAction action in notice.actions)
              NotificationEntryAction(
                id: action.id,
                label: action.label,
                available: action.available && !_busyAction,
                onPressed: action.available && !_busyAction
                    ? () => unawaited(_executeAction(notice, action))
                    : null,
              ),
          ],
          onOpenDetails: notice.link == null
              ? null
              : () => unawaited(_openLink(notice.link!)),
          onMarkRead: !notice.read && notice.state != NoticeState.invalidated
              ? () => unawaited(_markRead(notice))
              : null,
        ),
    ];
    return NotificationCenter(
      entries: entries,
      available: true,
      loading: _loading && feed.items.isEmpty,
      error: _error,
      onRetry: reload,
      pendingOnly: _filter == NoticeFilter.pending,
      onFilterChanged: _onFilterChanged,
      hasMore: feed.nextCursor != null,
      loadingMore: _loadingMore,
      loadMoreError: _loadMoreError,
      onLoadMore: loadMore,
    );
  }
}

class _CreateGroupSheet extends StatefulWidget {
  const _CreateGroupSheet({
    required this.groups,
    required this.invitees,
    required this.avatarPicker,
    this.onSessionExpired,
  });

  final GroupService groups;
  final List<String> invitees;
  final AvatarImagePicker avatarPicker;
  final VoidCallback? onSessionExpired;

  @override
  State<_CreateGroupSheet> createState() => _CreateGroupSheetState();
}

class _CreateGroupSheetState extends State<_CreateGroupSheet> {
  bool _busy = false;
  String? _error;
  AvatarPick? _avatar;
  final String _operationId = newOperationId('cg');

  Future<void> _pickAvatar() async {
    final AvatarPick? picked = await widget.avatarPicker.pickImage();
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _avatar = picked);
  }

  Future<void> _submit(String name, String? description) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final MediaSource? avatarSource = _avatar == null
          ? null
          : MediaSource(bytes: _avatar!.bytes, path: _avatar!.path);
      final GroupProfile created = await widget.groups.createGroup(
        operationId: _operationId,
        name: name,
        description: description ?? '',
        invitees: widget.invitees,
        avatar: avatarSource,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(created);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
        return;
      }
      setState(() {
        _busy = false;
        _error = failure.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = '创建群失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.paper,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppBar(
          title: const Text('新建群聊'),
          leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            0,
          ),
          child: Row(
            children: <Widget>[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _busy ? null : _pickAvatar,
                icon: const Icon(Icons.photo_outlined, size: 18),
                label: Text(
                  _avatar == null ? '自选头像（可选）' : '已选 ${_avatar!.name}',
                ),
              ),
              if (_avatar != null) ...<Widget>[
                const SizedBox(width: AppSpacing.xs),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _avatar = null),
                  child: const Text('恢复默认'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: GroupDetailsForm(
            onSubmit: _submit,
            busy: _busy,
            error: _error,
          ),
        ),
      ],
    ),
  );
}

class _FindGroupSheet extends StatefulWidget {
  const _FindGroupSheet({required this.groups, this.onSessionExpired});

  final GroupService groups;
  final VoidCallback? onSessionExpired;

  @override
  State<_FindGroupSheet> createState() => _FindGroupSheetState();
}

class _FindGroupSheetState extends State<_FindGroupSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final String number = _controller.text.trim();
    if (!isValidGroupNumber(number)) {
      setState(() => _error = '请输入 8 位群号');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final GroupProfile profile = await widget.groups.findGroup(number);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(profile);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
        return;
      }
      setState(() {
        _busy = false;
        _error = failure.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = '查找群失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.paper,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppBar(
          title: const Text('申请加入群'),
          leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                key: const Key('find-group-number-input'),
                controller: _controller,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '8 位群号'),
                onSubmitted: (_) => unawaited(_lookup()),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                Text(_error!, style: const TextStyle(color: AppColors.danger)),
              ],
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                key: const Key('find-group-submit'),
                onPressed: _busy ? null : _lookup,
                child: Text(_busy ? '正在查找…' : '查找群资料'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

enum _ProfileSubPage { details, edit, members }

class _GroupProfileHost extends StatefulWidget {
  const _GroupProfileHost({
    required this.groupNumber,
    required this.groups,
    required this.avatarPicker,
    this.initialProfile,
    this.chat,
    this.profile,
    this.onOpenDirectChat,
    this.onGroupsChanged,
    this.onSessionExpired,
  });

  final String groupNumber;
  final GroupProfile? initialProfile;
  final GroupService groups;
  final AvatarImagePicker avatarPicker;
  final ChatService? chat;
  final ProfileGateway? profile;
  final Future<void> Function(ChatUser user)? onOpenDirectChat;
  final VoidCallback? onGroupsChanged;
  final VoidCallback? onSessionExpired;

  @override
  State<_GroupProfileHost> createState() => _GroupProfileHostState();
}

class _GroupProfileHostState extends State<_GroupProfileHost> {
  GroupProfile? _group;
  Uint8List? _avatar;
  List<GroupMember> _members = <GroupMember>[];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _editError;
  AvatarPick? _editAvatar;
  bool _editResetAvatar = false;
  _ProfileSubPage _page = _ProfileSubPage.details;

  @override
  void initState() {
    super.initState();
    _group = widget.initialProfile;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = _group == null;
      _error = null;
    });
    try {
      final GroupProfile loaded = await widget.groups.findGroup(
        widget.groupNumber,
      );
      Uint8List? avatarBytes = _avatar;
      if (loaded.avatarUrl.isNotEmpty) {
        try {
          final GroupAvatarImage image = await widget.groups.loadGroupAvatar(
            groupNumber: loaded.groupNumber,
            avatarUrl: loaded.avatarUrl,
            thumb: true,
          );
          avatarBytes = Uint8List.fromList(image.bytes);
        } catch (_) {
          // Avatar load failures leave initials/placeholder cleanly.
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _group = loaded;
        _avatar = avatarBytes;
        _loading = false;
      });
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
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
        _error = '群资料加载失败，请重试';
      });
    }
  }

  Future<void> _apply() async {
    final GroupProfile? current = _group;
    if (current == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.groups.applyToGroup(conversation: current.conversation);
      if (!mounted) {
        return;
      }
      _snack('已发送入群申请');
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
      }
    } catch (_) {
      _snack('申请失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openMembers() async {
    final GroupProfile? current = _group;
    if (current == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final List<GroupMember> all = await _fetchAllMembers(
        current.conversation,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _members = all;
        _busy = false;
        _page = _ProfileSubPage.members;
      });
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() => _busy = false);
      }
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
      }
      _snack('成员名单加载失败');
    }
  }

  Future<List<GroupMember>> _fetchAllMembers(ConversationRef conv) async {
    final List<GroupMember> members = <GroupMember>[];
    String after = '';
    while (true) {
      final GroupMemberPage page = await widget.groups.listGroupMembers(
        conversation: conv,
        afterAccount: after,
        limit: 100,
      );
      members.addAll(page.items);
      if (page.nextCursor == null || page.nextCursor!.compareTo(after) <= 0) {
        return members;
      }
      after = page.nextCursor!;
    }
  }

  Future<void> _invite() async {
    final GroupProfile? current = _group;
    final ChatService? chat = widget.chat;
    final ProfileGateway? profile = widget.profile;
    if (current == null || chat == null || profile == null || _busy) {
      return;
    }
    Set<String> existingAccounts = <String>{
      for (final GroupMember m in _members) m.account,
    };
    if (existingAccounts.isEmpty) {
      try {
        final List<GroupMember> loaded = await _fetchAllMembers(
          current.conversation,
        );
        existingAccounts = <String>{
          for (final GroupMember m in loaded) m.account,
        };
      } catch (_) {
        // Proceed with server validation if preload fails.
      }
    }
    if (!mounted) {
      return;
    }
    final List<ChatUser>? picked = await openUserDirectoryPicker(
      context,
      chat: chat,
      profile: profile,
      excludedAccounts: existingAccounts,
      allowEmpty: false,
      onSessionExpired: widget.onSessionExpired,
    );
    if (picked == null || picked.isEmpty || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.groups.inviteToGroup(
        conversation: current.conversation,
        accounts: picked.map((ChatUser u) => u.account).toList(growable: false),
      );
      _snack('已发送邀请');
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
      }
    } catch (_) {
      _snack('邀请失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _removeMember(GroupMember member) async {
    final GroupProfile? current = _group;
    if (current == null || _busy) {
      return;
    }
    final bool? confirmed = await _confirm(
      title: '移除成员',
      content: '确认将 ${member.username}（${member.account}）移出群聊吗？',
      confirmLabel: '移除',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final GroupProfile updated = await widget.groups.removeGroupMember(
        conversation: current.conversation,
        account: member.account,
      );
      final List<GroupMember> reloaded = await _fetchAllMembers(
        updated.conversation,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _group = updated;
        _members = reloaded;
      });
      widget.onGroupsChanged?.call();
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
      }
    } catch (_) {
      _snack('移除失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggleAllowInvites(bool allow) async {
    final GroupProfile? current = _group;
    if (current == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final GroupProfile updated = await widget.groups.updateGroup(
        conversation: current.conversation,
        allowMemberInvites: allow,
      );
      if (!mounted) {
        return;
      }
      setState(() => _group = updated);
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
      }
    } catch (_) {
      _snack('更新设置失败');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _saveEdit(String name, String? description) async {
    final GroupProfile? current = _group;
    if (current == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _editError = null;
    });
    try {
      final MediaSource? avatarSource = _editAvatar == null
          ? null
          : MediaSource(bytes: _editAvatar!.bytes, path: _editAvatar!.path);
      final GroupProfile updated = await widget.groups.updateGroup(
        conversation: current.conversation,
        name: name,
        description: description ?? '',
        avatar: _editResetAvatar ? null : avatarSource,
        resetAvatar: _editResetAvatar,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _group = updated;
        if (_editResetAvatar) {
          _avatar = null;
        }
        _editAvatar = null;
        _editResetAvatar = false;
        _page = _ProfileSubPage.details;
      });
      unawaited(_load());
      widget.onGroupsChanged?.call();
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
        return;
      }
      setState(() => _editError = failure.message);
    } catch (_) {
      if (mounted) {
        setState(() => _editError = '保存失败，请重试');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _leave() async {
    final GroupProfile? current = _group;
    if (current == null || _busy) {
      return;
    }
    final bool? confirmed = await _confirm(
      title: '退出群聊',
      content: '退出后群会话将从列表移除，且无法再接收消息。确定退出吗？',
      confirmLabel: '退出',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.groups.leaveGroup(conversation: current.conversation);
      widget.onGroupsChanged?.call();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
      }
    } catch (_) {
      _snack('退出群聊失败');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _disband() async {
    final GroupProfile? current = _group;
    if (current == null || _busy) {
      return;
    }
    final bool? confirmed = await _confirm(
      title: '解散群聊',
      content: '解散后所有成员将无法再收发消息且不可恢复。确定解散吗？',
      confirmLabel: '解散',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final GroupProfile dissolved = await widget.groups.dissolveGroup(
        conversation: current.conversation,
      );
      widget.onGroupsChanged?.call();
      if (mounted) {
        setState(() {
          _group = dissolved;
          _page = _ProfileSubPage.details;
        });
      }
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        widget.onSessionExpired?.call();
      } else {
        _snack(failure.message);
      }
    } catch (_) {
      _snack('解散群聊失败');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String content,
    required String confirmLabel,
    bool destructive = false,
  }) => showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          style: destructive
              ? TextButton.styleFrom(foregroundColor: AppColors.danger)
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  GroupProfileRole _mapRole(GroupRole? role) => switch (role) {
    GroupRole.owner => GroupProfileRole.owner,
    GroupRole.member => GroupProfileRole.member,
    null => GroupProfileRole.visitor,
  };

  @override
  Widget build(BuildContext context) {
    if (_loading && _group == null) {
      return Material(
        color: AppColors.paper,
        child: Column(
          children: <Widget>[
            AppBar(title: const Text('群资料'), leading: const CloseButton()),
            const Expanded(child: Center(child: CircularProgressIndicator())),
          ],
        ),
      );
    }
    if (_error != null && _group == null) {
      return Material(
        color: AppColors.paper,
        child: Column(
          children: <Widget>[
            AppBar(title: const Text('群资料'), leading: const CloseButton()),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    final GroupProfile group = _group!;
    if (_page == _ProfileSubPage.edit) {
      return Material(
        color: AppColors.paper,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AppBar(
              title: const Text('编辑群资料'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () =>
                    setState(() => _page = _ProfileSubPage.details),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                0,
              ),
              child: Wrap(
                spacing: AppSpacing.xs,
                children: <Widget>[
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: _busy
                        ? null
                        : () async {
                            final AvatarPick? picked = await widget.avatarPicker
                                .pickImage();
                            if (!mounted || picked == null) return;
                            setState(() {
                              _editAvatar = picked;
                              _editResetAvatar = false;
                            });
                          },
                    icon: const Icon(Icons.photo_outlined, size: 18),
                    label: Text(
                      _editAvatar == null ? '更换群头像' : _editAvatar!.name,
                    ),
                  ),
                  TextButton(
                    key: const Key('group-edit-avatar-reset'),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _editAvatar = null;
                            _editResetAvatar = true;
                          }),
                    child: const Text('恢复默认头像'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GroupDetailsForm(
                initialName: group.name,
                initialDescription: group.description,
                busy: _busy,
                error: _editError,
                onSubmit: _saveEdit,
              ),
            ),
          ],
        ),
      );
    }
    if (_page == _ProfileSubPage.members) {
      final bool isOwner = group.role == GroupRole.owner;
      final ProfileGateway? profileGateway = widget.profile;
      return Material(
        color: AppColors.paper,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AppBar(
              title: Text('群成员（${_members.length}）'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () =>
                    setState(() => _page = _ProfileSubPage.details),
              ),
            ),
            Expanded(
              child: profileGateway == null
                  ? const Center(child: Text('无法加载成员资料'))
                  : ListView.builder(
                      key: const Key('group-members-list'),
                      itemCount: _members.length,
                      itemBuilder: (BuildContext context, int index) {
                        final GroupMember member = _members[index];
                        final ChatUser user = ChatUser(
                          account: member.account,
                          username: member.username,
                          avatarUrl: member.avatarUrl,
                          avatarVersion: member.avatarVersion,
                          presence: member.presence,
                        );
                        final String? self = widget.chat?.selfAccount;
                        final bool isSelf =
                            self != null && self == member.account;
                        return UserIdentityRow(
                          user: user,
                          profile: profileGateway,
                          onOpenChat: !isSelf && widget.onOpenDirectChat != null
                              ? () async {
                                  Navigator.of(context).pop();
                                  await widget.onOpenDirectChat!(user);
                                }
                              : null,
                          trailing:
                              isOwner &&
                                  !isSelf &&
                                  member.role != GroupRole.owner
                              ? IconButton(
                                  key: ValueKey<String>(
                                    'remove-member-${member.account}',
                                  ),
                                  tooltip: '移除成员',
                                  icon: const Icon(
                                    Icons.person_remove_outlined,
                                  ),
                                  onPressed: _busy
                                      ? null
                                      : () => unawaited(_removeMember(member)),
                                )
                              : member.role == GroupRole.owner
                              ? const Padding(
                                  padding: EdgeInsets.only(
                                    right: AppSpacing.md,
                                  ),
                                  child: Text(
                                    '群主',
                                    style: TextStyle(
                                      color: AppColors.accentDeep,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                )
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    }
    return GroupProfilePanel(
      number: group.groupNumber,
      name: group.name,
      description: group.description,
      avatar: _avatar,
      role: _mapRole(group.role),
      dissolved: group.isDissolved,
      canInvite: group.canInvite,
      allowMemberInvites: group.allowMemberInvites ?? false,
      onApply: _busy ? null : _apply,
      onMembers: _busy ? null : _openMembers,
      onInvite: _busy ? null : _invite,
      onEdit: _busy
          ? null
          : () => setState(() {
              _editError = null;
              _editAvatar = null;
              _editResetAvatar = false;
              _page = _ProfileSubPage.edit;
            }),
      onLeave: _busy ? null : _leave,
      onDisband: _busy ? null : _disband,
      onAllowMemberInvitesChanged: _busy ? null : _toggleAllowInvites,
    );
  }
}
