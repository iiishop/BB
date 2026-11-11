import 'package:flutter/material.dart';

import '../app.dart';
import 'widgets/auth_widgets.dart';

/// Shown while a persisted credential is read and verified with
/// `GET /auth/session`. It never claims a login state until the server answers.
class RestoringView extends StatelessWidget {
  const RestoringView({super.key});

  static const Key viewKey = Key('auth-restoring');
  static const String title = '正在恢复登录状态';
  static const String subtitle = '正在验证本地保存的登录凭据…';

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      key: RestoringView.viewKey,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const BrandMark(size: 56),
                const SizedBox(height: AppSpacing.lg),
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: AppColors.accent,
                    backgroundColor: AppColors.accentSoft,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Semantics(
                  liveRegion: true,
                  child: Text(title, style: text.titleMedium),
                ),
                const SizedBox(height: AppSpacing.xs + 2),
                Text(subtitle, style: text.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
