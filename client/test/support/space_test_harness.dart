import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_space_gateway.dart';

const Size spacePhone = Size(390, 844);
const Size spaceWide = Size(1440, 900);
const Size spaceFold = Size(1024, 768);

DisplayFeature verticalHinge(double x, double height) => DisplayFeature(
  bounds: Rect.fromLTWH(x, 0, 0, height),
  type: DisplayFeatureType.hinge,
  state: DisplayFeatureState.postureFlat,
);

DisplayFeature horizontalHinge(double y, double width) => DisplayFeature(
  bounds: Rect.fromLTWH(0, y, width, 0),
  type: DisplayFeatureType.hinge,
  state: DisplayFeatureState.postureFlat,
);

/// Pumps the Space surface at an explicit logical size. Tests use this instead
/// of the default 800×600 so phone/PC/fold behaviour is the same code path as
/// the device would take.
Future<void> pumpSpacePage(
  WidgetTester tester, {
  required FakeSpaceGateway gateway,
  ProfileGateway? profile,
  Size size = spacePhone,
  List<DisplayFeature> features = const <DisplayFeature>[],
  bool settle = true,
  Key? pageKey,
  void Function()? onSessionExpired,
  Duration? pollInterval,
  bool autoPoll = false,
  SpaceLocalStore? store,
  bool remount = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (remount) {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(size: size, displayFeatures: features),
        child: child!,
      ),
      home: Scaffold(
        body: SpacePage(
          key: pageKey,
          gateway: gateway,
          store: store ?? SpaceLocalStore(scopeKey: gateway.scopeKey),
          profile: profile,
          onSessionExpired: onSessionExpired,
          pollInterval: pollInterval,
          autoPoll: autoPoll,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}
