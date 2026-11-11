import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_profile_gateway.dart';

/// Renders the three Profile presentations to PNG evidence.
///
/// Opt-in because it writes files: run with
/// `QA_SCREENSHOT_DIR=.qa-artifacts/screenshots QA_CJK_FONT=/path/font.ttf
///  flutter test test/profile_screenshot_test.dart`.
///
/// These are widget-test renders, not Android/Windows runtime screenshots.
void main() {
  final String? outputDir = Platform.environment['QA_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? avatarPath = Platform.environment['QA_AVATAR_PNG'];
  final String? skipReason = outputDir == null
      ? 'QA_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture narrow, wide and folded Profile presentations', (
    WidgetTester tester,
  ) async {
    final Directory directory = Directory(outputDir!);
    directory.createSync(recursive: true);
    if (fontPath != null && File(fontPath).existsSync()) {
      final Uint8List fontBytes = File(fontPath).readAsBytesSync();
      await tester.runAsync(() async {
        // Widget tests default to Ahem (boxes); register the real CJK face for
        // both the default family and Ahem so explicitly-styled buttons inherit
        // it too.
        for (final String family in <String>['Roboto', 'Ahem']) {
          await (FontLoader(family)..addFont(
                Future<ByteData>.value(ByteData.view(fontBytes.buffer)),
              ))
              .load();
        }
      });
    }
    if (iconFontPath != null && File(iconFontPath).existsSync()) {
      final Uint8List iconBytes = File(iconFontPath).readAsBytesSync();
      await tester.runAsync(() async {
        await (FontLoader(
              'MaterialIcons',
            )..addFont(Future<ByteData>.value(ByteData.view(iconBytes.buffer))))
            .load();
      });
    }
    final FakeProfileGateway gateway = FakeProfileGateway();
    if (avatarPath != null && File(avatarPath).existsSync()) {
      gateway.avatar = File(avatarPath).readAsBytesSync();
    }
    final GlobalKey boundaryKey = GlobalKey();
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
    final FakeAuthGateway auth = FakeAuthGateway();

    Future<void> pumpAt(
      Size size, {
      List<DisplayFeature> features = const <DisplayFeature>[],
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      // Drop the previous MaterialApp (and any open dialog route) so scenarios
      // cannot leak route state into each other.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _screenshotTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(size: size, displayFeatures: features),
              child: child!,
            ),
            home: HomeView(
              user: const AuthUser(
                account: '40218765',
                username: 'muse.tester',
              ),
              profile: gateway,
              auth: auth,
              heartbeat: heartbeat,
              onSignedOut: (LogoutResult? _) {},
              onSessionExpired: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      // Golden capture lets the test framework rasterize; calling
      // RenderRepaintBoundary.toImage directly deadlocks under the fake async
      // clock used by widget tests.
      await expectLater(
        find.byKey(boundaryKey),
        matchesGoldenFile('../.qa-artifacts/screenshots/$name'),
      );
    }

    await pumpAt(const Size(390, 844));
    await capture('profile-home-narrow.png');
    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsOneWidget);
    await capture('profile-panel-narrow.png');
    expect(tester.takeException(), isNull);

    await pumpAt(const Size(1440, 900));
    await capture('profile-home-wide.png');
    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsOneWidget);
    await capture('profile-panel-wide.png');
    expect(tester.takeException(), isNull);

    await pumpAt(
      const Size(1024, 768),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(512, 0, 0, 768),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    await capture('profile-panel-folded.png');
    expect(tester.takeException(), isNull);

    for (final String name in <String>[
      'profile-home-narrow.png',
      'profile-panel-narrow.png',
      'profile-home-wide.png',
      'profile-panel-wide.png',
      'profile-panel-folded.png',
    ]) {
      expect(
        File('${directory.path}${Platform.pathSeparator}$name').existsSync(),
        isTrue,
      );
    }
  }, skip: skipReason != null);
}

/// App theme with the button-label font family pinned for the renderer.
///
/// Widget tests resolve an unstyled `fontFamily` to Ahem (box glyphs), while
/// production resolves it to the platform font. The screenshot renderer pins
/// the real CJK family loaded above.
ThemeData _screenshotTheme() {
  final ThemeData base = buildAppTheme();
  TextStyle label(double size, FontWeight weight, [double spacing = 0]) {
    return TextStyle(
      fontFamily: 'Roboto',
      fontSize: size,
      fontWeight: weight,
      letterSpacing: spacing,
      color: AppColors.surface,
    );
  }

  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle>(
          label(16, FontWeight.w600, 0.1),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle>(
          label(15.5, FontWeight.w600).copyWith(color: AppColors.accentDeep),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle>(
          label(14.5, FontWeight.w600).copyWith(color: AppColors.accent),
        ),
      ),
    ),
  );
}
