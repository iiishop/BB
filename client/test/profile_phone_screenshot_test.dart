import 'dart:io';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
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

/// PNG evidence for DEA-492 at the real phone viewport (390 x 844, DPR 1).
///
/// Opt-in because it writes files:
/// `QA_SCREENSHOT_DIR=.qa-artifacts/screenshots/dea492
///  QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc
///  QA_ICON_FONT=.../MaterialIcons-Regular.otf
///  QA_AVATAR_PNG=test/fixtures/avatars/10000001.png
///  flutter test --update-goldens test/profile_phone_screenshot_test.dart`
///
/// These are widget-test renders at the target viewport, not Android device
/// captures; the real-runtime evidence is recorded separately.
void main() {
  final String? outputDir = Platform.environment['QA_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? avatarPath = Platform.environment['QA_AVATAR_PNG'];
  final String? skipReason = outputDir == null
      ? 'QA_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture the phone Profile states at 390 x 844', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      await _loadFonts(fontPath, iconFontPath);
    });
    final FakeProfileGateway gateway = FakeProfileGateway();
    if (avatarPath != null && File(avatarPath).existsSync()) {
      gateway.avatar = File(avatarPath).readAsBytesSync();
    }
    final GlobalKey boundary = GlobalKey();
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession()..establish(token: 'shot', user: _shotUser),
      ),
    );
    addTearDown(heartbeat.dispose);

    // Widget tests decode images on the real event loop; without this the
    // avatar would be captured before its bytes had been decoded.
    Future<void> settleImages() async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
    }

    Future<void> pumpPhone({Profile? profile, double textScale = 1}) async {
      if (profile != null) {
        gateway.profile = profile;
      }
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _screenshotTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: const Size(390, 844),
                textScaler: TextScaler.linear(textScale),
              ),
              child: child!,
            ),
            home: HomeView(
              user: _shotUser,
              profile: gateway,
              auth: FakeAuthGateway(),
              heartbeat: heartbeat,
              onSignedOut: (LogoutResult? _) {},
              onSessionExpired: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HomeView.avatarEntryKey));
      await tester.pumpAndSettle();
      await settleImages();
      expect(find.byType(ProfilePanel), findsOneWidget);
    }

    Future<void> capture(String name) async {
      await expectLater(
        find.byKey(boundary),
        matchesGoldenFile('../$outputDir/$name'),
      );
    }

    // 1. Requested profile, own photo, signature present.
    await pumpPhone();
    await capture('01-profile-phone-default.png');

    // 2. No signature yet (explicit empty state, not invented text).
    await pumpPhone(
      profile: const Profile(
        account: '40218765',
        username: 'muse.tester',
        signature: null,
        avatarUrl: '/avatars/40218765.png',
        avatarVersion: 'v1',
      ),
    );
    await capture('02-profile-phone-no-signature.png');

    // 3. The longest values the contract allows.
    await pumpPhone(
      profile: const Profile(
        account: '40218765',
        username: '一二三四五六七八九十一二三四五六七八九十',
        signature: '这一行签名写得很长很长，用来确认它会换行显示，并且不会盖住下面的编辑资料按钮和个人主页按钮。',
        avatarUrl: '/avatars/40218765.png',
        avatarVersion: 'v1',
      ),
    );
    await capture('03-profile-phone-long-text.png');

    // 4. System text at 200 %.
    await pumpPhone(
      profile: const Profile(
        account: '40218765',
        username: 'muse.tester',
        signature: '把日子过成自己的节奏。',
        avatarUrl: '/avatars/40218765.png',
        avatarVersion: 'v1',
      ),
      textScale: 2,
    );
    await capture('04-profile-phone-large-text.png');

    // 5. Edit entry: the actions the old inline list carried.
    await pumpPhone();
    await tester.tap(find.byKey(ProfilePanel.editProfileKey));
    await tester.pumpAndSettle();
    await capture('05-profile-phone-edit-sheet.png');
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    // 6. Rim sweep in progress, photo upright, then the resting page.
    await tester.tap(find.byKey(ProfilePanel.closeButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 360));
    await tester.pump(const Duration(milliseconds: 120));
    await capture('06-profile-phone-ring-mid.png');
    await tester.pumpAndSettle();
    await capture('07-profile-phone-ring-rest.png');

    // 7. Avatar in flight from the messages entry, and after landing.
    await tester.tap(find.byKey(ProfilePanel.closeButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HomeView.avatarEntryKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await capture('08-profile-phone-avatar-flight.png');
    await tester.pumpAndSettle();
    await capture('09-profile-phone-landed.png');

    for (final String name in <String>[
      '01-profile-phone-default.png',
      '02-profile-phone-no-signature.png',
      '03-profile-phone-long-text.png',
      '04-profile-phone-large-text.png',
      '05-profile-phone-edit-sheet.png',
      '06-profile-phone-ring-mid.png',
      '07-profile-phone-ring-rest.png',
      '08-profile-phone-avatar-flight.png',
      '09-profile-phone-landed.png',
    ]) {
      expect(
        File('$outputDir${Platform.pathSeparator}$name').existsSync(),
        isTrue,
        reason: '$name was not written',
      );
    }
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);
}

const AuthUser _shotUser = AuthUser(
  account: '40218765',
  username: 'muse.tester',
);

Future<void> _loadFonts(String? fontPath, String? iconFontPath) async {
  if (fontPath != null && File(fontPath).existsSync()) {
    final Uint8List bytes = File(fontPath).readAsBytesSync();
    for (final String family in <String>['Roboto', 'Ahem']) {
      await (FontLoader(
        family,
      )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)))).load();
    }
  }
  if (iconFontPath != null && File(iconFontPath).existsSync()) {
    final Uint8List bytes = File(iconFontPath).readAsBytesSync();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)))).load();
  }
}

/// Same pinned button-label font as the existing Profile screenshot test: an
/// unstyled family resolves to Ahem (boxes) in the widget-test renderer.
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
