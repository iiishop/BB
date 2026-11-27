import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';
import 'support/phone_profile.dart';

const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

/// QA-465-05 follow-up: the exit animation must use the same live mode as the
/// panel content. These tests assert an intermediate frame, not just disposal.
void main() {
  late FakeProfileGateway gateway;

  setUp(() {
    gateway = FakeProfileGateway();
  });

  Future<ValueNotifier<List<DisplayFeature>>> pumpHost(
    WidgetTester tester, {
    Size size = const Size(1024, 768),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ValueNotifier<List<DisplayFeature>> features =
        ValueNotifier<List<DisplayFeature>>(const <DisplayFeature>[]);
    addTearDown(features.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<List<DisplayFeature>>(
        valueListenable: features,
        builder: (BuildContext context, List<DisplayFeature> value, Widget? _) {
          return MaterialApp(
            theme: buildAppTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(displayFeatures: value),
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
                      onLogout: () async =>
                          const LogoutResult(serverNotified: true),
                    ),
                    child: const Text('open-profile'),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();
    return features;
  }

  ProfilePanel panel(WidgetTester tester) =>
      tester.widget<ProfilePanel>(find.byType(ProfilePanel));

  double panelX(WidgetTester tester) =>
      tester.getTopLeft(find.byKey(ProfilePanel.panelKey)).dx;

  Future<void> dismissAndPumpFrame(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(ProfilePanel))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> reflow(
    WidgetTester tester,
    ValueNotifier<List<DisplayFeature>> features,
    ProfilePanelMode mode,
  ) async {
    tester.view.physicalSize = mode == ProfilePanelMode.mobile
        ? const Size(390, 844)
        : const Size(1024, 768);
    features.value = mode == ProfilePanelMode.folded
        ? <DisplayFeature>[
            DisplayFeature(
              bounds: const Rect.fromLTWH(512, 0, 0, 768),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureFlat,
            ),
          ]
        : const <DisplayFeature>[];
    await tester.pumpAndSettle();
    expect(panel(tester).mode, mode);
  }

  for (final ProfilePanelMode from in ProfilePanelMode.values) {
    for (final ProfilePanelMode to in ProfilePanelMode.values) {
      if (from == to) continue;
      testWidgets('edit menu selection survives $from to $to', (
        WidgetTester tester,
      ) async {
        final features = await pumpHost(tester);
        await reflow(tester, features, from);
        final Object originalState = tester.state(find.byType(ProfilePanel));
        final int profileReads = gateway.loadProfileCalls;
        final int avatarReads = gateway.loadAvatarCalls;
        final int coverReads = gateway.loadCoverCalls;
        await openProfileEditSheet(tester);
        await reflow(tester, features, to);
        await tester.ensureVisible(find.byKey(ProfilePanel.editSignatureKey));
        await tester.tap(find.byKey(ProfilePanel.editSignatureKey));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('profile-edit-field')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('profile-edit-field')),
          '菜单跨形态保存',
        );
        await tester.tap(find.byKey(const Key('profile-edit-save')));
        await tester.pumpAndSettle();
        expect(gateway.patches.single.signature, '菜单跨形态保存');
        expect(find.text('菜单跨形态保存'), findsOneWidget);
        expect(tester.state(find.byType(ProfilePanel)), same(originalState));
        expect(gateway.loadProfileCalls, profileReads);
        expect(gateway.loadAvatarCalls, avatarReads);
        expect(gateway.loadCoverCalls, coverReads);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('an open signature editor saves after switching presentation', (
    WidgetTester tester,
  ) async {
    final features = await pumpHost(tester);
    await openProfileEditSheet(tester);
    await tester.tap(find.byKey(ProfilePanel.editSignatureKey));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      '编辑中展开',
    );
    await reflow(tester, features, ProfilePanelMode.folded);
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();
    expect(gateway.patches.single.signature, '编辑中展开');
    expect(find.text('编辑中展开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flat hinge appears then closes with a left slide', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<List<DisplayFeature>> features = await pumpHost(tester);
    expect(panel(tester).mode, ProfilePanelMode.desktop);

    features.value = <DisplayFeature>[
      DisplayFeature(
        bounds: const Rect.fromLTWH(512, 0, 0, 768),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    await tester.pumpAndSettle();
    expect(panel(tester).mode, ProfilePanelMode.folded);
    expect(
      tester.getSize(find.byKey(ProfilePanel.panelKey)).width,
      closeTo(512, 0.1),
    );

    final double before = panelX(tester);
    await dismissAndPumpFrame(tester);
    expect(
      panelX(tester),
      lessThan(before - 1),
      reason: 'folded dismissal must slide left',
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsNothing);
  });

  testWidgets('moving hinge keeps the left slide on close', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<List<DisplayFeature>> features = await pumpHost(tester);
    features.value = <DisplayFeature>[
      DisplayFeature(
        bounds: const Rect.fromLTWH(512, 0, 0, 768),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    await tester.pumpAndSettle();
    features.value = <DisplayFeature>[
      DisplayFeature(
        bounds: const Rect.fromLTWH(420, 0, 0, 768),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    await tester.pumpAndSettle();
    expect(panel(tester).mode, ProfilePanelMode.folded);
    expect(
      tester.getSize(find.byKey(ProfilePanel.panelKey)).width,
      closeTo(420, 0.1),
    );

    final double before = panelX(tester);
    await dismissAndPumpFrame(tester);
    expect(panelX(tester), lessThan(before - 1));
    await tester.pumpAndSettle();
  });

  testWidgets('hinge disappears back to desktop and closes with card motion', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<List<DisplayFeature>> features = await pumpHost(tester);
    features.value = <DisplayFeature>[
      DisplayFeature(
        bounds: const Rect.fromLTWH(512, 0, 0, 768),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    await tester.pumpAndSettle();
    expect(panel(tester).mode, ProfilePanelMode.folded);
    features.value = const <DisplayFeature>[];
    await tester.pumpAndSettle();
    expect(panel(tester).mode, ProfilePanelMode.desktop);

    final double before = panelX(tester);
    await dismissAndPumpFrame(tester);
    // Desktop is fade+scale around the centre: it must not translate left like
    // the mobile/folded slide.
    expect(
      panelX(tester),
      greaterThanOrEqualTo(before - 0.5),
      reason: 'desktop card must keep its fade/scale exit, not a stale slide',
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsNothing);
  });

  testWidgets('edits survive a desktop-to-mobile reflow before dismissal', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, size: const Size(1280, 900));
    expect(panel(tester).mode, ProfilePanelMode.desktop);

    await openProfileEditSheet(tester);
    await tester.tap(find.byKey(ProfilePanel.editSignatureKey));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      '跨形态签名',
    );
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();
    expect(gateway.profile.signature, '跨形态签名');

    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(panel(tester).mode, ProfilePanelMode.mobile);
    expect(find.text('跨形态签名'), findsWidgets);

    await openProfileEditSheet(tester);
    await tester.tap(find.byKey(ProfilePanel.editNicknameKey));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      '跨形态昵称',
    );
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();
    expect(find.text('跨形态昵称'), findsWidgets);
    expect(tester.takeException(), isNull);

    final double before = panelX(tester);
    await dismissAndPumpFrame(tester);
    expect(panelX(tester), lessThan(before - 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
