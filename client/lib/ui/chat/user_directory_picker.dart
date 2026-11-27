import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../../services/profile_service.dart';
import '../profile/profile_panel.dart';
import 'user_identity_row.dart';

Future<List<ChatUser>?> openUserDirectoryPicker(
  BuildContext context, {
  required ChatService chat,
  required ProfileGateway profile,
  Set<String> excludedAccounts = const <String>{},
  bool allowEmpty = true,
  VoidCallback? onSessionExpired,
}) => openProfileSurface<List<ChatUser>>(
  context,
  label: '选择用户',
  builder: (_) => UserDirectoryPicker(
    chat: chat,
    profile: profile,
    excludedAccounts: excludedAccounts,
    allowEmpty: allowEmpty,
    onSessionExpired: onSessionExpired,
  ),
);

/// Reads the existing BB directory without sorting by chats or deriving unread.
/// An empty selection is a valid creation choice; cancel returns null.
class UserDirectoryPicker extends StatefulWidget {
  const UserDirectoryPicker({
    super.key,
    required this.chat,
    required this.profile,
    this.excludedAccounts = const <String>{},
    this.allowEmpty = true,
    this.onSessionExpired,
  });

  final ChatService chat;
  final ProfileGateway profile;
  final Set<String> excludedAccounts;
  final bool allowEmpty;
  final VoidCallback? onSessionExpired;

  static const Key confirmKey = Key('directory-confirm');
  static const Key searchKey = Key('directory-search');
  static const Key retryKey = Key('directory-retry');
  static const Key listKey = Key('directory-list');

  @override
  State<UserDirectoryPicker> createState() => _UserDirectoryPickerState();
}

class _UserDirectoryPickerState extends State<UserDirectoryPicker> {
  List<ChatUser> _users = <ChatUser>[];
  final Set<String> _selected = <String>{};
  String _query = '';
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, ChatUser> users = <String, ChatUser>{};
      String after = '';
      while (true) {
        final UserPage page = await widget.chat.listUsers(
          afterAccount: after,
          limit: 100,
        );
        if (!mounted) {
          return;
        }
        for (final ChatUser user in page.items) {
          if (user.account != widget.chat.selfAccount &&
              !widget.excludedAccounts.contains(user.account)) {
            users[user.account] = user;
          }
        }
        final String? next = page.nextCursor;
        if (next == null) {
          break;
        }
        if (next.compareTo(after) <= 0) {
          throw const FormatException('user cursor did not advance');
        }
        after = next;
      }
      setState(() {
        _users = users.values.toList()
          ..sort((a, b) => a.account.compareTo(b.account));
        _selected.retainAll(users.keys);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error is AuthFailure ? error.message : '用户目录加载失败，请重试';
      });
      if (error is AuthFailure && error.status == 401) {
        widget.onSessionExpired?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final String query = _query.toLowerCase().trim();
    final List<ChatUser> users = _users
        .where(
          (u) =>
              u.account.contains(query) ||
              u.username.toLowerCase().contains(query),
        )
        .toList();
    return Material(
      color: AppColors.paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppBar(
            title: const Text('选择用户'),
            leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: TextField(
              key: UserDirectoryPicker.searchKey,
              decoration: const InputDecoration(
                labelText: '昵称或BB号',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(_error!, textAlign: TextAlign.center),
                          TextButton(
                            key: UserDirectoryPicker.retryKey,
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  )
                : users.isEmpty
                ? Center(child: Text(query.isEmpty ? '暂无可选择的用户' : '没有匹配的用户'))
                : ListView.builder(
                    key: UserDirectoryPicker.listKey,
                    itemCount: users.length,
                    itemBuilder: (context, index) {
                      final ChatUser user = users[index];
                      return UserIdentityRow(
                        user: user,
                        profile: widget.profile,
                        selected: _selected.contains(user.account),
                        onSelected: (value) => setState(() {
                          value
                              ? _selected.add(user.account)
                              : _selected.remove(user.account);
                        }),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: FilledButton(
              key: UserDirectoryPicker.confirmKey,
              onPressed:
                  _loading ||
                      _error != null ||
                      (!widget.allowEmpty && _selected.isEmpty)
                  ? null
                  : () => Navigator.of(context).pop(
                      _users
                          .where((u) => _selected.contains(u.account))
                          .toList(),
                    ),
              child: Text(
                _selected.isEmpty
                    ? (widget.allowEmpty ? '跳过，暂不邀请' : '请选择用户')
                    : '确认选择（${_selected.length}）',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
