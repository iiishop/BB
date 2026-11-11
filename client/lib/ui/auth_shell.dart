import 'package:flutter/material.dart';

import '../app.dart';
import 'widgets/auth_widgets.dart';

/// One responsive frame for every auth step.
///
/// Narrow (< 960 logical px): brand header stacked above a single full-width
/// card, safe-area aware and scrollable so the software keyboard never clips
/// the submit action.
/// Wide: a deep-teal brand panel beside a fixed-width form column, centred in
/// the window. One widget tree — only the arrangement changes.
class AuthShell extends StatelessWidget {
  const AuthShell({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.card,
    this.footer,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget card;
  final Widget? footer;

  /// Marks the wide-screen brand panel; also used by tests to assert layout.
  static const Key brandPanelKey = Key('auth-brand-panel');

  /// Form column key so tests can measure the compact/wide arrangement.
  static const Key formColumnKey = Key('auth-form-column');

  /// Wide-panel session hint. Must describe the persisted session: the client
  /// stores the credential locally and verifies it on the next launch.
  static const String sessionHint = '8 位账号登录 · 凭据保存在本机，重启后自动验证';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool wide = constraints.maxWidth >= 960;
            return wide
                ? _WideLayout(
                    eyebrow: eyebrow,
                    title: title,
                    subtitle: subtitle,
                    card: card,
                    footer: footer,
                  )
                : _NarrowLayout(
                    eyebrow: eyebrow,
                    title: title,
                    subtitle: subtitle,
                    card: card,
                    footer: footer,
                  );
          },
        ),
      ),
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.card,
    this.footer,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget card;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            key: AuthShell.formColumnKey,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const BrandHeader(),
              const SizedBox(height: AppSpacing.xxl),
              _FormHeader(
                eyebrow: eyebrow,
                title: title,
                subtitle: subtitle,
                compact: true,
              ),
              const SizedBox(height: AppSpacing.lg),
              AuthCard(child: card),
              if (footer != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.card,
    this.footer,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget card;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.xl,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              const Expanded(child: _BrandPanel(key: AuthShell.brandPanelKey)),
              const SizedBox(width: AppSpacing.xxl + AppSpacing.sm),
              SizedBox(
                width: 440,
                child: Column(
                  key: AuthShell.formColumnKey,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _FormHeader(
                      eyebrow: eyebrow,
                      title: title,
                      subtitle: subtitle,
                      compact: false,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AuthCard(child: card),
                    if (footer != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.md),
                      footer!,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FormHeader extends StatelessWidget {
  const _FormHeader({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.compact,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          eyebrow,
          style: text.labelSmall?.copyWith(color: AppColors.accent),
        ),
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          header: true,
          child: Text(
            title,
            style: text.headlineLarge?.copyWith(fontSize: compact ? 34 : 32),
          ),
        ),
        const SizedBox(height: AppSpacing.sm + 2),
        Text(subtitle, style: text.bodyLarge),
      ],
    );
  }
}

/// Product panel shown on wide windows only.
class _BrandPanel extends StatelessWidget {
  const _BrandPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.panel),
      child: Container(
        constraints: const BoxConstraints(minHeight: 560),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              AppColors.accentNight,
              AppColors.accentDeep,
              AppColors.accent,
            ],
          ),
        ),
        child: Stack(
          children: <Widget>[
            const Positioned(
              right: -70,
              top: -60,
              child: _Orb(size: 240, opacity: 0.07),
            ),
            const Positioned(
              right: 30,
              bottom: -90,
              child: _Orb(size: 220, opacity: 0.05),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const BrandMark(onDark: true),
                      const SizedBox(width: AppSpacing.sm + AppSpacing.xs),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            'BB',
                            style: text.titleMedium?.copyWith(
                              color: AppColors.surface,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '私人社交',
                            style: text.bodySmall?.copyWith(
                              color: AppColors.surface.withValues(alpha: 0.72),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xxl + AppSpacing.xxl),
                  Text(
                    '只与你信任的人\n保持联系。',
                    style: text.headlineLarge?.copyWith(
                      color: AppColors.surface,
                      fontSize: 36,
                      height: 1.22,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '一个安静的私人社交空间。\n账号与身份由你自己掌握。',
                    style: text.bodyLarge?.copyWith(
                      color: AppColors.surface.withValues(alpha: 0.76),
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxl + AppSpacing.md),
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: AppColors.surface.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          AuthShell.sessionHint,
                          style: text.bodySmall?.copyWith(
                            color: AppColors.surface.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Orb extends StatelessWidget {
  const _Orb({required this.size, required this.opacity});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surface.withValues(alpha: opacity),
        ),
      ),
    );
  }
}
