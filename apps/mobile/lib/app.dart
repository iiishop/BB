import 'package:flutter/material.dart';

import 'pipeline_smoke_page.dart';

/// Spacing scale shared by the Flutter client. Keep new screens on these
/// steps so the mobile surface stays visually consistent as modules land.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// Corner radii shared by the Flutter client.
abstract final class AppRadius {
  static const double brand = 14;
  static const double button = 16;
  static const double card = 20;
}

/// Named colors used by the smoke page. A social surface, not a dashboard:
/// warm paper, ink text and a single teal accent.
abstract final class AppColors {
  static const Color paper = Color(0xFFF7F5F1);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF161D1E);
  static const Color inkMuted = Color(0xFF5C6A6B);
  static const Color border = Color(0xFFE2DED7);
  static const Color accent = Color(0xFF0E6F68);
  static const Color accentDeep = Color(0xFF0A4F4A);
  static const Color success = Color(0xFF1F7A4D);
  static const Color successSurface = Color(0xFFE9F4ED);
  static const Color successBorder = Color(0xFFB9DCC7);
}

/// Material 3 theme for the BB mobile client.
ThemeData buildAppTheme() {
  final ColorScheme scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.accent,
        onPrimary: AppColors.surface,
        surface: AppColors.paper,
        onSurface: AppColors.ink,
        outline: AppColors.border,
        outlineVariant: AppColors.border,
      );
  final TextTheme base = ThemeData.light().textTheme;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.paper,
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.copyWith(
      headlineLarge: base.headlineLarge?.copyWith(
        color: AppColors.ink,
        fontSize: 38,
        height: 1.1,
        fontWeight: FontWeight.w700,
        letterSpacing: -1,
      ),
      titleLarge: base.titleLarge?.copyWith(
        color: AppColors.ink,
        fontSize: 22,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        color: AppColors.inkMuted,
        fontSize: 15.5,
        height: 1.55,
      ),
      bodySmall: base.bodySmall?.copyWith(
        color: AppColors.inkMuted,
        fontSize: 12.5,
        height: 1.5,
      ),
      labelSmall: base.labelSmall?.copyWith(
        color: AppColors.inkMuted,
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.surface,
        minimumSize: const Size.fromHeight(56),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
    ),
  );
}

/// Root widget for the BB mobile client.
class BbMobileApp extends StatelessWidget {
  const BbMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: PipelineSmokePage.title,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const PipelineSmokePage(),
    );
  }
}
