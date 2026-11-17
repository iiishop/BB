import 'package:flutter/material.dart';

import '../../../app.dart';

/// Follow / following control for someone else's home page.
///
/// The label is only ever the authoritative state the controller holds; a
/// failed write leaves it unchanged and the page reports the failure. Tapping
/// "已关注" is interpreted by the caller as "ask to unfollow first".
class SpaceProfileFollowButton extends StatelessWidget {
  const SpaceProfileFollowButton({
    super.key,
    required this.following,
    required this.busy,
    required this.onPressed,
  });

  final bool following;
  final bool busy;
  final VoidCallback? onPressed;

  static const Key buttonKey = Key('space-profile-follow');

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 96,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (following) {
      return OutlinedButton.icon(
        key: buttonKey,
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
      key: buttonKey,
      onPressed: onPressed,
      style: FilledButton.styleFrom(minimumSize: const Size(96, 40)),
      icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
      label: const Text('关注'),
    );
  }
}
