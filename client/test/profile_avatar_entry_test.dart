import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';
import 'support/phone_profile.dart';

/// DEA-482: the avatar source dialog must offer platform-appropriate entry
/// points. Desktop keeps the path field but gains a native "选择图片" button;
/// Android replaces the path field with an explicit "从相册选择" entry.
///
/// `defaultTargetPlatform` is Android in widget tests, so each case pins the
/// platform explicitly and restores it before the test body ends.
const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

void main() {
  late FakeProfileGateway gateway;

  setUp(() {
    gateway = FakeProfileGateway();
  });

  Future<void> openAvatarDialog(
    WidgetTester tester, {
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => openProfilePanel(
                  context,
                  gateway: gateway,
                  user: _user,
                  onLogout: () async =>
                      const LogoutResult(serverNotified: true),
                ),
                child: const Text('open-profile'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();
    await openProfileEditSheet(tester);
    await tester.tap(find.text('更换头像').first);
    await tester.pumpAndSettle();
  }

  testWidgets('desktop path entry keeps the field and adds a native picker', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await openAvatarDialog(tester, size: const Size(1280, 900));

      expect(find.byKey(const Key('avatar-source-field')), findsOneWidget);
      expect(find.byKey(const Key('avatar-pick-file')), findsOneWidget);
      expect(find.text('选择图片'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('android entry replaces the path field with a gallery picker', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await openAvatarDialog(tester, size: const Size(390, 844));

      expect(find.byKey(const Key('avatar-pick-gallery')), findsOneWidget);
      expect(find.text('从相册选择'), findsOneWidget);
      expect(find.byKey(const Key('avatar-source-field')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the dialog previews the selected image before confirmation', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await openAvatarDialog(tester, size: const Size(1280, 900));

      expect(find.byKey(const Key('avatar-preview')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
