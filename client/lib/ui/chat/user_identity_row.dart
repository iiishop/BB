import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../models/chat_models.dart';
import '../../models/profile_models.dart';
import '../../services/profile_service.dart';
import 'chat_format.dart';

/// Identity only: directory and member lists never inherit chat previews,
/// ordering, unread counts or view acknowledgements from UsersListView.
class UserIdentityRow extends StatelessWidget {
  const UserIdentityRow({
    super.key,
    required this.user,
    required this.profile,
    this.onOpenChat,
    this.selected,
    this.onSelected,
    this.trailing,
  });

  final ChatUser user;
  final ProfileGateway profile;
  final VoidCallback? onOpenChat;
  final bool? selected;
  final ValueChanged<bool>? onSelected;
  final Widget? trailing;

  static Key rowKey(String account) => ValueKey('identity-row-$account');

  @override
  Widget build(BuildContext context) {
    final bool desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };
    final VoidCallback? select = onSelected == null
        ? null
        : () => onSelected!(!(selected ?? false));
    return Semantics(
      selected: selected,
      hint: onOpenChat == null ? null : (desktop ? '双击进入私聊' : '点击进入私聊'),
      child: Material(
        key: rowKey(user.account),
        color: selected == true ? AppColors.accentSoft : Colors.transparent,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                onTap: onOpenChat,
                child: Focus(
                  canRequestFocus: false,
                  onKeyEvent: (node, event) {
                    if (desktop &&
                        selected == null &&
                        onOpenChat != null &&
                        event is KeyDownEvent &&
                        (event.logicalKey == LogicalKeyboardKey.enter ||
                            event.logicalKey == LogicalKeyboardKey.space)) {
                      onOpenChat!();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: InkWell(
                    onTap: select ?? (desktop ? null : onOpenChat),
                    onDoubleTap: desktop && selected == null
                        ? onOpenChat
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Row(
                        children: <Widget>[
                          UserIdentityAvatar(
                            user: user,
                            profile: profile,
                            online: user.presence == Presence.online,
                            size: 48,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  user.username,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                Text(
                                  'BB号 ${user.account} · ${user.presence == Presence.online ? '在线' : '离线'}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (selected == null)
              ?trailing
            else
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Checkbox(
                  value: selected,
                  onChanged: onSelected == null
                      ? null
                      : (bool? value) => onSelected!(value!),
                  semanticLabel: '选择 ${user.username}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shared identity avatar for the conversation list and directory rows. Bytes
/// still come from the existing authorized ProfileGateway thumbnail cache.
class UserIdentityAvatar extends StatefulWidget {
  const UserIdentityAvatar({
    super.key,
    required this.user,
    required this.profile,
    required this.online,
    required this.size,
    this.avatarKey,
    this.presenceKey,
  });

  final ChatUser user;
  final ProfileGateway profile;
  final bool online;
  final double size;
  final Key? avatarKey;
  final Key? presenceKey;

  @override
  State<UserIdentityAvatar> createState() => _UserIdentityAvatarState();
}

class _UserIdentityAvatarState extends State<UserIdentityAvatar> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant UserIdentityAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.account != widget.user.account ||
        oldWidget.user.avatarVersion != widget.user.avatarVersion ||
        oldWidget.profile != widget.profile) {
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
  Widget build(BuildContext context) => Semantics(
    label: widget.online ? '在线' : '离线',
    child: Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Container(
          key: widget.avatarKey,
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<Uint8List>(
            future: _future,
            builder: (context, snapshot) => snapshot.hasData
                ? Image.memory(
                    snapshot.data!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) => _initials(),
                  )
                : _initials(),
          ),
        ),
        if (widget.online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              key: widget.presenceKey,
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: AppColors.success,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.paper, width: 2),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _initials() => Center(
    child: Text(
      initialsOf(widget.user.username),
      style: TextStyle(
        fontSize: widget.size * 0.36,
        fontWeight: FontWeight.w700,
        color: AppColors.accentDeep,
      ),
    ),
  );
}
