import 'package:flutter/material.dart';

import 'services/auth_service.dart';
import 'ui/auth_flow.dart';

/// Spacing scale shared by the Flutter client. Keep new screens on these
/// steps so the surface stays visually consistent as modules land.
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
  static const double field = 14;
  static const double button = 16;
  static const double card = 20;
  static const double panel = 28;
}

/// Named colors used across the client. A social surface, not a dashboard:
/// warm paper, ink text and a single teal accent.
abstract final class AppColors {
  static const Color paper = Color(0xFFF7F5F1);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF161D1E);
  static const Color inkMuted = Color(0xFF5C6A6B);
  static const Color border = Color(0xFFE2DED7);
  static const Color accent = Color(0xFF0E6F68);
  static const Color accentDeep = Color(0xFF0A4F4A);
  static const Color accentNight = Color(0xFF073B37);
  static const Color accentSoft = Color(0xFFE6F0EE);
  static const Color success = Color(0xFF1F7A4D);
  static const Color successSurface = Color(0xFFE9F4ED);
  static const Color successBorder = Color(0xFFB9DCC7);
  static const Color danger = Color(0xFFB3261E);
  static const Color dangerSurface = Color(0xFFFBEDEB);
  static const Color dangerBorder = Color(0xFFEFC9C4);
}

/// Material 3 theme for the BB client.
ThemeData buildAppTheme() {
  final ColorScheme scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.accent,
        onPrimary: AppColors.surface,
        secondary: AppColors.accentDeep,
        surface: AppColors.paper,
        onSurface: AppColors.ink,
        error: AppColors.danger,
        outline: AppColors.border,
        outlineVariant: AppColors.border,
      );
  final TextTheme base = ThemeData.light().textTheme;
  final OutlineInputBorder idleBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.field),
    borderSide: const BorderSide(color: AppColors.border),
  );
  final OutlineInputBorder focusedBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.field),
    borderSide: const BorderSide(color: AppColors.accent, width: 1.6),
  );
  final OutlineInputBorder errorBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.field),
    borderSide: const BorderSide(color: AppColors.danger, width: 1.4),
  );

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
      headlineMedium: base.headlineMedium?.copyWith(
        color: AppColors.ink,
        fontSize: 28,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: base.titleLarge?.copyWith(
        color: AppColors.ink,
        fontSize: 22,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleMedium: base.titleMedium?.copyWith(
        color: AppColors.ink,
        fontSize: 16.5,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        color: AppColors.inkMuted,
        fontSize: 15.5,
        height: 1.55,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        color: AppColors.ink,
        fontSize: 14.5,
        height: 1.5,
      ),
      bodySmall: base.bodySmall?.copyWith(
        color: AppColors.inkMuted,
        fontSize: 12.5,
        height: 1.5,
      ),
      labelLarge: base.labelLarge?.copyWith(
        color: AppColors.ink,
        fontSize: 14.5,
        height: 1.2,
        fontWeight: FontWeight.w600,
      ),
      labelSmall: base.labelSmall?.copyWith(
        color: AppColors.inkMuted,
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md + AppSpacing.xs,
      ),
      border: idleBorder,
      enabledBorder: idleBorder,
      focusedBorder: focusedBorder,
      errorBorder: errorBorder,
      focusedErrorBorder: errorBorder,
      labelStyle: const TextStyle(
        color: AppColors.inkMuted,
        fontSize: 14.5,
        fontWeight: FontWeight.w500,
      ),
      floatingLabelStyle: const TextStyle(
        color: AppColors.accent,
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
      ),
      hintStyle: const TextStyle(color: AppColors.inkMuted, fontSize: 14.5),
      errorStyle: const TextStyle(
        color: AppColors.danger,
        fontSize: 12.5,
        height: 1.4,
      ),
      errorMaxLines: 3,
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
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accentDeep,
        minimumSize: const Size.fromHeight(52),
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.ink,
      contentTextStyle: const TextStyle(color: AppColors.surface, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.brand),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: AppColors.inkMuted,
        minimumSize: const Size(48, 48),
      ),
    ),
  );
}

/// Root widget for the BB client.
class BbClientApp extends StatelessWidget {
  const BbClientApp({super.key, required this.authGateway});

  final AuthGateway authGateway;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BB',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AuthFlow(gateway: authGateway),
    );
  }
}
