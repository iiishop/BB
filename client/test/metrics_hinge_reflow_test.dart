import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';

const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

/// QA-465-03 follow-up: a flat hinge appearing, moving or disappearing while
/// the panel is already open must reflow immediately, not only on reopen.
void main() {
  testWidgets('flat hinge add/move/remove reflows an open Profile panel', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final ValueNotifier<List<DisplayFeature>> features =
        ValueNotifier<List<DisplayFeature>>(const <DisplayFeature>[]);
    addTearDown(features.dispose);
    final FakeProfileGateway gateway = FakeProfileGateway();

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

    ProfilePanel panel() =>
        tester.widget<ProfilePanel>(find.byType(ProfilePanel));
    expect(panel().mode, ProfilePanelMode.desktop);

    features.value = <DisplayFeature>[
      DisplayFeature(
        bounds: const Rect.fromLTWH(512, 0, 0, 768),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    await tester.pumpAndSettle();
    expect(panel().mode, ProfilePanelMode.folded);
    expect(
      tester.getSize(find.byKey(ProfilePanel.panelKey)).width,
      closeTo(512, 0.1),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);

    features.value = <DisplayFeature>[
      DisplayFeature(
        bounds: const Rect.fromLTWH(420, 0, 0, 768),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    await tester.pumpAndSettle();
    expect(panel().mode, ProfilePanelMode.folded);
    expect(
      tester.getSize(find.byKey(ProfilePanel.panelKey)).width,
      closeTo(420, 0.1),
    );

    features.value = const <DisplayFeature>[];
    await tester.pumpAndSettle();
    expect(panel().mode, ProfilePanelMode.desktop);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
