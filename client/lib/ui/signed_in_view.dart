import 'package:flutter/material.dart';

import '../app.dart';
import '../models/auth_models.dart';
import 'auth_shell.dart';

/// Completion state after a successful login.
///
/// Deliberately not a profile page: this step only proves the session was
/// established and lets the user leave it.
class SignedInView extends StatelessWidget {
  const SignedInView({super.key, required this.user, required this.onSignOut});

  final AuthUser user;
  final VoidCallback onSignOut;

  static const Key accountValueKey = Key('signed-in-account');
  static const Key signOutButtonKey = Key('sign-out');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AuthShell(
      eyebrow: 'STEP-1 · 已登录',
      title: '登录成功',
      subtitle: '会话只保留在本次运行中，退出后需要重新登录。',
      card: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.check_circle,
                color: AppColors.success,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('欢迎回来，${user.username}', style: text.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('当前账号', style: text.bodySmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            user.account,
            key: SignedInView.accountValueKey,
            style: text.displaySmall?.copyWith(
              color: AppColors.accentDeep,
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          Text('后续的社交功能会使用这个账号。', style: text.bodySmall),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton(
            key: SignedInView.signOutButtonKey,
            onPressed: onSignOut,
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
  }
}
