import 'package:flutter/material.dart';

import '../../app.dart';
import 'space_follow_store.dart';

/// Follow / following control shared by Space feed cards and the author home
/// page. The label is only ever the store's authoritative state; a failed write
/// leaves it unchanged and the caller reports the failure.
class SpaceFollowButton extends StatelessWidget {
  const SpaceFollowButton({
    super.key,
    required this.following,
    required this.busy,
    required this.onPressed,
    this.compact = false,
  });

  final bool following;
  final bool busy;
  final VoidCallback? onPressed;

  /// Feed-card density: a text button instead of a filled 40 px control.
  final bool compact;

  static const Key buttonKey = Key('space-follow-button');
  static const Key dialogKey = Key('space-unfollow-dialog');
  static const Key confirmKey = Key('space-unfollow-confirm');

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return SizedBox(
        width: compact ? 56 : 96,
        height: 32,
        child: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!compact) {
      if (following) {
        return OutlinedButton.icon(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(96, 40),
            side: const BorderSide(color: AppColors.border),
            foregroundColor: AppColors.inkMuted,
          ),
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('已关注'),
        );
      }
      return FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(minimumSize: const Size(96, 40)),
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
        label: const Text('关注'),
      );
    }
    if (following) {
      return TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          foregroundColor: AppColors.inkMuted,
        ),
        icon: const Icon(Icons.check_rounded, size: 16),
        label: const Text('已关注', style: TextStyle(fontSize: 12.5)),
      );
    }
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      ),
      icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
      label: const Text('关注', style: TextStyle(fontSize: 12.5)),
    );
  }
}

/// Unfollow always needs an explicit confirmation that names the target.
Future<bool> confirmSpaceUnfollow(
  BuildContext context, {
  required String name,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      key: SpaceFollowButton.dialogKey,
      title: const Text('取消关注？'),
      content: Text('取消后将不再关注 $name。关注关系会立即解除。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: SpaceFollowButton.confirmKey,
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('取消关注'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Shared interaction used by a feed card and the home page: confirm an
/// unfollow, write the desired state, then report a failure without changing
/// the displayed relationship.
Future<void> toggleSpaceFollow(
  BuildContext context, {
  required SpaceFollowStore store,
  required String account,
  required String name,
}) async {
  if (store.isSelf(account) || store.isWriting(account)) {
    return;
  }
  final bool currently = store.stateFor(account) ?? false;
  if (currently && !await confirmSpaceUnfollow(context, name: name)) {
    return;
  }
  final bool applied = await store.setFollowing(account, !currently);
  if (!context.mounted) {
    return;
  }
  if (!applied && store.error != null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(store.error!)));
  }
}
