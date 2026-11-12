import 'dart:typed_data';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';

const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

void main() {
  late FakeProfileGateway gateway;
  late int logoutCalls;

  setUp(() {
    gateway = FakeProfileGateway();
    logoutCalls = 0;
  });

  Future<void> pumpHost(
    WidgetTester tester, {
    required Size size,
    List<DisplayFeature> features = const <DisplayFeature>[],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(displayFeatures: features),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => openProfilePanel(
                  context,
                  gateway: gateway,
                  user: _user,
                  onLogout: () async {
                    logoutCalls += 1;
                    return const LogoutResult(serverNotified: true);
                  },
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
  }

  testWidgets('narrow viewport uses the full-screen mobile presentation', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, size: const Size(390, 844));

    final ProfilePanel panel = tester.widget<ProfilePanel>(
      find.byType(ProfilePanel),
    );
    expect(panel.mode, ProfilePanelMode.mobile);
    final Size panelSize = tester.getSize(find.byKey(ProfilePanel.panelKey));
    expect(panelSize.width, closeTo(390, 0.1));
    expect(panelSize.height, closeTo(844, 0.1));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide desktop viewport uses a floating card, not full screen', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, size: const Size(1280, 900));

    final ProfilePanel panel = tester.widget<ProfilePanel>(
      find.byType(ProfilePanel),
    );
    expect(panel.mode, ProfilePanelMode.desktop);
    final Size panelSize = tester.getSize(find.byKey(ProfilePanel.panelKey));
    expect(panelSize.width, lessThanOrEqualTo(440));
    expect(panelSize.width, lessThan(1280));
    final ModalBarrier barrier = tester.widget<ModalBarrier>(
      find.byType(ModalBarrier).first,
    );
    expect(
      barrier.color == null || barrier.color == Colors.transparent,
      isTrue,
      reason: 'no dark backdrop',
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flat fold uses the left half and blurs the right half', (
    WidgetTester tester,
  ) async {
    await pumpHost(
      tester,
      size: const Size(1024, 768),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(512, 0, 0, 768),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );

    final ProfilePanel panel = tester.widget<ProfilePanel>(
      find.byType(ProfilePanel),
    );
    expect(panel.mode, ProfilePanelMode.folded);
    final Size panelSize = tester.getSize(find.byKey(ProfilePanel.panelKey));
    expect(panelSize.width, closeTo(512, 0.1));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a non-flat hinge does not select the folded layout', (
    WidgetTester tester,
  ) async {
    await pumpHost(
      tester,
      size: const Size(1024, 768),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(512, 0, 0, 768),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );
    final ProfilePanel panel = tester.widget<ProfilePanel>(
      find.byType(ProfilePanel),
    );
    expect(panel.mode, ProfilePanelMode.desktop);
  });

  testWidgets('nickname edit trims, saves and updates the panel', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(ProfilePanel.editNicknameKey));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      '  新昵称  ',
    );
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();

    expect(gateway.patches.single.setUsername, isTrue);
    expect(gateway.patches.single.username, '新昵称');
    expect(find.text('新昵称'), findsOneWidget);
  });

  testWidgets('signature can be cleared from the editor', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(ProfilePanel.editSignatureKey));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('profile-edit-field')), '   ');
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();

    expect(gateway.patches.single.setSignature, isTrue);
    expect(gateway.profile.signature, isNull);
    expect(find.text('还没有签名'), findsOneWidget);
  });

  testWidgets('avatar dialog routes base64 through the client gateway', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, size: const Size(390, 844));
    await tester.tap(find.text('更换头像').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Base64'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('avatar-source-field')),
      'data:image/png;base64,AAAA',
    );
    await tester.tap(find.byKey(const Key('avatar-source-apply')));
    await tester.pumpAndSettle();

    expect(gateway.avatarSources.single, startsWith('base64:'));
    expect(find.text('头像已更新'), findsOneWidget);
  });

  testWidgets('logout calls the server logout path and closes the panel', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(ProfilePanel.logoutButtonKey));
    await tester.pumpAndSettle();

    expect(logoutCalls, 1);
    expect(find.byType(ProfilePanel), findsNothing);
  });

  testWidgets('opening the panel revalidates profile and avatar', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, size: const Size(1280, 900));
    expect(gateway.loadProfileCalls, 1);
    expect(gateway.loadAvatarCalls, 1);
    // The avatar bytes are rendered, never an invented default.
    expect(find.byType(Image), findsOneWidget);
    expect(gateway.avatar, isNotEmpty);
    expect(Uint8List.fromList(gateway.avatar).isNotEmpty, isTrue);
  });
  testWidgets('QA open panel reflows on live metrics change', (tester) async {
    await pumpHost(tester, size: const Size(1280, 900));
    expect(
      tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
      ProfilePanelMode.desktop,
    );
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
      ProfilePanelMode.mobile,
    );
    expect(
      tester.getSize(find.byKey(ProfilePanel.panelKey)).width,
      closeTo(390, 0.1),
    );
    expect(tester.takeException(), isNull);
  });
}
